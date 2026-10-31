#!/usr/bin/env bash
# Screenshots of the app against the throwaway server of
# scripts/test-server.sh (start it first), into docs/screenshots.
# Debug builds, put in the right state by launch arguments (App/DebugLaunch.swift).
# The Mac app snapshots its own window: no screen recording permission needed.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs/screenshots
DD=build/screenshots
mkdir -p "$OUT"
LOGIN=(-PlumeTestServer http://127.0.0.1:8099 -PlumeTestUser admin -PlumeTestPassword plume-test-pass)
scripts/generate.sh >/dev/null

shoot_ios() { # device name, output, launch arguments…
  local device="$1" out="$2"; shift 2
  local app="$DD/Build/Products/Debug-iphonesimulator/Plume.app"
  local id; id="$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")"
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null
  xcrun simctl install "$device" "$app"
  xcrun simctl terminate "$device" "$id" 2>/dev/null || true
  xcrun simctl launch "$device" "$id" "${LOGIN[@]}" "$@" >/dev/null
  sleep 9
  xcrun simctl io "$device" screenshot "$OUT/$out" >/dev/null 2>&1
  echo "$OUT/$out"
}

xcodebuild -project Plume.xcodeproj -scheme PlumeiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build -quiet
IPHONE="${PLUME_IPHONE:-iPhone 17 Pro}"
IPAD="${PLUME_IPAD:-iPad Pro 13-inch (M5)}"
shoot_ios "$IPHONE" iphone-files.png
shoot_ios "$IPHONE" iphone-folder.png -PlumeInitialPath "Lisbon 2026" -PlumePin "Lisbon 2026"
shoot_ios "$IPHONE" iphone-preview.png -PlumeInitialPath "Taxes" -PlumePreview "Taxes/Tax return 2025.pdf"
shoot_ios "$IPAD" ipad-photos.png -PlumeInitialPath "Photos"

# Mac: signed ad hoc and without entitlements (no team needed); the
# extensions don't run, and without an app group the data stays in a
# temporary folder: the window is all that matters here.
xcodebuild -project Plume.xcodeproj -scheme PlumeMac -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$DD" build -quiet CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual PLUME_MAC_APP_GROUP=
"$DD/Build/Products/Debug/Plume.app/Contents/MacOS/Plume" "${LOGIN[@]}" -PlumeInitialPath "Lisbon 2026" \
  -PlumeSnapshot "$PWD/$OUT/mac.png" >/dev/null 2>&1
echo "$OUT/mac.png"
