#!/bin/bash
# Power breakdown in the macOS row: logic, live counter reading and PNG. Run: Tests/power-breakdown.sh [PNG folder]. Doesn't touch the real app's settings, history or charge limit.
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
