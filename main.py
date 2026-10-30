"""CLI: run / test-alice / devices / test-match."""
import argparse
import asyncio
import logging
import sys
from pathlib import Path

from dotenv import load_dotenv

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

import actions  # noqa: E402
import alice  # noqa: E402
from rules import ConfigError, find_rule, load_rules, sender_keys  # noqa: E402


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[logging.StreamHandler(), logging.FileHandler(HERE / "tg-alice.log", encoding="utf-8")],
    )


async def cmd_run(args) -> None:
    from telegram_listener import listen
    await listen(load_rules())


async def cmd_test_alice(args) -> None:
    rule = load_rules()[0]
    logging.info("Выполняю действие правила %r без Telegram", rule.name)
    await actions.run_action(rule.action)


async def cmd_devices(args) -> None:
    devices = await alice.list_devices()
    print("Станции аккаунта:")
    for d in devices:
        print(f"  id={d['id']}  platform={d['platform']}  name={d.get('name')}")
    print("Найдено по mDNS (ищу 4 сек)...")
    for dev_id, ip in (await alice.discover_stations()).items():
        print(f"  deviceId={dev_id}  ip={ip}")


async def cmd_test_match(args) -> None:
    keys = sender_keys(username=args.sender, first_name=args.sender)
    rule = find_rule(load_rules(), keys, args.text)
    if rule:
        print(f"Сработает правило: {rule.name!r}, действие: {rule.action}, cooldown: {rule.cooldown}с")
    else:
        print("Ни одно правило не подходит")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Telegram -> Алиса: действия по правилам из config.yaml")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="слушать Telegram и выполнять правила").set_defaults(fn=cmd_run)
    sub.add_parser("test-alice", help="выполнить действие первого правила без Telegram").set_defaults(fn=cmd_test_alice)
    sub.add_parser("devices", help="показать станции аккаунта и IP из mDNS").set_defaults(fn=cmd_devices)
    t = sub.add_parser("test-match", help="какое правило сработает (без действий)")
    t.add_argument("--from", dest="sender", required=True, help="username, id или имя отправителя")
    t.add_argument("--text", default="", help="текст сообщения")
    t.set_defaults(fn=cmd_test_match)
    return p


def main() -> None:
    args = build_parser().parse_args()
    setup_logging()
    try:
        asyncio.run(args.fn(args))
    except (alice.AliceError, ConfigError, ValueError) as e:
        logging.error("%s", e)
        sys.exit(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
