#!/bin/bash
# Режим «Minimal energy use»: логіка й PNG вкладки Power. Запуск: Tests/minimal-energy.sh [тека для PNG]. Файли налаштувань, історії й ліміту заряду справжньої апки не чіпає.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/minimal-energy}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/MinimalEnergy/main.swift -o "$TMP/minimal-energy" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/minimal-energy" "$OUT" Resources/Fonts
echo; echo "PNGs: $OUT"
