#!/bin/bash
# Run the simulator build in screenshot mode and capture every main screen.
#
#   scripts/screenshots.sh <path/to/FilmShooter.app> <out-dir>
#
# The app is launched with `-FSScreenshot <scene>`; in that mode the camera is
# fed from Documents/ScreenshotSample.jpg and the scene opens directly.
set -uo pipefail

APP="$1"
OUT="$2"
BUNDLE=io.github.filmshooter.app
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$OUT"

# Newest iPhone Pro simulator available on the image.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
d = json.load(sys.stdin)["devices"]
best = None
for rt, devs in d.items():
    if "iOS" not in rt: continue
    ver = tuple(int(x) for x in re.findall(r"\d+", rt.split("iOS")[-1])[:2])
    for dev in devs:
        name = dev["name"]
        if not name.startswith("iPhone"): continue
        num = re.findall(r"iPhone (\d+)", name)
        score = (ver, int(num[0]) if num else 0, "Pro" in name and "Max" not in name)
        if best is None or score > best[0]: best = (score, dev["udid"], name, rt)
print(best[1]); print(best[2] + " / " + best[3], file=sys.stderr)
')
echo "simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true

xcrun simctl install "$UDID" "$APP"
for svc in camera photos photos-add; do xcrun simctl privacy "$UDID" grant "$svc" "$BUNDLE" || true; done

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
mkdir -p "$DATA/Documents"
cp "$here/Screenshots/sample_scene.jpg" "$DATA/Documents/ScreenshotSample.jpg"

shot() {  # shot <scene> <seconds>
  local scene="$1" wait="$2"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE" -FSScreenshot "$scene" > /dev/null
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$OUT/$scene.png" > /dev/null 2>&1 && echo "shot  $scene"
}

# 1. Seed: develop the sample with a few films so the gallery has prints.
xcrun simctl launch "$UDID" "$BUNDLE" -FSScreenshot seed > /dev/null
for i in $(seq 1 90); do
  n=$(ls "$DATA/Documents/Roll/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n" -ge 4 ]] && break
  if ! pgrep -f "FilmShooter.app/FilmShooter" > /dev/null; then echo "app is not running (crashed?) after ${i} polls"; break; fi
  sleep 2
done
echo "seeded prints: ${n:-0}"
sleep 2
xcrun simctl io "$UDID" screenshot "$OUT/seed.png" > /dev/null 2>&1

# Crash reports and the app's unified log, if anything went wrong.
mkdir -p "$OUT/diagnostics"
cp ~/Library/Logs/DiagnosticReports/FilmShooter* "$OUT/diagnostics/" 2>/dev/null || true
xcrun simctl spawn "$UDID" log show --last 6m --style compact   --predicate 'process == "FilmShooter"' > "$OUT/diagnostics/unified.log" 2>/dev/null || true

# 2. Every screen.
shot camera 9
shot camera-film 9
shot print 8
shot library 12
shot gallery 6
shot detail 7
shot editor 16
shot settings 5
shot about 5

# 3. The developed prints themselves, as JPEG, to judge the engine's output.
mkdir -p "$OUT/prints"
for f in "$DATA/Documents/Roll/"*; do
  case "$f" in
    *-thumb.jpg|*.json|*-src.*) ;;
    *.heic|*.jpg) sips -s format jpeg -Z 1600 "$f" --out "$OUT/prints/$(basename "${f%.*}").jpg" > /dev/null 2>&1 ;;
  esac
done
cp "$DATA/Documents/Roll/"*.json "$OUT/prints/" 2>/dev/null || true
cp ~/Library/Logs/DiagnosticReports/FilmShooter* "$OUT/diagnostics/" 2>/dev/null || true
# The app's own log (engine errors etc.).
cp "$DATA/Documents/screenshot-log.txt" "$OUT/" 2>/dev/null || true
ls -la "$OUT" "$OUT/prints"
