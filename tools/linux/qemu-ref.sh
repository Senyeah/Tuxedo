#!/bin/sh
# Boot the Henge Linux guest on QEMU virt, the reference for Henge's board.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${HENGE_LINUX_OUT:-$HOME/Repos/Henge/build/linux}
QEMU=${QEMU:-/opt/homebrew/bin/qemu-system-aarch64}

ACCEL=tcg
ITS=on
DTB=
GPU=0
DIRECT=0

usage() {
    echo "usage: qemu-ref.sh [--accel hvf|tcg] [--its-off] [--dtb FILE] [--gpu] [--direct] [-- extra qemu args]"
    exit 2
}

while [ $# -gt 0 ]; do
    case $1 in
        --accel) ACCEL=$2; shift 2 ;;
        --its-off) ITS=off; shift ;;
        --dtb) DTB=$2; shift 2 ;;
        --gpu) GPU=1; shift ;;
        --direct) DIRECT=1; shift ;;
        --) shift; break ;;
        *) usage ;;
    esac
done

# hvf aborts on U-Boot (hvf_handle_exception isv assert), so firmware boots need tcg
if [ "$ACCEL" = hvf ] && [ "$DIRECT" = 0 ]; then
    echo "qemu-ref.sh: --accel hvf needs --direct (U-Boot aborts under hvf)" >&2
    exit 2
fi

# hvf's hardware vGIC has no ITS
[ "$ACCEL" = hvf ] && ITS=off

# snapshot=on keeps the shared image unmodified
set -- -M "virt,gic-version=3,highmem=off,its=$ITS" -cpu max -smp 4 -m 2048 \
    -accel "$ACCEL" \
    -drive if=none,file="$OUT/debian-console.img",format=raw,id=d0,snapshot=on \
    -device virtio-blk-pci,drive=d0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci -device qemu-xhci -device usb-kbd "$@"

if [ "$GPU" = 1 ]; then
    set -- "$@" -device virtio-gpu-pci -display cocoa -serial mon:stdio
else
    set -- "$@" -nographic
fi

[ -n "$DTB" ] && set -- "$@" -dtb "$DTB"

if [ "$DIRECT" = 1 ]; then
    PARTUUID=$(cat "$OUT/debian-console.partuuid")
    set -- "$@" -kernel "$OUT/Image" -initrd "$OUT/initrd.img" \
        -append "root=PARTUUID=$PARTUUID rw console=ttyAMA0 console=tty0"
else
    set -- "$@" -bios "$OUT/u-boot.bin"
fi

exec "$QEMU" "$@"
