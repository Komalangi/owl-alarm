"""Сова: слушает несколько Telegram-аккаунтов и Алиса читает вслух сообщения от выбранных людей.

Фраза всегда одна: «<Аккаунт>, тебе пишет <имя>: <текст>».
Настройки (аккаунты, задачи, вкл/выкл) лежат в watch.json, правятся через веб-интерфейс на 127.0.0.1:7781.
"""
import asyncio
import json
import logging
import os
import re
import time
import uuid
from collections import deque
from pathlib import Path

from aiohttp import web
from telethon import TelegramClient, events
from telethon.errors import (PhoneCodeExpiredError, PhoneCodeInvalidError, PhoneNumberInvalidError,
                             PasswordHashInvalidError, SessionPasswordNeededError)

import alice

log = logging.getLogger("sova")
HERE = Path(__file__).parent
STORE = HERE / "watch.json"
SESSIONS = HERE / "sessions"
UI = HERE / "ui.html"
PORT = 7781
MAX_TEXT = 280          # дальше Алиса говорит «и так далее»
CHARS_PER_SEC = 13      # примерная скорость речи, чтобы не перебивать саму себя


# ───────── хранилище ─────────

class Store:
    def __init__(self, path: Path = STORE):
        self.path = path
        data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        self.enabled: bool = data.get("enabled", True)
        self.volume: float | None = data.get("volume", 0.8)
        self.accounts: list[dict] = data.get("accounts", [])
        self.tasks: list[dict] = data.get("tasks", [])

    def save(self) -> None:
        data = {"enabled": self.enabled, "volume": self.volume, "accounts": self.accounts, "tasks": self.tasks}
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.path)

    def account(self, acc_id: str) -> dict:
        for a in self.accounts:
            if a["id"] == acc_id:
                return a
        raise web.HTTPNotFound(text="Нет такого аккаунта")

    def task(self, task_id: str) -> dict:
        for t in self.tasks:
            if t["id"] == task_id:
                return t
        raise web.HTTPNotFound(text="Нет такой задачи")


def norm(s) -> str:
    return str(s).strip().lstrip("@").lower()


def sender_keys(sender) -> set[str]:
    keys = set()
    for attr in ("username", "id", "first_name", "last_name"):
        v = getattr(sender, attr, None)
        if v:
            keys.add(norm(v))
    for u in getattr(sender, "usernames", None) or []:
        keys.add(norm(u.username))
    full = " ".join(p for p in (getattr(sender, "first_name", None), getattr(sender, "last_name", None)) if p)
    if full:
        keys.add(norm(full))
    return keys


# ───────── что говорить ─────────

URL_RE = re.compile(r"https?://\S+|www\.\S+")
JUNK_RE = re.compile(r"[^\w\s.,!?:;()«»\"'—–\-%№+=/]", re.UNICODE)


def media_word(msg) -> str | None:
    if msg.voice:
        return "голосовое сообщение"
    if msg.video_note:
        return "видеосообщение"
    if msg.sticker:
        return "стикер"
    if msg.gif:
        return "гифку"
    if msg.photo:
        return "фото"
    if msg.video:
        return "видео"
    if msg.audio:
        return "аудио"
    if msg.document:
        return "файл"
    if msg.contact:
        return "контакт"
    if msg.geo or msg.venue:
        return "геолокацию"
    if msg.poll:
        return "опрос"
    return None


def clean_text(text: str) -> str:
    text = URL_RE.sub(" ссылка ", text or "")
    text = JUNK_RE.sub(" ", text)          # эмодзи и прочие значки Алиса читает плохо
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT].rsplit(" ", 1)[0] + "… и так далее"
    return text


def phrase(account_label: str, name: str, msg) -> str:
    text = clean_text(msg.raw_text)
    media = media_word(msg)
    if media and text:
        body = f"{media}, {text}"
    elif media:
        body = media
    else:
        body = text or "пустое сообщение"
    return f"{account_label}, тебе пишет {name}: {body}"


# ───────── очередь речи ─────────

