#!/bin/bash
# Builds Henge for the iOS Simulator, boots a simulator if none is booted, installs and launches it.
# Usage: ios/scripts/sim_build.sh [device name or UDID]   (default: the booted simulator, else "iPhone 18 Pro")
set -euo pipefail
cd "$(dirname "$0")/../.."
BUNDLE=com.henge.app
DD=build/ios-sim-app

. ios/scripts/gfx_env.sh
# The guest network, when tools/build_sim_net.sh has built libslirp and glib for the simulator
SIM_NET_ROOT=${SIM_NET_ROOT:-$PWD/build/husk/build/ios-sim-arm64/sysroot}
if [ -f "$SIM_NET_ROOT/lib/libslirp.a" ]; then HENGE_SIM_NET=1; else HENGE_SIM_NET=; SIM_NET_ROOT=; echo "no simulator libslirp: the guest has no network (tools/build_sim_net.sh)"; fi
make ios-sim-lib ${HENGE_GFX:+GFX=1} ${HENGE_SIM_NET:+SIM_NET_ROOT=$SIM_NET_ROOT}
(cd ios && xcodegen generate)
LOG="$DD/build.log"
mkdir -p "$DD"
# The old Henge.app survives a failed build, so the exit code decides, not the bundle.
if ! xcodebuild -project ios/Henge.xcodeproj -scheme HengeSim -skipPackagePluginValidation \
  -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath "$DD" HENGE_GFX_DIR="$GFX_ROOT" HENGE_GFX="$HENGE_GFX" HENGE_SIM_NET="$HENGE_SIM_NET" HENGE_SIM_NET_ROOT="$SIM_NET_ROOT" build >"$LOG" 2>&1; then
  grep -E 'error:' "$LOG" >&2 || tail -20 "$LOG" >&2
  echo "build failed (log: $LOG)" >&2
  exit 1
fi
grep -E 'BUILD SUCCEEDED' "$LOG"
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
