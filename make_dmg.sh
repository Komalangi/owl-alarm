#!/bin/bash
# Собирает build/Sova-<VERSION>.dmg с Сова.app, ссылкой на «Программы» и инструкцией.
set -euo pipefail
cd "$(dirname "$0")"
export VERSION="${VERSION:-1.0.0}"
bash ./build_app.sh
STAGE="$(mktemp -d /tmp/sova-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "build/Сова.app" "$STAGE/Сова.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Как установить.txt" <<'TXT'
Как установить Сову

1. Перетащи Сову в «Программы» (Applications).

2. Первый запуск: правый клик по Сове → «Открыть» → «Открыть».
   Приложение не подписано Apple, поэтому обычный двойной клик не сработает.
   На новых macOS: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть».

3. Первый запуск ставит компоненты 1–2 минуты. Нужен интернет и Python 3.9+
   (есть на любом маке с Command Line Tools, иначе macOS сама предложит их поставить).

4. Дальше в окне Совы: подключи Telegram (api_id и api_hash с my.telegram.org),
   подключи колонку, добавь аккаунт и задачи.
TXT
OUT="build/Sova-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Сова" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "DMG: $PWD/$OUT"
