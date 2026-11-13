# Linux guest tools

These scripts build the firmware and the Debian image for Linux guests. They run on a Mac with Docker.
Every script runs inside the builder container, so no cross compiler is needed.

## Layout

- `versions.env`: pinned versions (U-Boot tag, Debian suite, snapshot date).
- `Dockerfile`: the builder image (`debian:trixie` with the build tools).
- `build-uboot.sh`, `build-image.sh`, `customize.sh`, `rootfs/`: see Order.
- `customize-desktop.sh`, `rootfs-desktop/`: extra files for the desktop image (`build-image.sh --desktop`).
- `henge-guest/` (G9): the source of the `henge-guest` Debian package. It holds the grow and first-boot scripts (`/usr/lib/henge/`) and units (`/usr/lib/systemd/system/henge-*.service`, G8), and enables them in `postinst`. `build-guest-pkg.sh` builds the `.deb` on its own; `build-image.sh` builds it too and installs it in both images. P6 adds the shared-folder mount (`home-henge-Henge.mount` and `.automount`, `/etc/henge/davfs2.conf`); P7 adds the clipboard helper (`henge-clipboard` and a user unit), and 1.2.2 the keyboard helper (`henge-keyboard` and a user unit). `grow-check.py` tests the grow units, `share-check.py` the shared folder, `clipboard-check.py` the clipboard and `keyboard-check.py` the keyboard helper.
- `run.sh`: runs a command in the builder image. `build/linux/` is mounted at `/out`, the repo's `tools/linux/` at `/tools` (read only), and a named volume at `/work` for source trees.

`run.sh` builds the image on first use. `HENGE_LINUX_OUT` is the artefact directory. `run.sh`, `package-image.sh`, `serve.sh`, `qemu-ref.sh`, `qemu-check.py`, `balloon-check.py` and `sound-check.py` default to the author's `$HOME/Repos/Henge/build/linux`, so on any other Mac set it first (see From nothing). `smoke.py` and the Makefile targets default to `build/linux` of the main checkout, where all worktrees share the files.

Keep source trees in `/work`, not on the Mac filesystem. It is case-insensitive and the kernel tree has names that differ only by case.

U-Boot is GPL-2.0 and Debian's packages have their own licences. [docs/licensing.md](../../docs/licensing.md) says what to keep with a shipped image and how to fetch the source.

## From nothing

This builds every artefact, in order, on an Apple Silicon Mac. The times are the ones the findings log recorded on an M4 Pro. The commands without a time were not timed.

Needs:

- Xcode 27 or later, `uv`, and Homebrew's `pkgconf` and `libslirp` (`brew install pkgconf libslirp`). `make` also finds libplist, libimobiledevice, libusbmuxd, libimobiledevice-glue, libtatsu, libzip and curl through `pkg-config` for the Mac tool; `make` says which one is missing.
- Docker with arm64 images (Docker Desktop or colima). Keep the artefact directory under your home folder: a path under `/private/tmp` made the scripts exit 0 and write nothing to the Mac.
- Disk space: the console image takes about 0.45 GB and the desktop image about 0.77 GB on disk (each is a 3 GB sparse file), plus Docker's work volume. `tools/gfx` (optional) takes about 8.3 GB.
- QEMU (`brew install qemu`) only for the reference checks (`qemu-ref.sh`, `qemu-check.py`, `make test-linux-dtb`).

Steps, from the root of a clean checkout:

```sh
export HENGE_LINUX_OUT=$PWD/build/linux       # set it in every shell that runs these scripts

tools/linux/run.sh uname -m                   # builds the builder image, prints aarch64
tools/linux/build-uboot.sh                    # build/linux/u-boot.bin and .manifest
tools/linux/build-uboot.sh --stock            # u-boot-stock.bin, with the 2 s countdown; the U-Boot prompt tests need it
tools/linux/build-image.sh                    # about 6 min (the first image): debian-console.img, Image, initrd.img, .partuuid, .manifest
tools/linux/build-image.sh --desktop          # debian-desktop.img (labwc and foot)

make                                          # the Mac tool: build/hengevm, build/hvsparse
make test-linux-direct                        # Image and initrd.img on build/hengevm, to a shell
make test-linux-smoke                         # U-Boot, extlinux, Debian, restarts and the power key
```

