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

## Desktop

The desktop image is variant A of G6: labwc on Wayland with the pixman renderer, and one foot terminal. It needs no OpenGL.

- Autologin on tty1 runs `/usr/local/bin/henge-session` from `/etc/profile.d/henge-desktop.sh`. The serial console stays a plain shell. If labwc stops, tty1 keeps a shell.
- The renderer is `pixman`. To change it, write `gles2` or `pixman` into `/etc/henge/renderer`. The session reads the file at every start. Without the file it uses `pixman`.
- labwc runs `/etc/xdg/labwc/autostart`. It starts foot and, if `/etc/henge/bench.sh` is executable, runs it once in the background with `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `WLR_RENDERER` set. Its output goes to `$XDG_RUNTIME_DIR/henge-bench.log`. The user `henge` is in the `dialout` group, so the script can also write to `/dev/ttyAMA0`.
- `$XDG_RUNTIME_DIR/henge-times` (`/run/user/1000/henge-times`) holds the guest uptime in seconds at login, when labwc is up and when the terminal's shell starts.
- The touchpad has tap to click and natural scrolling (`/etc/xdg/labwc/rc.xml`).
- The `labwc` package depends on `xwayland`, so it is installed. labwc starts it only when an X11 program asks, so a normal session has no Xwayland process.