class Speaker:
    def __init__(self, store: Store):
        self.store = store
        self.queue: asyncio.Queue = asyncio.Queue()
        self.history: deque = deque(maxlen=30)
        self.station = {"name": None, "ok": False, "error": None, "configured": bool(os.getenv("YANDEX_TOKEN"))}
        self.checker: asyncio.Task | None = None

    def put(self, account: str, sender: str, text: str, spoken: str) -> None:
        self.queue.put_nowait((account, sender, text, spoken))

    def recheck(self) -> None:
        if self.checker:
            self.checker.cancel()
        self.station.update(name=None, ok=False, error=None, configured=bool(os.getenv("YANDEX_TOKEN")))
        self.checker = asyncio.create_task(self.check_station())

    async def run(self) -> None:
        self.recheck()
        while True:
            account, sender, text, spoken = await self.queue.get()
            item = {"time": time.strftime("%H:%M"), "account": account, "sender": sender,
                    "text": text, "ok": True, "error": None}
            try:
                await alice.say(spoken, self.store.volume)
                self.station.update(ok=True, error=None)
                await asyncio.sleep(2 + len(spoken) / CHARS_PER_SEC)
            except Exception as e:  # колонка не должна ронять сервис
                log.error("Не удалось озвучить: %s", e)
                item.update(ok=False, error=str(e))
                self.station.update(ok=False, error=str(e))
            self.history.appendleft(item)

    async def check_station(self) -> None:
        """Имя станции для интерфейса; при сбое (например, 429 от Яндекса) повторяем раз в 2 минуты."""
        while True:
            try:
                self.station["name"] = await alice.station_name()
                self.station.update(ok=True, error=None)
                return
            except Exception as e:
                self.station.update(ok=False, error=str(e))
            await asyncio.sleep(120)


# ───────── аккаунты Telegram ─────────

class Account:
    """Один аккаунт: свой клиент Telethon, вход по шагам, слушатель."""

    def __init__(self, cfg: dict, app: "Sova"):
        self.cfg = cfg
        self.app = app
        self.status = "connecting"
        self.login_step: str | None = None
        self.error: str | None = None
        self.phone_hash: str | None = None
        self.task: asyncio.Task | None = None
        self.client = TelegramClient(str(SESSIONS / cfg["id"]), int(os.environ["TG_API_ID"]),
                                     os.environ["TG_API_HASH"])
        self.client.add_event_handler(self.on_message, events.NewMessage(incoming=True))

    def state(self) -> dict:
        return {"id": self.cfg["id"], "label": self.cfg["label"], "username": self.cfg.get("username"),
                "phone": self.cfg.get("phone"), "status": self.status, "login_step": self.login_step,
                "error": self.error}

    def start(self) -> None:
        self.task = asyncio.create_task(self.run())

    async def stop(self) -> None:
        if self.task:
            self.task.cancel()
        await self.client.disconnect()

    async def run(self) -> None:
        delay = 5
        while True:
            try:
                self.status, self.error = "connecting", None
                await self.client.connect()
                if not await self.client.is_user_authorized():
                    self.status = "need_login"
                    self.login_step = self.login_step or ("code" if self.phone_hash else "phone")
                    return  # дальше ведёт login(); после входа run() стартует заново
                me = await self.client.get_me()
                if self.cfg.get("username") != me.username:
                    self.cfg["username"] = me.username
                    self.app.store.save()
                self.status, self.login_step, delay = "online", None, 5
                log.info("%s (@%s) слушаю", self.cfg["label"], me.username)
                await self.client.run_until_disconnected()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.error("%s: %r", self.cfg["label"], e)
                self.status, self.error = "error", str(e)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 300)

    async def login(self, body: dict) -> None:
        self.error = None
        try:
            await self.client.connect()
            if "phone" in body:
                self.cfg["phone"] = body["phone"].strip()
                self.app.store.save()
                sent = await self.client.send_code_request(self.cfg["phone"])
                self.phone_hash, self.login_step = sent.phone_code_hash, "code"
                return
            if "code" in body:
                try:
                    await self.client.sign_in(self.cfg["phone"], str(body["code"]).strip(),
                                              phone_code_hash=self.phone_hash)
                except SessionPasswordNeededError:
                    self.login_step = "password"
                    return
            elif "password" in body:
                await self.client.sign_in(password=body["password"])
            else:
                raise ValueError("Нужно phone, code или password")
        except (PhoneCodeInvalidError, PhoneCodeExpiredError):
            raise ValueError("Код неверный или просрочен")
        except PhoneNumberInvalidError:
            self.login_step = "phone"
            raise ValueError("Телефон неверный, формат +79991234567")
        except PasswordHashInvalidError:
            raise ValueError("Пароль 2FA неверный")
        self.login_step, self.phone_hash = None, None
        self.start()

    async def on_message(self, event) -> None:
        store = self.app.store
        if not store.enabled:
            return
        sender = await event.get_sender()
        if sender is None or getattr(sender, "bot", False):
            return
        keys = sender_keys(sender)
        for t in store.tasks:
            if not t.get("enabled", True) or t["account"] not in ("*", self.cfg["id"]):
                continue
            if norm(t["sender"]) in keys:
                spoken = phrase(self.cfg["label"], t["name"], event.message)
                log.info("%s ← %s: %s", self.cfg["label"], t["name"], spoken)
                self.app.speaker.put(self.cfg["label"], t["name"], event.raw_text or spoken, spoken)
                return


