#!/bin/bash
# Перемикач «Track devices»: логіка й PNG поповера та налаштувань. Запуск: Tests/device-tracking.sh [тека для PNG]. Налаштувань, історії й ліміту заряду справжньої апки не чіпає; свої тестові налаштування прибирає.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/device-tracking}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$HOME/Library/Preferences/device-tracking.plist"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/DeviceTracking/main.swift -o "$TMP/device-tracking" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/device-tracking" "$OUT" Resources/Fonts
echo; echo "PNGs: $OUT"
