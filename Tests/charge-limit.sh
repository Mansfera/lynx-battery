#!/bin/bash
# Charge limit bounds and conversion between scales. Run: Tests/charge-limit.sh. Doesn't touch the real app's settings.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/ChargeLimit/main.swift Sources/ChargeConfig.swift Sources/ChargeControl.swift Sources/AppData.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/charge-limit" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/charge-limit"
