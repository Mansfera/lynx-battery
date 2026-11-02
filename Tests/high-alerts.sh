#!/bin/bash
# Високі пороги сповіщень у всіх режимах відсотка. Запуск: Tests/high-alerts.sh. Налаштувань і файлів ліміту не чіпає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/HighAlerts/main.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/high-alerts" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/high-alerts"
