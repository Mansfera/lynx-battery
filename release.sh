#!/bin/bash
set -euo pipefail
V="${1:?usage: ./release.sh <version>, e.g. 1.2.3}"
cd "$(dirname "$0")"

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

git add Info.plist
git diff --cached --quiet || git commit -m "Release $V"
git push
gh release create "v$V" "$DMG" -R Mansfera/lynx-battery --target "$(git rev-parse HEAD)" --title "Lynx Battery $V" \
  --notes "Install: \`brew install --cask mansfera/tap/lynx-battery\` or open the DMG and drag the app to Applications."

TAP=build/tap
rm -rf "$TAP"
gh repo clone Mansfera/homebrew-tap "$TAP" -- -q
sed -e "s/__VERSION__/$V/" -e "s/__SHA256__/$SHA/" Homebrew/lynx-battery.rb > "$TAP/Casks/lynx-battery.rb"
git -C "$TAP" add Casks/lynx-battery.rb
git -C "$TAP" commit -m "lynx-battery $V"
git -C "$TAP" push -q
echo "✅ Released $V — brew install --cask mansfera/tap/lynx-battery"
