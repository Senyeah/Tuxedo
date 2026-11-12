#!/bin/sh
# Build the Debian disk image: the console image, or with --desktop the desktop image.
# Runs on the Mac, builds inside the container.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

INNER=0
DESKTOP=0
for arg in "$@"; do
    case $arg in
        --inner) INNER=1 ;;
        --desktop) DESKTOP=1 ;;
        *) echo "usage: build-image.sh [--desktop]" >&2; exit 2 ;;
    esac
done

if [ "$INNER" = 0 ]; then
    if [ "$DESKTOP" = 1 ]; then
        exec "$HERE/run.sh" sh /tools/build-image.sh --inner --desktop
    fi
    exec "$HERE/run.sh" sh /tools/build-image.sh --inner
fi

. /tools/versions.env

MIRROR=${DEBIAN_MIRROR:-https://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT/}
SIZE_MB=3072
PKGS="linux-image-arm64-16k,systemd-sysv,udev,dbus,kmod,initramfs-tools,u-boot-menu,zstd,iproute2,iputils-ping,systemd-resolved,systemd-timesyncd,ca-certificates,sudo,less,nano,procps,cloud-guest-utils,e2fsprogs,gdisk,davfs2"

# Fixed IDs keep the image and extlinux.conf the same between builds
if [ "$DESKTOP" = 1 ]; then
    NAME=debian-desktop
    WORK=/work/G6
    # Variant A: labwc on Wayland. The GL libraries let henge-session pick gles2 when virgl is present (A7)
    PKGS="$PKGS,labwc,foot,fonts-dejavu-core,libpam-systemd,xkb-data,mesa-utils,mesa-utils-bin,glmark2-es2-wayland,libgl1-mesa-dri,libgles2,libegl1,wlr-randr,wl-clipboard,xclip,python3"
    PARTUUID=${HENGE_PARTUUID:-9c4e7a21-3d58-4b0f-a6c2-1f8d5e90b3a7}
    FSUUID=${HENGE_FSUUID:-6d0b8e35-c1a2-47f9-9e64-b7a13c52d80f}
else
    NAME=debian-console
    WORK=/work
    PARTUUID=${HENGE_PARTUUID:-5e1d9a4c-0c1e-4c7b-9f1a-6a3c0d2b7e11}
    FSUUID=${HENGE_FSUUID:-a3f1c2d4-7b6e-4d58-8c91-2e0b5f4a9d33}
fi
export PARTUUID

ROOT=$WORK/rootfs
FSIMG=$WORK/root.ext4
IMG=$WORK/$NAME.img

mkdir -p "$WORK"
rm -rf "$ROOT" "$FSIMG" "$IMG"
mkdir -p "$ROOT"

# Installed by a hook after the other packages: apt cannot see a local file in the chroot
rm -f "$WORK"/henge-guest_*.deb
sh /tools/build-guest-pkg.sh --inner "$WORK" >/dev/null
GUEST_DEB=$(ls "$WORK"/henge-guest_*.deb)

# The desktop files are copied after the packages, so they replace the packages' own defaults
set -- --customize-hook='cp "'"$GUEST_DEB"'" "$1/tmp/henge-guest.deb"; chroot "$1" dpkg -i /tmp/henge-guest.deb; rm -f "$1/tmp/henge-guest.deb"' \
    --customize-hook='cp /tools/customize.sh "$1/tmp/customize.sh"; chroot "$1" sh -e /tmp/customize.sh; rm -f "$1/tmp/customize.sh"'
if [ "$DESKTOP" = 1 ]; then
    set -- "$@" \
        --customize-hook='cp -a /tools/rootfs-desktop/. "$1"/' \
        --customize-hook='cp /tools/customize-desktop.sh "$1/tmp/customize-desktop.sh"; chroot "$1" sh -e /tmp/customize-desktop.sh; rm -f "$1/tmp/customize-desktop.sh"'
fi

# Snapshot Release files carry an old Valid-Until date
mmdebstrap --mode=root --variant=minbase --arch=arm64 \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --include="$PKGS" \
    --setup-hook='cp -a /tools/rootfs/. "$1"/' \
    "$@" \
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

# No loop devices: build the filesystem as a file, then copy it in.
# A whole number of 16 KB pages: on a 16 KB kernel resize2fs rounds its target down to one, and would see a shrink.
FSBYTES=$((SECTORS * 512 / 16384 * 16384))
truncate -s "$FSBYTES" "$FSIMG"
mke2fs -q -t ext4 -L henge-root -U "$FSUUID" -E root_owner=0:0,hash_seed="$FSUUID" -d "$ROOT" "$FSIMG"
[ $(( $(dumpe2fs -h "$FSIMG" 2>/dev/null | sed -n 's/^Block count: *//p') * 4096 % 16384 )) -eq 0 ]
dd if="$FSIMG" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
rm -f "$FSIMG"

# Direct-boot kernel and initrd for the tests. The desktop image has the same kernel, so it keeps the console image's files.
if [ "$DESKTOP" = 0 ]; then
    cp -L "$ROOT/boot/initrd.img-$KVER" /out/initrd.img
    cp "$ROOT/boot/config-$KVER" /out/config-debian-16k
    case "$VMLINUZ_FILE" in
        *"gzip compressed"*) zcat "$VMLINUZ" > /out/Image ;;
        *) cp "$VMLINUZ" /out/Image ;;
    esac
    IMAGE_FILE=$(file -b /out/Image)
else
    IMAGE_FILE=$VMLINUZ_FILE
fi

# Copy then rename, so an image that is in use is never changed half way
cp "$IMG" "/out/$NAME.img.tmp"
mv "/out/$NAME.img.tmp" "/out/$NAME.img"
echo "$PARTUUID" > "/out/$NAME.partuuid"

{
    echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mirror=$MIRROR"
    echo "suite=$DEBIAN_SUITE"
    [ "$DESKTOP" = 1 ] && echo "variant=A (labwc, foot, renderer chosen at session start: gles2 with virgl, else pixman)"
    echo "kernel_version=$KVER"
    echo "vmlinuz_file=$VMLINUZ_FILE"
    echo "image_file=$IMAGE_FILE"
    echo "rootfs_used_mb=$(du -sxm "$ROOT" | cut -f1)"
    echo "partuuid=$PARTUUID"
    echo "image_sha256=$(sha256sum /out/$NAME.img | cut -d' ' -f1)"
    echo "[extlinux.conf]"
    cat "$ROOT/boot/extlinux/extlinux.conf"
    echo "[kernel config]"
    grep -E 'CONFIG_ARM64_(4K|16K|64K)_PAGES|CONFIG_ARM64_VA_BITS|CONFIG_ARM64_PA_BITS' "$ROOT/boot/config-$KVER"
    echo "[packages]"
    chroot "$ROOT" dpkg-query -W
} > "/out/$NAME.manifest"
head -14 "/out/$NAME.manifest"
