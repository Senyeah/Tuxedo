#!/bin/bash
# Source-only verification: no signing assets, external dependencies or simulator needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="build/display-check"
mkdir -p "$OUT"
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find ios/Tuxedo ios/Pad -name '*.swift' -print | sort)
SOURCES+=(ios/TuxJITHelper/TuxJITMessages.swift)

# SwiftTerm, at the version in ios/project.yml, built for the device from its own checkout.
ST_DIR="$OUT/SwiftTerm-src"
if [ ! -d "$ST_DIR" ]; then
  git clone -q --depth 1 --branch v1.99.1 https://github.com/migueldeicaza/SwiftTerm "$ST_DIR"
fi
swift build -q --package-path "$ST_DIR" --product SwiftTerm --sdk "$IOS_SDK" --triple arm64-apple-ios17.0 \
  --scratch-path "$OUT/swiftterm" >/dev/null 2>&1
ST_MODULE=$(dirname "$(find "$OUT/swiftterm" -name SwiftTerm.swiftmodule -print -quit)")

# Compile the complete Swift app against the real SDK, keeping the iOS 17 deployment target.
# Linking/package export still require the dependencies described in ios/README.md.
xcrun swiftc -emit-object -whole-module-optimization -swift-version 5 \
  -target arm64-apple-ios17.0 -sdk "$IOS_SDK" \
  -import-objc-header ios/Tuxedo/TuxBridge.h -Ihost -Icore -Idevices -I "$ST_MODULE" \
  "${SOURCES[@]}" -o "$OUT/Tuxedo.o"

make test-display-routing

# The C handoff must be compiled too: display attachment can race lazy GPU creation.
for source in host/vm.c; do
  name=$(basename "$source" .c)
  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot "$IOS_SDK" \
    -std=c11 -Wall -Wextra -Werror -Icore -Ihost -Idevices \
    -c "$source" -o "$OUT/$name-ios.o"
  xcrun --sdk macosx clang -arch arm64 -std=c11 -Wall -Wextra -Werror \
    -Icore -Ihost -Idevices -c "$source" -o "$OUT/$name-mac.o"
done
