#!/bin/sh
# Build henge-ffmpeg_<version>_arm64.deb (docs/guest-video-encode-plan.md, VE3.1, VE3.2) from the build of
# build-ffmpeg.sh in $TUX_LINUX_OUT/ffmpeg, in an arm64 debian:trixie container with the pinned snapshot.
# The binaries go in /usr/lib/henge/ffmpeg/bin; postinst links ffmpeg and ffprobe into /usr/local/bin.
# The man page is tools/linux/hvcodec/ffmpeg-henge.7.md through pandoc, and must pass hvcodec/manpage-check.py.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

if [ "${1:-}" != "--inner" ]; then
    OUT=${TUX_LINUX_OUT:-$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
    if [ ! -f "$OUT/ffmpeg/ffmpeg.manifest" ]; then
        echo "build-ffmpeg-pkg.sh: no $OUT/ffmpeg/ffmpeg.manifest; run build-ffmpeg.sh (make linux-ffmpeg) first" >&2
        exit 1
    fi
    TTY=
    [ -t 0 ] && TTY=-t
    exec docker run --rm -i $TTY --platform linux/arm64 \
        -v "$OUT":/out \
        -v "$ROOT":/src:ro \
        debian:trixie sh /src/tools/linux/build-ffmpeg-pkg.sh --inner
fi

. /src/tools/linux/versions.env
HV=/src/tools/linux/hvcodec
M=/out/ffmpeg/ffmpeg.manifest
BIN=/out/ffmpeg/bin
get() { sed -n "s/^$1=//p" "$M"; }
die() { echo "build-ffmpeg-pkg.sh: $*" >&2; exit 1; }

# A stale build must not go out under this version: the manifest must match the sources and the binaries.
[ "$(get release)" = "$FFMPEG_VERSION" ] && [ "$(get henge_rev)" = "$FFMPEG_TUX_REV" ] ||
    die "the build is FFmpeg $(get release) henge$(get henge_rev), versions.env says $FFMPEG_VERSION henge$FFMPEG_TUX_REV; run make linux-ffmpeg"
[ "$(get patch_sha256)" = "$(sha256sum "$HV/ffmpeg-henge.patch" | cut -d' ' -f1)" ] ||
    die "ffmpeg-henge.patch changed since the build; run make linux-ffmpeg (and raise FFMPEG_TUX_REV if it was published)"
[ "$(get libhvcodec_sha256)" = "$(cat "$HV/libhvcodec/hvcodec.c" "$HV/libhvcodec/hvcodec.h" /src/host/vcodec_proto.h /src/host/vcodec_dev.h | sha256sum | cut -d' ' -f1)" ] ||
    die "libhvcodec changed since the build; run make linux-ffmpeg"
for f in ffmpeg ffprobe henge-codec-info; do
    [ "$(get "sha256_$f")" = "$(sha256sum "$BIN/$f" | cut -d' ' -f1)" ] || die "$BIN/$f is not the binary in the manifest"
done

APT_PKGS="dpkg-dev pandoc man-db python3-minimal xz-utils $(get runtime)"
. /src/tools/linux/snapshot-apt.sh

VER=$FFMPEG_VERSION-henge$FFMPEG_TUX_REV
SOURCE_URL=https://walkies.site/henge-linux-catalogue/source/ffmpeg-$VER/
DEB=/out/ffmpeg/henge-ffmpeg_${VER}_arm64.deb
export SOURCE_DATE_EPOCH=1762905600
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
P=$T/pkg
DOC=$P/usr/share/doc/henge-ffmpeg
install -d "$P/DEBIAN" "$P/usr/lib/henge/ffmpeg/bin" "$P/usr/bin" "$P/usr/share/man/man7" "$DOC"
for f in ffmpeg ffprobe henge-codec-info; do install -m 0755 "$BIN/$f" "$P/usr/lib/henge/ffmpeg/bin/$f"; done
ln -s ../lib/henge/ffmpeg/bin/henge-codec-info "$P/usr/bin/henge-codec-info"

pandoc -s -f markdown -t man -M footer="henge-ffmpeg $VER" "$HV/ffmpeg-henge.7.md" -o "$T/ffmpeg-henge.7"
gzip -9n -c "$T/ffmpeg-henge.7" > "$P/usr/share/man/man7/ffmpeg-henge.7.gz"
python3 "$HV/manpage-check.py" --ffmpeg "$P/usr/lib/henge/ffmpeg/bin/ffmpeg" "$P/usr/share/man/man7/ffmpeg-henge.7.gz"

sed -e "s#@SOURCE_URL@#$SOURCE_URL#" -e "s#@FFMPEG_VERSION@#$FFMPEG_VERSION#" /src/tools/linux/henge-ffmpeg/copyright > "$DOC/copyright"
tar -xJOf "/out/ffmpeg/src/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION/LICENSE.md" > "$DOC/LICENSE.md"
cp "$M" "$DOC/ffmpeg.manifest"
cp /src/tools/linux/henge-ffmpeg/DEBIAN/postinst /src/tools/linux/henge-ffmpeg/DEBIAN/prerm "$P/DEBIAN/"

# dpkg-shlibdeps reads a debian/control
mkdir -p "$T/src/debian"
printf 'Source: henge-ffmpeg\n\nPackage: henge-ffmpeg\nArchitecture: arm64\n' > "$T/src/debian/control"
DEPENDS=$(cd "$T/src" && dpkg-shlibdeps -O -e"$P/usr/lib/henge/ffmpeg/bin/ffmpeg" -e"$P/usr/lib/henge/ffmpeg/bin/ffprobe" \
    -e"$P/usr/lib/henge/ffmpeg/bin/henge-codec-info" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$DEPENDS" ] || die "dpkg-shlibdeps gave no dependencies"

cat > "$P/DEBIAN/control" <<EOF
Package: henge-ffmpeg
Version: $VER
Architecture: arm64
Maintainer: Henge <henge@localhost>
Installed-Size: $(du -sk --exclude=DEBIAN "$P" | cut -f1)
Depends: $DEPENDS
Recommends: man-db
Section: video
Priority: optional
Description: ffmpeg with the device's hardware video codecs, for Henge guests
 FFmpeg $FFMPEG_VERSION with the Henge codecs: -hwaccel henge (H.264, HEVC, AV1
 and VP9 decode on the device), the encoders h264_henge, hevc_henge,
 mjpeg_henge and av1_henge, and the scale_henge filter. The frames stay on the
 device, so a transcode uses almost no CPU in the guest.
 .
 The commands ffmpeg and ffprobe in /usr/local/bin are links to this build,
 and come before Debian's in PATH. Debian's ffmpeg stays at /usr/bin/ffmpeg.
 See ffmpeg-henge(7) and henge-codec-info.
EOF

(cd "$P" && find usr -type f -exec md5sum {} + | sort -k2 > DEBIAN/md5sums)
find "$P" -type d -exec chmod 0755 {} +
find "$P" -type f -exec chmod 0644 {} +
chmod 0755 "$P"/usr/lib/henge/ffmpeg/bin/* "$P/DEBIAN/postinst" "$P/DEBIAN/prerm"
find "$P" -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
dpkg-deb --root-owner-group -Zxz --build "$P" "$DEB" >/dev/null
dpkg-deb -I "$DEB" | sed -n '/Package:/,/Description:/p'
echo "$DEB $(stat -c %s "$DEB") bytes, sha256 $(sha256sum "$DEB" | cut -d' ' -f1)"
