#!/bin/bash
# Один раз: ключ Ed25519 для підпису релізів. Приватний — у login Keychain, публічний — у Sources/UpdateKey.swift (його комітимо).
# Повторний запуск бере ключ, що вже є в Keychain. --force створює новий, коли в Keychain його немає, а в UpdateKey.swift є старий.
set -euo pipefail
cd "$(dirname "$0")"
SERVICE=com.mansfera.lynxbattery.update-signing
ACCOUNT=release
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tools/SignUpdate/main.swift Sources/UpdateSignature.swift Sources/UpdatePolicy.swift Sources/UpdateKey.swift \
    -o "$TMP/sign-update" -swift-version 5 -target arm64-apple-macos14.0

if KEY="$(security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null)"; then
    echo "Using the key already in your Keychain ($SERVICE)."
else
    if grep -q 'publicKey = "[^"]' Sources/UpdateKey.swift && [ "${1:-}" != "--force" ]; then
        echo "Sources/UpdateKey.swift already has a key, but your Keychain doesn't: restore it from your backup."
        echo "A new key means installed copies can't auto-install the next release. To make one anyway: ./make-update-key.sh --force"
        exit 1
    fi
    KEY="$("$TMP/sign-update" generate)"
    # Через stdin, щоб ключ не з'явився в аргументах процесу
    printf 'add-generic-password -s %s -a %s -l "Lynx Battery update signing key" -w %s\n' "$SERVICE" "$ACCOUNT" "$KEY" | security -i
    security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 || { echo "Couldn't save the key to the Keychain."; exit 1; }
    echo "Saved a new private key to your login Keychain ($SERVICE)."
fi

PUB="$(printf '%s' "$KEY" | "$TMP/sign-update" public)"
cat > Sources/UpdateKey.swift <<EOF
/// Публічний ключ Ed25519, яким підписано релізи (base64, 32 байти). Його пише make-update-key.sh.
/// Порожній — апка й хелпер не можуть перевірити оновлення, тож не встановлюють їх самі.
enum UpdateKey {
    static let publicKey = "$PUB"
}
EOF
echo "Wrote the public key to Sources/UpdateKey.swift: $PUB"
echo
echo "Next:"
echo "  • Back up the private key somewhere safe (a password manager): Keychain Access → \"Lynx Battery update signing key\"."
echo "    Without it, releases can't be signed for copies that already have this public key."
echo "  • Commit Sources/UpdateKey.swift, rebuild, and reinstall the helper from the Charge tab (Helper update)."