`build/linux` ends up with `u-boot.bin`, `u-boot-stock.bin`, `Image`, `initrd.img`, `config-debian-16k`, both images and their `.partuuid` and `.manifest` files. All of it stays out of git. The pins are in `versions.env`: the U-Boot tag and the Debian snapshot date. The builder image is `debian:trixie` and is not pinned by digest.

To boot by hand, use a copy, because `hengevm` writes to the disk. `cp -c` makes an APFS clone that costs no space:

```sh
cp -c build/linux/debian-console.img /tmp/henge-debian.img
build/hengevm --board virt --firmware build/linux/u-boot.bin --disk /tmp/henge-debian.img --ram 2048 --cpus 2
```

Debian autologs in as `henge`. `Ctrl-A p` presses the power key, and `Ctrl-A x` stops the machine. For the desktop image add `--window`, and `--gpu-accel` for 3D after `tools/gfx` (below).

Then, as needed:

```sh
tools/linux/package-image.sh --image build/linux/debian-console.img --kind console   # build/linux/dist/: package + linux-images.json
tools/linux/package-image.sh --image build/linux/debian-desktop.img --kind desktop
tools/linux/serve.sh                          # the catalogue on the LAN, for the app's Settings
tools/linux/export-ios.sh build/linux/debian-console.img build/linux/u-boot.bin Debian   # a folder to import through Files

tools/gfx/build-deps.sh                       # 30 to 60 min, about 9 GB: ANGLE, libepoxy, virglrenderer (optional)
make GFX=1                                    # hengevm with --gpu-accel
make test-linux-accel                         # virgl against pixman, frame time and glmark2
```

The app: `ios/scripts/sim_build.sh` builds and runs it in the iOS Simulator with no phone, signing or Husk checkout. A device build needs the Husk checkout, `ios/scripts/fetch_deps.sh` and `ios/scripts/package_ipa.sh` (see the root README, Building). With `tools/gfx` built, both scripts link the graphics libraries on their own (`ios/scripts/gfx_env.sh`). The app gets a Linux image from the catalogue address in Settings or from an imported folder.

If a step fails, run it again with the same `HENGE_LINUX_OUT`. `build-image.sh` renames its output into place, so a failed build does not damage an image that is in use, and `make clean` keeps `build/linux`.

## Order

1. `run.sh uname -m` checks the container. It prints `aarch64`.
2. `build-uboot.sh` (G2, P2) makes `u-boot.bin`, `u-boot.config` and `u-boot.manifest` (tag, commit, fragment, SHA-256). It builds `qemu_arm64_defconfig` plus the boot-speed fragment `u-boot-henge.config` (no autoboot countdown, no EFI boot manager) in `/work/u-boot`. `build-uboot.sh --stock` builds the unmodified defconfig as `u-boot-stock.bin`, which keeps the 2 s countdown; the checks that stop at the `=>` prompt (`smoke.py --uboot` second boot, `input-check.py`, `kernel-boot-time.py`, `qemu-ref.sh`) use it when it exists. Check it with `qemu-system-aarch64 -M virt -cpu cortex-a57 -nographic -bios build/linux/u-boot.bin`.
3. `build-image.sh` (G3, K1, G4) makes `debian-console.img`, `Image`, `initrd.img`, `config-debian-16k`, `debian-console.partuuid` and `debian-console.manifest` (kernel format, extlinux.conf, kernel config lines, package list). It takes about 6 minutes. `customize.sh` runs inside the new root filesystem and `rootfs/` is copied into it first. Set `DEBIAN_MIRROR` to use another mirror, for example `http://deb.debian.org/debian/`.
4. `build-image.sh --desktop` (G6) makes `debian-desktop.img`, `debian-desktop.partuuid` and `debian-desktop.manifest`. It adds labwc, foot, fonts-dejavu-core and the Mesa test tools to the console image's packages. It builds in `/work/G6` and does not touch the console image or `Image` and `initrd.img`. See Desktop below.
5. `qemu-ref.sh` (G5) boots the result on QEMU's `virt` machine.

