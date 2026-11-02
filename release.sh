#!/bin/bash
# Реліз: ./release.sh 1.0.1
# Збирає апку, пакує DMG, публікує GitHub Release і оновлює cask у VoloNehoda/homebrew-tap.
set -euo pipefail
V="${1:?usage: ./release.sh <version>, e.g. 1.0.1}"
cd "$(dirname "$0")"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

env -u SIMULATE_NO_BATTERY ./build.sh

rm -rf build/dmg dist && mkdir -p build/dmg dist
ditto "Lynx Battery.app" "build/dmg/Lynx Battery.app"
ln -s /Applications build/dmg/Applications
DMG="dist/Lynx-Battery-$V.dmg"
hdiutil create -volname "Lynx Battery" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "DMG $DMG  sha256 $SHA"

git add Info.plist
git commit -m "Release $V" >/dev/null || true
git push
gh release create "v$V" "$DMG" --title "Lynx Battery $V" \
  --notes "Install: \`brew install --cask volonehoda/tap/etherlynx-battery\` or open the DMG and drag the app to Applications."

# Cask у tap: нова версія й контрольна сума, а ще нова назва апки й DMG (токен cask лишається etherlynx-battery)
TAP=build/tap
rm -rf "$TAP"
gh repo clone VoloNehoda/homebrew-tap "$TAP" -- -q
sed -i '' -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/; s/Etherlynx Battery\.app/Lynx Battery.app/g; s/Etherlynx-Battery-/Lynx-Battery-/; s/^  name \"Etherlynx Battery\"/  name \"Lynx Battery\"/" "$TAP/Casks/etherlynx-battery.rb"
git -C "$TAP" commit -am "etherlynx-battery $V" >/dev/null
git -C "$TAP" push -q
echo "✅ Released $V — brew upgrade --cask etherlynx-battery"
