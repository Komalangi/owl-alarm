"""Реестр действий. Новый тип действия = функция + строка в ACTIONS."""
import logging

import alice

log = logging.getLogger("actions")


async def alice_alarm(params: dict) -> None:
    await alice.set_alarm(
        minutes=int(params.get("minutes", 1)),
        song=params.get("song", ""),
        volume=float(params.get("volume", 1.0)),
        text_template=params.get("text_template") or alice.DEFAULT_TEMPLATE,
    )


ACTIONS = {
    "alice_alarm": alice_alarm,
}


async def run_action(params: dict) -> None:
    fn = ACTIONS.get(params["type"])
    if fn is None:
        raise ValueError(f"Неизвестный тип действия: {params['type']!r} (есть: {', '.join(ACTIONS)})")
    await fn(params)