Options of `qemu-ref.sh`: `--accel hvf|tcg` (default `tcg`), `--its-off`, `--dtb FILE`, `--gpu`, `--direct` (boot `Image` and `initrd.img` with `-kernel`). `hvf` works only with `--direct`, because U-Boot aborts under `hvf`; `hvf` also forces the ITS off. The disk opens with `snapshot=on`, so the shared image never changes.

`qemu-check.py` drives it with pexpect (`uv run`): it checks page size, CPU count, network, run-time VA size and power off, and saves the reference output to `build/linux/ref/`. Use `--direct --accel hvf` for the fast check and the default for the full U-Boot path.

## First boot and disk growth (G8)

Both units come from the `henge-guest` package. Raise `Version` in `henge-guest/DEBIAN/control` when a file in it changes. `smoke.py --disk` and `--uboot` check `dpkg-query` and `systemctl is-enabled` for the package and its units.

- `henge-grow.service` runs on every boot. `henge-grow` finds the root partition from sysfs. It keeps the disk size (512-byte sectors) of its last run in `/var/lib/henge/grow-size`; when the size is the same it logs "disk unchanged" and stops (the tools cost about 2 s at 1 CPU). Otherwise it moves the backup GPT header to the end of the disk (`sgdisk -e`), runs `growpart` and then `resize2fs` on the mounted root, and writes the new size. The app grows the disk file, and the next boot grows the guest.
- `henge-firstboot.service` runs once, while `/var/lib/henge/firstboot-done` is missing. It runs `systemd-machine-id-setup` if `/etc/machine-id` is empty, then writes the marker.
- `grow-check.py` (`uv run`) clones an image, grows the clone to 16 GB (sparse), boots it through U-Boot, checks the grown partition, filesystem and GPT, boots it again unchanged (the journal must say "disk unchanged"), grows it by 4 GB more and boots a third time (the tools must run again and the stamp must follow the size). `--qemu` uses QEMU TCG. Otherwise it uses `build/hengevm`. `--image`, `--firmware` and `--work-dir` choose files.

## Shared folder (P6)

`henge-guest` mounts `http://10.0.2.4/` (the share server in `host/share.c`, reached through the user-mode network) at `/home/henge/Henge` with `davfs2`. The package depends on `davfs2`, and `build-image.sh` installs it.

- `home-henge-Henge.automount` is enabled; the mount happens on the first visit to `~/Henge`, so a boot with no network or no `--share` does not wait for it. Without the share, the first visit takes about 12 s (davfs2's connect timeouts, under the unit's `TimeoutSec=20`), then shows only what davfs2 cached, and writes fail with "Resource temporarily unavailable". The unit does not fail and the system stays `running`.
- `/etc/henge/davfs2.conf` is passed with the `conf=` mount option and does not touch Debian's `/etc/davfs2/davfs2.conf`. It sets `ask_auth 0`, `dir_refresh 5` (a change made on the Mac shows in the guest within about 5 s) and `delay_upload 1` (a write reaches the Mac about a second after close). The unmount at shutdown uploads what is left.
- Files belong to `henge:henge`. davfs2 caches in `/var/cache/davfs2` and shows its own `lost+found` in the folder's root; it cannot be hidden.
- Locks: the server accepts `LOCK` and `UNLOCK` and enforces nothing, and davfs2 is content with that (`use_locks` stays on). The check sees no davfs2 message about locks.
- `share-check.py` (`uv run`) boots a clone of `--image` with `--share`, and checks the mount, create, rename, delete, names with spaces and non-ASCII characters, a 100 MB copy each way, and a write right before poweroff. A second boot without `--share` checks that the machine still reaches `running` and that a visit to the folder fails in time. `--size-mb`, `--cpus`, `--image`, `--firmware` and `--work-dir` choose the run.

## Clipboard (P7)

