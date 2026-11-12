#!/bin/sh
# A11 spike: builds window_probe (steps 1 and 2) into $OUT. Nothing here is part of the default build.
# Usage: tools/gfx/venus-spike/build.sh OUT_DIR
set -eu
OUT=${1:?usage: build.sh OUT_DIR}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT"
mkdir -p "$OUT"
make -s B="$OUT" "$OUT/classify.o" "$OUT/operands.o" "$OUT/translate.o" "$OUT/dispatch.o" "$OUT/mmu.o" "$OUT/memop.o" \
	"$OUT/exception.o" "$OUT/sysreg.o" "$OUT/machine.o" "$OUT/jit_region.o" "$OUT/enter.o" "$OUT/disk.o"
V=tools/gfx/venus-spike
clang -std=gnu11 -Wall -Wextra -O2 -g -fobjc-arc -Icore -Ihost -Idevices -Itests -c "$V/window_probe.m" -o "$OUT/window_probe.o"
clang -c -Itests "$V/window_guest.S" -o "$OUT/window_guest.o"
clang -c -Itests tests/harness.S -o "$OUT/harness.o"
clang "$OUT/window_probe.o" "$OUT/window_guest.o" "$OUT/harness.o" "$OUT"/classify.o "$OUT"/operands.o "$OUT"/translate.o "$OUT"/dispatch.o \
	"$OUT"/mmu.o "$OUT"/memop.o "$OUT"/exception.o "$OUT"/sysreg.o "$OUT"/machine.o "$OUT"/jit_region.o "$OUT"/enter.o "$OUT"/disk.o \
	-framework Foundation -framework Metal -o "$OUT/window_probe"
echo "built $OUT/window_probe"
