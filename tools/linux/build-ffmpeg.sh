#!/bin/sh
# Build the patched ffmpeg for the guest (docs/guest-video-encode-plan.md, VE2.6): FFmpeg $FFMPEG_VERSION with
# tools/linux/hvcodec/ffmpeg-henge.patch, libhvcodec and henge-codec-info, for arm64 Debian trixie.
# Runs on the Mac; builds natively in an arm64 debian:trixie container with packages from the pinned snapshot.
# Output in $HENGE_LINUX_OUT/ffmpeg: bin/ffmpeg, bin/ffprobe, bin/henge-codec-info, ffmpeg.manifest.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

if [ "${1:-}" != "--inner" ]; then
    . "$HERE/versions.env"
    OUT=${HENGE_LINUX_OUT:-$HOME/Repos/Henge/build/linux}
    VOLUME=${HENGE_LINUX_VOLUME:-henge-linux-work}
    TARBALL="$OUT/ffmpeg/src/ffmpeg-$FFMPEG_VERSION.tar.xz"
    mkdir -p "$OUT/ffmpeg/src"
    if [ ! -f "$TARBALL" ]; then
        curl -fsSL -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
        mv "$TARBALL.part" "$TARBALL"
    fi
    if [ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" != "$FFMPEG_SHA256" ]; then
        echo "build-ffmpeg.sh: $TARBALL does not match FFMPEG_SHA256" >&2
        exit 1
    fi
    TTY=
    [ -t 0 ] && TTY=-t
    exec docker run --rm -i $TTY --platform linux/arm64 \
        -v "$OUT":/out \
        -v "$VOLUME":/work \
        -v "$ROOT":/src:ro \
        debian:trixie sh /src/tools/linux/build-ffmpeg.sh --inner
fi

. /src/tools/linux/versions.env
# The -dev packages are the runtime libraries' versions, so the binary matches what the guest installs
APT_PKGS="build-essential pkgconf libx264-dev libx265-dev libdav1d-dev libopus-dev libmp3lame-dev libgnutls28-dev zlib1g-dev xz-utils patch"
. /src/tools/linux/snapshot-apt.sh

NAME=ffmpeg-$FFMPEG_VERSION
SRC=/work/$NAME-henge
STAGE=/work/ffmpeg-stage
OUTDIR=/out/ffmpeg
rm -rf "$SRC" "$STAGE" "$OUTDIR/bin"
mkdir -p "$SRC" "$STAGE/include" "$STAGE/lib" "$OUTDIR/bin"
tar -xJf "$OUTDIR/src/$NAME.tar.xz" -C "$SRC" --strip-components=1
patch -d "$SRC" -p1 --quiet --forward < /src/tools/linux/hvcodec/ffmpeg-henge.patch

# libhvcodec: the client, linked in statically (LGPL-2.1-or-later, as FFmpeg's own code here)
HV=/src/tools/linux/hvcodec
cp "$HV/libhvcodec/hvcodec.h" /src/host/vcodec_proto.h "$STAGE/include/"
cc -O2 -g -Wall -Wextra -fPIC -I"$STAGE/include" -c "$HV/libhvcodec/hvcodec.c" -o "$STAGE/hvcodec.o"
ar rcs "$STAGE/lib/libhvcodec.a" "$STAGE/hvcodec.o"

CONFIGURE="--prefix=/usr/lib/henge/ffmpeg --extra-version=henge$FFMPEG_HENGE_REV \
--disable-autodetect --disable-shared --enable-static --disable-doc --disable-ffplay --disable-debug \
--enable-gpl --enable-pthreads --enable-zlib --enable-iconv --enable-gnutls \
--enable-libx264 --enable-libx265 --enable-libdav1d --enable-libopus --enable-libmp3lame \
--enable-henge"
cd "$SRC"
# shellcheck disable=SC2086
./configure $CONFIGURE --extra-cflags="-I$STAGE/include" --extra-ldflags="-L$STAGE/lib" > "$STAGE/configure.log" 2>&1 ||
    { tail -30 "$STAGE/configure.log"; exit 1; }
make -j"$(nproc)" ffmpeg ffprobe > "$STAGE/make.log" 2>&1 || { grep -n "error" "$STAGE/make.log" | head -20; exit 1; }
cc -O2 -Wall -Wextra -I"$STAGE/include" "$HV/henge-codec-info.c" "$STAGE/lib/libhvcodec.a" -lpthread -o "$STAGE/henge-codec-info"

for f in ffmpeg ffprobe; do strip -o "$OUTDIR/bin/$f" "$f"; done
strip -o "$OUTDIR/bin/henge-codec-info" "$STAGE/henge-codec-info"
"$OUTDIR/bin/ffmpeg" -hide_banner -hwaccels | grep -qx henge
"$OUTDIR/bin/ffmpeg" -hide_banner -encoders | grep -q hevc_henge

# The Debian packages that the binaries load, for the guest and for henge-ffmpeg's Depends (VE3.1)
RUNTIME=$(for f in "$OUTDIR"/bin/*; do ldd "$f"; done | awk '/=>/ {print $3}' | sed 's#^/lib/#/usr/lib/#' | sort -u |
    xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | sort -u | tr '\n' ' ')
{
    echo "release=$FFMPEG_VERSION"
    echo "henge_rev=$FFMPEG_HENGE_REV"
    echo "tarball=$NAME.tar.xz"
    echo "tarball_sha256=$FFMPEG_SHA256"
    echo "patch_sha256=$(sha256sum /src/tools/linux/hvcodec/ffmpeg-henge.patch | cut -d' ' -f1)"
    echo "libhvcodec_sha256=$(cat "$HV/libhvcodec/hvcodec.c" "$HV/libhvcodec/hvcodec.h" /src/host/vcodec_proto.h | sha256sum | cut -d' ' -f1)"
    echo "debian_snapshot=$DEBIAN_SNAPSHOT"
    echo "configure=$CONFIGURE"
    echo "build_deps=$(dpkg-query -W -f '${Package}=${Version} ' libx264-dev libx265-dev libdav1d-dev libopus-dev libmp3lame-dev libgnutls28-dev zlib1g-dev gcc)"
    echo "runtime=$RUNTIME"
    for f in ffmpeg ffprobe henge-codec-info; do echo "sha256_$f=$(sha256sum "$OUTDIR/bin/$f" | cut -d' ' -f1)"; done
} > "$OUTDIR/ffmpeg.manifest"
cat "$OUTDIR/ffmpeg.manifest"
