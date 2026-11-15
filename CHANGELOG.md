# Changelog

macOS guest support was removed on 14/11/2026. The dated history below stays as written.

This fork collects the fixes from the community forks of [Leviidev/Henge](https://github.com/Leviidev/Henge)
into one build, with a few additions, aimed above all at iPad (tested hardware: iPad Pro M4).
Every change keeps its original author in the git history.

## Unreleased

### Rename
- The project is now called Tuxedo (formerly Henge). Tuxedo is a new app: it installs beside Henge and shares no data with it.
- The app: bundle id `nz.jackgreenhill.tuxedo`, URL scheme `tux`, settings keys `tux.*`, Documents files `tux-*`, and a new Keychain service prefix. No old name is read. Build 103 is the first Tuxedo build.
- The engine: `hengevm` is `tuxvm`, `henge_vm_*` is `tux_vm_*`, and `HENGE_*` variables are `TUX_*`.
- Host and guest: `/.tux/*`, `X-Tux-Seq`, the virtio-fs tag `tux-files`, and `/media/tux`. The guest packages are `tux-guest`, `tux-ffmpeg`, `tux-va` and `tux-codec-dkms`. A guest with `henge-*` packages loses the clipboard, status, keyboard, wallet and Files folders. Re-create it from a Tuxedo image.
- Images: the user and the hostname are `tux`. The app refuses a catalogue entry with no `guestUser` (a Henge image).
- apt: a new repository at `walkies.site/tux-linux-catalogue/apt` with a new signing key (`60E3070A44CF4B9F1F4B27E8FA32ECDBA657D9FF`).
- The Trackpad Lab and upstream's public source files (`repo.json`, `tools/update-source.py`) are removed.

### Linux guests
- Henge boots Debian 13 (arm64) as a second kind of machine, on a `virt` board that copies QEMU's, started by U-Boot v2026.10 and a 16 KB-page Debian kernel. `hengevm --board virt` runs it on the Mac, and the app runs it as a machine of kind Linux, with a SwiftTerm console, a screen that follows the phone's size and rotation or an external display, a shared folder and clipboard, sound, and opt-in 3D (virgl on ANGLE and Metal, OpenGL ES 3.0). Images come from a catalogue set in Settings or from a folder in Files. Verified on the Mac tool and in the iOS Simulator; the iPhone checks are not done. `tools/linux/README.md` builds the firmware and images, `docs/licensing.md` has the licences and source offers, and the root README lists the limits.
- In the background a Linux machine with graphics acceleration always pauses whole, even while its guest plays sound (the sound stops): iOS allows no Metal work there. The pause waits up to 1.5 s for the renderer's queue to empty, then stops the presenter until the resume.

### Tuxedo Additions
- "Insert Tuxedo Additions CD" in a machine's Details gives the guest a read-only media folder, and a wizard in the app sets the machine up. The app carries the media as `Tuxedo.app/TuxAdditions/`. It is a folder, not a real disc. It needs no network. `docs/guest-additions-design.md` is the design.
- The wizard has the steps Connect, Overview, Account, Tuxedo Additions, Desktop, Applications, SSH, Review, Progress and Done. The guest runs only the choices that the media's `actions.json` names, with checked values. The password goes in the job once and is never saved or logged.
- Autorun by signal: a guest with `tux-guest` 1.11.0 checks the media signature with the key it already has, then starts the agent as root. A guest with no `tux-guest` gets a command to type.
- `tux-guest` 1.11.0: a fresh machine has no account marker (`/var/lib/tux/account.json`), so its console signs in as root. The app then opens the wizard at the Account step by itself ("Not now" is remembered for the machine). The Account step sets the password, sudo, automatic sign-in and root lock, and ends the root console. An upgrade on a machine that is in use leaves its console as it was.
- The media: the four Tuxedo packages and the Debian packages that a minimal guest lacks (`openssh-server` too) in a signed apt repository, with `SHA256SUMS.gpg`, `README.txt` and `source/SOURCES.txt`. `make linux-additions` builds it.
- Engine: the virtio-fs device now exists on every Linux machine in the app (`fs_always`; `tuxvm --fs-device`), so insert and eject need no restart. New link `GET` and `POST /.tux/additions`. `tuxvm --additions DIR` and the `additions*` input lines test it.
- The Desktop step shows on every guest, also one that has a desktop. A person can install KDE Plasma or Xfce and switch between the installed desktops. A switch writes `/etc/tux/session` (`tux-session` starts labwc, Plasma or Xfce from tty1) and needs no download for a desktop that is installed. No display manager is used. The job can carry `reboot_after`; the Review step has a "Restart when finished" switch for it. Real-guest check: `tools/linux/desktop-check.py`.
- Licences: the app now carries GPL and LGPL binaries (`tux-ffmpeg` and Debian packages). `docs/licensing.md` and `ios/Tuxedo/Resources/legal/LICENSES-TuxedoAdditions.txt` have the source offer.
- Tests: `make test-additions-engine`, `test-additions-builder`, `test-additions-agent`, `test-additions-policy`, `test-tux-files-additions` and `test-tux-guest-scripts`. Not run on the iPhone: part 5b of `docs/iphone-checklist.md`.

### The screen is a Magic Trackpad 2
- The session's trackpad is no longer a relative mouse: the engine presents it to the Mac as
  a Magic Trackpad 2 (Apple's vendor multitouch format) on the xHCI USB bus, so the guest's
  own multitouch engine does the pointing and gestures: two-finger scroll, three-finger
  swipes for Spaces, Mission Control and App Exposé, two-finger taps for right-click, and so
  on. Settings > Trackpad picks the input mode: the touchscreen itself, or the volume buttons.
- **Touchscreen mode**: a quick tap is a left click, a quick two-finger tap is a right click,
  and touching then holding presses the button down so moving drags.
- **Volume-button mode** (iPhone): up is left click, down is right click (or swap them), and
  the surface only points and gestures. Settings offers three ways to read the buttons:
  *delay hold* (wait to detect a hold, so the click lags), *tap then drag* (click at once,
  then press down if still held), and *camera intercept* (true press/release via the camera;
  it always runs a frame stream, which the capture interaction needs, so the camera stays on).
- The session controls are now shown with a four-finger tap, leaving three fingers free for
  the Mac's own gestures.
- With the guest on an external display, the phone is one dotted pad instead of the text
  overlay: a finger lights the dots and leaves a short blue trail (a drag leaves a longer one
  with a ring), two keys at the bottom click left and right, and the session's tools sit in a
  quiet pill at the top. The keys go away while the on-screen keyboard is up, and the pad's
  edge follows the keyboard. The upright trackpad panel under the picture is the same pad.
  A two-finger tap is a right click in both input modes; with the keyboard up a tap is a left
  click in both. A tap during a held key or volume button no longer drops the drag. Settings >
  Trackpad has Haptics (All, Clicks only, Off) and Motion feel (Texture, Ticks, Off). The
  surface is in `ios/Pad`, shared with Trackpad Lab (`ios/TrackpadLab`), where it was tuned;
  the plan is `docs/external-trackpad-plan.md`. Not yet checked on the iPhone in Henge
  (`docs/iphone-checklist.md`, part 8b).
- `devices/xhci.c` generalises the xHCI host to two USB devices (the keyboard and the
  trackpad). The report format follows the Linux kernel's `hid-magicmouse` MT2 support and
  VoodooInput's Magic Trackpad II emulation.

## 0.2.0 (100)

Based on upstream `main` at b744a78.

### Display colour
- macOS no longer looks pale: the half-float display surface is shown as WindowServer wrote it
  instead of being sRGB-encoded a second time. Colour probe for diagnosis (`HV_COLOR_PROBE`).
  — [hungbenjamin402](https://github.com/hungbenjamin402/Henge)
- Colour matching for the iPad's P3 panel (the Mac's frames are tagged sRGB), with live
  *Color matching*, *Linear color conversion* and *Brightness* controls in the session's Details.
  — [sonnx0868](https://github.com/sonnx0868/Henge)

### iPad, Magic Keyboard and trackpad
- Magic Keyboard scrolling calibrated, smoother input, and the device's thermal state in Details.
- Smaller, sharper pointer on iPad, with a size and a sharp-edges setting.
- Video planes copied through the IOSurface's real layout.
  — all three: [sonnx0868](https://github.com/sonnx0868/Henge)
- iPadOS's own hide-keyboard key ends typing, so the Mac takes the full screen again.
  — [gavinnolan](https://github.com/gavinnolan/Henge)
- Screen modes for a Mac on iPad: *Retina* (every pixel of the panel, at 2x), *Performance*
  (about 30% fewer pixels), *Fit this iPad* and *16:9*. Retina is opt-in: it costs a lot of
  emulated GPU work.
  — Retina from [AdamLovattDevOps](https://github.com/AdamLovattDevOps/Henge), Performance from sonnx0868
- 120 Hz ProMotion support, 4 GB default memory on 8 GB iPads, sampling profiler and GPU
  trace/shader dump tools. — [AdamLovattDevOps](https://github.com/AdamLovattDevOps/Henge)

### External display
- A Mac on an external display before iOS 27 too (iOS 17–26), the picture coming back to the
  device when the monitor is unplugged, and unplugging one display no longer freezes the others.
  — [hungbenjamin402](https://github.com/hungbenjamin402/Henge)

### JIT
- At launch, LocalDevVPN is connected first when it is off.
  — [braedonsaunders](https://github.com/braedonsaunders/Henge) (upstream PR #3)
- JIT on cellular: explains the failure and retries instead of blaming LocalDevVPN.
- Personal (free) teams can sign the app: `HENGE_ENTITLEMENTS`.
  — both: [hungbenjamin402](https://github.com/hungbenjamin402/Henge)

### New in this fork
- **Performance settings** (Settings → Performance), applied each time a Mac starts:
  - *Mac refresh rate*: 60 Hz by default. Every frame is emulated and replayed, so 120 Hz
    halves the CPU left to apps; 120 Hz stays available.
  - *Faster disk writes* (on): `F_BARRIERFSYNC` instead of a full `fsync`.
  - *Quicker wake from idle* (off): an idle CPU watches for work for 50 µs before sleeping.
  - *Superblocks (experimental)* (off): translated code runs on past conditional branches.
  - `Documents/henge-env.txt` still overrides everything.
- **Hide the session controls**: a button left of Keyboard hides the bar over the Mac; a
  four-finger tap brings it back (a hint says so the first three times). iPadOS's own
  three-finger undo/copy/paste bar is turned off inside the session so it doesn't interfere.
- Merges kept the Xcode 27 build: the built-in StikJIT helper and the Liquid Glass icon stay
  (the m4 fork's Xcode 16 changes, which remove them, are left out).
- Display name back to *Henge*; version 0.2.0 (100) so sideloading stores treat it as an update.

### Not included
- `HV_GROUPS` (grouped memory accesses): upstream measured it no faster and it fills the JIT
  region sooner.

## Building

As upstream (see README): Xcode 27, `xcodegen`, `meson`, `rustup` with `aarch64-apple-ios`,
and a built [Husk](https://github.com/Leviidev/Husk) at `~/Documents/Coding/Husk`. Only Husk's
`build_ios.sh libffi glib libslirp` and `build_rppairing_ios.sh` are needed for Henge.
