#!/bin/bash
# Початок заряду: межа утримання при зміні ліміту й живий струм замість застарілого IsCharging. Запуск: Tests/charge-start.sh. Налаштувань і SMC не змінює.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/ChargeStart/main.swift Sources/ChargeConfig.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/charge-start" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/charge-start"
