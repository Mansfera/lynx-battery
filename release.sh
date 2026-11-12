#!/bin/bash
set -euo pipefail
V="${1:?usage: ./release.sh <version>, e.g. 1.2.3}"
cd "$(dirname "$0")"

# Releases are signed with a YubiKey release key (add-release-key.sh). Without one, installed copies won't auto-install the release.
SSHKEYGEN="${SSHKEYGEN:-$(command -v /opt/homebrew/bin/ssh-keygen || command -v ssh-keygen)}"
mkdir -p build
swiftc Tools/UpdateSig/main.swift Sources/UpdateSignature.swift Sources/UpdatePolicy.swift Sources/UpdateKey.swift \
    -o build/update-sig -swift-version 5 -target arm64-apple-macos14.0
KEYS=()
for k in "$HOME"/.ssh/lynx_release_*; do
    case "$k" in *.pub) continue ;; esac
    [ -f "$k" ] && [ -f "$k.pub" ] && build/update-sig trusted "$k.pub" >/dev/null 2>&1 && KEYS+=("$k")
done
[ ${#KEYS[@]} -gt 0 ] || { echo "No ~/.ssh/lynx_release_* key that Sources/UpdateKey.swift trusts: run ./add-release-key.sh first."; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

env -u SIMULATE_NO_BATTERY -u SIMULATE_VERSION ./build.sh

rm -rf build/dmg dist && mkdir -p build/dmg dist
ditto "Lynx Battery.app" "build/dmg/Lynx Battery.app"
ln -s /Applications build/dmg/Applications
DMG="dist/Lynx-Battery-$V.dmg"
hdiutil create -volname "Lynx Battery" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "DMG $DMG  sha256 $SHA"
# Whichever YubiKey is plugged in signs: the one that isn't fails fast, and the next key file is tried
build/update-sig message "$DMG" "$V" > "build/Lynx-Battery-$V.msg"
rm -f "build/Lynx-Battery-$V.msg.sig" "$DMG.sig"
for k in "${KEYS[@]}"; do
    echo "Signing with $(build/update-sig trusted "$k.pub"): enter the YubiKey's PIN and touch it when it blinks."
    if "$SSHKEYGEN" -Y sign -f "$k" -n lynx-battery-update "build/Lynx-Battery-$V.msg"; then
        mv "build/Lynx-Battery-$V.msg.sig" "$DMG.sig"
        break
    fi
done
[ -f "$DMG.sig" ] || { echo "Couldn't sign with any release key: is a YubiKey from Sources/UpdateKey.swift plugged in?"; exit 1; }
build/update-sig verify "$DMG" "$V" "$DMG.sig" >/dev/null || { echo "The signature doesn't verify: not releasing."; exit 1; }
echo "Signed $DMG.sig"

git add Info.plist
git diff --cached --quiet || git commit -m "Release $V"
git push
gh release create "v$V" "$DMG" "$DMG.sig" -R Mansfera/lynx-battery --target "$(git rev-parse HEAD)" --title "Lynx Battery $V" \
  --notes "Install: \`brew install --cask mansfera/tap/lynx-battery\` or open the DMG and drag the app to Applications."

TAP=build/tap
rm -rf "$TAP"
gh repo clone Mansfera/homebrew-tap "$TAP" -- -q
sed -e "s/__VERSION__/$V/" -e "s/__SHA256__/$SHA/" Homebrew/lynx-battery.rb > "$TAP/Casks/lynx-battery.rb"
git -C "$TAP" add Casks/lynx-battery.rb
git -C "$TAP" commit -m "lynx-battery $V"
git -C "$TAP" push -q
echo "✅ Released $V — brew install --cask mansfera/tap/lynx-battery"
