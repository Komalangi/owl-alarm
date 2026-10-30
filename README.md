# tg-alice

Фоновая программа: слушает ваш личный Telegram-аккаунт (userbot на Telethon) и по правилам из `config.yaml`
управляет Яндекс Станцией. Пример правила: сообщение от выбранного контакта -> громкость на максимум
и будильник Алисы через 1 минуту на заданную песню.

Важно:
- компьютер и Станция должны быть в одной Wi-Fi сети (управление идёт по локальной сети);
- для будильника с песней нужна подписка Яндекс Музыки (Плюс).

## Установка

```bash
cd tg-alice
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
cp config.example.yaml config.yaml
```

В `config.yaml` замените `"Имя контакта"` в `name` и `from` на того, чьё сообщение должно будить:
имя контакта как в Telegram, username без `@` или числовой id. Можно перечислить несколько:
`from: ["Аня", "anya_tg", "123456789"]`.

## Ключи

**Telegram api_id / api_hash.** Откройте https://my.telegram.org, войдите, зайдите в «API development tools»,
создайте приложение. Значения `api_id` и `api_hash` впишите в `.env` (`TG_API_ID`, `TG_API_HASH`).

**YANDEX_TOKEN.** Откройте в браузере
`https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d`,
войдите в аккаунт, к которому привязана Станция. После редиректа скопируйте значение `access_token`
из адресной строки и впишите в `.env` как `YANDEX_TOKEN`.

## Первый запуск

```bash
python main.py run
```

Telethon спросит номер телефона и код из Telegram (и пароль 2FA, если включён). Вводите сами в терминале.
Сессия сохранится в файл `tg_session.session` рядом с программой, дальше вход не нужен. Этот файл даёт доступ
к аккаунту: никому не передавайте.

## Проверка связки с Алисой

```bash
python main.py devices      # станции аккаунта (id, platform, name) и IP из mDNS
python main.py test-alice   # сразу выполнить действие первого правила, без Telegram
python main.py test-match --from "Имя контакта" --text "привет"   # какое правило сработает (dry-run)
```

Если mDNS не находит станцию, пропишите её IP в `STATION_IP`. Если на аккаунте несколько устройств,
задайте `STATION_DEVICE_ID` (id видно в `devices`). Если Алиса не поняла фразу, поправьте `text_template`
в конфиге. Подробности ответов станции смотрите в `tg-alice.log`.

## Правила

В `config.yaml` в списке `rules` добавьте блок:

```yaml
- name: "Мама"
  match:
    from: ["mama_username", "123456789", "Мама"]   # username, id или имя контакта
    text_contains: "срочно"                          # необязательно
  action:
    type: alice_alarm
    minutes: 2
    song: "..."
    volume: 1.0
    text_template: "Поставь будильник через {minutes} {minutes_word} на песню {song}"
  cooldown_seconds: 300   # не чаще раза в 5 минут (по умолчанию 300)
```

Срабатывает первое подходящее правило. Новый тип действия: напишите функцию в `actions.py` и добавьте её
в словарь `ACTIONS`.

## Автозапуск (launchd)

```bash
sed "s|__PROJECT_DIR__|$(pwd)|g" com.user.tg-alice.plist > ~/Library/LaunchAgents/com.user.tg-alice.plist
launchctl load ~/Library/LaunchAgents/com.user.tg-alice.plist
```

Сначала выполните первый интерактивный вход (`python main.py run`), иначе в фоне некому ввести код.
Остановка: `launchctl unload ~/Library/LaunchAgents/com.user.tg-alice.plist`.
