#!/bin/sh
# Run a command in the builder image. Artefacts go to /out, sources to the /work volume.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${HENGE_LINUX_OUT:-$HOME/Repos/Henge/build/linux}
IMAGE=${HENGE_LINUX_IMAGE:-henge-linux-builder}
VOLUME=${HENGE_LINUX_VOLUME:-henge-linux-work}

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