`henge-clipboard` (`/usr/lib/henge/`, run by the user unit `henge-clipboard.service`) speaks the same `/.henge/clipboard` protocol as the macOS helper `tools/henge-agent.m`, so `host/share.c` and the app's "helper running" test (`henge_share_agent_seen`, a poll in the last 40 s) work unchanged. The desktop image's labwc `autostart` imports `WAYLAND_DISPLAY` and `DISPLAY` into the user manager and starts the unit, so it runs only on the desktop; the console image has no clipboard (the app writes pasted text to the console).

- Device to guest: a `GET ?since=N` that the server holds up to 25 s, as in macOS. The first request uses `since=0`; the answer that comes back at once is what the device held before the helper started, and is dropped (macOS uses a huge `since` for this, which blinds it for the first 25 s). News goes to `wl-copy`.
- Guest to device: Wayland uses `wl-paste --type text --watch` (one base64 line per change); X11 (`HENGE_CLIPBOARD=x11`, or `DISPLAY` without `WAYLAND_DISPLAY`) looks with `xclip` once a second, as the macOS helper does. Text that was just set from the device is not sent back, and a clipboard with the `x-kde-passwordManagerHint` type (password managers) is not sent. Clipboards over 16 MB or not valid UTF-8 are not sent. Not tested: the password manager type, as `wl-copy` cannot offer two types.
- The app's paste button sets the device clipboard, waits 0.8 s and sends Ctrl-V; its menu chooses Ctrl-Shift-V for terminals.
- The desktop package list adds `wl-clipboard`, `xclip` and `python3`; the package only recommends them.
- `clipboard-check.py` (`uv run`, `make test-linux-clipboard`) boots a clone of the desktop image with `--share` and `HV_INPUT_FILE` (`clip TEXT` and `getclip`), and checks each of the points above, plus the X11 mode through XWayland. `--image`, `--hengevm`, `--cpus` and `--work-dir` choose the run.

## Keyboard follows the focus

The device shows its on-screen keyboard when the focused program in the desktop wants text, and hides it after. Keys still arrive through the virtio keyboard.

Wayland has one event for "this program wants text": a client enables its `text-input` object when a text field gets the focus (`zwp_text_input_v3.enable`, and the same in v1 and v2), and disables it when the focus leaves. No protocol gives that event to an ordinary client. Each compositor gives it to one place:

- wlroots (labwc 0.8.3): the seat's input method, `zwp_input_method_v2` (`activate`, `deactivate`, applied on `done`). Any client can ask for it; there is one for each seat. labwc has text-input-v3 only.
- KWin 6.3: `InputMethod::setActive` (`src/inputmethod.cpp`) follows text-input v1, v2 and v3 and shows as the property `active` (signal `activeChanged`) of `org.kde.kwin.VirtualKeyboard` at `/VirtualKeyboard` on `org.kde.KWin`. It changes with no input method installed, so the helper does not take KWin's input method place (`kwinrc` `InputMethod`), and Maliit or Fcitx 5 can stay. It needs `VirtualKeyboardEnabled` (the default). `KWIN_IM_SHOW_ALWAYS` and the last input device only decide if KWin shows its own panel; they do not change `active`.

`henge-keyboard` (`/usr/lib/henge/`, the user unit `henge-keyboard.service`) uses the first of these that it finds:

- It speaks the Wayland wire protocol itself, as `wlprobe.py` does, and binds `zwp_input_method_manager_v2`. It sends no text and takes no keyboard grab, so typing is not changed. If the seat has an input method already (`unavailable`), it stops and exit status 0 keeps systemd from a restart.
- On KWin it runs `busctl --user monitor` for `activeChanged` and reads `active` with `busctl get-property`.
- It sends `PUT /.henge/keyboard` with the body `show` or `hide` to `host/share.c`. A `hide` waits 0.3 s, because focus that moves between two fields is `deactivate` then `activate`. A send that fails is tried again after 2 s. It sends `hide` when it stops.
- labwc's `autostart` starts the unit; in Plasma `/etc/xdg/autostart/henge-keyboard.desktop` (KDE only) does.

