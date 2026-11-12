#!/bin/bash
# Update check: versions, parsing the GitHub response, banner and alert. Run: Tests/update-check.sh. No network, doesn't touch settings.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/UpdateCheck/main.swift Sources/UpdatePolicy.swift \
    -o "$TMP/update-check" -swift-version 5 -target arm64-apple-macos14.0
"$TMP/update-check"
