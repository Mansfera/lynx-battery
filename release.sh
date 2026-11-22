#!/bin/bash
set -euo pipefail
usage() { echo "usage: ./release.sh <version> [--skip-build|-sb], e.g. ./release.sh 1.2.3"; echo "  --skip-build, -sb  publish the Lynx Battery.app that's already built, instead of building it again"; exit 1; }
V=""; SKIP_BUILD=0
for a in "$@"; do
    case "$a" in
        --skip-build|-sb) SKIP_BUILD=1 ;;
        -*) usage ;;
        *) [ -z "$V" ] && V="$a" || usage ;;
    esac
done
[ -n "$V" ] || usage
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

APP="Lynx Battery.app"
if [ "$SKIP_BUILD" = 1 ]; then
    # Publish the app as it is: it must already be this version and built from the current sources
    # build.sh deletes the app before compiling, so an interrupted build leaves a bundle without Info.plist or binaries
    for f in Contents/Info.plist Contents/MacOS/LynxBattery Contents/Library/LaunchServices/com.mansfera.lynxbattery.helper; do
        [ -f "$APP/$f" ] || { echo "$APP isn't a finished build (no $f): run without --skip-build."; exit 1; }
    done
    BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
    [ "$BUILT" = "$V" ] || { echo "$APP is version $BUILT, not $V: run without --skip-build."; exit 1; }
    NEWER=$(find Sources Helper Resources build.sh -newer "$APP/Contents/MacOS/LynxBattery" -type f ! -name '.*' | head -3)
    [ -z "$NEWER" ] || { echo "$APP is older than the sources ($(echo $NEWER | tr ' ' ',')…): run without --skip-build."; exit 1; }
    # The release commit records the version and build number that the app was built with
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")" Info.plist
    echo "Skipping the build: publishing $APP ($V, build $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist))"
else
    # The build number counts from the last commit, so a failed run that's tried again doesn't bump it twice
    git show HEAD:Info.plist > build/Info.head.plist
    BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/Info.head.plist) + 1 ))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
    env -u SIMULATE_NO_BATTERY -u SIMULATE_VERSION ./build.sh
fi

rm -rf build/dmg dist && mkdir -p build/dmg dist
ditto "$APP" "build/dmg/$APP"
ln -s /Applications build/dmg/Applications
DMG="dist/Lynx-Battery-$V.dmg"
hdiutil create -volname "Lynx Battery" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
rm -rf build/dmg  # the staging copy of the app is only needed inside the DMG
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "DMG $DMG  sha256 $SHA"
build/update-sig message "$DMG" "$V" > "build/Lynx-Battery-$V.msg"
rm -f "build/Lynx-Battery-$V.msg.sig" "$DMG.sig"
# The PIN is the YubiKey's FIDO2 PIN (ykman fido access change-pin), not anything commit signing asks for.
# 8 wrong PINs in a row lock FIDO2 for good, and resetting it wipes the release key on that YubiKey.
PIN_LEFT=$(ykman fido info 2>/dev/null | awk -F': *' '/^PIN:/ { print $2 }' || true)
if [ -n "$PIN_LEFT" ]; then
    echo "YubiKey FIDO2 PIN: $PIN_LEFT"
    case "$PIN_LEFT" in [123]\ *) echo "⚠️  Few PIN attempts left: if you're not sure of the PIN, stop (Ctrl-C) rather than guess." ;; esac
fi
# Whichever YubiKey is plugged in signs: a key file whose key isn't on it fails, and the next one is tried
ERR=build/sign.err
WRONG_PIN=0
for k in "${KEYS[@]}"; do
    echo "Signing with $(build/update-sig trusted "$k.pub"): enter the YubiKey's FIDO2 PIN and touch it when it blinks."
    set +e
    "$SSHKEYGEN" -Y sign -f "$k" -n lynx-battery-update "build/Lynx-Battery-$V.msg" 2>&1 >/dev/null | tee "$ERR" >&2
    RC=${PIPESTATUS[0]}
    set -e
    if [ "$RC" = 0 ]; then
        mv "build/Lynx-Battery-$V.msg.sig" "$DMG.sig"
        break
    fi
    # The PIN is checked before the key is looked up, so the next key file would only spend another attempt on the same PIN
    if grep -q "incorrect passphrase" "$ERR"; then WRONG_PIN=1; break; fi
done
if [ ! -f "$DMG.sig" ]; then
    if [ "$WRONG_PIN" = 1 ]; then
        echo "Wrong PIN, or the YubiKey wasn't touched in time.$(ykman fido info 2>/dev/null | awk -F': *' '/^PIN:/ { print " PIN: " $2 }' || true)"
    else
        echo "Couldn't sign with any release key. After 3 wrong PINs in a row the YubiKey refuses until you unplug it and plug it back in."
        echo "Otherwise, the plugged-in YubiKey doesn't hold a key from Sources/UpdateKey.swift."
    fi
    echo "Nothing was published. Fix it and run ./release.sh $V --skip-build to sign the same app without rebuilding."
    exit 1
fi
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
rm -rf "$TAP"
echo "✅ Released $V — brew install --cask mansfera/tap/lynx-battery"
