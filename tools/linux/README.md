# Linux guest tools

These scripts build the firmware and the Debian image for Linux guests. They run on a Mac with Docker.
Every script runs inside the builder container, so no cross compiler is needed.

## Layout

- `versions.env`: pinned versions (U-Boot tag, Debian suite, snapshot date).
- `Dockerfile`: the builder image (`debian:trixie` with the build tools).
- `build-uboot.sh`, `build-image.sh`, `customize.sh`, `rootfs/`: see Order.
- `run.sh`: runs a command in the builder image. `build/linux/` is mounted at `/out`, the repo's `tools/linux/` at `/tools` (read only), and a named volume at `/work` for source trees.

`run.sh` builds the image on first use. Set `HENGE_LINUX_OUT` to change the artefact directory. The default is the shared `$HOME/Repos/Henge/build/linux`, so all worktrees see the same files.

Keep source trees in `/work`, not on the Mac filesystem. It is case-insensitive and the kernel tree has names that differ only by case.

## Order

1. `run.sh uname -m` checks the container. It prints `aarch64`.
2. `build-uboot.sh` (G2) makes `u-boot.bin`, `u-boot.config` and `u-boot.manifest` (tag, commit, SHA-256). It builds `qemu_arm64_defconfig` with no fragment in `/work/u-boot`. Check it with `qemu-system-aarch64 -M virt -cpu cortex-a57 -nographic -bios build/linux/u-boot.bin`.
3. `build-image.sh` (G3, K1, G4) makes `debian-console.img`, `Image`, `initrd.img`, `config-debian-16k`, `debian-console.partuuid` and `debian-console.manifest` (kernel format, extlinux.conf, kernel config lines, package list). It takes about 6 minutes. `customize.sh` runs inside the new root filesystem and `rootfs/` is copied into it first. Set `DEBIAN_MIRROR` to use another mirror, for example `http://deb.debian.org/debian/`.
4. `qemu-ref.sh` (G5) boots the result on QEMU's `virt` machine.

Step 4 does not exist yet.

## Checks on the Mac

- `dtb-compare.py` (T2, `make test-linux-dtb`) compares Henge's device tree with QEMU's.
- `smoke.py --direct` (E8, `make test-linux-direct`) boots `Image` and `initrd.img` on `build/hengevm` to the `(initramfs)` prompt, runs `cat /proc/cpuinfo` and `uname -m`, restarts with `reboot -f` to the prompt again, and powers off. `--no-reboot` checks that `reboot -f` ends `hengevm` with status 3, and `--fatal` that a SIGILL still prints the crash report; the make target runs all three. It reads the artefacts from `HENGE_LINUX_OUT`, or from `build/linux` in the main checkout. `--cpus`, `--ram`, `--phone` and `--runs` pass through; `--qemu` runs the same checks on QEMU, and `--qemu --henge-dtb` boots QEMU with Henge's tree. Extra options for the make target go in `SMOKE_ARGS`.
