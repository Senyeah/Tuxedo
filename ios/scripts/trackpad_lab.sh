#!/bin/bash
# Builds Trackpad Lab (docs/external-trackpad-plan.md) and starts it on the phone or the simulator.
# Usage: ios/scripts/trackpad_lab.sh [phone UDID]      build for iOS, install on the phone, launch
#        ios/scripts/trackpad_lab.sh sim [device]       build for the simulator, install, launch
#        ios/scripts/trackpad_lab.sh build              build for iOS only (signed, team BPWS3F8T7H)
# The phone's UDID: xcrun devicectl list devices.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
BUNDLE=nz.jackgreenhill.henge.trackpadlab
DD=$ROOT/build/trackpad-lab
TEAM=${TEAM:-BPWS3F8T7H}
mkdir -p "$DD"
(cd ios/TrackpadLab && xcodegen generate --quiet)

if [ "${1:-}" = sim ]; then
  LOG=$DD/sim-build.log
  xcodebuild -project ios/TrackpadLab/TrackpadLab.xcodeproj -scheme TrackpadLab -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build >"$LOG" 2>&1 \
    || { grep -E 'error:' "$LOG" >&2 || tail -20 "$LOG" >&2; echo "build failed (log: $LOG)" >&2; exit 1; }
  APP=$DD/Build/Products/Release-iphonesimulator/TrackpadLab.app
  DEVICE=${2:-}
  if [ -z "$DEVICE" ]; then
    DEVICE=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1 || true)
    DEVICE=${DEVICE:-iPhone 18 Pro}
  fi
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE"
  exit 0
fi

LOG=$DD/build.log
xcodebuild -project ios/TrackpadLab/TrackpadLab.xcodeproj -scheme TrackpadLab -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build >"$LOG" 2>&1 \
  || { grep -E 'error:' "$LOG" >&2 || tail -20 "$LOG" >&2; echo "build failed (log: $LOG)" >&2; exit 1; }
APP=$DD/Build/Products/Release-iphoneos/TrackpadLab.app
echo "built $APP"
[ "${1:-}" = build ] && exit 0

PHONE=${1:-}
if [ -z "$PHONE" ]; then
  echo "name the phone: $0 <UDID> (xcrun devicectl list devices)" >&2
  exit 1
fi
xcrun devicectl device install app --device "$PHONE" "$APP"
xcrun devicectl device process launch --device "$PHONE" "$BUNDLE"
