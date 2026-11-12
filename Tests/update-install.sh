#!/bin/bash
# The update install end to end, as the helper does it: real DMGs, throwaway release keys, a temp folder instead of /Applications.
# Run: Tests/update-install.sh, about a minute. No root and no helper; the installed app is left alone.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/UpdateInstall/main.swift Tests/Shared/SKSigner.swift Sources/UpdatePolicy.swift Sources/UpdateSignature.swift Sources/UpdateKey.swift Sources/UpdateInstall.swift \
    -o "$TMP/update-install" -swift-version 5 -target arm64-apple-macos14.0
"$TMP/update-install"
