#!/bin/bash
# Rebuilds the icons from generate.py. The output is in git, so build.sh needs neither Xcode nor this script.
# Requires: Xcode 26+ (actool, ictool), ImageMagick, shapely. Python can be set: PYTHON=venv/bin/python
set -euo pipefail
cd "$(dirname "$0")"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

"${PYTHON:-python3}" generate.py

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# PNGs for the picker in settings and the custom Finder icon: an 824 icon on a 1024 canvas, like other macOS apps
for icon in *.icon; do
    name="${icon%.icon}"
    "$ICTOOL" "$icon" --export-image --output-file "$TMP/$name.png" --platform macOS --rendition Default \
        --width 824 --height 824 --scale 1 >/dev/null
    magick "$TMP/$name.png" -background none -gravity center -extent 1024x1024 -depth 8 "$name.png"
done

# Default glass icon: Assets.car for macOS 26+, AppIcon.icns for older ones
cp -R green-eyes.icon "$TMP/AppIcon.icon"
mkdir "$TMP/out"
xcrun actool "$TMP/AppIcon.icon" --compile "$TMP/out" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 --target-device mac \
    --output-partial-info-plist "$TMP/out/partial.plist" >/dev/null 2>&1
cp "$TMP/out/Assets.car" "$TMP/out/AppIcon.icns" ..
echo "✅ Icons rebuilt"
