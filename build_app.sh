#!/bin/bash
# Сборка «Сова.app» из SovaApp.swift (Command Line Tools, без Xcode) и установка в /Applications.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$(pwd)"
APP="$PROJECT/Сова.app"
DEST="/Applications/Сова.app"
TMP="$(mktemp -d /tmp/sova-build.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "→ компилирую Swift…"
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
PROJ_ESC="$(esc "$PROJECT")"
mkdir -p "$TMP/src"
python3 - "$PROJECT/SovaApp.swift" "$TMP/src/main.swift" "$PROJ_ESC" <<'PY'
import sys
src, out, proj = sys.argv[1:4]
open(out, "w", encoding="utf-8").write(open(src, encoding="utf-8").read().replace("__PROJECT__", proj))
PY
xcrun swiftc -O -o "$TMP/Sova" "$TMP/src/main.swift" \
  -framework Cocoa -framework WebKit -framework ServiceManagement

echo "→ собираю пакет…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/Sova" "$APP/Contents/MacOS/Sova"
chmod +x "$APP/Contents/MacOS/Sova"

# иконка: сова на тёмном круге (рисуем Swift-скриптом, затем iconutil)
ICON_OK=0
cat > "$TMP/icon.swift" <<'SW'
import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor.clear.set()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let inset: CGFloat = 40
let circle = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
NSGradient(starting: NSColor(red: 0.16, green: 0.19, blue: 0.30, alpha: 1), ending: NSColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1))!.draw(in: circle, angle: -90)
NSColor(red: 1, green: 0.79, blue: 0.30, alpha: 0.9).setStroke()
circle.lineWidth = 14
circle.stroke()
let s = NSAttributedString(string: "🦉", attributes: [.font: NSFont.systemFont(ofSize: 560)])
let b = s.size()
s.draw(at: NSPoint(x: (size - b.width) / 2, y: (size - b.height) / 2 - 10))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SW
if xcrun swiftc -o "$TMP/icon" "$TMP/icon.swift" -framework Cocoa 2>/dev/null && "$TMP/icon" "$TMP/icon1024.png" 2>/dev/null; then
  SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  if iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then ICON_OK=1; fi
fi
[ "$ICON_OK" = 1 ] && echo "→ иконка готова" || echo "→ иконку сгенерировать не вышло, собираю без неё"

ICON_KEY=""
[ "$ICON_OK" = 1 ] && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.user.sova</string>
<key>CFBundleName</key><string>Сова</string>
<key>CFBundleDisplayName</key><string>Сова</string>
<key>CFBundleExecutable</key><string>Sova</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
$ICON_KEY
</dict></plist>
PL

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(codesign пропущен)"
touch "$APP"

rm -rf "$HOME/Applications/Сова.app"  # старое место установки
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Готово: $APP"
echo "Установлено: $DEST"
