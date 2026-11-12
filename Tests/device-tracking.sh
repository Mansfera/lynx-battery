#!/bin/bash
# The "Track devices" toggle: logic and PNGs of the popover and settings. Run: Tests/device-tracking.sh [PNG folder]. Doesn't touch the real app's settings, history or charge limit; cleans up its own test settings.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/device-tracking}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$HOME/Library/Preferences/device-tracking.plist"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/DeviceTracking/main.swift -o "$TMP/device-tracking" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/device-tracking" "$OUT" Resources/Fonts
echo; echo "PNGs: $OUT"
