#!/bin/bash
# Темп хелпера наживо: справжній код хелпера в окремій теці й без запису в SMC (прапорець HELPER_TEST).
# Запуск: Tests/helper-pace.sh, близько 3 хв. Без root. Ліміту заряду й файлів встановленого хелпера не чіпає.
set -e
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
HELPER_PID=""
trap '[ -n "$HELPER_PID" ] && kill "$HELPER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
swiftc Helper/main.swift Sources/SMC.swift Sources/Battery.swift Sources/ChargeConfig.swift -D HELPER_TEST \
    -o "$TMP/helper" -framework IOKit -swift-version 5 -target arm64-apple-macos14.0
DIR="$TMP/data"; mkdir -p "$DIR"
LIVE="/Library/Application Support/com.mansfera.lynxbattery"
BEFORE="$(stat -f '%m' "$LIVE/charge-config.json" 2>/dev/null || true)"

# Атомарно, як апка: тимчасовий файл і перейменування
write_config() { printf '%s' "$1" > "$DIR/.tmp"; mv "$DIR/.tmp" "$DIR/charge-config.json"; }
stamp() { stat -f '%m' "$DIR/charge-status.json" 2>/dev/null || echo 0; }

# Найбільша пауза між записами стану за N секунд
longest_gap() {
    local last now gap=0 end=$((SECONDS + $1))
    last=$(date +%s)
    local seen; seen=$(stamp)
    while ((SECONDS < end)); do
        sleep 1
        now=$(stamp)
        if [ "$now" != "$seen" ]; then
            ((now - last > gap)) && gap=$((now - last))
            last=$now; seen=$now
        fi
    done
    echo "$gap"
}

fail=0
check() { if [ "$2" = 1 ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

write_config '{"enabled":false,"limit":80,"sailing":true,"sailRange":5,"heatProtection":true,"heatMax":35,"sleepUntilLimit":false,"magsafeLED":false,"discharge":true,"topUp":false,"lowPower":false}'
HELPER_TEST_DIR="$DIR" "$TMP/helper" > "$TMP/helper.log" 2>&1 &
HELPER_PID=$!
sleep 2
check "writes a status at start" "$([ -s "$DIR/charge-status.json" ] && echo 1)"

GAP=$(longest_gap 40)
echo "      normal: longest gap ${GAP}s"
check "normal pace: about every 15 s" "$( ((GAP >= 10 && GAP <= 20)) && echo 1)"

# Зміна налаштувань застосовується одразу, а не за наступним tick
sleep 2; B=$(stamp); sleep 1.2
write_config '{"enabled":false,"limit":80,"sailing":true,"sailRange":5,"heatProtection":true,"heatMax":35,"sleepUntilLimit":false,"magsafeLED":false,"discharge":true,"topUp":false,"lowPower":false,"minimalEnergy":true}'
sleep 1
check "a config change wakes the helper within a second" "$( (($(stamp) > B)) && echo 1)"

# Апка після запису ще й шле сповіщення: воно будить хелпер навіть без події теки. Запис на місці теку не змінює
sleep 2; B=$(stamp); sleep 1.2
printf '%s' '{"enabled":false,"limit":75,"sailing":true,"sailRange":5,"heatProtection":true,"heatMax":35,"sleepUntilLimit":false,"magsafeLED":false,"discharge":true,"topUp":false,"lowPower":false,"minimalEnergy":true}' > "$DIR/charge-config.json"
sleep 1
check "an in-place write alone waits for the next tick" "$( (($(stamp) == B)) && echo 1)"
notifyutil -p "com.mansfera.lynxbattery.test.config-changed:$DIR"
sleep 1
check "the app's notification wakes the helper within a second" "$( (($(stamp) > B)) && echo 1)"

GAP=$(longest_gap 95)
echo "      minimal: longest gap ${GAP}s"
check "minimal pace: slower than normal" "$( ((GAP >= 30)) && echo 1)"
check "minimal pace: still inside the alive window" "$( ((GAP <= 50)) && echo 1)"

write_config '{"enabled":false,"limit":80,"sailing":true,"sailRange":5,"heatProtection":true,"heatMax":35,"sleepUntilLimit":false,"magsafeLED":false,"discharge":true,"topUp":false,"lowPower":false}'
sleep 1
GAP=$(longest_gap 35)
echo "      back to normal: longest gap ${GAP}s"
check "turning it off restores the normal pace" "$( ((GAP >= 10 && GAP <= 20)) && echo 1)"

kill -0 "$HELPER_PID" 2>/dev/null; check "the helper is still running" "$( [ $? = 0 ] && echo 1)"
AFTER="$(stat -f '%m' "$LIVE/charge-config.json" 2>/dev/null || true)"
echo "      helper log:"; sed 's/^/        /' "$TMP/helper.log" | tail -5
echo "      live config mtime before=$BEFORE after=$AFTER (only the app or installed helper changes it)"
[ "$fail" = 0 ] && echo "All passed" || { echo "FAILED"; exit 1; }
