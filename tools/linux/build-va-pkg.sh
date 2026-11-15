#!/bin/sh
# Build tux-va_<version>_arm64.deb into $TUX_LINUX_OUT/va, in an arm64 debian:trixie container with the pinned
# snapshot. tux-va/tux_va.c is the VA-API driver that goes in front of Mesa's virgl driver (the why is in that
# file). Before the package: the driver against a stand-in for Mesa's (tux-va/test). After it: the package is
# installed over mesa-va-drivers in the container and removed again, and Mesa's link must move and come back.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

if [ "${1:-}" != "--inner" ]; then
    OUT=${TUX_LINUX_OUT:-$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
    mkdir -p "$OUT/va"
    TTY=
    [ -t 0 ] && TTY=-t
    exec docker run --rm -i $TTY --platform linux/arm64 -v "$OUT/va":/out -v "$ROOT":/src:ro \
        debian:trixie sh /src/tools/linux/build-va-pkg.sh --inner
fi

. /src/tools/linux/versions.env
PKG=/src/tools/linux/tux-va
VER=$(sed -n 's/^Version: //p' "$PKG/DEBIAN/control")
APT_PKGS="dpkg-dev gcc libc6-dev libva-dev mesa-va-drivers"
. /src/tools/linux/snapshot-apt.sh
die() { echo "build-va-pkg.sh: $*" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
DRI=/usr/lib/aarch64-linux-gnu/dri
CFLAGS="-O2 -Wall -Wextra -Werror -fPIC -fvisibility=hidden"
mkdir -p "$T/pkg$DRI" "$T/pkg/usr/share/doc/tux-va" "$T/try"
# No build ID and no paths in the file: two builds give the same package
gcc $CFLAGS -shared -Wl,-z,defs -Wl,--build-id=none -ffile-prefix-map="$PKG"=. \
    -o "$T/pkg$DRI/virtio_gpu_drv_video.so" "$PKG/tux_va.c"
strip --strip-unneeded "$T/pkg$DRI/virtio_gpu_drv_video.so"

cp "$T/pkg$DRI/virtio_gpu_drv_video.so" "$T/try/"
gcc $CFLAGS -shared -o "$T/try/mesa_virtio_gpu_drv_video.so" "$PKG/test/fake_mesa.c"
gcc -O2 -Wall -Wextra -Werror -o "$T/try/test" "$PKG/test/test.c"
"$T/try/test" "$T/try" || die "the driver changed the wrong answers"

cp -a "$PKG/DEBIAN" "$T/pkg/DEBIAN"
cp /src/LICENSE "$T/pkg/usr/share/doc/tux-va/copyright"
find "$T/pkg" -type d -exec chmod 0755 {} +
find "$T/pkg" -type f -exec chmod 0644 {} +
chmod 0755 "$T/pkg/DEBIAN/preinst" "$T/pkg/DEBIAN/postrm"
export SOURCE_DATE_EPOCH=1762905600
find "$T/pkg" -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
DEB=/out/tux-va_${VER}_arm64.deb
dpkg-deb --root-owner-group -Zxz --build "$T/pkg" "$DEB" >/dev/null

MESA=$(readlink "$DRI/virtio_gpu_drv_video.so")
[ -n "$MESA" ] || die "mesa-va-drivers has no virtio_gpu_drv_video.so link"
dpkg -i "$DEB" >/dev/null
[ "$(readlink "$DRI/mesa_virtio_gpu_drv_video.so")" = "$MESA" ] && [ ! -L "$DRI/virtio_gpu_drv_video.so" ] ||
    die "after the install, Mesa's link is not at mesa_virtio_gpu_drv_video.so"
# Mesa's real driver loads through ours; with no display it has nothing to do
cat > "$T/load.c" <<EOC
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
    void *h = dlopen("$DRI/virtio_gpu_drv_video.so", RTLD_NOW);
    void *m = dlopen("$DRI/mesa_virtio_gpu_drv_video.so", RTLD_NOW);
    if (!h || !dlsym(h, "__vaDriverInit_1_0") || !m || !dlsym(m, "__vaDriverInit_1_$(sed -n 's/^#define VA_MINOR_VERSION *//p' /usr/include/va/va_version.h)"))
        return printf("%s\n", dlerror()), 1;
    return 0;
}
EOC
gcc -o "$T/load" "$T/load.c" && "$T/load" || die "the installed drivers do not load"
# An upgrade of mesa-va-drivers goes to the diverted name
DEBIAN_FRONTEND=noninteractive apt-get -q install -y --reinstall mesa-va-drivers >/dev/null
[ "$(readlink "$DRI/mesa_virtio_gpu_drv_video.so")" = "$MESA" ] && [ ! -L "$DRI/virtio_gpu_drv_video.so" ] ||
    die "a reinstall of mesa-va-drivers replaced the driver"
dpkg -r tux-va >/dev/null
[ "$(readlink "$DRI/virtio_gpu_drv_video.so")" = "$MESA" ] && [ ! -e "$DRI/mesa_virtio_gpu_drv_video.so" ] ||
    die "after the remove, Mesa's link is not back"
[ -z "$(dpkg-divert --list "$DRI/*")" ] || die "the diversion is still there after the remove"
echo "$DEB ($(du -k "$DEB" | cut -f1) KB, sha256 $(sha256sum "$DEB" | cut -c1-16))"
