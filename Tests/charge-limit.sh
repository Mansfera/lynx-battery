#!/bin/bash
# Межі ліміту заряду й переведення між шкалами. Запуск: Tests/charge-limit.sh. Налаштувань справжньої апки не чіпає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/ChargeLimit/main.swift Sources/ChargeConfig.swift Sources/ChargeControl.swift Sources/AppData.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/charge-limit" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/charge-limit"
