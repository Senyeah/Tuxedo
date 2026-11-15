#!/bin/bash
# G7: pack a guest image for download and add it to linux-images.json. Runs on a Mac (needs build/hvsparse).
# Usage: package-image.sh --image FILE --kind console|desktop [--out DIR] [--firmware FILE] [--manifest FILE]
#        [--date YYYYMMDD] [--min-build N] [--no-verify] [--touch]
# --touch: "touch": true in the entry, so a machine installed from it starts in touch mode (a Plasma image).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LINUX=${TUX_LINUX_OUT:-$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
IMAGE= KIND= OUT= FIRMWARE=$LINUX/u-boot.bin MANIFEST= VERIFY=1 MIN_BUILD= TOUCH=0
DATE=$(TZ=Etc/GMT-12 date +%Y%m%d)

while [ $# -gt 0 ]; do
    case $1 in
        --image) IMAGE=$2; shift 2 ;;
        --kind) KIND=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --firmware) FIRMWARE=$2; shift 2 ;;
        --manifest) MANIFEST=$2; shift 2 ;;
        --date) DATE=$2; shift 2 ;;
        --min-build) MIN_BUILD=$2; shift 2 ;;
        --no-verify) VERIFY=0; shift ;;
        --touch) TOUCH=1; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -f "$IMAGE" ] || { echo "--image FILE is required" >&2; exit 2; }
case $KIND in console|desktop) ;; *) echo "--kind console|desktop is required" >&2; exit 2 ;; esac
[ -f "$FIRMWARE" ] || { echo "no firmware at $FIRMWARE" >&2; exit 2; }
OUT=${OUT:-$LINUX/dist}
MANIFEST=${MANIFEST:-${IMAGE%.img}.manifest}
[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST (--manifest)" >&2; exit 2; }
# The first build that can install Linux: one past the build in Info.plist now
[ -n "$MIN_BUILD" ] || MIN_BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ROOT/ios/Tuxedo/Info.plist") + 1 ))

HVSPARSE=$ROOT/build/hvsparse
[ -x "$HVSPARSE" ] || make -C "$ROOT" build/hvsparse >/dev/null
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { wc -c < "$1" | tr -d ' '; }

mkdir -p "$OUT"
BASE=debian-$KIND-$DATE
TMP=$(mktemp -d "$OUT/.pack.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "pack $IMAGE"
"$HVSPARSE" pack "$IMAGE" "$TMP/disk.img.hvsparse"
echo "compress"
compression_tool -encode -a lzfse -i "$TMP/disk.img.hvsparse" -o "$TMP/$BASE.hvsparse.lzfse"

IMG_SHA=$(sha "$IMAGE")
WANT=$(sed -n 's/^image_sha256=//p' "$MANIFEST")
[ -z "$WANT" ] || [ "$WANT" = "$IMG_SHA" ] || { echo "image SHA-256 differs from the manifest's image_sha256" >&2; exit 1; }

if [ "$VERIFY" = 1 ]; then
    echo "verify: decode, unpack, compare"
    compression_tool -decode -a lzfse -i "$TMP/$BASE.hvsparse.lzfse" -o "$TMP/back.hvsparse"
    "$HVSPARSE" unpack "$TMP/back.hvsparse" "$TMP/back.img"
    [ "$(sha "$TMP/back.img")" = "$IMG_SHA" ] || { echo "round trip SHA-256 mismatch" >&2; exit 1; }
    rm -f "$TMP/back.img" "$TMP/back.hvsparse"
    echo "round trip matches $IMG_SHA"
fi

FW_SHA=$(sha "$FIRMWARE")
FW_NAME=u-boot-${FW_SHA:0:12}.bin
[ -f "$OUT/$FW_NAME" ] || cp "$FIRMWARE" "$OUT/$FW_NAME"

UNPACKED=$(size "$TMP/disk.img.hvsparse")
mv -f "$TMP/$BASE.hvsparse.lzfse" "$OUT/$BASE.hvsparse.lzfse"
DISK_SHA=$(sha "$OUT/$BASE.hvsparse.lzfse")

KERNEL=$(sed -n 's/^kernel_version=//p' "$MANIFEST")
# Empty for an image from before Tuxedo: no key, and the app reads the legacy user
GUEST_USER=$(sed -n 's/^guest_user=//p' "$MANIFEST")
python3 - "$OUT/linux-images.json" "$KIND" "$DATE" "$KERNEL" "$MIN_BUILD" \
    "$BASE.hvsparse.lzfse" "$(size "$OUT/$BASE.hvsparse.lzfse")" "$DISK_SHA" "$UNPACKED" "$(size "$IMAGE")" \
    "$FW_NAME" "$(size "$FIRMWARE")" "$FW_SHA" "$TOUCH" "$GUEST_USER" <<'PY'
import json, os, sys
(path, kind, date, kernel, min_build, disk, disk_bytes, disk_sha, unpacked, logical,
 fw, fw_bytes, fw_sha, touch, guest_user) = sys.argv[1:]
entry = {
    "id": f"debian-{kind}",
    "name": "Debian 13 (console)" if kind == "console" else "Debian 13 (desktop)",
    "version": date,
    "kind": kind,
    "diskURL": disk,
    "diskBytes": int(disk_bytes),
    "diskSHA256": disk_sha,
    "unpackedBytes": int(unpacked),
    "logicalBytes": int(logical),
    "firmwareURL": fw,
    "firmwareBytes": int(fw_bytes),
    "firmwareSHA256": fw_sha,
    "kernel": kernel,
    "minBuild": int(min_build),
    **({"touch": True} if touch == "1" else {}),
    **({"guestUser": guest_user} if guest_user else {}),
}
cat = {"images": []}
if os.path.exists(path):
    cat = json.load(open(path))
cat["images"] = [e for e in cat["images"] if e["id"] != entry["id"]] + [entry]
cat["images"].sort(key=lambda e: e["id"])
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cat, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
echo "wrote $OUT/$BASE.hvsparse.lzfse and updated $OUT/linux-images.json"
