#!/usr/bin/env bash
# Archives the iPhone/iPad app in Release, signed for distribution with your
# team, and uploads it to App Store Connect for TestFlight.
#
#   PLUME_TEAM=ABCDE12345 PLUME_BUNDLE_PREFIX=com.example.plume scripts/testflight-ios.sh
#
# Without these variables, the values of Config/Local.xcconfig
# (scripts/configure.sh) are used.
#
# Prerequisites:
# - a paid Apple Developer Program membership;
# - the app's record in App Store Connect (Apps → +, platform iOS, bundle
#   identifier <prefix>). Xcode registers the bundle identifiers of the app
#   and its extensions, and the app group, on the first archive;
# - the upload: the Apple account signed in to Xcode (Settings → Accounts) is
#   enough, or an App Store Connect API key (Admin role) passed through
#   ASC_KEY_PATH (.p8 file, kept out of the repository), ASC_KEY_ID and
#   ASC_ISSUER_ID.
#
# The build number is the timestamp (YYYYMMDDHHMM): each upload exceeds the
# previous one, as App Store Connect requires. PLUME_BUILD overrides it.
#
# PLUME_TESTFLIGHT_INTERNAL=1 marks the build for internal testing only: it
# can then never be submitted to the App Store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

local_setting() { sed -nE "s/^$1 *= *(.*)$/\1/p" Config/Local.xcconfig 2>/dev/null | tail -1; }
TEAM="${PLUME_TEAM:-$(local_setting DEVELOPMENT_TEAM)}"
PREFIX="${PLUME_BUNDLE_PREFIX:-$(local_setting PLUME_BUNDLE_PREFIX)}"
[[ -n "$TEAM" && -n "$PREFIX" ]] || {
  echo "Set PLUME_TEAM and PLUME_BUNDLE_PREFIX, or run scripts/configure.sh first." >&2; exit 1; }
BUILD="${PLUME_BUILD:-$(date -u +%Y%m%d%H%M)}"
[[ "${PLUME_TESTFLIGHT_INTERNAL:-0}" == 1 ]] && INTERNAL=true || INTERNAL=false
OUT="build/testflight"
ARCHIVE="$OUT/Plume.xcarchive"

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi

rm -rf "$OUT"
mkdir -p "$OUT"
scripts/generate.sh

xcodebuild -project Plume.xcodeproj -scheme PlumeiOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData-device \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" PLUME_BUNDLE_PREFIX="$PREFIX" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive -quiet

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>testFlightInternalTestingOnly</key><$INTERNAL/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

echo "Uploaded to App Store Connect: version $(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist"), build $BUILD."
echo "It appears in TestFlight after Apple's processing (usually 5 to 15 minutes)."
