# Henge for iOS

The Henge app on HengeVM's engine. Build: `ios/scripts/package_ipa.sh` (writes
`~/Desktop/Henge.ipa`; `--trollstore` writes `Henge.tipa`, for TrollStore and
TrollStore Lite, without the entitlements TrollStore bans). Needs Xcode 27 or later, xcodegen,
and the prebuilt pieces
`ios/scripts/fetch_deps.sh` copies from Husk (StikJIT, the pairing library,
libslirp and glib for iOS). `HENGE_ENTITLEMENTS` picks the app's entitlements file
(default `Henge/Henge.entitlements`). A free personal team uses
`Henge/Henge.personal.entitlements`: pass it to xcodebuild as a build setting
(`xcodebuild ... HENGE_ENTITLEMENTS=Henge/Henge.personal.entitlements`, since
`project.yml` sets it and an environment variable does not override that), and to
the packager as an environment variable (`HENGE_ENTITLEMENTS=... ios/scripts/package_ipa.sh`).

- **JIT**: on iOS 26+ (TXM) only an attached debugger can grant executable
  memory. Henge uses the same machinery as Husk: StikDebug, TrollStore, a
  jailbreak, or the built-in StikJIT helper (`HengeJITHelper.appex`, with
  on-device pairing on iOS 27). The app claims one 1 GB region per launch
  (`JITBootstrap.jitBytes`) and the engine writes through a `vm_remap`'d alias
  (`host/jit_region.c`, split mode).
- **Memory**: `increased-memory-limit` is recommended, not required. Once a
  debugger has attached, guest RAM is kept out of the app's memory limit, and if
  iOS refuses that it comes from a file on free storage instead.
- **Machines** are Linux machines (below). One can be installed on the iPhone from
  an image catalogue, exported from the app, or made on a computer (disk packed with its holes left
  out, see `host/hvsparse.h`), and dropped on Henge in Finder or picked in Files.
- **Display**: the guest's virtio GPU commands are drawn into a `CAMetalLayer`
  (`devices/vgpu_*`, [docs/architecture.md](../docs/architecture.md)).
- **External display**: on iOS 27, `SessionView` registers a SwiftUI
  `ExternalNonInteractiveAccessory` during a session. On iOS 17–26 iOS offers
  the display scene to the app delegate instead (`HengeAppDelegate`), and
  `LegacyExternalDisplay` shows the session there as `ExternalScreenPlan` decides;
  outside a session the display mirrors the phone. `DisplayRouter` selects
  one live `CAMetalLayer`, preferring the external surface and returning to the
  device on disconnect. The phone's session owns the VM and all input; the
  accessory only presents pixels. The existing guest resolution is unchanged
  (1920×1080 by default on iPhone), fitted to the monitor without stretching.
  USB-C video and a hub's keyboard/mouse can be used together when iOS recognizes
  the peripherals. AirPlay may also provide an external scene, with
  transport-dependent latency. Run `make test-display-routing`
  for routing lifecycle checks; `ios/scripts/check_display.sh` also compiles all
  app Swift sources and the iOS/macOS renderer without linking external libraries.
  USB-C video is user-confirmed on an iPhone 17 Pro running iOS 27 with
  development build 0.1/2; activation is automatic during a session. The
  iOS 17–26 path compiles and its plan is tested, but has not run on hardware yet.
  Remaining acceptance checks: connect before/during boot, unplug/replug with an
  idle desktop, rotate the phone, use keyboard/mouse through the dock, and end
  the session while connected. These individual lifecycle cases, other devices
  and AirPlay have not been separately verified.
- **Sharing** (`Henge/Sharing.swift`, `host/share.c`,
  [docs/architecture.md](../docs/architecture.md)): the Shared folder in Files and
  the clipboard. The guest's clipboard follows along; going the other way uses the
  system paste button, since iOS asks permission when an app reads it on its own.
- **Hardware input** (`Henge/Hardware.swift`): a keyboard's keys go to the guest's
  USB keyboard by HID usage, which is how iOS reports them. A trackpad or mouse
  goes through GameController with the pointer locked, which iPadOS allows only
  for an app filling the screen. The first scroll values are logged to
  `henge.log`, to tune scrolling from a real device.
- **Chips**: the virtual CPU offers Armv8.5 instructions (`core/sysreg.c`), which
  Linux uses and which run as they are, so Henge needs an A14 or M1 or newer.

## Linux machines

A machine folder needs `u-boot.bin` and `machine.json` (`MachineFolder.required`, in `MachineModel.swift`), and `disk.img`, or `disk.img.hvsparse` in an exported folder. `machine.json` has `name` and `ramMB`; other keys are ignored.

