#!/bin/zsh
# Makes a folder Henge on iOS can bring in, for a Linux machine (twin of tools/export_ios.sh).
#   tools/linux/export-ios.sh DISK FIRMWARE [NAME] [RAM_MB] [OUTDIR]
# DISK is a Debian image (build/linux/debian-console.img), FIRMWARE is u-boot.bin.
# The disk goes in packed (disk.img.hvsparse: holes left out). Reads both inputs; writes nothing to them.
set -e
DISK=$1; FW=$2; NAME=${3:-Debian}; RAM=${4:-2048}; OUT=${5:-$HOME/Desktop/$NAME}
[ -f "$DISK" ] && [ -f "$FW" ] || { echo "usage: $0 DISK FIRMWARE [NAME] [RAM_MB] [OUTDIR]" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
make -C "$HERE" build/hvsparse >/dev/null
mkdir -p "$OUT"
cp "$FW" "$OUT/u-boot.bin"
echo "packing the disk (only its data moves)..."
"$HERE/build/hvsparse" pack "$DISK" "$OUT/disk.img.hvsparse"
cat > "$OUT/machine.json" <<JSON
{"name": "$NAME", "kind": "linux", "ramMB": $RAM}
JSON
echo "$OUT: $(du -sh "$OUT" | cut -f1)"
