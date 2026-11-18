#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HidenKO.app
BIN="$APP/Contents/MacOS/HidenKO"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
# Icon/AppIcon.icon — файл Icon Composer: actool делает из него
# иконку Liquid Glass для macOS 26+ (Assets.car) и классическую AppIcon.icns для macOS 15.
xcrun actool --compile "$PWD/$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-info.plist" \
    --errors --output-format human-readable-text "$PWD/Icon/AppIcon.icon" 2>/dev/null | grep -i error || true

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$BIN" Sources/*.swift \
    -framework AppKit -framework QuartzCore

chmod +x "$BIN"
# Подпись сертификатом Apple Development: у ad-hoc подписи личность меняется
# с каждой сборкой, и macOS заново спрашивает доступ к «Загрузкам» и т. п., а обработка обоев висит,
# пока на запрос не ответят. Без сертификата — ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
codesign --force --deep -s "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
