#!/bin/bash
# libffi, glib and libslirp for the iOS Simulator, so TuxSim's guests get a network.
# Husk's build_ios.sh builds for iphoneos only; this runs a copy of it with the simulator SDK.
# Output: $HUSK/build/ios-sim-arm64/sysroot (make ios-sim-lib uses it when it exists).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HUSK=${HUSK:-$REPO/build/husk}
[ -f "$HUSK/scripts/build_ios.sh" ] || { echo "no Husk checkout at $HUSK (set HUSK)" >&2; exit 1; }
[ -d "$HUSK/third_party/build" ] || { echo "run Husk's scripts/fetch_sources.sh first" >&2; exit 1; }

# Its own source tree: the autotools stages build in the source directory
SIMSRC="$HUSK/third_party/build-sim"
if [ ! -d "$SIMSRC" ]; then
    /bin/cp -c -R "$HUSK/third_party/build" "$SIMSRC"
    find "$SIMSRC" -maxdepth 2 -name _husk_build -type d -exec rm -rf {} +
    (cd "$SIMSRC/libffi-3.5.0" && { make distclean >/dev/null 2>&1 || true; })
fi

SCRIPT="$HUSK/scripts/.build_ios_sim.sh"
sed -e 's|^SRC="\$HUSK_ROOT/third_party/build"|SRC="$HUSK_ROOT/third_party/build-sim"|' \
    -e 's|ios-arm64|ios-sim-arm64|g' \
    -e 's|build/stamps"|build/stamps-sim"|' -e 's|build/logs"|build/logs-sim"|' \
    -e 's|^SDK=iphoneos|SDK=iphonesimulator|' \
    -e 's|^CFLAGS_TARGET="-target \$ARCH-apple-ios\$SDKMINVER"|CFLAGS_TARGET="-target $ARCH-apple-ios$SDKMINVER-simulator"|' \
    -e "s|subsystem = 'ios'|subsystem = 'ios-simulator'|" \
    "$HUSK/scripts/build_ios.sh" > "$SCRIPT"
for want in 'third_party/build-sim' 'build/stamps-sim' 'SDK=iphonesimulator' 'ios$SDKMINVER-simulator' "ios-simulator'"; do
    grep -qF "$want" "$SCRIPT" || { echo "build_ios.sh changed: no '$want' after the edit" >&2; exit 1; }
done
PATH="$REPO/build/gfx/work/venv/bin:$PATH" bash "$SCRIPT" libffi glib libslirp
OUT="$HUSK/build/ios-sim-arm64/sysroot"
for l in libslirp libglib-2.0 libintl libpcre2-8; do
    xcrun vtool -show-build "$OUT/lib/$l.a" 2>/dev/null | grep -q IOSSIMULATOR ||
        { mkdir -p "$OUT/.check" && (cd "$OUT/.check" && ar x "$OUT/lib/$l.a" && xcrun vtool -show-build "$(ls | grep "\.o$" | head -1)" | grep -q IOSSIMULATOR) ||
          { echo "$l.a is not built for the simulator" >&2; exit 1; }; rm -rf "$OUT/.check"; }
done
echo "simulator network libraries in $OUT"
