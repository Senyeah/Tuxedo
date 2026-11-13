#!/bin/bash
# Builds ANGLE (Metal), libepoxy and virglrenderer as static libraries for macOS, iOS and the iOS simulator.
# Output: $GFX_ROOT/<target>/{lib,include,share/licenses}. See README.md.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
. "$HERE/versions.env"

REPO=$(cd "$HERE/../.." && pwd)
# A worktree shares the main checkout's build/gfx.
COMMON=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
MAIN_ROOT=${COMMON:+$(dirname "$COMMON")}
GFX_ROOT=${GFX_ROOT:-${MAIN_ROOT:-$REPO}/build/gfx}
GFX_SRC=${GFX_SRC:-$GFX_ROOT/src}
GFX_WORK=${GFX_WORK:-$GFX_ROOT/work}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
VENV=$GFX_WORK/venv

usage() {
	cat <<EOF
Usage: $(basename "$0") [--target macos|ios|sim|all] [--only angle|epoxy|virgl] [--check] [-h]
  --target T   Build one target, or all three (default). With all, a simulator failure is a warning.
  --only L     Build one library: epoxy or virgl rebuild in minutes and skip the ANGLE sync. Default: all three.
  --check      Build nothing. Verify the libraries with vtool and exit 0 only if macos and ios are right.
Env: GFX_ROOT ($GFX_ROOT), GFX_SRC, GFX_WORK, JOBS.
EOF
}

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
fsize() { wc -c <"$1" | tr -d ' '; } # GNU and BSD stat differ

target_info() {
	case $1 in
	macos) SDK=macosx PLATFORM=MACOS ;;
	ios) SDK=iphoneos PLATFORM=IOS ;;
	sim) SDK=iphonesimulator PLATFORM=IOSSIMULATOR ;;
	*) die "unknown target $1" ;;
	esac
}

# ---- check ----

# Prints "platform..." lines for every Mach-O member of an archive. vtool cannot read archives.
archive_platforms() {
	local lib=$1 tmp
	tmp=$(mktemp -d)
	(cd "$tmp" && xcrun ar x "$lib")
	find "$tmp" -name '*.o' -print0 | xargs -0 -n1 -P8 xcrun vtool -show-build 2>/dev/null |
		awk '$1 == "platform" { p = $2 } $1 == "minos" { print p, $2 }' | sort | uniq -c
	rm -rf "$tmp"
}

check_target() {
	local t=$1 ok=1 lib f found
	target_info "$t"
	local dir=$GFX_ROOT/$t/lib
	echo "target $t (expect platform $PLATFORM)"
	for lib in libvirglrenderer.a libepoxy.a libEGL.a libGLESv2.a; do
		f=$dir/$lib
		if [ ! -f "$f" ]; then
			echo "  MISSING $f"
			ok=0
			continue
		fi
		found=$(archive_platforms "$f")
		local size
		size=$(fsize "$f")
		if [ -z "$found" ]; then
			echo "  FAIL $lib: no Mach-O members with a build version ($size bytes)"
			ok=0
		elif [ "$(echo "$found" | awk -v p="$PLATFORM" '$2 != p' | wc -l)" -ne 0 ]; then
			echo "  FAIL $lib: wrong platform ($size bytes)"
			echo "$found" | sed 's/^/        /'
			ok=0
		else
			echo "  ok   $lib ($size bytes): $(echo "$found" | awk '{printf "%s members %s minos %s; ", $1, $2, $3}')"
		fi
	done
	[ $ok -eq 1 ]
}

do_check() {
	local rc=0
	check_target macos || rc=1
	check_target ios || rc=1
	if [ -d "$GFX_ROOT/sim/lib" ]; then
		check_target sim || echo "  (sim is not a gate: ignored)"
	else
		echo "target sim: not built, skipped"
	fi
	[ $rc -eq 0 ] && echo "check passed" || echo "check FAILED"
	return $rc
}

# ---- sources and tools ----

