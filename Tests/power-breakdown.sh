#!/bin/bash
# Розбивка потужності в рядку macOS: логіка, живе читання лічильників і PNG. Запуск: Tests/power-breakdown.sh [тека для PNG]. Налаштувань, історії й ліміту заряду справжньої апки не чіпає.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/power-breakdown}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$HOME/Library/Preferences/power-breakdown.plist"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/PowerBreakdown/main.swift -o "$TMP/power-breakdown" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/power-breakdown" "$OUT" Resources/Fonts
echo; echo "PNGs: $OUT"
