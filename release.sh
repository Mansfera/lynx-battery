#!/bin/bash
# Реліз: ./release.sh 1.0.1
# Збирає апку, пакує DMG і публікує GitHub Release.
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
gh release create "v$V" "$DMG" -R Mansfera/lynx-battery --title "Lynx Battery $V" \
  --notes "Open the DMG and drag the app to Applications. It's not notarized, so the first launch needs right-click → Open."
echo "✅ Released $V"