git_pin() { # dir url commit
	local dir=$1 url=$2 commit=$3
	if [ ! -d "$dir/.git" ]; then
		mkdir -p "$dir"
		git -C "$dir" init -q
		git -C "$dir" remote add origin "$url"
	fi
	if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
		git -C "$dir" fetch -q --depth 1 origin "$commit"
		git -C "$dir" checkout -q -f FETCH_HEAD
	fi
}

ensure_tools() {
	command -v uv >/dev/null || die "uv not found"
	command -v pkg-config >/dev/null || die "pkg-config not found (brew install pkgconf)"
	xcrun --sdk iphoneos --show-sdk-path >/dev/null || die "iOS SDK not found"
	if [ ! -x "$VENV/bin/meson" ]; then
		say "python tools in $VENV"
		mkdir -p "$GFX_WORK"
		uv venv -q "$VENV"
		# shellcheck disable=SC2086
		uv pip install -q --python "$VENV/bin/python" $PY_TOOLS
	fi
}

ensure_angle_src() {
	local dir=$GFX_SRC/angle-gclient stamp
	stamp=$dir/.synced-$ANGLE_COMMIT
	git_pin "$GFX_SRC/depot_tools" "$DEPOT_TOOLS_REPO" "$DEPOT_TOOLS_COMMIT"
	export DEPOT_TOOLS_UPDATE=0
	export PATH=$GFX_SRC/depot_tools:$PATH
	if [ ! -f "$stamp" ]; then
		say "ANGLE $ANGLE_COMMIT: gclient sync (several GB)"
		mkdir -p "$dir"
		cat >"$dir/.gclient" <<EOF
solutions = [{
  "name": "angle",
  "url": "$ANGLE_REPO",
  "deps_file": "DEPS",
  "managed": False,
  "custom_deps": {},
  "custom_vars": {},
}]
target_os = ["ios", "mac"]
EOF
		# Drop our BUILD.gn patch so gclient sees a clean tree.
		[ -d "$dir/angle/.git" ] && git -C "$dir/angle" checkout -q -- BUILD.gn src/libANGLE/renderer/metal/metal_backend.gni || true
		(cd "$dir" && gclient sync --no-history --revision "angle@$ANGLE_COMMIT" -j8)
		touch "$stamp"
	fi
	grep -q henge_angle_archive "$dir/angle/BUILD.gn" || cat "$HERE/angle-archive.gn" >>"$dir/angle/BUILD.gn"
	# On macOS ANGLE compiles its Metal shaders at build time and needs Apple's Metal Toolchain download.
	# Use run-time compilation, as iOS does. The result is the same shaders.
	local gni=$dir/angle/src/libANGLE/renderer/metal/metal_backend.gni
	if grep -q 'angle_has_build && !is_ios && target_os == host_os' "$gni"; then
		sed 's/angle_has_build && !is_ios && target_os == host_os/false/' "$gni" >"$gni.tmp" && mv "$gni.tmp" "$gni"
	fi
}