# ───────── сервис и API ─────────

class Sova:
    def __init__(self):
        SESSIONS.mkdir(exist_ok=True)
        self.store = Store()
        self.speaker = Speaker(self.store)
        self.accounts: dict[str, Account] = {}

    def add_runner(self, cfg: dict) -> Account:
        acc = Account(cfg, self)
        self.accounts[cfg["id"]] = acc
        acc.start()
        return acc

    def state(self) -> dict:
        return {"enabled": self.store.enabled, "volume": self.store.volume, "station": self.speaker.station,
                "accounts": [self.accounts[a["id"]].state() for a in self.store.accounts],
                "tasks": self.store.tasks, "history": list(self.speaker.history)[:10]}

    # обработчики

    async def h_index(self, req):
        return web.FileResponse(UI)

    async def h_state(self, req):
        return ok(**self.state())

    async def h_enabled(self, req):
        self.store.enabled = bool((await req.json())["enabled"])
        self.store.save()
        return ok()

    async def h_volume(self, req):
        v = (await req.json())["volume"]
        self.store.volume = None if v is None else min(max(float(v), 0.0), 1.0)
        self.store.save()
        return ok()

    async def h_station(self, req):
        """Подключить колонку: OAuth-токен Яндекса и, по желанию, IP станции. Пишется в .env."""
        b = await req.json()
        token = (b.get("token") or "").strip()
        m = re.search(r"access_token=([^&\s]+)", token)   # можно вставить адрес целиком
        token = m.group(1) if m else token
        if not token:
            raise ValueError("Вставь токен Яндекса")
        values = {"YANDEX_TOKEN": token, "STATION_IP": (b.get("ip") or "").strip()}
        set_env(values)
        alice.reset_station()
        try:
            name = await alice.station_name()
        except alice.AliceError as e:
            self.speaker.recheck()
            raise ValueError(str(e))
        self.speaker.recheck()
        return ok(name=name)

    async def h_task_add(self, req):
        b = await req.json()
        sender = norm(b.get("sender", ""))
        if not sender:
            raise ValueError("Укажи ник")
        account = b.get("account") or "*"
        if account != "*":
            self.store.account(account)
        self.store.tasks.append({"id": uuid.uuid4().hex[:8], "account": account, "sender": sender,
                                 "name": (b.get("name") or sender).strip(), "enabled": True})
        self.store.save()
        return ok()

    async def h_task_patch(self, req):
        t, b = self.store.task(req.match_info["id"]), await req.json()
        for k in ("account", "sender", "name", "enabled"):
            if k in b:
                t[k] = norm(b[k]) if k == "sender" else b[k]
        self.store.save()
        return ok()

    async def h_task_del(self, req):
        self.store.tasks.remove(self.store.task(req.match_info["id"]))
        self.store.save()
        return ok()

    async def h_acc_add(self, req):
        b = await req.json()
        label = (b.get("label") or "").strip()
        if not label:
            raise ValueError("Укажи, как Алиса называет аккаунт")
        cfg = {"id": uuid.uuid4().hex[:8], "label": label, "username": None, "phone": None}
        self.store.accounts.append(cfg)
        self.store.save()
        acc = Account(cfg, self)
        self.accounts[cfg["id"]] = acc
        acc.status, acc.login_step = "need_login", "phone"
        if b.get("phone"):
            await acc.login({"phone": b["phone"]})
        return ok()

    async def h_acc_patch(self, req):
        cfg, b = self.store.account(req.match_info["id"]), await req.json()
        if (b.get("label") or "").strip():
            cfg["label"] = b["label"].strip()
            self.store.save()
        return ok()

    async def h_acc_del(self, req):
        acc_id = req.match_info["id"]
        cfg = self.store.account(acc_id)
        await self.accounts.pop(acc_id).stop()
        self.store.accounts.remove(cfg)
        self.store.tasks = [t for t in self.store.tasks if t["account"] != acc_id]
        self.store.save()
        (SESSIONS / f"{acc_id}.session").unlink(missing_ok=True)
        return ok()

    async def h_acc_login(self, req):
        self.store.account(req.match_info["id"])
        await self.accounts[req.match_info["id"]].login(await req.json())
        return ok()

    async def h_test(self, req):
        label = self.store.accounts[0]["label"] if self.store.accounts else "Проверка"
        self.speaker.put(label, "Сова", "проверка", f"{label}, тебе пишет Сова: проверка связи, всё работает")
        return ok()


