#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Run a command in the builder image. Artefacts go to /out, sources to the /work volume.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${TUX_LINUX_OUT:-$(cd "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
IMAGE=${TUX_LINUX_IMAGE:-tux-linux-builder}
VOLUME=${TUX_LINUX_VOLUME:-tux-linux-work}

mkdir -p "$OUT"

# Rebuild is cheap when the layers are cached
docker build -q --platform linux/arm64 -t "$IMAGE" "$HERE" >/dev/null

# -t only when stdin is a terminal, so scripts and CI work
TTY=
[ -t 0 ] && TTY=-t

exec docker run --rm -i $TTY --platform linux/arm64 \
    -v "$OUT":/out \
    -v "$VOLUME":/work \
    -v "$HERE":/tools:ro \
    "$IMAGE" "$@"
