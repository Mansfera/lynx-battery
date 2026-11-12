#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP="Lynx Battery.app"
echo "Building $APP ..."

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SIM=()
case "${SIMULATE_NO_BATTERY:-}" in
    "") ;;
    no-watts) SIM=(-D SIMULATE_NO_BATTERY -D SIMULATE_NO_WATTS) ;;
    *) SIM=(-D SIMULATE_NO_BATTERY) ;;
esac

swiftc Sources/*.swift ${SIM[@]+"${SIM[@]}"} \
    -o "$APP/Contents/MacOS/LynxBattery" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -O

mkdir -p "$APP/Contents/Library/LaunchServices"
swiftc Helper/main.swift Sources/SMC.swift Sources/Battery.swift Sources/ChargeConfig.swift Sources/UpdatePolicy.swift Sources/UpdateSignature.swift Sources/UpdateKey.swift Sources/UpdateInstall.swift \
    -o "$APP/Contents/Library/LaunchServices/com.mansfera.lynxbattery.helper" \
    -framework IOKit -swift-version 5 -target arm64-apple-macos14.0 -O

cp Info.plist "$APP/Contents/Info.plist"
# Перевірка оновлень вручну: SIMULATE_VERSION=1.0.0 ./build.sh збирає апку, що вважає себе старою.
# Міняє лише копію Info.plist у збірці; release.sh цю змінну скидає.
if [ -n "${SIMULATE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SIMULATE_VERSION" "$APP/Contents/Info.plist"
    echo "⚠️  Simulating version $SIMULATE_VERSION"
fi
cp -R Resources/Fonts Resources/Marks Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Icons"
cp Resources/Icons/*.png "$APP/Contents/Resources/Icons/"
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✅ Done: $DIR/$APP"