- **Boot**: `henge_vm_boot_linux(firmware, disk, ram_mb, cpus, accel, video, encode, ...)` in `Native/henge-vm.h` starts `hengevm`'s `virt` board with U-Boot. The same header has `henge_vm_console_read` and `henge_vm_console_write` for the serial console, and `henge_vm_power_button`, which presses the guest's power key. Shut Down on a Linux session presses it, so Debian shuts down by itself.
- **Session**: `SessionView` shows the console (`ConsoleView.swift`, a SwiftTerm terminal over the engine's 256 KB ring) or the screen. A machine opens on the console. The console model lives with the session, so its scrollback survives a switch to the screen and back. The serial line has no window size and the guest shell assumes 80 columns, so `ConsoleModel.fit()` types `stty rows R cols C` on request.
- **Install**: `LinuxCatalogue.swift` reads `linux-images.json`, `LinuxDownload.swift` and `RangedDownload.swift` fetch the firmware and the disk and resume with byte ranges, `LinuxUnpack.swift` decodes the LZFSE package and runs `hv_sparse_unpack`, and `LinuxInstaller.swift` grows the disk to the chosen size and writes the installed marker last. `tools/linux/package-image.sh` writes the catalogue and its packages (see [tools/linux/README.md](../tools/linux/README.md)).
- **Catalogue setting**: Settings, Linux images, Catalogue URL (the `henge.linux.catalogueURL` default). Empty means no catalogue: import a folder instead. File names in the catalogue may be relative to its URL. A public host must use `https`, because App Transport Security refuses plain `http` except to local hosts (`NSAllowsLocalNetworking`). An image's `minBuild` is checked against `CFBundleVersion`.
- **Screen**: a Linux machine on the phone follows the phone's safe area at scale 2 and the device's rotation (`DisplayModePolicy.swift`). Settings also offers an external display, 2560x1440 and 1920x1080. The guest follows a mode change through `/.henge/display` and `henge-display`.
- **Graphics acceleration**: see below. **Sharing**: the shared folder is `~/Henge` in the guest, and the desktop image shares the clipboard.
- **SwiftTerm**: the console's terminal, a Swift package (MIT) in `project.yml`, pinned to 1.99.1. It is the app's only Swift package. Its build plugin needs `-skipPackagePluginValidation`, and `xcodebuild` must not get `-sdk`. Its licence is in `Henge/Resources/legal/LICENSE-SwiftTerm-MIT.txt`. `ios/scripts/check_display.sh` clones it over the network on its first run.
- **iPad and hardware keyboards** have not been tried with Linux. The iPhone checklist ([docs/iphone-checklist.md](../docs/iphone-checklist.md)) is not done.

## iOS Simulator

`ios/scripts/sim_build.sh [device]` builds the `HengeSim` target, boots a simulator if none is booted
(default "iPhone 18 Pro"), installs and launches Henge, and prints the path of `henge.log`. It needs no
phone, signing, Husk checkout or libslirp: the engine is built for `iphonesimulator` in `build/ios-sim`
(`make ios-sim-lib`).

What differs from the device app: networking is a stub (`host/net_stub.c`, the guest has no network),
pairing is a stub (`HengeSim/sim_stubs.c`), and there is no JIT helper or StikJIT. The JIT region is
made in-process the way `host/jit_region.c` does (RW map, alias, R-X): a simulator process is a macOS
process, so no debugger is needed. Settings shows JIT "On" and `henge.log` has "self: PASS ... simulator memory".
Launch with `simctl`, not under a debugger. Memory figures in Settings read zero in the simulator.

## Graphics acceleration (Linux machines)

It is opt-in. With `HENGE_GFX=1` both app targets build the engine with `GFX=1` and link
the static ANGLE, libepoxy and virglrenderer from `build/gfx/{ios,sim}` (`tools/gfx/build-deps.sh`).
`sim_build.sh` and `package_ipa.sh` set `HENGE_GFX` and `HENGE_GFX_DIR` (from the main checkout, also in a
worktree) when the libraries exist (`scripts/gfx_env.sh`). Without them, and in CI, the app builds with
no acceleration and the switch shows an error. In Xcode, set both settings by hand. A Linux machine has a "Graphics acceleration" switch in its settings, off by
default, passed to `henge_vm_boot_linux`. With it on, a "Video decode" switch (also off by default) lets the guest's VA-API decode H.264, VP9 and AV1 on VideoToolbox; the phone's decoder then parses data that the guest controls (`tools/linux/README.md`, "Video decode"). A Linux machine also has a "Video encode" switch, off by default, that needs no acceleration: the guest's `ffmpeg` from `henge-ffmpeg` then encodes and decodes on VideoToolbox through `hvcodec` (`host/vcodec.m`), at `10.0.2.4:8470` and on the DMA device for `/dev/hvcodec`, with the iOS memory limits in `ffmpeg-henge(7)`. The phone's codecs then take data that the guest controls. When the app goes to the background, `henge_vm_set_background` ends the codec sessions (`hv_vcodec_lose_sessions`), so `ffmpeg` stops with one error and does not encode in the background. GPU memory (textures, render targets, the scanout's `IOSurface`)
counts against the app on the phone, unlike guest RAM, and `phys_footprint` in the simulator does not
show it, so memory figures need the device. In the background an accelerated machine pauses whole (`hv_vm_set_background`), even while its guest plays sound, because iOS allows no Metal work there: `hv_vm_pause` waits up to 1.5 s for the renderer's queue to empty, then stops the presenter until the resume. A machine without acceleration pauses unless its guest plays sound. ANGLE, libepoxy and virglrenderer licences are in
`Henge/Resources/legal/`.

Code from Husk (GPL-2.0-or-later): `Henge/JIT/*`, `Henge/HengeLog.swift`,
`Henge/Native/henge-ios-jit.*`, `henge-brk.S`, `HengeJITHelper/`. StikJIT is
MPL-2.0 and idevice MIT (`Henge/Resources/legal/`); `tcg-apple-jit.h` is QEMU's
(LGPL-2.1). See [docs/licensing.md](../docs/licensing.md).
