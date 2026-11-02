#!/bin/bash
# Хелпер після `brew upgrade`: коли повертається і відмова без root. Запуск: Tests/helper-restore.sh. Нічого не встановлює.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/HelperRestore/main.swift Sources/ChargeConfig.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/helper-restore" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/helper-restore"

swiftc Helper/main.swift Sources/SMC.swift Sources/Battery.swift Sources/ChargeConfig.swift \
    -o "$TMP/helper" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
if out="$("$TMP/helper" --restore 2>&1)"; then echo "FAIL --restore ran without root"; exit 1; fi
[ "$out" = "--restore needs root" ] && echo "ok   --restore refuses without root" || { echo "FAIL unexpected output: $out"; exit 1; }
