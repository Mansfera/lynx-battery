#!/bin/bash
# Неможливі показники «top» не псують «енергію за апками». Запуск: Tests/energy-history.sh. Працює на файлі в тимчасовій теці, справжньої energy.json не чіпає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/EnergyHistory/main.swift Sources/Energy.swift Sources/History.swift Sources/AppData.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/energy-history" -framework Cocoa -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/energy-history" "$TMP"