def set_env(values: dict) -> None:
    """Обновить ключи в .env (остальные строки не трогаем) и в окружении процесса."""
    path = HERE / ".env"
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    left = dict(values)
    for i, line in enumerate(lines):
        key = line.split("=", 1)[0].strip()
        if key in left:
            lines[i] = f"{key}={left.pop(key)}"
    lines += [f"{k}={v}" for k, v in left.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    path.chmod(0o600)
    for k, v in values.items():
        os.environ[k] = v


def ok(**kw):
    return web.json_response({"ok": True, **kw})


@web.middleware
async def errors(req, handler):
    try:
        return await handler(req)
    except web.HTTPException as e:
        if e.status < 400:
            raise
        return web.json_response({"ok": False, "error": e.text}, status=e.status)
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
        return web.json_response({"ok": False, "error": str(e) or repr(e)}, status=400)
    except Exception as e:
        log.exception("API")
        return web.json_response({"ok": False, "error": str(e) or repr(e)}, status=400)


async def serve(port: int = PORT) -> None:
    sova = Sova()
    app = web.Application(middlewares=[errors])
    r = app.router
    r.add_get("/", sova.h_index)
    r.add_get("/api/state", sova.h_state)
    r.add_post("/api/enabled", sova.h_enabled)
    r.add_post("/api/volume", sova.h_volume)
    r.add_post("/api/station", sova.h_station)
    r.add_post("/api/tasks", sova.h_task_add)
    r.add_patch("/api/tasks/{id}", sova.h_task_patch)
    r.add_delete("/api/tasks/{id}", sova.h_task_del)
    r.add_post("/api/accounts", sova.h_acc_add)
    r.add_patch("/api/accounts/{id}", sova.h_acc_patch)
    r.add_delete("/api/accounts/{id}", sova.h_acc_del)
    r.add_post("/api/accounts/{id}/login", sova.h_acc_login)
    r.add_post("/api/test", sova.h_test)

    runner = web.AppRunner(app, access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()
    log.info("Сова: http://127.0.0.1:%s", port)

    for cfg in sova.store.accounts:
        sova.add_runner(cfg)
    await sova.speaker.run()
