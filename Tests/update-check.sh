#!/bin/bash
# Перевірка оновлень: версії, розбір відповіді GitHub, банер і сповіщення. Запуск: Tests/update-check.sh. Без мережі, налаштувань не чіпає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/UpdateCheck/main.swift Sources/UpdatePolicy.swift \
    -o "$TMP/update-check" -swift-version 5 -target arm64-apple-macos14.0
"$TMP/update-check"
