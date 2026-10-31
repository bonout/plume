#!/usr/bin/env bash
# Archives the app in Release, signed for distribution with your team, and
# uploads it to App Store Connect for TestFlight.
#
#   PLUME_TEAM=ABCDE12345 PLUME_BUNDLE_PREFIX=com.example.plume scripts/testflight.sh ios
#   … scripts/testflight.sh mac
#
# Without these variables, the values of Config/Local.xcconfig
# (scripts/configure.sh) are used.
#
# Prerequisites:
# - a paid Apple Developer Program membership;
# - the app's record in App Store Connect (Apps → +, platforms iOS and
#   macOS, bundle identifier <prefix>). Xcode registers the bundle
#   identifiers of the extensions on the first archive; on
#   developer.apple.com, the iPhone app group group.<prefix> must be
#   assigned to the three identifiers (App Groups → Configure);
# - the upload: the Apple account signed in to Xcode (Settings → Accounts) is
#   enough, or an App Store Connect API key (Admin role) passed through
#   ASC_KEY_PATH (.p8 file, kept out of the repository), ASC_KEY_ID and
#   ASC_ISSUER_ID.
#
# The build number is the timestamp (YYYYMMDDHHMM): each upload exceeds the
# previous one, as App Store Connect requires. PLUME_BUILD overrides it.
#
# PLUME_TESTFLIGHT_DRY_RUN=1 signs and exports without uploading.
#
# PLUME_TESTFLIGHT_INTERNAL=1 marks the build for internal testing only: it
# can then never be submitted to the App Store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios) SCHEME=PlumeiOS; DESTINATION='generic/platform=iOS'
       # iOS needs a provisioning profile for every extension even to
       # archive: development signing, with the account or the API key.
       SIGNING=(CODE_SIGN_STYLE=Automatic) ;;
  mac) SCHEME=PlumeMac; DESTINATION='generic/platform=macOS'
       # The Mac archive is signed for this machine only; the export signs
       # it for distribution. No development profile, so no need to
       # register the building Mac (a new one on every CI run).
       SIGNING=(CODE_SIGN_STYLE=Automatic) ;;
  *) echo "usage: scripts/testflight.sh ios|mac" >&2; exit 1 ;;
esac

local_setting() { sed -nE "s/^$1 *= *(.*)$/\1/p" Config/Local.xcconfig 2>/dev/null | tail -1; }
TEAM="${PLUME_TEAM:-$(local_setting DEVELOPMENT_TEAM)}"
PREFIX="${PLUME_BUNDLE_PREFIX:-$(local_setting PLUME_BUNDLE_PREFIX)}"
[[ -n "$TEAM" && -n "$PREFIX" ]] || {
  echo "Set PLUME_TEAM and PLUME_BUNDLE_PREFIX, or run scripts/configure.sh first." >&2; exit 1; }
BUILD="${PLUME_BUILD:-$(date -u +%Y%m%d%H%M)}"
[[ "${PLUME_TESTFLIGHT_INTERNAL:-0}" == 1 ]] && INTERNAL=true || INTERNAL=false
[[ "${PLUME_TESTFLIGHT_DRY_RUN:-0}" == 1 ]] && DESTINATION_KIND=export || DESTINATION_KIND=upload
OUT="build/testflight-$PLATFORM"
ARCHIVE="$OUT/Plume.xcarchive"

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "${ASC_KEY_ID:?}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?}")
fi

rm -rf "$OUT"
mkdir -p "$OUT"
scripts/generate.sh

xcodebuild -project Plume.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination "$DESTINATION" -derivedDataPath "build/DerivedData-$PLATFORM" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" PLUME_BUNDLE_PREFIX="$PREFIX" "${SIGNING[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive -quiet

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION_KIND</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>testFlightInternalTestingOnly</key><$INTERNAL/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

[[ "$DESTINATION_KIND" == export ]] && { echo "Exported to $OUT/export (dry run, nothing uploaded)."; exit 0; }
echo "Uploaded to App Store Connect ($PLATFORM): version $(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist"), build $BUILD."
echo "It appears in TestFlight after Apple's processing (usually 5 to 15 minutes)."
