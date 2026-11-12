#!/bin/bash
# Impossible "top" readings don't corrupt "energy by app". Run: Tests/energy-history.sh. Works on a file in a temp folder, doesn't touch the real energy.json.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/EnergyHistory/main.swift Sources/Energy.swift Sources/History.swift Sources/AppData.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/energy-history" -framework Cocoa -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
CFFIXED_USER_HOME="$TMP" "$TMP/energy-history" "$TMP"
