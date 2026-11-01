#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
LANG_CODE=${1:-en}
DEVICE=${PLUME_VIDEO_DEVICE:-iPhone 17 Pro Max}
DD=build/site-video
WORK=$DD/work
OUT=docs/screenshots/$LANG_CODE
mkdir -p "$WORK" "$OUT"
UDID=$(xcrun simctl list devices available -j | python3 -c "import json,sys; print(next(d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']==sys.argv[1]))" "$DEVICE")
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
xcodebuild -project Plume.xcodeproj -scheme PlumeiOS -destination "id=$UDID" -derivedDataPath "$DD" build-for-testing -quiet
LOG=$WORK/test.log
TEST_RUNNER_PLUME_SITE_VIDEO=$LANG_CODE xcodebuild -project Plume.xcodeproj -scheme PlumeiOS -destination "id=$UDID" \
  -derivedDataPath "$DD" test-without-building -only-testing:PlumeUITests/SiteVideoTests > "$LOG" 2>&1 &
TEST=$!
until grep -q VIDEO-START "$LOG" 2>/dev/null; do kill -0 $TEST 2>/dev/null || { tail -20 "$LOG"; exit 1; }; sleep 0.2; done
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$WORK/raw.mov" >/dev/null 2>&1 &
RECORDER=$!
until grep -q VIDEO-END "$LOG" 2>/dev/null; do kill -0 $TEST 2>/dev/null || break; sleep 0.2; done
kill -INT $RECORDER
wait $RECORDER || true
wait $TEST || { tail -20 "$LOG"; exit 1; }
xcrun simctl status_bar "$UDID" clear
ffmpeg -y -loglevel error -i "$WORK/raw.mov" -vf "setpts=PTS/1.15,fps=30,scale=660:-2:flags=lanczos,format=yuv420p" \
  -c:v libx264 -preset slow -crf 26 -profile:v high -movflags +faststart -an "$OUT/iphone-tour.mp4"
ffmpeg -y -loglevel error -ss 0.3 -i "$OUT/iphone-tour.mp4" -frames:v 1 -q:v 3 "$OUT/iphone-tour.jpg"
ls -la "$OUT/iphone-tour.mp4" "$OUT/iphone-tour.jpg"
