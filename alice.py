"""Управление Яндекс Станцией по локальному протоколу glagol."""
import asyncio
import json
import logging
import os
import ssl
import time
import uuid

import aiohttp
import certifi
import websockets
from zeroconf import ServiceStateChange
from zeroconf.asyncio import AsyncServiceBrowser, AsyncZeroconf

log = logging.getLogger("alice")

API = "https://quasar.yandex.net/glagol"
MDNS_TYPE = "_yandexio._tcp.local."
STATION_PORT = 1961
DEFAULT_TEMPLATE = "Поставь будильник через {minutes} {minutes_word} на песню {song}"
HTTP_TIMEOUT = aiohttp.ClientTimeout(total=15)
# Python с python.org на macOS не видит системные сертификаты — берём из certifi
SSL_CTX = ssl.create_default_context(cafile=certifi.where())


class AliceError(Exception):
    """Понятная пользователю ошибка (без трейсбека)."""


def _token() -> str:
    t = os.getenv("YANDEX_TOKEN", "").strip()
    if not t:
        raise AliceError("Не задан YANDEX_TOKEN (см. .env.example и README)")
    return t


def _minutes_word(n: int) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return "минуту"
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return "минуты"
    return "минут"


async def _get(session: aiohttp.ClientSession, path: str, **params) -> dict:
    headers = {"Authorization": f"Oauth {_token()}"}
    try:
        async with session.get(f"{API}/{path}", headers=headers, params=params) as r:
            if r.status in (401, 403):
                raise AliceError("Яндекс отклонил токен (401/403): YANDEX_TOKEN неверный или просрочен")
            if r.status != 200:
                raise AliceError(f"Яндекс API {path}: HTTP {r.status}: {(await r.text())[:200]}")
            return await r.json()
    except (aiohttp.ClientError, asyncio.TimeoutError) as e:
        raise AliceError(f"Нет связи с quasar.yandex.net: {e!r}")


async def list_devices() -> list[dict]:
    async with aiohttp.ClientSession(timeout=HTTP_TIMEOUT, connector=aiohttp.TCPConnector(ssl=SSL_CTX)) as s:
        data = await _get(s, "device_list")
    return data.get("devices", [])


async def discover_stations(timeout: float = 4.0) -> dict[str, str]:
    """mDNS: {deviceId: ip} для всех станций в локальной сети."""
    found: dict[str, str] = {}
    azc = AsyncZeroconf()
    pending: list[asyncio.Task] = []

    async def resolve(name: str):
        info = await azc.async_get_service_info(MDNS_TYPE, name, 3000)
        if not info:
            return
        txt = {(k.decode() if isinstance(k, bytes) else k): (v.decode() if isinstance(v, bytes) else v)
               for k, v in info.properties.items()}
        addrs = info.parsed_addresses()
        if txt.get("deviceId") and addrs:
            found[txt["deviceId"]] = addrs[0]

    def on_change(zeroconf, service_type, name, state_change):
        if state_change in (ServiceStateChange.Added, ServiceStateChange.Updated):
            pending.append(asyncio.ensure_future(resolve(name)))

    browser = AsyncServiceBrowser(azc.zeroconf, MDNS_TYPE, handlers=[on_change])
    try:
        await asyncio.sleep(timeout)
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
    finally:
        await browser.async_cancel()
        await azc.async_close()
    return found


async def _pick_device(devices: list[dict]) -> dict:
    if not devices:
        raise AliceError("На аккаунте Яндекса нет устройств (колонка привязана к другому аккаунту?)")
    want = os.getenv("STATION_DEVICE_ID", "").strip()
    if want:
        for d in devices:
            if d["id"] == want:
                return d
        raise AliceError(f"Устройство {want} не найдено среди устройств аккаунта")
    if len(devices) > 1:
        log.warning("На аккаунте несколько устройств, беру первое (%s). "
                    "Задайте STATION_DEVICE_ID.", devices[0].get("name"))
    return devices[0]


async def _resolve_station() -> tuple[str, str]:
    """Возвращает (ip, conversationToken)."""
    devices = await list_devices()
    dev = await _pick_device(devices)
    async with aiohttp.ClientSession(timeout=HTTP_TIMEOUT, connector=aiohttp.TCPConnector(ssl=SSL_CTX)) as s:
        data = await _get(s, "token", device_id=dev["id"], platform=dev["platform"])
    token = data.get("token")
    if not token:
        raise AliceError(f"Яндекс не вернул conversationToken: {data}")

    ip = os.getenv("STATION_IP", "").strip()
    if not ip:
        log.info("STATION_IP не задан, ищу станцию через mDNS...")
        ip = (await discover_stations()).get(dev["id"], "")
    if not ip:
        raise AliceError("Станция не найдена в сети по mDNS. Проверьте, что компьютер и станция "
                         "в одной Wi-Fi сети, или задайте STATION_IP")
    log.info("Станция %r: %s", dev.get("name"), ip)
    return ip, token


def _msg(token: str, payload: dict) -> str:
    return json.dumps({
        "conversationToken": token,
        "id": str(uuid.uuid4()),
        "sentTime": int(time.time() * 1000),
        "payload": payload,
    })


async def _send(ws, token: str, payload: dict, listen: float = 2.0) -> None:
    """Отправить команду и залогировать всё, что станция ответит за `listen` секунд."""
    await ws.send(_msg(token, payload))
    log.info("-> %s", payload)
    end = time.monotonic() + listen
    while (left := end - time.monotonic()) > 0:
        try:
            reply = await asyncio.wait_for(ws.recv(), left)
        except asyncio.TimeoutError:
            break
        log.info("<- %s", str(reply)[:500])


async def set_alarm(minutes: int, song: str, volume: float = 1.0,
                    text_template: str = DEFAULT_TEMPLATE) -> None:
    text = text_template.format(minutes=minutes, minutes_word=_minutes_word(minutes), song=song)
    ip, token = await _resolve_station()

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # у станции самоподписанный сертификат

    try:
        async with websockets.connect(f"wss://{ip}:{STATION_PORT}", ssl=ctx, open_timeout=10) as ws:
            await _send(ws, token, {"command": "setVolume", "volume": volume})
            await _send(ws, token, {"command": "sendText", "text": text}, listen=4.0)
    except (OSError, asyncio.TimeoutError, websockets.WebSocketException) as e:
        raise AliceError(f"Не удалось подключиться к станции {ip}:{STATION_PORT}: {e!r}")
    log.info("Команда отправлена: %s", text)
