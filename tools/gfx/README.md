# Graphics dependencies

Static libraries for the accelerated-graphics plan ([LINUX-PLAN-10](../../LINUX-PLAN-10-accelerated-graphics.md), task A2): ANGLE (EGL and OpenGL ES on Metal), libepoxy and virglrenderer.

`make GFX=1` links them into the Mac tool, the tests and the iOS libraries (task A5). See [Using them](#using-them-gfx1).

## Use

```sh
tools/gfx/build-deps.sh                  # all three targets
tools/gfx/build-deps.sh --target ios     # one target: macos, ios or sim
tools/gfx/build-deps.sh --check          # verify with vtool, exit 0 only if macos and ios are right
tools/gfx/build-deps.sh --only epoxy     # rebuild one library (epoxy or virgl) in about a minute, no ANGLE sync
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
- Venus, neptune and the render server are off. Platform is EGL only. No GBM, no DRM, no minigbm, no vtest. Video is on, with a VideoToolbox back end (below).
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

## libepoxy and the missing frameworks

libepoxy opens the GL libraries with `dlopen("EGL.framework/EGL")` and `dlopen("GLESv2.framework/GLESv2")`, and on Apple platforms also the system `OpenGL.framework`. With static ANGLE there is no such framework, and ANGLE's entry points are hidden from `dlsym` (`ANGLE_EXPORT` and `EGLAPI` are empty in the static configuration).

The fix is a patch to libepoxy, `libepoxy-static-gl.patch`, which `build-deps.sh` applies after it pins the source (it checks first, so a second run does nothing). On Apple platforms with EGL, `get_dlopen_handle` gives every library name one sentinel handle, and `do_dlsym` answers a lookup on that handle with ANGLE's `eglGetProcAddress`. ANGLE returns the core GLES functions and the EGL functions from it. The patch calls ANGLE's symbol through an assembler label, because libepoxy's own header renames `eglGetProcAddress` to its wrapper inside that file, and the wrapper calls `do_dlsym` again.

Why a patch and not a shim in Tuxedo: a `dlopen` and `dlsym` of our own, as `tests/test_virgl_host.m` had until A5, replaces the system ones for every caller in the process. The app and the tool use `dlopen` for other things. The patch changes only libepoxy, in the same way on macOS, iOS and the simulator, and an unpatched `libepoxy.a` is easy to detect (it lacks the symbol `epoxy_tux_static_gl`; the Makefile stops with a message).

A libepoxy built before A5 must be rebuilt: `tools/gfx/build-deps.sh --only epoxy`.

## virglrenderer and GL_TIMESTAMP

ANGLE's Metal backend lists `GL_EXT_disjoint_timer_query`, but GL_TIMESTAMP has 0 counter bits and `QueryMtl::queryCounter` is a stub. virglrenderer turns timer queries on from that extension. The guest cannot be told otherwise: Mesa ignores the `timer_query` cap when `host_feature_check_version` is below 15, and UTM's fork sets it to 4 on ANGLE. So a guest timestamp query never gets an answer, and a guest that waits for one stops. KWin 6.3 waits for one every frame, in `GLRenderTimeQuery::query`.

`virglrenderer-angle-timestamp.patch` makes virglrenderer ask for the counter bits on GLES. With 0 bits, a timestamp query is invalid, so it is done at once with the result 0, as on a host with no timer queries. GL_TIME_ELAPSED still works. `build-deps.sh` applies the patch in the same way as the libepoxy one. A virglrenderer built before it must be rebuilt: `tools/gfx/build-deps.sh --only virgl`.

## virglrenderer and guest video decode

`virglrenderer-videotoolbox.patch` (on top of the timestamp patch) builds `-Dvideo=true` with a VideoToolbox back end, `src/vrend/virgl_video_vt.m`, in place of the VA-API one. It needs no libva and no libdrm, and the video back end starts without a DRM descriptor. The guest's Mesa VA-API driver (`virtio_gpu_drv_video.so`) then lists H.264 decode, and VP9 profiles 0 and 2 when VideoToolbox has a VP9 hardware decoder after `VTRegisterSupplementalVideoDecoderIfAvailable`, and AV1 main profile (8 and 10 bits) when it has an AV1 hardware decoder. For H.264 the back end writes an SPS and a PPS from the parsed fields, reads the PPS id from each slice header, collects the slices of a picture between `BEGIN_FRAME` and `END_FRAME`, and decodes one `CMSampleBuffer` synchronously at `END_FRAME`. For VP9 virgl carries the whole frame, so the back end only writes a `vpcC` atom from the profile and the bit depth, and reads the frame header to find key and hidden frames. For AV1 virgl carries only the tile data and the parsed fields, so the back end writes a sequence header OBU (also in the `av1C` atom), a frame header OBU and a tile group OBU. VA-API has no `refresh_frame_flags`, so the back end keeps its own map of VideoToolbox's 8 reference slots by guest surface, and rewrites `ref_frame_idx` to it (see `docs/guest-video-decode-research.md`, "Stage 5 results"). The back end gives the output to `vrend_video.c` as an IOSurface. `vrend_video.c` binds each plane as an ANGLE IOSurface pbuffer (`R8` or `RG8`; `R16` or `RG16` for 10 bits) and copies it into the plane resource's texture on the GPU (`glCopyTexSubImage2D`). It keeps the pbuffers in a cache by IOSurface, because VideoToolbox reuses a small pool. The back end tells it when the pool may be new (a new session, or a format of another size), and it then drops the cache. Until the copy's fence signals, the surface stays "in use" (`IOSurfaceIncrementUseCount`), so the pool does not give it back to the decoder. If ANGLE refuses a plane, that codec copies on the CPU from then on (`IOSurfaceLock`, `glTexSubImage2D`); `VREND_VIDEO_CPU_COPY=1` forces the CPU copy for measurements. NV12, I420, YV12 and P010 targets work. See `docs/guest-video-decode-research.md`.

Guest video is off unless the embedder asks for it. Tuxedo passes `VIRGL_RENDERER_USE_VIDEO` (`devices/vgpu_virgl.m`) only with `tuxvm --gpu-accel --gpu-video`; the iOS app never passes it. Without the flag the back end does not start, the capset lists no video, and every video command fails as in a library built without video. `virgl_video_vt.m` names its frameworks in the object (`.linker_option`: VideoToolbox, CoreMedia, CoreVideo, IOSurface, CoreFoundation), and `vrend_renderer.c` always pulls it in, so the linker adds them to every app that links the library, even when the app's link line does not name them. `tools/linux/video-decode-check.py` (`make test-linux-video`) checks it in the guest.

The guest controls every video command, so the patch also bounds what upstream's `vrend_video.c` trusts:

- `DECODE_BITSTREAM` copies at most the bitstream resource's size (`width0`), and only from a `VIRGL_BIND_CUSTOM` buffer. Upstream copies the guest's size into a `width0` heap block.
- A plane copy goes only into a 2D texture of the plane's format (`R8` for luma and I420 chroma, `R8G8` for NV12 chroma, `R16` and `R16G16` for P010), and only inside the smaller of the two sizes. The CPU copy also reads only inside the IOSurface plane.
- At most 16 codecs in a context, and at most 16 MiB of slices (or of a VP9 or AV1 frame) in a picture. An AV1 sample is at most that much plus its headers, and a buffer larger than 4 MiB is freed after its frame.
- AV1: every index from the descriptor (`ref_frame_idx`, `primary_ref_frame`, the tile counts and the tile offsets and sizes, `cdef_bits`, the film grain counts, the order hint bits) is bounded before use. The tiles must lie inside the frame's data, and their sizes must add up to at most its size: 256 overlapping tiles would otherwise make a 4 GiB sample from 16 MiB. Film grain, switch frames and large-scale tiles are refused.
- VP9: a frame that codes its size (key, intra-only, or an inter frame with no `found_ref`) must code the descriptor's size, which is at most 4096x4096. VideoToolbox sizes its output from the stream, not from the format description.

`make test-vgpu-virgl` sends the video commands with video off (they must fail) and, with a patched library, an oversized `DECODE_BITSTREAM` with video on under `libgmalloc`. Without the size bound that run crashes. It then runs `make test-vt-crafted`, which calls the back end directly with 256 overlapping AV1 tiles and with VP9 key frames that code another size than their descriptor, and is linked without VideoToolbox, CoreMedia and CoreVideo.

## Using them (GFX=1)

```sh
make GFX=1                    # tuxvm and every test link the renderer (devices/vgpu_virgl.m)
make GFX=1 test               # also runs test_vgpu_virgl
make test-vgpu-virgl          # the renderer behind the virtio GPU, driven through its control queue (skips without libraries)
make ios-lib GFX=1 IOS_DEPS=/opt/homebrew
make ios-sim-lib GFX=1
make ios-gfx-probe            # links device and simulator binaries; runs the simulator one in a booted simulator
make -s ios-gfx-ldflags       # link flags for an app that uses libtuxvm.a built with GFX=1 (IOS_GFX_TARGET=sim for the simulator)
```

`GFX_ROOT` (default: `build/gfx` of the main checkout, also from a worktree) and `GFX_DIR` (default: `$GFX_ROOT/macos`) say where the libraries are. The iOS libraries use `$GFX_ROOT/ios` and `$GFX_ROOT/sim`. Without `GFX=1` nothing needs the libraries.

Link line for an app: the four libraries, `-framework Metal -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreFoundation -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo` (the last three come from the library itself, but naming them does no harm), `-framework UIKit` (iOS) or `-framework AppKit` and `-framework IOKit` (macOS), and `-lc++`. The app project needs no `-ObjC` or `-force_load`: nothing refers to the renderer by name until the board creates it, and the linker takes `vgpu_virgl.o` from `libtuxvm.a` only then.

virglrenderer keeps global state, so one renderer can live in a process at a time. `hv_vgpu_virgl_create` returns NULL for a second one.

## Not decided here

- ANGLE's WebKit patches (see Pins) are still not applied. A5's test runs 3D commands through the pinned build and they work.
- virglrenderer's own log lines (the first 32 warnings) go to stderr. `HV_VIRGL_VERBOSE=1` shows all of them.

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
