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

Options of `qemu-ref.sh`: `--accel hvf|tcg` (default `tcg`), `--its-off`, `--dtb FILE`, `--gpu`, `--direct` (boot `Image` and `initrd.img` with `-kernel`). `hvf` works only with `--direct`, because U-Boot aborts under `hvf`; `hvf` also forces the ITS off. The disk opens with `snapshot=on`, so the shared image never changes.

`qemu-check.py` drives it with pexpect (`uv run`): it checks page size, CPU count, network, run-time VA size and power off, and saves the reference output to `build/linux/ref/`. Use `--direct --accel hvf` for the fast check and the default for the full U-Boot path.
