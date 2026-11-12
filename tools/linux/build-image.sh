#!/bin/sh
# Build the Debian console disk image. Runs on the Mac, builds inside the container.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--inner" ]; then
    exec "$HERE/run.sh" sh /tools/build-image.sh --inner
fi

. /tools/versions.env

MIRROR=${DEBIAN_MIRROR:-https://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT/}
ROOT=/work/rootfs
FSIMG=/work/root.ext4
IMG=/work/debian-console.img
SIZE_MB=3072
PKGS="linux-image-arm64-16k,systemd-sysv,udev,dbus,kmod,initramfs-tools,u-boot-menu,zstd,iproute2,iputils-ping,systemd-resolved,systemd-timesyncd,ca-certificates,sudo,less,nano,procps,cloud-guest-utils,e2fsprogs"

# Fixed IDs keep the image and extlinux.conf the same between builds
PARTUUID=${HENGE_PARTUUID:-5e1d9a4c-0c1e-4c7b-9f1a-6a3c0d2b7e11}
FSUUID=${HENGE_FSUUID:-a3f1c2d4-7b6e-4d58-8c91-2e0b5f4a9d33}
export PARTUUID

rm -rf "$ROOT" "$FSIMG" "$IMG"
mkdir -p "$ROOT"

# Snapshot Release files carry an old Valid-Until date
mmdebstrap --mode=root --variant=minbase --arch=arm64 \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --include="$PKGS" \
    --setup-hook='cp -a /tools/rootfs/. "$1"/' \
    --customize-hook='cp /tools/customize.sh "$1/tmp/customize.sh"; chroot "$1" sh -e /tmp/customize.sh; rm -f "$1/tmp/customize.sh"' \
    "$DEBIAN_SUITE" "$ROOT" "deb $MIRROR $DEBIAN_SUITE main"

# The vmlinuz format decides what G4 must do
VMLINUZ=$(ls "$ROOT"/boot/vmlinuz-* | sort -V | tail -n 1)
KVER=${VMLINUZ##*/vmlinuz-}
VMLINUZ_FILE=$(file -b "$VMLINUZ")
echo "vmlinuz: $VMLINUZ_FILE"

# GPT with one partition at 1 MB and the legacy-boot attribute
truncate -s ${SIZE_MB}M "$IMG"
sgdisk -o -n 1:2048:0 -t 1:8300 -c 1:henge-root -A 1:set:2 -u 1:"$PARTUUID" "$IMG" >/dev/null
SECTORS=$(sgdisk -i 1 "$IMG" | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')
[ -n "$SECTORS" ]

# No loop devices: build the filesystem as a file, then copy it in
truncate -s $((SECTORS * 512)) "$FSIMG"
mke2fs -q -t ext4 -L henge-root -U "$FSUUID" -E root_owner=0:0,hash_seed="$FSUUID" -d "$ROOT" "$FSIMG"
dd if="$FSIMG" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
rm -f "$FSIMG"

# Direct-boot kernel and initrd for the tests
cp -L "$ROOT/boot/initrd.img-$KVER" /out/initrd.img
cp "$ROOT/boot/config-$KVER" /out/config-debian-16k
case "$VMLINUZ_FILE" in
    *"gzip compressed"*) zcat "$VMLINUZ" > /out/Image ;;
    *) cp "$VMLINUZ" /out/Image ;;
esac
IMAGE_FILE=$(file -b /out/Image)

cp "$IMG" /out/debian-console.img
echo "$PARTUUID" > /out/debian-console.partuuid

{
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mirror=$MIRROR"
    echo "suite=$DEBIAN_SUITE"
    echo "kernel_version=$KVER"
    echo "vmlinuz_file=$VMLINUZ_FILE"
    echo "image_file=$IMAGE_FILE"
    echo "partuuid=$PARTUUID"
    echo "image_sha256=$(sha256sum /out/debian-console.img | cut -d' ' -f1)"
    echo "[extlinux.conf]"
    cat "$ROOT/boot/extlinux/extlinux.conf"
    echo "[kernel config]"
    grep -E 'CONFIG_ARM64_(4K|16K|64K)_PAGES|CONFIG_ARM64_VA_BITS|CONFIG_ARM64_PA_BITS' "$ROOT/boot/config-$KVER"
    echo "[packages]"
    chroot "$ROOT" dpkg-query -W
} > /out/debian-console.manifest
head -14 /out/debian-console.manifest
