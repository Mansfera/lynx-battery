#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP="Lynx Battery.app"
echo "Building $APP ..."

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Перевірка режиму Mac без батареї на MacBook: SIMULATE_NO_BATTERY=1 ./build.sh
# (=no-watts — ще й без ключа потужності). Прапорець компіляції: у звичайній збірці цього коду немає.
SIM=()
case "${SIMULATE_NO_BATTERY:-}" in
    "") ;;
    no-watts) SIM=(-D SIMULATE_NO_BATTERY -D SIMULATE_NO_WATTS) ;;
    *) SIM=(-D SIMULATE_NO_BATTERY) ;;
esac

# swift-version 5 — без суворої Swift 6 concurrency
swiftc Sources/*.swift ${SIM[@]+"${SIM[@]}"} \
    -o "$APP/Contents/MacOS/LynxBattery" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -O

# Root-хелпер ліміту заряду: ставиться в систему лише з налаштувань апки, з паролем адміністратора
mkdir -p "$APP/Contents/Library/LaunchServices"
swiftc Helper/main.swift Sources/SMC.swift Sources/Battery.swift Sources/ChargeConfig.swift \
    -o "$APP/Contents/Library/LaunchServices/com.mansfera.lynxbattery.helper" \
    -framework IOKit -swift-version 5 -target arm64-apple-macos14.0 -O

cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts Resources/Marks Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Icons"
cp Resources/Icons/*.png "$APP/Contents/Resources/Icons/"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✅ Done: $DIR/$APP"
