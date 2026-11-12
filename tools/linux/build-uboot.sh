#!/bin/sh
# Build U-Boot for the QEMU virt board. Runs on the Mac, builds inside the container.
# build-uboot.sh makes u-boot.bin with the boot-speed fragment (u-boot-henge.config);
# --stock makes u-boot-stock.bin from the unmodified defconfig, which keeps the autoboot countdown.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--inner" ]; then
    exec "$HERE/run.sh" sh /tools/build-uboot.sh --inner "$@"
fi
shift
STOCK=0
[ "${1:-}" = "--stock" ] && STOCK=1
NAME=u-boot
[ "$STOCK" = 1 ] && NAME=u-boot-stock

. /tools/versions.env

# Source stays in the /work volume (the Mac filesystem is case-insensitive)
SRC=/work/u-boot
if [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" = "$UBOOT_TAG" ]; then
    git -C "$SRC" clean -fdxq
    git -C "$SRC" checkout -q -- .
else
    rm -rf "$SRC"
    git clone -q --depth 1 --branch "$UBOOT_TAG" https://source.denx.de/u-boot/u-boot.git "$SRC"
fi

cd "$SRC"
make qemu_arm64_defconfig
if [ "$STOCK" = 0 ]; then
    ./scripts/kconfig/merge_config.sh -m .config /tools/u-boot-henge.config
    make olddefconfig
fi
make -j"$(nproc)"

cp u-boot.bin "/out/$NAME.bin"
cp .config "/out/$NAME.config"
{
    echo "tag=$UBOOT_TAG"
    echo "commit=$(git rev-parse HEAD)"
    echo "fragment=$([ "$STOCK" = 0 ] && echo u-boot-henge.config || echo none)"
    echo "sha256=$(sha256sum u-boot.bin | cut -d' ' -f1)"
} > "/out/$NAME.manifest"
cat "/out/$NAME.manifest"
