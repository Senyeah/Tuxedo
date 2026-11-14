#!/bin/zsh
# Builds Tuxedo for iOS and writes ~/Desktop/Tuxedo.ipa (or ~/Desktop/Tuxedo.tipa with --trollstore).
# Unsigned build, then signed ad hoc inside out with the entitlements file named by the
# TUX_ENTITLEMENTS environment variable (default Tuxedo/Tuxedo.entitlements), as Husk's
# package_ipa.sh does: the sideloader (SideStore, AltStore, Impactor) re-signs it
# with the user's own certificate and keeps the entitlements it can.
# --trollstore strips the entitlements TrollStore bans under PPL/TXM.
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
TROLLSTORE=false
[ "$1" = "--trollstore" ] && TROLLSTORE=true
OUT="$HOME/Desktop/Henge.ipa"
[ "$TROLLSTORE" = true ] && OUT="$HOME/Desktop/Henge.tipa"
[ -d "$IOS/deps/StikJIT.xcframework" ] || "$IOS/scripts/fetch_deps.sh"
cd "$IOS"
xcodegen generate >/dev/null
. "$IOS/scripts/gfx_env.sh" # graphics acceleration when the libraries are built, else none
DD="$IOS/build/DerivedData"
mkdir -p "$IOS/build"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -skipPackagePluginValidation -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" TUX_GFX_DIR="$GFX_ROOT" TUX_GFX="$TUX_GFX" build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed; nothing packaged" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/Henge.app"
rc=0
for f in "$APP/Henge" "$APP/henge-jit.js" "$APP/PlugIns/HengeJITHelper.appex/HengeJITHelper" \
         "$APP/Frameworks/StikJIT.framework/StikJIT" "$APP/Frameworks/StikJIT.framework/Info.plist"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

STAGE="$(mktemp -d "$DD/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
ENT="$STAGE/entitlements.plist"
# TUX_ENTITLEMENTS picks another file, as for xcodebuild (Tuxedo/Tuxedo.personal.entitlements for a free team).
cp "$IOS/${TUX_ENTITLEMENTS:-Henge/Henge.entitlements}" "$ENT"
BANNED_KEYS=("com.apple.private.cs.debugger" "dynamic-codesigning" "com.apple.private.skip-library-validation")
if [ "$TROLLSTORE" = true ]; then for k in "${BANNED_KEYS[@]}"; do plutil -remove "$k" "$ENT" 2>/dev/null || true; done; fi
SAPP="$STAGE/Payload/Henge.app"
plutil -insert HengeBuildCommit -string "$(git -C "$IOS/.." rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" "$SAPP/Info.plist"
plutil -insert HengeBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAPP/Info.plist"
sign() { codesign --force --sign - --timestamp=none "$@"; }
for fw in "$SAPP"/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done
for ex in "$SAPP"/PlugIns/*.appex; do [ -d "$ex" ] && sign "$ex"; done
sign --entitlements "$ENT" "$SAPP"
EMBEDDED=$(codesign -d --entitlements - "$SAPP" 2>&1 || true)
# Every key the entitlements file asks for must be in the signature.
for k in $(plutil -convert json -o - "$ENT" | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)))'); do
    grep -q "$k" <<< "$EMBEDDED" || { echo "==> $k did not embed; refusing to package" >&2; exit 1; }
done
( cd "$STAGE" && zip -qry "$STAGE/package.tmp" Payload )
mv -f "$STAGE/package.tmp" "$OUT" # atomic: a half-written IPA never sits where the good one was
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
