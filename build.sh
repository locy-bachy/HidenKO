#!/bin/bash
# ./build.sh            собрать build/HidenKO.app (Apple Silicon)
# ./build.sh --release  сборка для раздачи: Apple Silicon + Intel, ad-hoc подпись,
#                       архив build/HidenKO-<версия>.zip
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

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

# -file-prefix-map: в программу не попадает путь к папке, где её собирали.
compile() {
    swiftc -O -swift-version 5 -target "$1-apple-macos14.0" -o "$2" Sources/*.swift \
        -framework AppKit -framework QuartzCore -file-prefix-map "$PWD=."
}

if (( RELEASE )); then
    compile arm64 build/HidenKO-arm64
    compile x86_64 build/HidenKO-x86_64
    lipo -create build/HidenKO-arm64 build/HidenKO-x86_64 -output "$BIN"
    rm -f build/HidenKO-arm64 build/HidenKO-x86_64
else
    compile arm64 "$BIN"
fi
chmod +x "$BIN"

if (( RELEASE )); then
    # Для раздачи только ad-hoc: в подписи сертификатом видны имя владельца и Team ID.
    codesign --force --deep -s - "$APP"
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
    ZIP="build/HidenKO-$VERSION.zip"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
    echo "Built $ZIP (Apple Silicon + Intel)"
    exit 0
fi

# Подпись сертификатом Apple Development: у ad-hoc подписи личность меняется
# с каждой сборкой, и macOS заново спрашивает доступ к «Загрузкам» и т. п., а обработка обоев висит,
# пока на запрос не ответят. Без сертификата — ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
codesign --force --deep -s "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