The host keeps the last request and a count (`hv_share_keyboard_wanted`). The app looks five times a second (`SessionView.followGuestKeyboard`, policy in `KeyboardFollow.swift`): `show` opens the keyboard; `hide` closes it only if the guest opened it; a keyboard that the person closes stays closed until the guest asks again. It does nothing while the console shows, with a hardware keyboard, or when Settings, "Show the keyboard when Linux wants text" is off.

What asks and what does not (labwc 0.8.3 and `kwin_wayland --virtual` 6.3.6, both in a Debian trixie container; the same result on each):

| Program | Result |
| --- | --- |
| GTK 4 entry (`zenity --entry`) | show, then hide |
| GTK 4 dialog with no entry (`zenity --info`) | nothing |
| Qt 6 line edit (`kdialog --inputbox`) | show, then hide |
| Qt 6 dialog with no field (`kdialog --msgbox`) | nothing |
| foot, Konsole | show while the terminal has the focus |
| XWayland programs (xterm, tested on labwc only) | nothing: X11 has no text-input. Use the keyboard button |

Limits:

- Programs with their own toolkit and no text-input (some games, SDL without IME) do not ask. Chromium and Electron ask only with text-input enabled (`--enable-wayland-ime`). Qt 5 has text-input-v2 only, so it asks on KWin and not on labwc.
- On labwc the helper is the input method. An input method for composition (Fcitx 5, IBus) wants the same place; the one that starts first gets it.
- The request is "a text field has the focus", not "the person tapped it". A terminal that has the focus when the desktop starts opens the keyboard.
- Not tested: a full Plasma session in the guest (KWin was tested alone, with its virtual backend), and the app on a device.

`keyboard-check.py` (`uv run`, `make test-linux-keyboard`) boots a clone of the desktop image with `--share` and `HV_INPUT_FILE` (`getkbd` prints the last request), and checks in the labwc session: the service runs; foot in focus gives `show`; a window with no text field gives `hide` and `show` comes back when it closes; no window gives `hide`; the helper sends `hide` when it stops and `show` when it starts with a text field in focus. `--gtk` installs zenity in the clone and checks a GTK entry. `tests/test_share_keyboard.c` (in `make test`) checks the endpoint and `make test-keyboard-follow` the app's policy.

## Packaging and catalogue (G7)

- `package-image.sh --image FILE --kind console|desktop` packs the raw image with `build/hvsparse`, compresses it with `compression_tool -encode -a lzfse` to `debian-<kind>-<date>.hvsparse.lzfse`, then decodes and unpacks the result and checks the SHA-256 against the image (`--no-verify` skips this). It copies the firmware to `u-boot-<sha12>.bin` and adds or replaces the entry `debian-<kind>` in `linux-images.json`. Output goes to `build/linux/dist/`; `--out DIR` changes it. The manifest next to the image gives the kernel string and is checked against `image_sha256`. `--firmware`, `--date` and `--min-build` override the defaults (`build/linux/u-boot.bin`, today in GMT+12, the Info.plist build plus one).
- `linux-images.json` is `{"images": [...]}`. Each entry has `id`, `name`, `version`, `kind`, `diskURL`, `diskBytes` (download), `diskSHA256`, `unpackedBytes` (the `.hvsparse` file, the data to write), `logicalBytes` (the disk), `firmwareURL`, `firmwareBytes`, `firmwareSHA256`, `kernel`, `minBuild`. The two URLs are relative to the catalogue's URL.
- `serve.sh` serves `build/linux/dist/` on the LAN address (`--bind`, `--port`, `--dir`). It asks before it opens the port; `--yes` skips the question. It answers `Range` requests, which `http.server` does not, because the app resumes downloads with them. Stop it with Ctrl-C.

## Checks on the Mac

