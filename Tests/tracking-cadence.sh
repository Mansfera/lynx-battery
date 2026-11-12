#!/bin/bash
# How often we measure per-app energy and live samples on the Power tab. Run: Tests/tracking-cadence.sh. Doesn't touch the real app's settings, history or charge limit; cleans up its own test settings.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$HOME/Library/Preferences/tracking-cadence.plist"' EXIT
SOURCES=()
for f in Sources/*.swift; do [ "$f" = Sources/main.swift ] || SOURCES+=("$f"); done
swiftc "${SOURCES[@]}" Tests/TrackingCadence/main.swift -o "$TMP/tracking-cadence" \
    -framework Cocoa -framework IOKit -framework SwiftUI -framework ServiceManagement -framework CoreBluetooth \
    -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/tracking-cadence"
