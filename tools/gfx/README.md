# Graphics dependencies

Static libraries for the accelerated-graphics plan ([LINUX-PLAN-10](../../LINUX-PLAN-10-accelerated-graphics.md), task A2): ANGLE (EGL and OpenGL ES on Metal), libepoxy and virglrenderer.

The Makefile does not use them yet. Task A5 wires them in behind `GFX=1`.

## Use

```sh
tools/gfx/build-deps.sh                  # all three targets
tools/gfx/build-deps.sh --target ios     # one target: macos, ios or sim
tools/gfx/build-deps.sh --check          # verify with vtool, exit 0 only if macos and ios are right
```

Needs Xcode, `uv` and `pkg-config` (`brew install pkgconf`). Nothing is installed system-wide. Python tools (meson, ninja) go into a uv venv.

Where things go (all outside git, shared by every worktree):

| Path | Content |
|---|---|
| `build/gfx/<target>/lib`, `include` | the libraries and headers, `<target>` is `macos`, `ios` or `sim` |
| `build/gfx/<target>/share/licenses` | licence files |
| `build/gfx/<target>/MANIFEST.txt` | commits, size and sha256 of each library |
| `build/gfx/src` | `depot_tools`, the ANGLE checkout (gclient), libepoxy, virglrenderer |
| `build/gfx/work` | build trees, the venv, logs |

`GFX_ROOT`, `GFX_SRC`, `GFX_WORK` and `JOBS` override the defaults. The first full build fetches about 8 GB of sources (mostly ANGLE and its dependencies) and takes 30 to 60 minutes on a busy Mac. All three targets use about 8.4 GB in total: 8.1 GB of sources, 0.15 GB of build trees and 54 MB of libraries.

## Pins

All pins are in `versions.env`. They start from UTM v5.0.8 (17/10/2026), the current UTM release, because that combination runs on iOS.

| Library | Pin | Where UTM v5.0.8 gets it |
|---|---|---|
| ANGLE | `40dfb3a8bd` (upstream, 15/02/2024) | `utmapp/WebKit` `ed78ab6e`, folder `Source/ThirdParty/ANGLE`, built with Xcode |
| libepoxy | `bf98587477` | `utmapp/libepoxy`, same commit |
| virglrenderer | `451505ad0a` | `utmapp/virglrenderer`, same commit |

How UTM builds them (`scripts/build_dependencies.sh`):

- ANGLE: `xcodebuild archive` of the WebKit ANGLE project. The result is a dynamic `EGL.framework` and `GLESv2.framework`.
- libepoxy: `-Dtests=false -Dglx=no -Degl=yes`.
- virglrenderer: `-Dtests=false -Dcheck-gl-errors=false -Dvenus=true -Dneptune=true -Dvulkan-dload=false`, and the render server in process mode on macOS and thread mode on iOS.

Differences here, on purpose:

- ANGLE comes from Chromium's repository at the same upstream commit, built with `gn`. The WebKit copy is that commit plus WebKit and UTM patches (for example, "Metal: Prevent EGLImage-backed textures from being reallocated", 24/02/2026). Those patches are not applied. A3 and A5 must check whether any of them matters.
- Venus, neptune and the render server are off. Platform is EGL only. No GBM, no DRM, no minigbm, no video, no vtest.
- All libraries are static.

### Does UTM's ANGLE give ES 3.0

The source says yes. In UTM's WebKit tree, `DisplayMtl::getMaxSupportedESVersion` returns ES 3.0 on the simulator and `kMaxSupportedGLVersion` (3.0) on GPUs that support Metal GPU family 3 or Mac 1, and ES 2.0 below that. So ANGLE's Metal backend is not what limited A1 to ES 2.0 on an M4 Pro. The limit probably comes from virglrenderer or from the context version that QEMU requests. A3 measures what this pin gives. The upstream commit built here has the same code path.

## ANGLE build notes

