#!/bin/bash
# Builds Henge for the iOS Simulator, boots a simulator if none is booted, installs and launches it.
# Usage: ios/scripts/sim_build.sh [device name or UDID]   (default: the booted simulator, else "iPhone 18 Pro")
set -euo pipefail
cd "$(dirname "$0")/../.."
BUNDLE=com.henge.app
DD=build/ios-sim-app

make ios-sim-lib build/henge-agent.gz
tools/build_ios_restore.sh sim
(cd ios && xcodegen generate)
xcodebuild -project ios/Henge.xcodeproj -scheme HengeSim -skipPackagePluginValidation \
  -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath "$DD" build \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
APP="$DD/Build/Products/Debug-iphonesimulator/Henge.app"
[ -d "$APP" ] || { echo "build failed: no $APP" >&2; exit 1; }

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1 || true)
  DEVICE="${DEVICE:-iPhone 18 Pro}"
fi
xcrun simctl boot "$DEVICE" 2>/dev/null || true # already booted is fine
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE"
echo "log: $(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)/Documents/henge.log"
