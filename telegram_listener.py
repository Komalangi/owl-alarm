"""Слушаем личный аккаунт Telegram (userbot) и запускаем действия по правилам."""
import asyncio
import logging
import os
import time
from pathlib import Path

from telethon import TelegramClient, events

import actions
from rules import Rule, find_rule, sender_keys

log = logging.getLogger("telegram")
SESSION = str(Path(__file__).parent / "tg_session")


def make_client() -> TelegramClient:
    api_id, api_hash = os.getenv("TG_API_ID"), os.getenv("TG_API_HASH")
    if not api_id or not api_hash:
        raise SystemExit("Не заданы TG_API_ID / TG_API_HASH (см. .env.example и README)")
    return TelegramClient(SESSION, int(api_id), api_hash)


async def _run_safe(rule: Rule) -> None:
    try:
        await actions.run_action(rule.action)
    except Exception as e:  # действие не должно ронять слушателя
        log.error("Правило %r: действие не выполнено: %s", rule.name, e)


async def listen(rules: list[Rule]) -> None:
    client = make_client()
    last_fired: dict[str, float] = {}

    @client.on(events.NewMessage(incoming=True))
    async def on_message(event):
        sender = await event.get_sender()
        keys = sender_keys(
            getattr(sender, "username", None), getattr(sender, "id", None),
            getattr(sender, "first_name", None), getattr(sender, "last_name", None),
        )
        rule = find_rule(rules, keys, event.raw_text, event.is_private)
        if not rule:
            return
        now = time.monotonic()
        if now - last_fired.get(rule.name, -1e9) < rule.cooldown:
            log.info("Правило %r сработало, но действует cooldown (%ss)", rule.name, rule.cooldown)
            return
        last_fired[rule.name] = now
        log.info("Правило %r сработало (отправитель: %s)", rule.name, sorted(keys))
        asyncio.create_task(_run_safe(rule))

    # При первом запуске Telethon сам спросит телефон и код в терминале
    await client.start()
    me = await client.get_me()
    log.info("Вошли как %s, слушаю сообщения...", me.first_name)
    await client.run_until_disconnected()
