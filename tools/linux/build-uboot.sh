#!/bin/sh
# Build U-Boot for the QEMU virt board. Runs on the Mac, builds inside the container.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--inner" ]; then
    exec "$HERE/run.sh" sh /tools/build-uboot.sh --inner
fi

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
make -j"$(nproc)"

cp u-boot.bin /out/u-boot.bin
cp .config /out/u-boot.config
{
    echo "tag=$UBOOT_TAG"
    echo "commit=$(git rev-parse HEAD)"
    echo "sha256=$(sha256sum u-boot.bin | cut -d' ' -f1)"
} > /out/u-boot.manifest
cat /out/u-boot.manifest
