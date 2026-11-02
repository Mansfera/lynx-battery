#!/bin/bash
# Хелпер після `brew upgrade`: коли повертається і відмова без root. Запуск: Tests/helper-restore.sh. Нічого не встановлює.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc Tests/HelperRestore/main.swift Sources/ChargeConfig.swift Sources/Battery.swift Sources/SMC.swift \
    -o "$TMP/helper-restore" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
"$TMP/helper-restore"

swiftc Helper/main.swift Sources/SMC.swift Sources/Battery.swift Sources/ChargeConfig.swift \
    -o "$TMP/helper" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
if out="$("$TMP/helper" --restore 2>&1)"; then echo "FAIL --restore ran without root"; exit 1; fi
[ "$out" = "--restore needs root" ] && echo "ok   --restore refuses without root" || { echo "FAIL unexpected output: $out"; exit 1; }

# Реальний файл налаштувань лише читаємо: позначка має збігатися з тим, що в ньому написано
CONFIG="/Library/Application Support/com.mansfera.lynxbattery/charge-config.json"
"$TMP/helper" --mark-restore "$TMP/marker" || { echo "FAIL --mark-restore failed without root"; exit 1; }
if grep -q '"enabled": *true' "$CONFIG" 2>/dev/null; then want=yes; else want=no; fi
if [ -e "$TMP/marker" ]; then got=yes; else got=no; fi
[ "$got" = "$want" ] && echo "ok   --mark-restore follows the limit without root" || { echo "FAIL marker: $got, limit on: $want"; exit 1; }

# Ці два поля викликають sudo, навіть коли хелпера немає
if grep -Eq '^ *(uninstall )?(launchctl|delete):' Homebrew/lynx-battery.rb; then echo "FAIL the cask's uninstall stanza asks for sudo every time"; exit 1; fi
echo "ok   the cask only asks for sudo with a helper to remove"

# Хелпер, що стояв до оновлення, повертається й із вимкненим лімітом
if ! grep -q 'touch "restore-helper", base: :temp' Homebrew/lynx-battery.rb; then echo "FAIL the cask doesn't mark an installed helper for restoring"; exit 1; fi
echo "ok   the cask marks an installed helper for restoring"
