#!/bin/bash
# Once per YubiKey: makes a FIDO2 release-signing key on the inserted YubiKey and adds its public key to
# Sources/UpdateKey.swift (commit it). Usage: ./add-release-key.sh 1, then with the other YubiKey ./add-release-key.sh 2.
# Re-running with a key file that already exists only adds it to UpdateKey.swift if it isn't there yet.
set -euo pipefail
N="${1:-}"
[[ "$N" =~ ^[1-9][0-9]?$ ]] || { echo "usage: ./add-release-key.sh <n>, e.g. 1 for the first YubiKey and 2 for the second"; exit 1; }
cd "$(dirname "$0")"
SSHKEYGEN="${SSHKEYGEN:-$(command -v /opt/homebrew/bin/ssh-keygen || command -v ssh-keygen)}"
KEY="$HOME/.ssh/lynx_release_$N"
LABEL="yubikey $N"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
build_tool() {
    swiftc Tools/UpdateSig/main.swift Sources/UpdateSignature.swift Sources/UpdatePolicy.swift Sources/UpdateKey.swift \
        -o "$TMP/update-sig" -swift-version 5 -target arm64-apple-macos14.0
}
build_tool

if [ -e "$KEY.pub" ]; then
    echo "Using the existing $KEY.pub."
else
    [ -e "$KEY" ] && { echo "$KEY exists without $KEY.pub: restore the .pub, or move $KEY away first."; exit 1; }
    echo "Insert YubiKey $N only (unplug the other one). Enter its FIDO2 PIN when asked and touch it when it blinks."
    # resident: the key can be fetched back from the YubiKey with ssh-keygen -K on any Mac.
    # verify-required: every signature needs the PIN as well as a touch, so a lost YubiKey can't sign alone.
    # user=: a distinct resident slot, so this never overwrites another resident key with the same application.
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    "$SSHKEYGEN" -t ed25519-sk -O resident -O verify-required -O application=ssh:lynx-release -O user="lynx-release-$N" \
        -C "lynx-battery release ($LABEL)" -N '' -f "$KEY"
fi
"$TMP/update-sig" key "$KEY.pub"

if T="$("$TMP/update-sig" trusted "$KEY.pub" 2>/dev/null)"; then
    echo "Sources/UpdateKey.swift already trusts this key (as \"$T\"). Nothing to do."
    exit 0
fi
if grep -q "label: \"$LABEL\"" Sources/UpdateKey.swift; then
    echo "Sources/UpdateKey.swift already has a different key labelled \"$LABEL\". Pick another number, or remove that entry first."
    exit 1
fi
PUB="$(cut -d' ' -f1,2 "$KEY.pub")"
awk -v line="        TrustedUpdateKey(label: \"$LABEL\", key: \"$PUB\")," '$0 == "    ]" && !done { print line; done = 1 } { print }' \
    Sources/UpdateKey.swift > "$TMP/UpdateKey.swift"
grep -qF "$PUB" "$TMP/UpdateKey.swift" || { echo "Couldn't find the end of the list in Sources/UpdateKey.swift."; exit 1; }
cp "$TMP/UpdateKey.swift" Sources/UpdateKey.swift
build_tool
"$TMP/update-sig" trusted "$KEY.pub" >/dev/null
echo "Added \"$LABEL\" to Sources/UpdateKey.swift: $PUB"
echo
echo "Next:"
echo "  • Back up $KEY and $KEY.pub (not secret: they're useless without this YubiKey and its PIN)."
echo "    If they're lost, the key is resident: on any Mac, insert the YubiKey and run"
echo "    cd ~/.ssh && $SSHKEYGEN -K, then rename the id_ed25519_sk_rk_lynx-release_lynx-release-$N files to lynx_release_$N and .pub."
echo "  • Run it again with the other YubiKey (./add-release-key.sh <n>), so either one can sign a release."
echo "  • Commit Sources/UpdateKey.swift, rebuild, and reinstall the helper from the Charge tab (Helper update): the helper has the keys built in."
