#!/bin/bash
# Update checks before install: signatures (throwaway keys, cross-checked with ssh-keygen), request paths, Homebrew.
# Run: Tests/update-verify.sh. No network, no root.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/UpdateVerify/main.swift Tests/Shared/SKSigner.swift Sources/UpdatePolicy.swift Sources/UpdateSignature.swift Sources/UpdateKey.swift Sources/UpdateInstall.swift \
    -o "$TMP/update-verify" -swift-version 5 -target arm64-apple-macos14.0
"$TMP/update-verify"
