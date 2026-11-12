#!/bin/bash
# Перевірка оновлення перед установкою: підпис тестовим ключем, шляхи запиту, Homebrew. Запуск: Tests/update-verify.sh. Без мережі й root.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/UpdateVerify/main.swift Sources/UpdatePolicy.swift Sources/UpdateSignature.swift Sources/UpdateKey.swift Sources/UpdateInstall.swift \
    -o "$TMP/update-verify" -swift-version 5 -target arm64-apple-macos14.0
"$TMP/update-verify"
