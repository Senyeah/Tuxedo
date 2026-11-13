#!/bin/bash
# Records Trackpad Lab's frames and videos on the simulator for the review gate (docs/external-trackpad-plan.md).
# Each still is LabDemo stepped with a fixed 1/120 s to a time and frozen, so each run gives the same frame.
# Usage: ios/scripts/trackpad_lab_frames.sh [out dir] [--no-build] [--no-video]
# Frames are compared with build/trackpad-lab-frames/reference (made on the first run): pass is 99.5 % of
# pixels within 4/255. PHONE and PAD name the simulators (default "TPLab iPhone", "TPLab iPad").
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
OUT=$ROOT/build/trackpad-lab-evidence
BUILD=1; VIDEO=1
for a in "$@"; do
  case $a in --no-build) BUILD=0 ;; --no-video) VIDEO=0 ;; *) OUT=$a ;; esac
done
REF=$ROOT/build/trackpad-lab-frames/reference
BUNDLE=nz.jackgreenhill.henge.trackpadlab
PHONE=${PHONE:-"TPLab iPhone"}
PAD=${PAD:-"TPLab iPad"}
mkdir -p "$OUT/frames" "$OUT/video" "$REF"

udid() { xcrun simctl list devices | grep -F "$1 (" | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1; }
boot() { xcrun simctl boot "$1" 2>/dev/null || true; xcrun simctl bootstatus "$1" -b >/dev/null; }

D=$(udid "$PHONE")
if [ $BUILD = 1 ]; then ios/scripts/trackpad_lab.sh sim "$D" >/dev/null; fi
APP=$ROOT/build/trackpad-lab/Build/Products/Release-iphonesimulator/TrackpadLab.app

# name:time in the script (LabDemo.swift)
STILLS="idle:0.3 rest:1.1 move:2.0 move-fade:2.7 flick:3.2 two-fingers:4.4 ripple:5.58 ripple-right:6.38
left-key:7.3 right-key:8.2 drag:10.2 drag-fade:11.1 key-drag:12.2 keyboard-up:13.4 keyboard-tap:13.98
keyboard-right-tap:14.58 dark-again:16.4"
SUBSET="idle:0.3 move:2.0 ripple:5.58 left-key:7.3 drag:10.2 keyboard-up:13.4"

shot() { # udid tag time [args...]
  local dev=$1 tag=$2 t=$3
  shift 3
  xcrun simctl launch --terminate-running-process "$dev" "$BUNDLE" -padLayout full -padDemoAt "$t" "$@" >/dev/null
  local wait=2.5
  case " $* " in *-padOrientation*) wait=4 ;; esac
  if awk "BEGIN{exit !($t >= 13.0 && $t < 15.2)}"; then wait=$(awk "BEGIN{print $wait + 1.5}"); fi
  sleep "$wait"
  xcrun simctl io "$dev" screenshot "$OUT/frames/$tag.png" >/dev/null 2>&1
  echo "$tag"
}

run() { # simulator-name label stills [args...]
  local name=$1 label=$2 list=$3
  shift 3
  local dev
  dev=$(udid "$name")
  boot "$dev"
  xcrun simctl install "$dev" "$APP"
  for s in $list; do shot "$dev" "$label-${s%%:*}" "${s##*:}" "$@"; done
}

run "$PHONE" iphone-portrait "$STILLS" -padOrientation portrait
run "$PHONE" iphone-landscape "$STILLS" -padOrientation landscape
run "$PHONE" iphone-portrait-reducemotion "$SUBSET" -padOrientation portrait -padReduceMotion 1
run "$PHONE" iphone-portrait-contrast "$SUBSET" -padOrientation portrait -padContrast 1
run "$PHONE" iphone-portrait-buttonshapes "$SUBSET" -padOrientation portrait -padButtonShapes 1
run "$PHONE" iphone-landscape-buttonshapes "idle:0.3 left-key:7.3" -padOrientation landscape -padButtonShapes 1
# The system's own text size, not a forced setting: the labels show and the row grows.
xcrun simctl ui "$D" content_size accessibility-large
run "$PHONE" iphone-portrait-textsize-ax2 "idle:0.3 left-key:7.3" -padOrientation portrait
xcrun simctl ui "$D" content_size large
run "$PAD" ipad-portrait "$SUBSET" -padOrientation portrait
run "$PAD" ipad-landscape "$SUBSET" -padOrientation landscape

# The script's haptics, twice through (33 s), for the restraint review.
xcrun simctl launch --terminate-running-process "$D" "$BUNDLE" -padLayout full -padOrientation portrait -padHapticCount 1 >/dev/null
sleep 5
cp "$(xcrun simctl get_app_container "$D" "$BUNDLE" data)/Documents/pad-haptics.json" "$OUT/haptics-33s.json"

if [ $VIDEO = 1 ]; then
  for speed in 1 0.25; do
    xcrun simctl launch --terminate-running-process "$D" "$BUNDLE" -padLayout full -padOrientation portrait -padDemo 1 -padDemoSpeed $speed >/dev/null
    secs=$(awk "BEGIN{print 16.5 / $speed + 3.5}")
    xcrun simctl io "$D" recordVideo --codec h264 --force "$OUT/video/iphone-demo-x$speed.mp4" &
    rec=$!
    sleep "$secs"
    kill -INT $rec
    wait $rec 2>/dev/null || true
    if [ "$speed" = 1 ]; then
      cp "$(xcrun simctl get_app_container "$D" "$BUNDLE" data)/Documents/pad-stats.json" "$OUT/frame-stats-simulator.json"
    fi
  done
fi

# The recorded-frame check.
xcrun swift "$ROOT/ios/scripts/trackpad_lab_compare.swift" "$OUT/frames" "$REF"