- Targets are `libEGL_static` and `libGLESv2_static` from ANGLE's `angle_static` group. ANGLE builds libANGLE as loose objects, so neither is an archive that holds it. `angle-archive.gn` adds one target, `henge_angle_archive`, with `complete_static_lib`. The script appends it to ANGLE's `BUILD.gn`.
- `libGLESv2.a` is that archive: the GL entry points, libANGLE, the shader translator, the Metal backend, abseil and the other bundled code. `libEGL.a` is only the `egl*` entry points, which call into `libGLESv2.a`. Link both.
- gn arguments: `is_component_build=false`, `angle_enable_metal=true`, `angle_enable_gl=false`, `angle_enable_vulkan=false`, `angle_enable_null=false`, `angle_enable_swiftshader=false`, `angle_enable_wgpu=false`, `use_custom_libcxx=false`, `symbol_level=0`, release build. iOS uses `target_os="ios"` with `target_environment` `device` or `simulator`, deployment target 17.0. macOS uses `target_os="mac"` and 15.2.
- Chromium's pinned clang 18 cannot compile against the Xcode 27 SDK's libc++ (errors in `__type_traits` and `__builtin_clzg`). The script builds with Xcode's clang through a symlink directory (`work/xcode-llvm`) and uses ANGLE's `llvm-ar`, because Xcode has none.
- On macOS, ANGLE compiles its internal Metal shaders at build time and needs Apple's separate Metal Toolchain download. The script turns that off in `metal_backend.gni` so the shaders are compiled at run time, as iOS always does. No download, same shaders.
- Link line for the app: `-framework Metal -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreFoundation -framework Foundation`, plus `-framework AppKit` on macOS or `-framework UIKit` on iOS, and the C++ runtime (`-lc++`).

## Open points for A3 and A5

- libepoxy opens EGL and GLESv2 with `dlopen("EGL.framework/EGL")` and `dlopen("GLESv2.framework/GLESv2")` on Apple platforms (`src/dispatch_common.c`). With static libraries there is no such framework. A5 must change the two names in `dispatch_common.c`, or call `epoxy` with the library handles already loaded, or export the EGL and GLES symbols from the main binary and `dlopen(NULL)`. This is the main cost of static linking. The alternative is dynamic frameworks, as UTM does.
- ANGLE's entry points are built with `ANGLE_EXPORT=` and `EGLAPI=` empty (its static configuration). Check visibility if a `dlopen` route is chosen.
- virglrenderer's `libvirglrenderer.a` needs `libepoxy.a` and the ANGLE libraries at the final link.

## Libraries

Sizes are the files in `build/gfx/<target>/lib`. Licence paths are relative to `build/gfx/<target>/share/licenses`. `MANIFEST.txt` has the sha256 values.

| Target | libEGL.a | libGLESv2.a | libepoxy.a | libvirglrenderer.a |
|---|---|---|---|---|
| macos | 14,336 bytes | 12,042,728 bytes | 1,878,824 bytes | 1,077,880 bytes |
| ios | 14,336 bytes | 12,106,808 bytes | 1,878,776 bytes | 1,075,072 bytes |
| sim | 14,336 bytes | 12,195,296 bytes | 1,878,776 bytes | 1,077,496 bytes |

Licence files. The `angle/src_*` files also include a few from ANGLE's tree that may not be linked (ceval, libXNVCtrl, volk). They are copied to be safe.

| Library | Licence | File |
|---|---|---|
| ANGLE | BSD 3-clause | `angle/LICENSE` |
| ANGLE bundled code | abseil (Apache 2.0), astc-encoder (Apache 2.0), zlib, jsoncpp (MIT), SPIR-V tools and headers (Apache 2.0), xxhash (BSD 2-clause) | `angle/third_party_*` and `angle/src_*` |
| libepoxy | MIT | `libepoxy/COPYING` |
| virglrenderer | MIT | `virglrenderer/COPYING` |

## Fallback that was not needed

The plan allows UTM's published frameworks if ANGLE does not build for iOS. It built for macOS, iOS and the simulator from source, so nothing was taken from UTM.
