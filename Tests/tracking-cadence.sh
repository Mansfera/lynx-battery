#!/bin/bash
# Як часто міряємо енергію по апках і живі заміри на вкладці Power. Запуск: Tests/tracking-cadence.sh. Налаштувань, історії й ліміту заряду справжньої апки не чіпає; свої тестові налаштування прибирає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$HOME/Library/Preferences/tracking-cadence.plist"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/TrackingCadence/main.swift -o "$TMP/tracking-cadence" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/tracking-cadence"
