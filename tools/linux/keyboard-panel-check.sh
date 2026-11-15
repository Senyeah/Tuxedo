#!/bin/sh
# tux-keyboard as KWin's input method, with the panel that keeps windows above the device keyboard.
# Runs kwin_wayland with its virtual backend in a container (kwin-panel/check.py has the checks). Runs on the Mac.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE=${TUX_KWIN_IMAGE:-tux-kwin-panel}

docker build -q --platform linux/arm64 -t "$IMAGE" "$HERE/kwin-panel" >/dev/null

# SYS_NICE: kwin_wayland has that file capability, and does not start without it
exec docker run --rm --platform linux/arm64 --cap-add SYS_NICE \
    -v "$HERE":/tools:ro \
    "$IMAGE" dbus-run-session python3 -B /tools/kwin-panel/check.py
