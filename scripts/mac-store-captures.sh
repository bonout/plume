#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/screenshots/raw}
DD=build/mac-shots
SERVER=${PLUME_UITEST_SERVER:-http://127.0.0.1:8099}
PASSWORD=${PLUME_UITEST_PASSWORD:-plume-demo-pass}
xcodebuild -project Plume.xcodeproj -scheme PlumeMac -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$DD" build -quiet CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM= \
  CODE_SIGN_STYLE=Manual PLUME_MAC_APP_GROUP=
APP="$DD/Build/Products/Debug/Plume.app/Contents/MacOS/Plume"

shoot() { # locale, user, language, name, launch arguments…
  local locale="$1" user="$2" language="$3" name="$4"; shift 4
  mkdir -p "$OUT/$locale"
  "$APP" -AppleLanguages "($language)" -AppleLocale "${language/-/_}" -PlumeResetAccount YES \
    -PlumeTestServer "$SERVER" -PlumeTestUser "$user" -PlumeTestPassword "$PASSWORD" \
    -PlumeSnapshot "$PWD/$OUT/$locale/Mac-$name.png" "$@" >/dev/null 2>&1 || true
  sips -c 1280 1670 --cropOffset 0 290 "$OUT/$locale/Mac-$name.png" >/dev/null
  echo "$OUT/$locale/Mac-$name.png"
}

shoot en-US demo en-US 01-browse -PlumeInitialPath "Photos/Space"
shoot en-US demo en-US 02-search -PlumeSearch resume
shoot en-US demo en-US 04-offline -PlumePin "Travel/Iceland 2026" -PlumeInitialPath "Travel/Iceland 2026"
shoot fr-FR demo-fr fr-FR 01-browse -PlumeInitialPath "Photos/Espace"
shoot fr-FR demo-fr fr-FR 02-search -PlumeSearch electricite
shoot fr-FR demo-fr fr-FR 04-offline -PlumePin "Voyages/Islande 2026" -PlumeInitialPath "Voyages/Islande 2026"
