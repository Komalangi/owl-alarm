"""Загрузка конфига и сопоставление сообщений с правилами."""
from dataclasses import dataclass
from pathlib import Path

import yaml

CONFIG_PATH = Path(__file__).parent / "config.yaml"


class ConfigError(Exception):
    pass


@dataclass
class Rule:
    name: str
    senders: list[str]          # уже в нижнем регистре, без "@"
    text_contains: str | None
    action: dict
    cooldown: int
    private_only: bool = True    # только личные сообщения, не группы


def _norm(s) -> str:
    return str(s).strip().lstrip("@").lower()


def load_rules(path: Path = CONFIG_PATH) -> list[Rule]:
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except FileNotFoundError:
        raise ConfigError(f"Не найден конфиг: {path}. Скопируйте config.example.yaml в config.yaml и впишите имя")
    except yaml.YAMLError as e:
        raise ConfigError(f"Ошибка YAML в {path}: {e}")

    rules = []
    for i, r in enumerate(data.get("rules") or [], 1):
        try:
            match = r.get("match") or {}
            tc = match.get("text_contains")
            rules.append(Rule(
                name=r.get("name") or f"rule{i}",
                senders=[_norm(x) for x in match.get("from", [])],
                text_contains=str(tc).lower() if tc else None,
                action=dict(r["action"]),
                cooldown=int(r.get("cooldown_seconds", 300)),
                private_only=bool(match.get("private_only", True)),
            ))
            if "type" not in rules[-1].action:
                raise KeyError("action.type")
        except (KeyError, AttributeError, TypeError, ValueError) as e:
            raise ConfigError(f"Некорректное правило №{i}: {e!r}")
    if not rules:
        raise ConfigError("В config.yaml нет ни одного правила")
    return rules


def sender_keys(username=None, user_id=None, first_name=None, last_name=None) -> set[str]:
    """Все способы, которыми отправителя можно назвать в конфиге."""
    keys = set()
    for v in (username, user_id, first_name, last_name):
        if v:
            keys.add(_norm(v))
    full = " ".join(p for p in (first_name, last_name) if p)
    if full:
        keys.add(_norm(full))
    return keys


def find_rule(rules: list[Rule], keys: set[str], text: str, is_private: bool = True) -> Rule | None:
    """Первое подходящее правило или None."""
    text = (text or "").lower()
    for rule in rules:
        if rule.private_only and not is_private:
            continue
        if rule.senders and not (keys & set(rule.senders)):
            continue
        if rule.text_contains and rule.text_contains not in text:
            continue
        return rule
    return None
