#!/bin/bash
# No-battery Mac mode on a MacBook: logic and screen PNGs in three builds — normal, no battery, no battery and no wattage.
# Run: Tests/desktop-mode.sh [PNG folder]. Doesn't touch the real app's settings, history or charge limit files.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/desktop-mode}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done

run() {   # name, compile flags
    local name="$1"; shift
    echo; echo "=== $name"
    swiftc "${SOURCES[@]}" Tests/DesktopMode/main.swift "$@" -o "$TMP/$name" \
        -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
        -swift-version 5 -target arm64-apple-macos14.0
    mkdir -p "$TMP/home-$name"
    CFFIXED_USER_HOME="$TMP/home-$name" "$TMP/$name" "$OUT/$name" Resources/Fonts
}

run real
run no-battery -D SIMULATE_NO_BATTERY
run no-watts -D SIMULATE_NO_BATTERY -D SIMULATE_NO_WATTS
echo; echo "PNGs: $OUT"