# Chromium's pinned clang is too old for the Xcode 27 SDK's libc++. Use Xcode's clang and ANGLE's llvm-ar.
xcode_llvm_dir() {
	local d=$GFX_WORK/xcode-llvm x f
	x=$(dirname "$(dirname "$(xcrun -f clang)")")
	if [ ! -e "$d/bin/clang" ]; then
		mkdir -p "$d/bin"
		for f in "$x"/bin/*; do ln -sf "$f" "$d/bin/$(basename "$f")"; done
		ln -sfn "$x/lib" "$d/lib"
	fi
	ln -sf "$GFX_SRC/angle-gclient/angle/third_party/llvm-build/Release+Asserts/bin/llvm-ar" "$d/bin/llvm-ar"
	echo "$d"
}

# ---- builds ----

build_angle() {
	local t=$1 A=$GFX_SRC/angle-gclient/angle out=$GFX_WORK/angle-$1 args llvm clang_major
	llvm=$(xcode_llvm_dir)
	clang_major=$(xcrun clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p')
	args='is_debug=false is_component_build=false symbol_level=0 dcheck_always_on=false use_custom_libcxx=false target_cpu="arm64"
		angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false angle_enable_null=false
		angle_enable_swiftshader=false angle_enable_wgpu=false angle_build_tests=false
		clang_use_chrome_plugins=false treat_warnings_as_errors=false'
	args="$args clang_base_path=\"$llvm\" clang_version=\"$clang_major\""
	case $t in
	macos) args="$args target_os=\"mac\" mac_deployment_target=\"$MACOS_MIN\" mac_min_system_version=\"$MACOS_MIN\"" ;;
	ios) args="$args target_os=\"ios\" target_environment=\"device\" ios_deployment_target=\"$IOS_MIN\" ios_enable_code_signing=false" ;;
	sim) args="$args target_os=\"ios\" target_environment=\"simulator\" ios_deployment_target=\"$IOS_MIN\" ios_enable_code_signing=false" ;;
	esac
	say "ANGLE $t: gn gen"
	"$A/buildtools/mac/gn" --root="$A" gen "$out" --args="$(echo $args)"
	say "ANGLE $t: ninja"
	"$VENV/bin/ninja" -C "$out" -j "$JOBS" henge_angle_archive libEGL_static

	local O=$GFX_ROOT/$t
	mkdir -p "$O/lib/pkgconfig" "$O/include" "$O/share/licenses/angle"
	cp "$out/obj/libhenge_angle_archive.a" "$O/lib/libGLESv2.a"
	cp "$out/obj/libEGL_static.a" "$O/lib/libEGL.a"
	for d in EGL GLES GLES2 GLES3 KHR; do
		rm -rf "${O:?}/include/$d"
		cp -R "$A/include/$d" "$O/include/$d"
	done
	# libepoxy and virglrenderer find the headers through these.
	local n
	for n in egl:EGL glesv2:GLESv2; do
		cat >"$O/lib/pkgconfig/${n%%:*}.pc" <<EOF
prefix=$O
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: ${n%%:*}
Description: ANGLE ${n##*:}, static
Version: 1.5
Libs: -L\${libdir} -l${n##*:}
Cflags: -I\${includedir}
EOF
	done
	cp "$A/LICENSE" "$O/share/licenses/angle/LICENSE"
	# Licences of the bundled code that ends up in the archive.
	local l
	for l in "$A"/third_party/{abseil-cpp,zlib,jsoncpp}/LICENSE* "$A"/third_party/astc-encoder/src/LICENSE* \
		"$A"/third_party/vulkan-deps/spirv-{tools,headers}/src/LICENSE* \
		"$A"/src/common/third_party/*/LICENSE* "$A"/src/third_party/*/LICENSE*; do
		[ -f "$l" ] || continue
		cp "$l" "$O/share/licenses/angle/$(echo "${l#"$A"/}" | tr '/' '_')"
	done
	return 0
}

cross_file() { # target -> path of a copy with -I of the target include dir
	local t=$1 f=$GFX_WORK/cross-$1.ini
	sed -E "/^(c|objc)_args = /s#\]\$#, '-I$GFX_ROOT/$t/include']#" "$HERE/cross-$t.ini" >"$f"
	echo "$f"
}

meson_build() { # target name srcdir meson-options...
	local t=$1 name=$2 src=$3 b O=$GFX_ROOT/$1 cross
	shift 3
	b=$GFX_WORK/$name-$t
	cross=$(cross_file "$t")
	rm -rf "$b"
	say "$name $t: meson"
	PATH=$VENV/bin:$PATH PKG_CONFIG_LIBDIR=$O/lib/pkgconfig \
		meson setup "$b" "$src" --cross-file "$cross" --prefix "$O" --libdir lib \
		--default-library static --buildtype release --wrap-mode nodownload "$@" >"$GFX_WORK/$name-$t.setup.log"
	PATH=$VENV/bin:$PATH meson install -C "$b" >"$GFX_WORK/$name-$t.build.log"
}

build_epoxy() {
	local t=$1 O=$GFX_ROOT/$1
	git_pin "$GFX_SRC/libepoxy" "$LIBEPOXY_REPO" "$LIBEPOXY_COMMIT"
	# ANGLE is static, so libepoxy must not dlopen EGL and GLES (see README). Idempotent.
	local patch=$HERE/libepoxy-static-gl.patch
	if ! git -C "$GFX_SRC/libepoxy" apply --reverse --check "$patch" 2>/dev/null; then
		git -C "$GFX_SRC/libepoxy" apply "$patch"
	fi
	meson_build "$t" epoxy "$GFX_SRC/libepoxy" -Dtests=false -Dglx=no -Degl=yes -Dx11=false -Ddocs=false
	mkdir -p "$O/share/licenses/libepoxy"
	cp "$GFX_SRC/libepoxy/COPYING" "$O/share/licenses/libepoxy/COPYING"
}

build_virgl() {
	local t=$1 O=$GFX_ROOT/$1
	git_pin "$GFX_SRC/virglrenderer" "$VIRGLRENDERER_REPO" "$VIRGLRENDERER_COMMIT"
	# ANGLE's Metal GL_TIMESTAMP never answers, and the guest waits for it (see README). Idempotent.
	local patch=$HERE/virglrenderer-angle-timestamp.patch
	if ! git -C "$GFX_SRC/virglrenderer" apply --reverse --check "$patch" 2>/dev/null; then
		git -C "$GFX_SRC/virglrenderer" apply "$patch"
	fi
	# No venus means no render server in this tree. EGL only: no GBM, no DRM, no minigbm.
	meson_build "$t" virgl "$GFX_SRC/virglrenderer" -Dtests=false -Dvtest=false -Dcheck-gl-errors=false \
		-Dvenus=false -Dplatforms=egl -Dminigbm_allocation=false -Dvideo=false
	mkdir -p "$O/share/licenses/virglrenderer"
	cp "$GFX_SRC/virglrenderer/COPYING" "$O/share/licenses/virglrenderer/COPYING"
}

write_manifest() {
	local t=$1 O=$GFX_ROOT/$1 f
	{
		echo "target $t"
		echo "angle $ANGLE_COMMIT"
		echo "libepoxy $LIBEPOXY_COMMIT"
		echo "libepoxy-patch $(shasum -a 256 "$HERE/libepoxy-static-gl.patch" | cut -d' ' -f1)"
		echo "virglrenderer $VIRGLRENDERER_COMMIT"
		echo "virglrenderer-patch $(shasum -a 256 "$HERE/virglrenderer-angle-timestamp.patch" | cut -d' ' -f1)"
		for f in libvirglrenderer.a libepoxy.a libEGL.a libGLESv2.a; do
			echo "$f $(fsize "$O/lib/$f") $(shasum -a 256 "$O/lib/$f" | cut -d' ' -f1)"
		done
	} >"$O/MANIFEST.txt"
}

build_target() {
	local t=$1
	target_info "$t"
	say "target $t"
	mkdir -p "$GFX_ROOT/$t"
	case $ONLY in all | angle) build_angle "$t" ;; esac
	case $ONLY in all | epoxy) build_epoxy "$t" ;; esac
	case $ONLY in all | virgl) build_virgl "$t" ;; esac
	write_manifest "$t"
}

# ---- main ----

TARGET=all
ONLY=all
CHECK=0
while [ $# -gt 0 ]; do
	case $1 in
	--target) TARGET=${2:?--target needs a value}; shift 2 ;;
	--only) ONLY=${2:?--only needs a value}; shift 2 ;;
	--check) CHECK=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "unknown option $1" ;;
	esac
done
case $TARGET in macos | ios | sim | all) ;; *) die "bad --target $TARGET" ;; esac
case $ONLY in angle | epoxy | virgl | all) ;; *) die "bad --only $ONLY" ;; esac

if [ $CHECK -eq 1 ]; then
	do_check
	exit $?
fi

ensure_tools
case $ONLY in all | angle) ensure_angle_src ;; esac
if [ "$TARGET" = all ]; then
	build_target macos
	build_target ios
	# Own process: set -e is off inside "||", and a half-built sim must not stop the rest.
	"$0" --target sim --only "$ONLY" || say "WARNING: sim build failed. The simulator is not a gate."
else
	build_target "$TARGET"
fi
say "done. Run $0 --check"
