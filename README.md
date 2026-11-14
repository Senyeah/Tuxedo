<p align="center">
  <img src="docs/icon.png" width="120" height="120" alt="Henge">
</p>

<h1 align="center">Henge</h1>

<p align="center">macOS and Linux on your iPhone and iPad.</p>

<p align="center">
  <a href="#install">Install</a>
  ·
  <a href="#linux-machines">Linux</a>
  ·
  <a href="docs/architecture.md">How it works</a>
  ·
  <a href="https://itslevii.dev">Website</a>
  ·
  <a href="https://github.com/Leviidev/Henge/releases">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/Leviidev/Henge/releases"><img src="https://img.shields.io/github/downloads/Leviidev/Henge/total?style=flat-square&color=2E6BFF&labelColor=111111" alt="Downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Leviidev/Henge?style=flat-square&color=2E6BFF&labelColor=111111" alt="GPL-2.0-or-later"></a>
</p>

Download macOS, install it on the device, and use it. Henge also runs Debian Linux: see [Linux machines](#linux-machines).

- **Own emulator** — iOS gives apps no hypervisor, so Henge runs the Mac's arm64 code through its own JIT, with its own MMU and devices. It doesn't use QEMU or Virtualization.framework.
- **Installs on the device** — Henge downloads Apple's restore image and restores it the way a Mac does. No Mac needed, and nothing is decrypted or patched.
- **Graphics** — macOS draws through a virtual GPU, and Henge replays its commands with Metal. Safari and Electron apps like Discord draw on it.
- **Touch** — The screen is a Magic Trackpad 2: two fingers to scroll, and the Mac's own gestures work on it — three-finger swipes for Spaces and Mission Control and more. The volume buttons are its buttons: up clicks, down right-clicks, hold to drag. Esc, Tab, Control, Option and Command sit above the keyboard.
- **Keyboard and mouse** — On iPad, a Magic Keyboard or a Bluetooth keyboard and mouse drive the Mac directly.
- **External display** — During a Mac session, connect a display with a video-capable USB-C cable or a USB-C/HDMI dock. The mode activates automatically: the monitor shows the Mac, while the iPhone or iPad keeps its trackpad and keyboard controls. Disconnect to return the image to the device. The existing guest resolution is preserved. On iOS 17–26 the same happens through an older iOS route, not yet tried on hardware; outside a Mac session the display mirrors the device. USB-C video is user-confirmed on an iPhone 17 Pro running iOS 27 (development build 0.1/2).
- **Sharing** — Copy and paste between macOS and the device, and a shared folder that shows up in Files and on the Mac.
- **Linux** — Debian 13 (arm64) boots on the same engine, on a virtual machine that follows QEMU's `virt` board and starts through U-Boot. A text console, a desktop, a shared folder, sound and opt-in 3D graphics. See [Linux machines](#linux-machines).
- **Fits the screen** — On iPad, a new Mac gets a screen the shape of the iPad's, so there are no black bars.

On an iPhone 17 Pro, macOS reaches the lock screen in about 15 seconds. Discord installs, opens in about 15 seconds, logs in and sends messages.

## Install

Sideload `Henge.ipa` from [Releases](https://github.com/Leviidev/Henge/releases) with SideStore or AltStore, or install `Henge.tipa` with TrollStore or TrollStore Lite. To get updates in SideStore or AltStore, add Henge's source, `https://raw.githubusercontent.com/Leviidev/Henge/main/repo.json`, or `https://itslevii.dev/repo.json` for all of Leviidev's apps. iOS or iPadOS 17 or later, on an A14 or M1 chip or newer. So far it's tested only on an iPhone 17 Pro: iPad support is new and hasn't run on a real iPad yet.

- **JIT** is required: StikDebug, TrollStore (which stops at iOS 17.0), TrollStore Lite (which needs a jailbreak), a jailbreak on its own, or the StikJIT helper built into Henge (iOS 26 or later).
- **Storage:** about 43 GB free for macOS Sequoia. That's 17 GB for the download, which you can delete afterwards, and 26 GB for the Mac.
- **Memory:** a Mac gets 4, 6 or 8 GB. Sign Henge with the increased memory limit entitlement if your certificate has it.

Then open the Install tab, pick macOS Sequoia 15.6.1, and keep Henge open with the device plugged in. Tahoe 26.6.2 and macOS 27.2 are offered too: both install and run on an iPhone 17 Pro, though Tahoe's first setup is slow and macOS 27 is the slowest (Safari's pages may stay blank on it). Sonoma 14.6.1 and Ventura 13.6 are smaller downloads (14.1 and 12.3 GB) for devices short on storage: they install, set up, and run Safari (both tested on an iPhone 17 Pro). Monterey isn't offered yet: it installs, but its desktop never appears.

## Sharing with the Mac

Do this once for each Mac: open Terminal on the Mac, then in Henge open Details and tap **Type the Set Up Command**. Press Return on the Mac, and choose Allow when macOS asks about `henge-agent` and local networks. It needs the Mac's keyboard layout to be U.S.

Then a Henge folder in the Mac's home folder is the same folder as Files › Henge › Shared. What you copy on the Mac is copied on the device too, and the paste button pastes from the device into the Mac.

## Linux machines

A Linux machine runs Debian 13 (trixie) for arm64, minimal. Henge starts it with U-Boot, on a virtual board that copies QEMU's `virt` machine, and it runs on the same JIT engine as macOS. There are two images:

- **Console**: a text terminal on the serial port. About 0.2 GB to download.
- **Desktop**: labwc (Wayland) and one terminal, with the screen, pointer and keyboard. About 0.3 GB to download.

Both are 16 KB-page Debian kernels (`linux-image-arm64-16k`). The disk is 3 GB inside the image and grows to the size you pick at install (16 GB by default). The user is `henge`, who logs in by itself and has passwordless `sudo`. There is no SSH server.

### Install

There is no default image host yet, so one of these:

- **A catalogue.** Open Settings, paste the address of a `linux-images.json` under Linux images, then open Install and choose Linux. Henge downloads the firmware and the disk, checks both, and makes the machine. A catalogue on a public host must use `https`. Plain `http` works only to a local address. `tools/linux/package-image.sh` makes a catalogue and `tools/linux/serve.sh` serves it on the LAN.
- **A folder.** `tools/linux/export-ios.sh DISK FIRMWARE [NAME] [RAM_MB]` makes a folder with `machine.json`, `u-boot.bin` and `disk.img.hvsparse`. Drop it on Henge in Finder or pick it in Files.

[tools/linux/README.md](tools/linux/README.md) builds the firmware and the images from nothing.

### What works

The Mac tool (`build/hengevm`) runs all of this under `make test-linux-*`. The app was run in the iOS Simulator. Nothing in this list has had its iPhone check yet.

- Boot through U-Boot to a login in about 5 to 7 s on the Mac tool at one CPU, restart, power off, and a power key (Shut Down in the app, `SIGTERM` or Ctrl-A p in `hengevm`). In the simulator the console prompt took about 12 s.
- 1 to 4 CPUs, virtio disk (with discard), network (user-mode NAT, `10.0.2.15`), entropy, USB keyboard and Magic Trackpad 2, sound, and the memory balloon device (off by default and not driven by the app).
- A screen that follows the phone's size and rotation, or an external display up to 4K, a shared folder at `~/Henge` and a shared clipboard (desktop image).
- Graphics acceleration, off by default: virgl on ANGLE and Metal, with OpenGL ES 3.0. It takes more memory on the phone, and a graphics fault can stop the machine.

### Known limits

- The guest kernel must use 16 KB or 64 KB pages. A 4 KB distribution kernel does not run.
- The iPhone checklist ([docs/iphone-checklist.md](docs/iphone-checklist.md)) is not done: JIT, the download over Wi-Fi, the shared folder, sound, the external display, acceleration and the memory figures are all unchecked on a device. The macOS regression check on the iPhone is also pending, because the engine changed.
- The iPad layout and a hardware keyboard and mouse have not been tried with Linux.
- Debuggers in the guest cannot single-step or set hardware breakpoints. There are no performance counters, and no KVM inside the guest.
- 3D stops at OpenGL ES 3.0. There is no Vulkan.
- If the app is suspended while the guest runs, Linux can report an RCU stall when it resumes.
- Without a shared folder, the first visit to `~/Henge` takes about 12 s.
- One machine runs at a time.

## Known limits

- Signing in to an Apple Account inside macOS fails with a verification error.
- Graphics are tested on macOS's own apps, Chrome, Firefox, VS Code and Discord. Other apps may draw wrongly.
- On macOS Sonoma, switching to a dynamic wallpaper (such as Sonoma) can stop the screen updating; opening any app brings it back. On Ventura, the Calendar icon in the Dock is missing its date.
- For the first few minutes after you log in, macOS is busy starting up in the background, so apps open more slowly.
- Only one Mac can start per launch. Quit Henge and open it again to start another, and to start one again after restarting or shutting down macOS.
- iPadOS keeps some keyboard shortcuts for itself, such as Command-Tab.
- It's emulation, so it runs slower than a real Mac.

## Screenshots

<table>
  <tr>
    <td align="center" colspan="3"><img src="Screenshots/ipad.jpg" alt="Discord on an iPad"><br><sub>iPad</sub></td>
  </tr>
  <tr>
    <td align="center" width="33%"><img src="Screenshots/macs.png" alt="Macs"><br><sub>Macs</sub></td>
    <td align="center" width="33%"><img src="Screenshots/trackpad.png" alt="Trackpad"><br><sub>Trackpad</sub></td>
    <td align="center" width="33%"><img src="Screenshots/install.png" alt="Install macOS"><br><sub>Install macOS</sub></td>
  </tr>
</table>

<sub>Captured on a Mac: the app's own screens with sample data, at iPad and iPhone sizes, showing a frame from Henge's renderer.</sub>

## Building

To use Henge, install the [latest release](https://github.com/Leviidev/Henge/releases). Every change lands on `main` as it's made, so `main` can be unfinished between releases.

On a Mac with Xcode 27 or later and `xcodegen`. Henge takes StikJIT, on-device pairing, libslirp and glib from a built [Husk](https://github.com/Leviidev/Husk) checkout at `~/Documents/Coding/Husk` (set `HUSK` to use another path):

```bash
ios/scripts/fetch_deps.sh
tools/build_ios_restore.sh
make ios-lib
ios/scripts/package_ipa.sh
```

That produces `~/Desktop/Henge.ipa`, and `package_ipa.sh --trollstore` writes `Henge.tipa`.

`make` builds the engine for the Mac, `build/hengevm`, and `make test` runs its tests. `make test-linux-smoke` boots Debian on it, after `tools/linux` has built the firmware and an image. Graphics acceleration needs the libraries from `tools/gfx/build-deps.sh` and `make GFX=1`.

## Licence

GPL-2.0-or-later. Henge compiles in usbmuxd (GPLv2 or GPLv3) and code from Husk (GPL-2.0-or-later), so the shipped binary is a combined GPL work. It cannot go on the App Store. See [docs/licensing.md](docs/licensing.md).

macOS and the Mac's boot ROM are Apple's and aren't part of Henge. Henge downloads both from Apple when you install.

A Linux image holds Debian packages and, next to it, a U-Boot binary. U-Boot is GPL-2.0, mostly or later, and Debian's packages have their own licences. [docs/licensing.md](docs/licensing.md) says where their source comes from.