- `dtb-compare.py` (T2, `make test-linux-dtb`) compares Henge's device tree with QEMU's.
- `smoke.py --direct` (E8, `make test-linux-direct`) boots `Image` and `initrd.img` on `build/hengevm` to the `(initramfs)` prompt, runs `cat /proc/cpuinfo` and `uname -m`, restarts with `reboot -f` to the prompt again, and powers off. `--no-reboot` checks that `reboot -f` ends `hengevm` with status 3, and `--fatal` that a SIGILL still prints the crash report; the make target runs all three. It reads the artefacts from `HENGE_LINUX_OUT`, or from `build/linux` in the main checkout. `--cpus`, `--ram`, `--phone` and `--runs` pass through; `--qemu` runs the same checks on QEMU, and `--qemu --henge-dtb` boots QEMU with Henge's tree. Extra options for the make target go in `SMOKE_ARGS`.
- `smoke.py --direct --disk` (E9, `make test-linux-disk`) boots the same kernel with `root=PARTUUID=` from `debian-console.partuuid` and an APFS clone (`/bin/cp -c`) of `debian-console.img` as `--disk`, so the shared image never changes. The clone goes in a temporary directory, or in `--work-dir`, which must be on the image's volume. After autologin it checks `systemctl is-system-running`, the root on `vda1`, the page size, `nproc`, `uname -m`, the RTC's year, the virtio entropy device (`rng_current` and bytes from `/dev/hwrng`), `10.0.2.15`, `sudo ping 10.0.2.2`, `getent hosts deb.debian.org` and `dmesg --level=err` against an allow list. It then writes 256 MB, syncs, powers off (status 0), boots the clone again and compares the checksum. `--qemu` runs the same checks on QEMU with a virtio disk, network and entropy device.
- `smoke.py --uboot` (E10, `make test-linux-uboot`) runs the same checks on the same kind of clone, but `hengevm --firmware u-boot.bin` boots it through U-Boot and `extlinux.conf`. The first boot is unattended. It checks that U-Boot uses its default environment and times each step: the banner, the devices, the countdown (only with the stock build), the extlinux step, and the kernel to login. The second boot uses the stock build and stops the countdown. At the `=>` prompt it checks `pci` (bridge, virtio block, network and entropy, xHCI), `virtio info` (the disk size) and `bootflow scan -l` (extlinux on `virtio 1`, DHCP to `10.0.2.15`, every bootflow valid). It then runs `boot` and compares the checksum. `/proc/cmdline` must hold the disk's `root=PARTUUID=`. `--qemu` runs it on QEMU with TCG, with limits four times longer.
- `smoke.py --uboot --stress --cpus 4` (E11, `make test-linux-smp`) boots one clone through U-Boot and checks the several-CPU path. `nproc` must match `--cpus`, and `dmesg` must say `smp: Brought up 1 node, 4 CPUs` with no CPU that failed to come online. It then runs `stress-ng --cpu 4 --vm 2 --vm-bytes 256M --timeout 60s --metrics-brief` and `make -j4` of the project that `cproject.sh` writes (48 C files). The program must print the checksum that the same project gives on the Mac. No kernel warning (`WARNING:`, `BUG:`, an oops, a stall, a lockup, a segfault) and no `dmesg` line at warning level or above may appear. The console image has no `stress-ng` or `gcc`, so the check installs `stress-ng` and `build-essential` in the clone with `apt-get` (about 105 s at 4 CPUs, through slirp to snapshot.debian.org). `--image FILE` clones a disk that has them already, which saves the install and the network. It also works with `--direct --disk`. Set `HV_BIG_LOCK=1` to run one CPU at a time, which separates a race in the engine from a logic fault.
- `smoke.py --uboot --power` (E12, T3, `make test-linux-smoke`) runs the `--uboot` checks and then four boots of a fresh clone. Each writes 64 MB without `sync` and ends the machine another way. Before a key case the test waits until logind watches `gpio-keys`; an earlier key is lost. The next boot must find the file whole and no journal recovery in `dmesg`. The four ways: `sudo reboot` (hengevm builds the machine again, U-Boot and Debian come back in the same process), the power key as `SIGTERM` (Debian shuts down by itself, exit status 0), the power key as `Ctrl-A p`, and two `SIGTERM`s (the second stops the machine at once, status 0, "stopped: interrupted"). `--power` also works with `--direct --disk`. With `--qemu` there is no power key (on the `-bios` path QEMU builds an ACPI GED, not gpio-keys, so `system_powerdown` does not reach this guest) and no `Ctrl-A p` or second-`SIGTERM` case; `sudo poweroff` takes the key's place. `--cpus`, `--ram`, `--phone` and `--runs` pass through; set them in `SMOKE_ARGS`, for example `make test-linux-smoke SMOKE_ARGS="--runs 5 --cpus 4"`.
- `input-check.py` (D5, `make test-linux-input`) boots a clone of `debian-desktop.img` and drives `hengevm` through `HV_INPUT_FILE`. It checks that U-Boot's xHCI keyboard stops the countdown and types, that dmesg shows a clean xHCI probe, the USB keyboard, the Magic Trackpad 2 and `magicmouse` bound to it, and that `libinput debug-events` in the guest records keys, virtio mouse moves, left and right buttons, wheel, one-finger moves, two-finger scroll and a trackpad click. The image needs `libinput-tools`; the check installs it in the clone with apt unless `--image` names a disk that has it. `HV_INPUT_FILE` lines on the virt board: `key N`, `type TEXT`, `rel DX DY`, `click 0 0`, `rclick`, `scroll X Y`, `btn CODE 1|0`, `tp ID PHASE X Y`, `tpframe`, `tpclick 1|0`, `msleep MS`, `wait S`.
- `balloon-check.py` (P10, `make test-linux-balloon`) boots a clone with `HV_BALLOON=0` and drives the target with `balloon MB` and `balloonstat` lines in `HV_INPUT_FILE` (the second prints actual, given back and taken back MB, partial pages, pages outside RAM and failures). It checks that `virtio_balloon` is bound, that inflating by `--mb` (default 512) lowers the guest's free memory by that much, that the device's counters show the same amount given back with no partial page or failure, that the host process's `footprint` falls after the guest dirtied and freed memory, and that deflate restores it. `--ram-file` puts guest RAM in a file (as on iOS; the footprint check is skipped, because the unlinked file cannot be seen). `--load` also installs `build-essential` and `stress-ng`, then inflates by half of `MemAvailable` during `make -j4` of `cproject.sh` (three times) and a stress run; `--overshoot` then asks for almost all of RAM under stress and fails on any OOM message. `--save-image FILE` keeps the disk with the packages for `--image`. On the virt board the device offers `VIRTIO_BALLOON_F_DEFLATE_ON_OOM`, so Linux deflates before it kills a process; Linux then keeps `MemTotal` and takes the pages from `MemFree`.
- `sound-check.py` (P8, `make test-linux-sound`) boots a clone with `HV_SND_CAPTURE=path`, which makes the host's audio backend (`host/audio_mac.c`) write every byte its render callback plays to `path` (silence too, while the stream runs; `path.fmt` holds channels, virtio format and rate). It checks that `snd_virtio` binds with no probe error, that ALSA lists one playback card and no capture, that `speaker-test -c2 -t sine -f 440 -l 1` arrives as 440 Hz, left then right, and that a 60 s file (440 Hz left, 660 Hz right) played by `aplay` arrives whole: 60.0 s, right level and pitch, no zero run over 1 ms, zero crossings on a straight line to 0.5 ms (a lost or repeated buffer would show), and 60 s of host wall time (the guest's audio clock does not drift). `--pipewire` repeats the file with `pw-play` through pipewire and wireplumber (user services). Images built before `alsa-utils` joined the console list lack it, so the check installs `alsa-utils` and `sox` (and the pipewire packages, `libpam-systemd`, `dbus-user-session`, and enables linger and starts `user@1000` for `henge` because the serial login has no user session) in the clone with apt, adds `henge` to group `audio` (`/dev/snd` is group audio; `customize.sh` now does this) waits for systemd and apt to settle after the reboot; `--image` uses a disk that has them, `--save-image` keeps one. `--keep-capture FILE` keeps the host's capture. The check hears nothing: it reads what the host played, so the Mac's speakers may be silent or muted.
- `kernel-boot-time.py` (K2, `uv run`) times what the initrd costs: it boots Debian's kernel from a clone of `debian-console.img` on QEMU (TCG) and on `hengevm`, by direct boot or through U-Boot (`ext4load` and `booti`), with and without the initrd, and reads the kernel's own timestamps (`Freeing initrd memory`, `Run /init`, the root mount, the first `systemd[1]` line). Without the initrd Debian's kernel cannot mount the root (`virtio_blk` and `ext4` are modules), so that run stops at `VFS: Cannot open root device`; its kernel time is what a kernel with the drivers built in would need. `--machine`, `--boot`, `--initrd on|off`, `--runs`, `--cpus`, `--hengevm`, `--work-dir`, `--console-dir` and `--json` select and keep results.
- hengevm on the virt board: `SIGTERM` and `Ctrl-A p` press the guest's power key (GPIO pin 3, high for 100 ms). A second `SIGTERM` stops the machine at once. `SIGINT` and `SIGHUP` still stop it at once. `Ctrl-A s` pauses and resumes the machine (`hv_vm_pause`, what the iOS app does in the background); `SIGTSTP` pauses it and stops the process, and `SIGCONT` resumes it. The guest's clock skips the paused time. `Ctrl-A b` enters and leaves the app's background (`hv_vm_set_background`): a machine started with `--gpu-accel` pauses there even while its guest plays sound. A pause also stops the Metal presenter, and with `--gpu-accel` it first waits up to 1.5 s for the renderer to finish what it holds.
- `gpu-pause-check.py` (A9c, `make test-linux-gpu-pause`) boots a clone of `debian-desktop.img` with `--gpu-accel`, runs glmark2, and pauses `hengevm` with `Ctrl-A s`, `SIGTSTP` and `Ctrl-A b` (with `aplay` playing). hengevm prints the renderer's request count after each pause and before the resume; they must be equal, the GPU must read `held`, glmark2 must go on, and dmesg must stay clean. It then restarts the guest, pauses the new machine and ends it with two `SIGTERM`s while paused: it must end within 15 s with no renderer time-out. `--seconds` sets the length of each pause (`GPU_PAUSE_ARGS`; the plan's step 5 says 60).
- `suspend-check.py` (E15, `make test-linux-suspend`) boots a clone of `debian-console.img` at 4 CPUs and pauses it for 30 s (`Ctrl-A s`, then `SIGSTOP`) and 120 s (`SIGTSTP`). After each pause the guest must report no RCU stall or kernel warning, its boot-time clock must have moved by the host's time less the pause (2 s slack, no step over 2 s), and its wall clock may step only forward, by what timesyncd puts back. A paused `hengevm` must use under 1% of a core. `--no-pause --expect-stall` shows the old behaviour (`SIGSTOP` alone gives the stall). `--seconds`, `--cpus`, `--sync-wait`, `--image` and `--work-dir` choose the run; set them in `SUSPEND_ARGS`.

