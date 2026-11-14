#!/bin/sh
# Build henge-codec-dkms_<version>_all.deb (docs/guest-video-encode-plan.md, VE4.2) into $TUX_LINUX_OUT/codec, in
# an arm64 debian:trixie container with the pinned snapshot. The module source is tools/linux/henge-codec-dkms with
# host/vcodec_dev.h, the device's ABI. Before the package, the module is built against the pinned 16 KB kernel's
# headers with -Werror, and DKMS installs the package in the container, so a source that does not build stops here.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

if [ "${1:-}" != "--inner" ]; then
    OUT=${TUX_LINUX_OUT:-$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
    mkdir -p "$OUT/codec"
    TTY=
    [ -t 0 ] && TTY=-t
    exec docker run --rm -i $TTY --platform linux/arm64 -v "$OUT/codec":/out -v "$ROOT":/src:ro \
        debian:trixie sh /src/tools/linux/build-codec-dkms-pkg.sh --inner
fi

. /src/tools/linux/versions.env
PKG=/src/tools/linux/henge-codec-dkms
VER=$(sed -n 's/^Version: //p' "$PKG/DEBIAN/control")
APT_PKGS="dpkg-dev dkms gcc make linux-headers-arm64-16k kmod"
. /src/tools/linux/snapshot-apt.sh
KVER=$(ls /usr/src | sed -n 's/^linux-headers-\(.*-arm64-16k\)$/\1/p' | head -1)
[ -n "$KVER" ] || { echo "build-codec-dkms-pkg.sh: no 16 KB kernel headers" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SRC=$T/pkg/usr/src/henge-codec-$VER
mkdir -p "$T/pkg"
cp -a "$PKG/." "$T/pkg/"
rm -rf "$T/pkg/usr/src/henge-codec"
mkdir -p "$SRC"
cp "$PKG/usr/src/henge-codec/henge_codec.c" "$PKG/usr/src/henge-codec/Makefile" /src/host/vcodec_dev.h "$SRC/"
sed "s/@VERSION@/$VER/" "$PKG/usr/src/henge-codec/dkms.conf" > "$SRC/dkms.conf"
sed -i "s/@VERSION@/$VER/" "$T/pkg/DEBIAN/postinst" "$T/pkg/DEBIAN/prerm"

# the source alone, with warnings as errors
cp -a "$SRC" "$T/try"
make -s -C "/usr/src/linux-headers-$KVER" M="$T/try" KCFLAGS=-Werror modules
modinfo "$T/try/henge_codec.ko" | grep -E '^(alias|vermagic|license):'

find "$T/pkg" -type d -exec chmod 0755 {} +
find "$T/pkg" -type f -exec chmod 0644 {} +
chmod 0755 "$T/pkg/DEBIAN/postinst" "$T/pkg/DEBIAN/prerm"
export SOURCE_DATE_EPOCH=1762905600
find "$T/pkg" -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
DEB=/out/henge-codec-dkms_${VER}_all.deb
dpkg-deb --root-owner-group -Zxz --build "$T/pkg" "$DEB" >/dev/null

# DKMS in the container: install builds the module for the kernel that has headers here
mkdir -p "/lib/modules/$KVER"
ln -sfn "/usr/src/linux-headers-$KVER" "/lib/modules/$KVER/build"
dpkg -i "$DEB" | tee "$T/install.log"
dkms status -m henge-codec -v "$VER" | grep -q "$KVER.*installed" || { echo "build-codec-dkms-pkg.sh: DKMS did not install the module" >&2; exit 1; }
ls "/lib/modules/$KVER/updates/dkms/"
dpkg -r henge-codec-dkms >/dev/null
[ -z "$(dkms status -m henge-codec)" ] || { echo "build-codec-dkms-pkg.sh: the module is still in DKMS after the remove" >&2; exit 1; }
echo "$DEB ($(du -k "$DEB" | cut -f1) KB) for kernels like $KVER"
