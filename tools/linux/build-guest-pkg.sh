#!/bin/sh
# Build the tux-guest package into a directory (default /out). Runs on the Mac, builds inside the container.
# build-image.sh calls the same --inner step, so this is for a package on its own.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != --inner ]; then
    exec "$HERE/run.sh" sh /tools/build-guest-pkg.sh --inner
fi

OUTDIR=${2:-/out}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The tools mount is read only, and dpkg-deb wants clean modes
cp -a /tools/tux-guest "$TMP/pkg"
find "$TMP/pkg" -type d -exec chmod 0755 {} +
find "$TMP/pkg" -type f -exec chmod 0644 {} +
chmod 0755 "$TMP"/pkg/usr/lib/tux/* "$TMP"/pkg/DEBIAN/preinst "$TMP"/pkg/DEBIAN/postinst "$TMP"/pkg/DEBIAN/prerm "$TMP"/pkg/DEBIAN/postrm
# A fixed time keeps the package the same between builds (SOURCE_DATE_EPOCH: the ar member times)
export SOURCE_DATE_EPOCH=1762905600
find "$TMP/pkg" -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
VER=$(sed -n 's/^Version: //p' "$TMP/pkg/DEBIAN/control")
dpkg-deb --root-owner-group -Zxz --build "$TMP/pkg" "$OUTDIR/tux-guest_${VER}_all.deb" >/dev/null
echo "$OUTDIR/tux-guest_${VER}_all.deb"