## Desktop

The desktop image is variant A of G6: labwc on Wayland and one foot terminal. It runs with pixman, or with gles2 when the GPU is virgl.

- Autologin on tty1 runs `/usr/local/bin/henge-session` from `/etc/profile.d/henge-desktop.sh`. The serial console stays a plain shell. If labwc stops, tty1 keeps a shell.
- The renderer is chosen at every session start: `gles2` if `/dev/dri/renderD128` exists and `eglinfo -B` names virgl, else `pixman`. To force one, write `gles2` or `pixman` into `/etc/henge/renderer`. The choice is printed on tty1 and written to `$XDG_RUNTIME_DIR/henge-session.log` as `renderer=...`.
- labwc runs `/etc/xdg/labwc/autostart`. It starts foot and, if `/etc/henge/bench.sh` is executable, runs it once in the background with `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `WLR_RENDERER` set. Its output goes to `$XDG_RUNTIME_DIR/henge-bench.log`. The user `henge` is in the `dialout` group, so the script can also write to `/dev/ttyAMA0`.
- `$XDG_RUNTIME_DIR/henge-times` (`/run/user/1000/henge-times`) holds the guest uptime in seconds at login, when labwc is up and when the terminal's shell starts.
- The touchpad has tap to click and natural scrolling (`/etc/xdg/labwc/rc.xml`).
- The `labwc` package depends on `xwayland`, so it is installed. labwc starts it only when an X11 program asks, so a normal session has no Xwayland process.
