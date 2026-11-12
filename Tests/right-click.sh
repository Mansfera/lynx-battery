#!/bin/bash
# Right-click on the icon: when it toggles Low Power and when it opens the popover, plus a PNG of the settings. Run: Tests/right-click.sh [PNG folder]. Doesn't touch the real app's settings or helper.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/right-click}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$HOME/Library/Preferences/right-click.plist"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/RightClick/main.swift -o "$TMP/right-click" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/right-click" "$OUT" Resources/Fonts
echo; echo "PNGs: $OUT"
