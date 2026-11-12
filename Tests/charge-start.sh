#!/bin/bash
# Charge start: the hold limit when the limit changes, and the live current instead of a stale IsCharging. Run: Tests/charge-start.sh. Doesn't change settings or the SMC.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/ChargeStart/main.swift Sources/ChargeConfig.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/charge-start" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/charge-start"
