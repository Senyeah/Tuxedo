# Linux guest tools

These scripts build the firmware and the Debian image for Linux guests. They run on a Mac with Docker.
Every script runs inside the builder container, so no cross compiler is needed.

## Layout

- `versions.env`: pinned versions (U-Boot tag, Debian suite, snapshot date).
- `Dockerfile`: the builder image (`debian:trixie` with the build tools).
- `run.sh`: runs a command in the builder image. `build/linux/` is mounted at `/out`, the repo's `tools/linux/` at `/tools` (read only), and a named volume at `/work` for source trees.

`run.sh` builds the image on first use. Set `HENGE_LINUX_OUT` to change the artefact directory. The default is the shared `$HOME/Repos/Henge/build/linux`, so all worktrees see the same files.

Keep source trees in `/work`, not on the Mac filesystem. It is case-insensitive and the kernel tree has names that differ only by case.

## Order

1. `run.sh uname -m` checks the container. It prints `aarch64`.
2. `build-uboot.sh` (G2) makes `u-boot.bin` and `u-boot.manifest`.
3. `build-image.sh` (G3) makes `debian-console.img`, `Image`, `initrd.img`, the partition UUID file and the manifest.
4. `qemu-ref.sh` (G5) boots the result on QEMU's `virt` machine.

Steps 2 to 4 do not exist yet. This table lists what each task adds.
