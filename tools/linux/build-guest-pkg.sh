#!/bin/sh
# Build the henge-guest package into a directory (default /out). Runs on the Mac, builds inside the container.
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
cp -a /tools/henge-guest "$TMP/pkg"
find "$TMP/pkg" -type d -exec chmod 0755 {} +
find "$TMP/pkg" -type f -exec chmod 0644 {} +
chmod 0755 "$TMP"/pkg/usr/lib/henge/* "$TMP"/pkg/DEBIAN/postinst "$TMP"/pkg/DEBIAN/prerm "$TMP"/pkg/DEBIAN/postrm
# A fixed time keeps the package the same between builds
find "$TMP/pkg" -exec touch -h -d @1762905600 {} +
VER=$(sed -n 's/^Version: //p' "$TMP/pkg/DEBIAN/control")
dpkg-deb --root-owner-group -Zxz --build "$TMP/pkg" "$OUTDIR/henge-guest_${VER}_all.deb" >/dev/null
echo "$OUTDIR/henge-guest_${VER}_all.deb"
