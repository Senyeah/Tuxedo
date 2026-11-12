# Linux guest tools

These scripts build the firmware and the Debian image for Linux guests. They run on a Mac with Docker.
Every script runs inside the builder container, so no cross compiler is needed.

## Layout

- `versions.env`: pinned versions (U-Boot tag, Debian suite, snapshot date).
- `Dockerfile`: the builder image (`debian:trixie` with the build tools).
- `build-uboot.sh`, `build-image.sh`, `customize.sh`, `rootfs/`: see Order.
- `customize-desktop.sh`, `rootfs-desktop/`: extra files for the desktop image (`build-image.sh --desktop`).
- `run.sh`: runs a command in the builder image. `build/linux/` is mounted at `/out`, the repo's `tools/linux/` at `/tools` (read only), and a named volume at `/work` for source trees.

`run.sh` builds the image on first use. Set `HENGE_LINUX_OUT` to change the artefact directory. The default is the shared `$HOME/Repos/Henge/build/linux`, so all worktrees see the same files.

Keep source trees in `/work`, not on the Mac filesystem. It is case-insensitive and the kernel tree has names that differ only by case.

## Order

1. `run.sh uname -m` checks the container. It prints `aarch64`.
2. `build-uboot.sh` (G2) makes `u-boot.bin`, `u-boot.config` and `u-boot.manifest` (tag, commit, SHA-256). It builds `qemu_arm64_defconfig` with no fragment in `/work/u-boot`. Check it with `qemu-system-aarch64 -M virt -cpu cortex-a57 -nographic -bios build/linux/u-boot.bin`.
3. `build-image.sh` (G3, K1, G4) makes `debian-console.img`, `Image`, `initrd.img`, `config-debian-16k`, `debian-console.partuuid` and `debian-console.manifest` (kernel format, extlinux.conf, kernel config lines, package list). It takes about 6 minutes. `customize.sh` runs inside the new root filesystem and `rootfs/` is copied into it first. Set `DEBIAN_MIRROR` to use another mirror, for example `http://deb.debian.org/debian/`.
4. `build-image.sh --desktop` (G6) makes `debian-desktop.img`, `debian-desktop.partuuid` and `debian-desktop.manifest`. It adds labwc, foot, fonts-dejavu-core and the Mesa test tools to the console image's packages. It builds in `/work/G6` and does not touch the console image or `Image` and `initrd.img`. See Desktop below.
5. `qemu-ref.sh` (G5) boots the result on QEMU's `virt` machine.

Options of `qemu-ref.sh`: `--accel hvf|tcg` (default `tcg`), `--its-off`, `--dtb FILE`, `--gpu`, `--direct` (boot `Image` and `initrd.img` with `-kernel`). `hvf` works only with `--direct`, because U-Boot aborts under `hvf`; `hvf` also forces the ITS off. The disk opens with `snapshot=on`, so the shared image never changes.

`qemu-check.py` drives it with pexpect (`uv run`): it checks page size, CPU count, network, run-time VA size and power off, and saves the reference output to `build/linux/ref/`. Use `--direct --accel hvf` for the fast check and the default for the full U-Boot path.

## Checks on the Mac

