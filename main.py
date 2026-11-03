"""CLI: serve (сервис Совы с веб-интерфейсом) / devices / say."""
import argparse
import asyncio
import logging
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

from dotenv import load_dotenv

HERE = Path(__file__).parent
load_dotenv(HERE / ".env")

import alice  # noqa: E402
import sova  # noqa: E402


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[logging.StreamHandler(),
                  RotatingFileHandler(HERE / "sova.log", maxBytes=2_000_000, backupCount=2, encoding="utf-8")],
    )
    logging.getLogger("telethon").setLevel(logging.WARNING)


async def cmd_serve(args) -> None:
    await sova.serve(args.port)


async def cmd_devices(args) -> None:
    devices = await alice.list_devices()
    print("Станции аккаунта:")
    for d in devices:
        print(f"  id={d['id']}  platform={d['platform']}  name={d.get('name')}")
    print("Найдено по mDNS (ищу 4 сек)...")
    for dev_id, ip in (await alice.discover_stations()).items():
        print(f"  deviceId={dev_id}  ip={ip}")


async def cmd_say(args) -> None:
    await alice.say(args.text)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Сова: Алиса читает вслух сообщения из Telegram")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="слушать аккаунты и отдавать интерфейс на 127.0.0.1")
    s.add_argument("--port", type=int, default=sova.PORT)
    s.set_defaults(fn=cmd_serve)
    sub.add_parser("devices", help="показать станции аккаунта и IP из mDNS").set_defaults(fn=cmd_devices)
    t = sub.add_parser("say", help="Алиса скажет текст")
    t.add_argument("text")
    t.set_defaults(fn=cmd_say)
    return p


def main() -> None:
    args = build_parser().parse_args()
    setup_logging()
    try:
        asyncio.run(args.fn(args))
    except alice.AliceError as e:
        logging.error("%s", e)
        sys.exit(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
