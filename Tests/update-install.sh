#!/bin/bash
# Установка оновлення від початку до кінця, як у хелпері: справжні DMG, тестовий ключ, тимчасова тека замість /Applications.
# Запуск: Tests/update-install.sh, близько хвилини. Без root і хелпера; встановленої апки не чіпає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/UpdateInstall/main.swift Sources/UpdatePolicy.swift Sources/UpdateSignature.swift Sources/UpdateKey.swift Sources/UpdateInstall.swift \
    -o "$TMP/update-install" -swift-version 5 -target arm64-apple-macos14.0
"$TMP/update-install"