- `dtb-compare.py` (T2, `make test-linux-dtb`) compares Henge's device tree with QEMU's.
- `smoke.py --direct` (E8, `make test-linux-direct`) boots `Image` and `initrd.img` on `build/hengevm` to the `(initramfs)` prompt, runs `cat /proc/cpuinfo` and `uname -m`, restarts with `reboot -f` to the prompt again, and powers off. `--no-reboot` checks that `reboot -f` ends `hengevm` with status 3, and `--fatal` that a SIGILL still prints the crash report; the make target runs all three. It reads the artefacts from `HENGE_LINUX_OUT`, or from `build/linux` in the main checkout. `--cpus`, `--ram`, `--phone` and `--runs` pass through; `--qemu` runs the same checks on QEMU, and `--qemu --henge-dtb` boots QEMU with Henge's tree. Extra options for the make target go in `SMOKE_ARGS`.
- `smoke.py --direct --disk` (E9, `make test-linux-disk`) boots the same kernel with `root=PARTUUID=` from `debian-console.partuuid` and an APFS clone (`/bin/cp -c`) of `debian-console.img` as `--disk`, so the shared image never changes. The clone goes in a temporary directory, or in `--work-dir`, which must be on the image's volume. After autologin it checks `systemctl is-system-running`, the root on `vda1`, the page size, `nproc`, `uname -m`, the RTC's year, the virtio entropy device (`rng_current` and bytes from `/dev/hwrng`), `10.0.2.15`, `sudo ping 10.0.2.2`, `getent hosts deb.debian.org` and `dmesg --level=err` against an allow list. It then writes 256 MB, syncs, powers off (status 0), boots the clone again and compares the checksum. `--qemu` runs the same checks on QEMU with a virtio disk, network and entropy device.
- `smoke.py --uboot` (E10, `make test-linux-uboot`) runs the same checks on the same kind of clone, but `hengevm --firmware u-boot.bin` boots it through U-Boot and `extlinux.conf`. The first boot is unattended. It checks that U-Boot uses its default environment and times each step: the banner, the devices, the countdown, `efi_mgr`, the extlinux menu, and the kernel to login. The second boot stops the countdown. At the `=>` prompt it checks `pci` (bridge, virtio block, network and entropy, xHCI), `virtio info` (the disk size) and `bootflow scan -l` (extlinux on `virtio 1`, DHCP to `10.0.2.15`, every bootflow valid). It then runs `boot` and compares the checksum. `/proc/cmdline` must hold the disk's `root=PARTUUID=`. `--qemu` runs it on QEMU with TCG, with limits four times longer.
- `smoke.py --uboot --stress --cpus 4` (E11, `make test-linux-smp`) boots one clone through U-Boot and checks the several-CPU path. `nproc` must match `--cpus`, and `dmesg` must say `smp: Brought up 1 node, 4 CPUs` with no CPU that failed to come online. It then runs `stress-ng --cpu 4 --vm 2 --vm-bytes 256M --timeout 60s --metrics-brief` and `make -j4` of the project that `cproject.sh` writes (48 C files). The program must print the checksum that the same project gives on the Mac. No kernel warning (`WARNING:`, `BUG:`, an oops, a stall, a lockup, a segfault) and no `dmesg` line at warning level or above may appear. The console image has no `stress-ng` or `gcc`, so the check installs `stress-ng` and `build-essential` in the clone with `apt-get` (about 105 s at 4 CPUs, through slirp to snapshot.debian.org). `--image FILE` clones a disk that has them already, which saves the install and the network. It also works with `--direct --disk`. Set `HV_BIG_LOCK=1` to run one CPU at a time, which separates a race in the engine from a logic fault.
- `smoke.py --uboot --power` (E12, T3, `make test-linux-smoke`) runs the `--uboot` checks and then four boots of a fresh clone. Each writes 64 MB without `sync` and ends the machine another way. The next boot must find the file whole and no journal recovery in `dmesg`. The four ways: `sudo reboot` (hengevm builds the machine again, U-Boot and Debian come back in the same process), the power key as `SIGTERM` (Debian shuts down by itself, exit status 0), the power key as `Ctrl-A p`, and two `SIGTERM`s (the second stops the machine at once, status 0, "stopped: interrupted"). `--power` also works with `--direct --disk`. With `--qemu` there is no power key (QEMU's `system_powerdown` never raises the PL061 interrupt in this guest) and no `Ctrl-A p` or second-`SIGTERM` case; `sudo poweroff` takes the key's place. `--cpus`, `--ram`, `--phone` and `--runs` pass through; set them in `SMOKE_ARGS`, for example `make test-linux-smoke SMOKE_ARGS="--runs 5 --cpus 4"`.
- hengevm on the virt board: `SIGTERM` and `Ctrl-A p` press the guest's power key (GPIO pin 3, high for 100 ms). A second `SIGTERM` stops the machine at once. `SIGINT` and `SIGHUP` still stop it at once.

## Desktop

The desktop image is variant A of G6: labwc on Wayland with the pixman renderer, and one foot terminal. It needs no OpenGL.

- Autologin on tty1 runs `/usr/local/bin/henge-session` from `/etc/profile.d/henge-desktop.sh`. The serial console stays a plain shell. If labwc stops, tty1 keeps a shell.
- The renderer is `pixman`. To change it, write `gles2` or `pixman` into `/etc/henge/renderer`. The session reads the file at every start. Without the file it uses `pixman`.
- labwc runs `/etc/xdg/labwc/autostart`. It starts foot and, if `/etc/henge/bench.sh` is executable, runs it once in the background with `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `WLR_RENDERER` set. Its output goes to `$XDG_RUNTIME_DIR/henge-bench.log`. The user `henge` is in the `dialout` group, so the script can also write to `/dev/ttyAMA0`.
- `$XDG_RUNTIME_DIR/henge-times` (`/run/user/1000/henge-times`) holds the guest uptime in seconds at login, when labwc is up and when the terminal's shell starts.
- The touchpad has tap to click and natural scrolling (`/etc/xdg/labwc/rc.xml`).
- The `labwc` package depends on `xwayland`, so it is installed. labwc starts it only when an X11 program asks, so a normal session has no Xwayland process.
