#!/bin/bash
# High alert thresholds in all percentage modes. Run: Tests/high-alerts.sh. Doesn't touch settings or limit files.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/HighAlerts/main.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/high-alerts" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/high-alerts"
