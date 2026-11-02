#!/bin/bash
# Перезбирає значки з generate.py. Результат у git, тож build.sh ні Xcode, ні цього скрипта не потребує.
# Потрібні: Xcode 26+ (actool, ictool), ImageMagick, shapely. Python можна задати: PYTHON=venv/bin/python
set -euo pipefail
cd "$(dirname "$0")"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

"${PYTHON:-python3}" generate.py

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# PNG для вибору в налаштуваннях і власного значка Finder: іконка 824 на полотні 1024, як у решти апок macOS
for icon in *.icon; do
    name="${icon%.icon}"
    "$ICTOOL" "$icon" --export-image --output-file "$TMP/$name.png" --platform macOS --rendition Default \
        --width 824 --height 824 --scale 1 >/dev/null
    magick "$TMP/$name.png" -background none -gravity center -extent 1024x1024 -depth 8 "$name.png"
done

# Скляна іконка за замовчуванням: Assets.car для macOS 26+, AppIcon.icns для старіших
cp -R green-eyes.icon "$TMP/AppIcon.icon"
mkdir "$TMP/out"
xcrun actool "$TMP/AppIcon.icon" --compile "$TMP/out" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 --target-device mac \
    --output-partial-info-plist "$TMP/out/partial.plist" >/dev/null 2>&1
cp "$TMP/out/Assets.car" "$TMP/out/AppIcon.icns" ..
echo "✅ Icons rebuilt"
