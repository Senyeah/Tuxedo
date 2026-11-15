#!/usr/bin/env bash
# Build Tuxedo's unsigned, ad-hoc-signed IPA on a Bitrise macOS/Xcode stack.
# Build check only: the IPA is not published.
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1

TUX_ROOT="${BITRISE_SOURCE_DIR:?Bitrise must set BITRISE_SOURCE_DIR}"
HUSK_ROOT="$(dirname "$TUX_ROOT")/Husk"
STIKJIT_ROOT="$(dirname "$TUX_ROOT")/StikJIT"
HUSK_REV=afe83d45b31194c4cc9f7b3db7ec2c757db8346e

missing=()
for tool in meson ninja pkg-config xcodegen cmake; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
    brew install "${missing[@]}"
fi

if ! command -v rustup >/dev/null 2>&1; then
    brew install rustup
    export PATH="$(brew --prefix rustup)/bin:$PATH"
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustup default stable
rustup target add aarch64-apple-ios

git clone --depth 1 https://github.com/Leviidev/Husk.git "$HUSK_ROOT"
git -C "$HUSK_ROOT" fetch --depth 1 origin "$HUSK_REV"
git -C "$HUSK_ROOT" checkout --detach "$HUSK_REV"
cd "$HUSK_ROOT"
./scripts/fetch_sources.sh
./scripts/build_ios.sh libffi glib libslirp
./scripts/build_rppairing_ios.sh

export HUSK="$HUSK_ROOT"
export IOS_DEPS="$HUSK_ROOT/build/ios-arm64/sysroot"
for dep in libhusk_rppairing.a; do
    test -s "$HUSK_ROOT/build/ios-arm64/lib/$dep"
done
for dep in libslirp.a libglib-2.0.a libintl.a libpcre2-8.a; do
    test -s "$IOS_DEPS/lib/$dep" || {
        echo "Missing Husk iOS dependency: $dep" >&2
        exit 1
    }
done

cd "$TUX_ROOT"
./ios/scripts/fetch_deps.sh
bash ci/build-stikjit.sh "$STIKJIT_ROOT"
rm -rf "$TUX_ROOT/ios/deps/StikJIT.xcframework"
ditto "$STIKJIT_ROOT/StikJIT.xcframework" "$TUX_ROOT/ios/deps/StikJIT.xcframework"
make ios-lib
mkdir -p "$HOME/Desktop"
./ios/scripts/package_ipa.sh
