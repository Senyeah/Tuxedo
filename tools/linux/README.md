# Linux guest tools

These scripts build the firmware and the Debian image for Linux guests. They run on a Mac with Docker.
Every script runs inside the builder container, so no cross compiler is needed.

## Layout

- `versions.env`: pinned versions (U-Boot tag, Debian suite, snapshot date).
- `Dockerfile`: the builder image (`debian:trixie` with the build tools).
- `build-uboot.sh`, `build-image.sh`, `customize.sh`, `rootfs/`: see Order.
- `customize-desktop.sh`, `rootfs-desktop/`: extra files for the desktop image (`build-image.sh --desktop`).
- `tux-guest/` (G9): the source of the `tux-guest` Debian package. It holds the grow and first-boot scripts (`/usr/lib/tux/`) and units (`/usr/lib/systemd/system/tux-*.service`, G8), and enables them in `postinst`. `build-guest-pkg.sh` builds the `.deb` on its own; `build-image.sh` builds it too and installs it in both images. P6 adds the shared-folder mount (`home-tux-Tux.mount` and `.automount`, `/etc/tux/davfs2.conf`); P7 adds the clipboard helper (`tux-clipboard` and a user unit). DS5 adds `tux-status` and its unit, and UPower's settings. 1.6.0 adds the wallet, `tux-secrets` (see Wallet); 1.6.1 puts the command on the PATH. 1.7.0 adds the folders from Files (`tux-files`, see Folders from Files); 1.8.0 takes the app's Export Changes and Discard Changes, and remounts a Copy-on-write folder when its original changes. 1.9.0 adds the Tuxedo apt repository's key (`/usr/share/keyrings/tux-archive.gpg`) and its source (`/etc/apt/sources.list.d/tux.sources`), which is off (see ffmpeg with the device's codecs); 1.9.1 makes that source the admin's file, not a conffile; 1.10.0 joins 1.8.0 and 1.9.1; 1.10.1 is the first with the `tux-*` names; 1.10.2 mounts the shared folder for the user `tux` and gives the wallet firewall that default; 1.11.0 adds Tuxedo Additions (the launcher, the console login, the report script; see Tuxedo Additions). `grow-check.py` tests the grow units, `share-check.py` the shared folder and `clipboard-check.py` the clipboard.
- `build-ffmpeg.sh` (VE2): the guest's `ffmpeg` with the Tuxedo codecs. It applies `hvcodec/ffmpeg-tux.patch` to the FFmpeg release in `versions.env`, builds `libhvcodec` (`hvcodec/libhvcodec/`) and `tux-codec-info`, and writes `ffmpeg/bin/` and `ffmpeg/ffmpeg.manifest` in the artefact directory. It runs in an arm64 `debian:trixie` container with packages from the pinned snapshot (about 3 min). `make test-linux-ffmpeg` checks the result in a clone of the desktop image. See `docs/guest-video-encode-plan.md`.
- `build-ffmpeg-pkg.sh` (VE3): the `tux-ffmpeg` package from that build, with `tux-ffmpeg/` (its `postinst`, `prerm` and `copyright`) and the man page `hvcodec/ffmpeg-tux.7.md`. Output: `ffmpeg/tux-ffmpeg_<release>-tux<N>_arm64.deb`. `make linux-ffmpeg-pkg`. `build-image.sh` installs this package (the version in `versions.env`) and `man-db` in both images, so build it first.
- `publish-apt.sh` (VE3): the signed apt repository in `build/linux/apt` and the source offer in `build/linux/source`. Nothing leaves the Mac unless you give it `--rsync`. `make linux-apt`. `tux-archive.asc` is the repository's public key.
- `build-va-pkg.sh`: the `tux-va` package from `tux-va/`, the VA-API driver that goes in front of Mesa's virgl driver so Firefox keeps VA-API decode (see Video decode). Output: `va/tux-va_<version>_arm64.deb`. `make linux-va-pkg`. Both images have the package, `publish-apt.sh` adds it to the repository, and `tux-guest` recommends it.
- `package-additions.sh` and `additions/` (Tuxedo Additions): the media that the app inserts as a CD. `make linux-additions`. See Tuxedo Additions.
- `snapshot-apt.sh`: sourced by the container scripts above, so they install packages from the snapshot in `versions.env`.
- `run.sh`: runs a command in the builder image. `build/linux/` is mounted at `/out`, the repo's `tools/linux/` at `/tools` (read only), and a named volume at `/work` for source trees.

`run.sh` builds the image on first use. `TUX_LINUX_OUT` is the artefact directory. The scripts and checks default to `build/linux` of the main checkout (found with `git rev-parse --git-common-dir`), where all worktrees share the files.

Keep source trees in `/work`, not on the Mac filesystem. It is case-insensitive and the kernel tree has names that differ only by case.

U-Boot is GPL-2.0 and Debian's packages have their own licences. [docs/licensing.md](../../docs/licensing.md) says what to keep with a shipped image and how to fetch the source.

## From nothing

This builds every artefact, in order, on an Apple Silicon Mac. The times are the ones the findings log recorded on an M4 Pro. The commands without a time were not timed.

Needs:

- Xcode 27 or later, `uv`, and Homebrew's `pkgconf` and `libslirp` (`brew install pkgconf libslirp`).
- Docker with arm64 images (Docker Desktop or colima). Keep the artefact directory under your home folder: a path under `/private/tmp` made the scripts exit 0 and write nothing to the Mac.
- Disk space: the console image takes about 0.53 GB and the desktop image about 0.85 GB on disk (each is a 3 GB sparse file), plus Docker's work volume. `tools/gfx` (optional) takes about 8.3 GB.
- QEMU (`brew install qemu`) only for the reference checks (`qemu-ref.sh`, `qemu-check.py`, `make test-linux-dtb`).

Steps, from the root of a clean checkout:

```sh
export TUX_LINUX_OUT=$PWD/build/linux       # set it in every shell that runs these scripts

tools/linux/run.sh uname -m                   # builds the builder image, prints aarch64
tools/linux/build-uboot.sh                    # build/linux/u-boot.bin and .manifest
tools/linux/build-uboot.sh --stock            # u-boot-stock.bin, with the 2 s countdown; the U-Boot prompt tests need it
make linux-ffmpeg linux-ffmpeg-pkg           # about 4 min: tux-ffmpeg, which both images install
tools/linux/build-image.sh                    # about 6 min (the first image): debian-console.img, Image, initrd.img, .partuuid, .manifest
tools/linux/build-image.sh --desktop          # debian-desktop.img (labwc and foot)

make                                          # the Mac tool: build/tuxvm, build/hvsparse
make test-linux-direct                        # Image and initrd.img on build/tuxvm, to a shell
make test-linux-smoke                         # U-Boot, extlinux, Debian, restarts and the power key
```

`build/linux` ends up with `u-boot.bin`, `u-boot-stock.bin`, `Image`, `initrd.img`, `config-debian-16k`, both images and their `.partuuid` and `.manifest` files. All of it stays out of git. The pins are in `versions.env`: the U-Boot tag and the Debian snapshot date. The builder image is `debian:trixie` and is not pinned by digest.

To boot by hand, use a copy, because `tuxvm` writes to the disk. `cp -c` makes an APFS clone that costs no space:

```sh
cp -c build/linux/debian-console.img /tmp/tux-debian.img
build/tuxvm --firmware build/linux/u-boot.bin --disk /tmp/tux-debian.img --ram 2048 --cpus 2
```

An image built before `tux-guest` 1.11.0 signs in as `tux` by itself. With 1.11.0, a machine with no account marker signs in as root (see Tuxedo Additions). `Ctrl-A p` presses the power key, and `Ctrl-A x` stops the machine. For the desktop image add `--window`, and `--gpu-accel` for 3D after `tools/gfx` (below).

Then, as needed:

```sh
tools/linux/package-image.sh --image build/linux/debian-console.img --kind console   # build/linux/dist/: package + linux-images.json
tools/linux/package-image.sh --image build/linux/debian-desktop.img --kind desktop
tools/linux/serve.sh                          # the catalogue on the LAN, for the app's Settings
tools/linux/export-ios.sh build/linux/debian-console.img build/linux/u-boot.bin Debian   # a folder to import through Files

tools/gfx/build-deps.sh                       # 30 to 60 min, about 9 GB: ANGLE, libepoxy, virglrenderer (optional)
make GFX=1                                    # tuxvm with --gpu-accel
make test-linux-accel                         # virgl against pixman, frame time and glmark2
```

The app: `ios/scripts/sim_build.sh` builds and runs it in the iOS Simulator with no phone, signing or Husk checkout. A device build needs the Husk checkout, `ios/scripts/fetch_deps.sh` and `ios/scripts/package_ipa.sh` (see the root README, Building). With `tools/gfx` built, both scripts link the graphics libraries on their own (`ios/scripts/gfx_env.sh`). The app gets a Linux image from the catalogue address in Settings or from an imported folder.

If a step fails, run it again with the same `TUX_LINUX_OUT`. `build-image.sh` renames its output into place, so a failed build does not damage an image that is in use, and `make clean` keeps `build/linux`.

## Order

1. `run.sh uname -m` checks the container. It prints `aarch64`.
2. `build-uboot.sh` (G2, P2) makes `u-boot.bin`, `u-boot.config` and `u-boot.manifest` (tag, commit, fragment, SHA-256). It builds `qemu_arm64_defconfig` plus the boot-speed fragment `u-boot-tux.config` (no autoboot countdown, no EFI boot manager) in `/work/u-boot`. `build-uboot.sh --stock` builds the unmodified defconfig as `u-boot-stock.bin`, which keeps the 2 s countdown; the checks that stop at the `=>` prompt (`smoke.py --uboot` second boot, `input-check.py`, `kernel-boot-time.py`, `qemu-ref.sh`) use it when it exists. Check it with `qemu-system-aarch64 -M virt -cpu cortex-a57 -nographic -bios build/linux/u-boot.bin`.
3. `build-image.sh` (G3, K1, G4) makes `debian-console.img`, `Image`, `initrd.img`, `config-debian-16k`, `debian-console.partuuid` and `debian-console.manifest` (kernel format, extlinux.conf, kernel config lines, package list, and `guest_user` and `guest_host`, read back from the new root file system). The checks take the user from there through `guest_user.py` (`TUX_GUEST_USER` overrides it for a disk with no manifest); a manifest with no `guest_user` is an image from before Tuxedo, and its user is the legacy name. It takes about 6 minutes. It installs `tux-guest`, built from `tux-guest/`, and `tux-ffmpeg` from `ffmpeg/` with `man-db` (apt brings the Debian libraries); it stops if that package is missing. `tux-codec-dkms` is not in the images (decision 11). `customize.sh` runs inside the new root filesystem and `rootfs/` is copied into it first. Set `DEBIAN_MIRROR` to use another mirror, for example `http://deb.debian.org/debian/`.
4. `build-image.sh --desktop` (G6) makes `debian-desktop.img`, `debian-desktop.partuuid` and `debian-desktop.manifest`. It adds labwc, foot, fonts-dejavu-core and the Mesa test tools to the console image's packages. It builds in `/work/G6` and does not touch the console image or `Image` and `initrd.img`. See Desktop below.
5. `qemu-ref.sh` (G5) boots the result on QEMU's `virt` machine.

Options of `qemu-ref.sh`: `--accel hvf|tcg` (default `tcg`), `--its-off`, `--dtb FILE`, `--gpu`, `--direct` (boot `Image` and `initrd.img` with `-kernel`). `hvf` works only with `--direct`, because U-Boot aborts under `hvf`; `hvf` also forces the ITS off. The disk opens with `snapshot=on`, so the shared image never changes.

`qemu-check.py` drives it with pexpect (`uv run`): it checks page size, CPU count, network, run-time VA size and power off, and saves the reference output to `build/linux/ref/`. Use `--direct --accel hvf` for the fast check and the default for the full U-Boot path.

## First boot and disk growth (G8)

Both units come from the `tux-guest` package. Raise `Version` in `tux-guest/DEBIAN/control` when a file in it changes. `smoke.py --disk` and `--uboot` check `dpkg-query` and `systemctl is-enabled` for the package and its units.

- `tux-grow.service` runs on every boot. `tux-grow` finds the root partition from sysfs. It keeps the disk size (512-byte sectors) of its last run in `/var/lib/tux/grow-size`; when the size is the same it logs "disk unchanged" and stops (the tools cost about 2 s at 1 CPU). Otherwise it moves the backup GPT header to the end of the disk (`sgdisk -e`), runs `growpart` and then `resize2fs` on the mounted root, and writes the new size. The app grows the disk file, and the next boot grows the guest.
- `tux-firstboot.service` runs once, while `/var/lib/tux/firstboot-done` is missing. It runs `systemd-machine-id-setup` if `/etc/machine-id` is empty, then writes the marker.
- `grow-check.py` (`uv run`) clones an image, grows the clone to 16 GB (sparse), boots it through U-Boot, checks the grown partition, filesystem and GPT, boots it again unchanged (the journal must say "disk unchanged"), grows it by 4 GB more and boots a third time (the tools must run again and the stamp must follow the size). `--qemu` uses QEMU TCG. Otherwise it uses `build/tuxvm`. `--image`, `--firmware` and `--work-dir` choose files.

## Shared folder (P6)

`tux-guest` mounts `http://10.0.2.4/` (the share server in `host/share.c`, reached through the user-mode network) at `/home/tux/Tux` with `davfs2`. The package depends on `davfs2`, and `build-image.sh` installs it.

- `home-tux-Tux.automount` is enabled; the mount happens on the first visit to `~/Tux`, so a boot with no network or no `--share` does not wait for it. Without the share, the first visit takes about 12 s (davfs2's connect timeouts, under the unit's `TimeoutSec=20`), then shows only what davfs2 cached, and writes fail with "Resource temporarily unavailable". The unit does not fail and the system stays `running`.
- `/etc/tux/davfs2.conf` is passed with the `conf=` mount option and does not touch Debian's `/etc/davfs2/davfs2.conf`. It sets `ask_auth 0`, `dir_refresh 5` (a change made on the Mac shows in the guest within about 5 s) and `delay_upload 1` (a write reaches the Mac about a second after close). The unmount at shutdown uploads what is left.
- Files belong to `tux:tux`. davfs2 caches in `/var/cache/davfs2` and shows its own `lost+found` in the folder's root; it cannot be hidden.
- Locks: the server accepts `LOCK` and `UNLOCK` and enforces nothing, and davfs2 is content with that (`use_locks` stays on). The check sees no davfs2 message about locks.
- `share-check.py` (`uv run`) boots a clone of `--image` with `--share`, and checks the mount, create, rename, delete, names with spaces and non-ASCII characters, a 100 MB copy each way, and a write right before poweroff. A second boot without `--share` checks that the machine still reaches `running` and that a visit to the folder fails in time. `--size-mb`, `--cpus`, `--image`, `--firmware` and `--work-dir` choose the run.

## Folders from Files (FM5)

A Linux machine can mount folders that the person picks in the Files app (docs/files-mount-plan.md). The host serves them on one virtio-fs device, tag `tux-files` (`devices/virtio_fs.c`, `host/fs_server.c`). `tux-guest` 1.7.0 and later mounts each one at `/media/tux/<name>`.

- `run-tux-files.mount` mounts the tag at `/run/tux/files`. Its root has a directory for each folder and `.tux-folders`, the table as JSON (index, id, name, mode, state, case, gen, orig, and an ask while the app has one open). The mount and `tux-files.service` have `ConditionDirectoryNotEmpty=/sys/fs/virtiofs`, so a machine with no folders skips both: no failed unit, and the system stays `running`.
- `tux-files.service` runs `/usr/lib/tux/tux-files run` (Python 3). It mounts each folder by its mode: Read-write (the default) and Read-only as bind mounts (`nosuid,nodev`), Copy-on-write as an overlay (`redirect_dir=off,index=off,metacopy=off,xino=off`) with the upper layer in `/var/lib/tux/files/<id>/` on the root disk (mode 0700, root; `tmpfiles.d/tux-files.conf`, which also empties `/media/tux` at boot, so no mount point is left from the last one). The kernel loads `overlay` on the first such mount. The host refuses every change in Read-only and Copy-on-write folders itself, so root's `mount -o remount,rw` gets `EROFS` from the host.
- News comes from a long `GET /.tux/folders?since=N` on the share server; without the share (`tuxvm` without `--share`) the helper reads `.tux-folders` every 2 s. On news it mounts a new folder, unmounts a removed one (lazily if a program has it open), and moves a renamed one (same id) with its upper layer. A new mode, or another original for a Copy-on-write folder (a new `gen`: the owner's decision 5, the guest's changes stay on top), waits until nothing has the folder open, then remounts it. A folder the app cannot reach gives `EIO` inside it and comes back with no remount; the helper logs it and, where `notify-send` and a session bus exist, tells the desktop once.
- The app's buttons (FM10): Export Changes and Discard Changes put an `ask` in the table (`{"n": N, "do": "export"}` or `"discard"`). The helper runs `export NAME` to `~/Tux/Exports` (it refuses when `~/Tux` is not mounted, because Files would not show the export) or `reset NAME`, then answers with `POST /.tux/folders/done?index=I&ask=N&ok=0|1`: the export's folder below `~/Tux`, its counts, and `files=N bytes=B` (every file it wrote, the lists too), or why not. davfs2 uploads after the answer, so the app shows the export only once `Shared/Exports/<folder>` has that many files and bytes, and says only part arrived after 30 s with nothing new. The host drops the ask once it has the answer, so a helper that starts again does not do it twice. A changed `orig` (the app saw the original change) remounts a Copy-on-write folder when nothing has it open, so a file new in the original shows.
- `tux-files list` shows the folders, and Copy-on-write layers that have no folder now, each with its key (the folder's id, or a hash of it). For such a layer, `export` and `reset` take its key or its name; a name that two layers have gives their keys and does nothing, and a name that a folder in the table has means that folder. `tux-files export NAME [DEST]` copies a Copy-on-write folder's changed and new files to `DEST`, by default `~/Tux/Exports/<name>-<dd-mm-yyyy-hhmm>/` (Files shows it under Tuxedo). `deletions.txt` there lists each deleted path; a line that ends in `/` is a directory that was deleted and made again, so nothing of the original in it is kept but what the export has. `links.txt` lists symbolic links that the destination cannot hold (davfs2 has none). `tux-files reset NAME` discards the changes (it refuses while the folder is open) and runs `fstrim /`; `tux-files remount NAME` mounts a folder again. The commands that need root run themselves through `sudo -n`. Removing the package unmounts the folders and keeps the layers.
- Copy-on-write limits, all overlayfs's own: renaming a directory from the original gives `EXDEV` (`redirect_dir` is off), so `mv` copies it and a program that calls `rename()` on it fails; a hard link to a file from the original is one file with two inode numbers (`index` is off); and a file that appears in the original while the folder is mounted shows after `tux-files remount NAME`, because the overlay keeps its own "no such file" for a name it has looked up. A change to a file already there shows at once.
- Places: the user unit `tux-files-places.service` (enabled for every user, `default.target`) adds `file:///media/tux Folders` to GTK's `~/.config/gtk-3.0/bookmarks`, and a bookmark to Dolphin's `~/.local/share/user-places.xbel` when KDE has made that file (so after the first Plasma login, at the next one).
- Everything in the folders shows as `tux:tux` (uid and gid 1000). `chown` to another owner gives `EPERM`; xattrs give `ENOTSUP`; device nodes and sockets give `EPERM`; a FIFO works. A path longer than the host's `PATH_MAX` (1024 bytes on iOS and macOS), and a symbolic link's text over 1023 bytes, give `ENAMETOOLONG`.

`files-check.py` (FM6, `make test-linux-files`, `uv run`) checks all of this on a clone of `--image` (default `debian-console.img`). Boot 0 installs `tux-guest` built from `tux-guest/` (Docker; `--deb FILE` names another), `gcc`, `git`, `make`, `perl` and fsx (LTP 20230127's `fsx-linux.c`, checked by SHA-256) with apt; `--save-image FILE` keeps that disk, and `--image FILE --no-install` uses it. Boot 1 has `--share` and `--folder a=DIR:ro --folder b=DIR:cow --folder c=DIR`, each with the same small tree, and checks:

- the mounts (types, `ro`/`rw`) and owners;
- Read-only: 15 kinds of change give `EROFS`, as tux and as root after `mount -o remount,bind,rw`; the Mac's folder is unchanged;
- create, write, append, delete, rename, `mkdir`, `rmdir`, `rm -r`, symbolic and hard links, `chmod` and an append to a 1 MB file in b and c: the guest's view is as expected in both; b's Mac folder is unchanged (a directory from the original gives `EXDEV`, `mv` copies it); c's Mac folder has every change (the hard link is one inode there); `tux-files export b` gives the 9 changed files, `deletions.txt` and `links.txt` in `~/Tux/Exports`; `reset` empties the upper layer;
- another original picked for b (`folder add b DIR2 cow`): the overlay moves onto it and keeps the guest's file;
- two layers with no folder, both called Docs: `tux-files list` gives each key, `reset Docs` refuses and names both keys, `export` and `reset` by key work;
- a file made on the Mac shows in c within 2 s, a changed file in c and b within 2 s, and a new file in b's original after `tux-files remount b`;
- the app's part (`folder touch b`, `folder export b`, `folder discard b` in `HV_INPUT_FILE`): a new file in b's original shows after a touch with no remount by hand; an export lands in the share's `Exports` with the changed file, the answer names it, and the share has the files and bytes the answer gives; a discard empties the upper layer; an export of the Read-write folder is refused by the host;
- a new mode (`a` to rw, then ro), `folder offline`/`online` (`EIO`, then the same mount works), `folder add d` and `folder remove d` while running;
- a program built on c three times with new code prints the new number each time (`hv_dma_written`), and a shared `mmap` write with `msync` reaches the Mac;
- links made on the Mac to `/`, `../../..` and `/private/etc` resolve in the guest, never to the Mac's files;
- fsx on c for `--fsx-seconds` (600) with mapped reads and writes;
- times for `tar x` of `--files` (10 000) small files, `rm -r`, `git clone` and `git status` (cold and warm) of a bundle of this repository, and `dd` of `--dd-mb` (1024) MB each way on c, b, the root disk and `~/Tux` (davfs2, `--davfs-files` 1000 and `--davfs-mb` 100, because davfs2 copies each file whole). `--json FILE` keeps them.

Boot 2 has no `--folder`: the system is `running`, no unit failed, and `/media/tux` is empty.

`files-check.py --pjdfstest` (FM7, `make test-linux-files-posix`, not part of `make test`) installs pjdfstest (commit `85a8aea`, built in the guest) in boot 0 and runs its rename, unlink, link, symlink, chmod, open and mkdir groups on c as root, then prints each group's counts and its failures grouped by the operation they tried. It fails on a cause that is not in this list. On the Mac (13/11/2026, a case-insensitive APFS folder in `/tmp`), 77 of 124 test files pass, and every one that fails fails first on one of these, all by design:

- `chown` or `lchown` to another owner: `EPERM`. Everything is `tux:tux`, so the tests that then act as uid 65534 or 65533 get `EACCES` or `EPERM` too (22 files, most of the `not ok` lines in rename 09 and 10).
- `mknod` of a block or character device: `EPERM`; the same test file goes on with the device that is not there (17 files).
- `bind` of a Unix socket: `EPERM` (open 24).
- A path over the host's `PATH_MAX` (1024 bytes), or a link's text over 1023 bytes: `ENAMETOOLONG` (7 files: the 03 tests, and rename 02).

| Group | ok | not ok | Test files that pass |
| --- | --- | --- | --- |
| rename | 1276 | 3581 | 14 of 25 |
| unlink | 149 | 291 | 10 of 15 |
| link | 190 | 169 | 11 of 18 |
| symlink | 75 | 20 | 9 of 13 |
| chmod | 181 | 146 | 7 of 13 |
| open | 132 | 205 | 19 of 27 |
| mkdir | 79 | 39 | 7 of 13 |

FM7 found two faults in the host, both fixed: a new file, directory or FIFO had the app's umask (022) applied on top of the guest's, so `open(O_CREAT, 0777)` gave 0755 (chmod 12, open 02); and `fstat` of an open file that the guest had unlinked gave `ESTALE` (unlink 14).

## Clipboard (P7)

`tux-clipboard` (`/usr/lib/tux/`, run by the user unit `tux-clipboard.service`) speaks the `/.tux/clipboard` protocol, so `host/share.c` and the app's "helper running" test (`tux_share_helper_seen`, a poll in the last 40 s) work unchanged. The desktop image's labwc `autostart` imports `WAYLAND_DISPLAY` and `DISPLAY` into the user manager and starts the unit, so it runs only on the desktop; the console image has no clipboard (the app writes pasted text to the console).

- Device to guest: a `GET ?since=N` that the server holds up to 25 s. The first request uses `since=0`; the answer that comes back at once is what the device held before the helper started, and is dropped. News goes to `wl-copy`.
- Guest to device: Wayland uses `wl-paste --type text --watch` (one base64 line per change); X11 (`TUX_CLIPBOARD=x11`, or `DISPLAY` without `WAYLAND_DISPLAY`) looks with `xclip` once a second. Text that was just set from the device is not sent back, and a clipboard with the `x-kde-passwordManagerHint` type (password managers) is not sent. Clipboards over 16 MB or not valid UTF-8 are not sent. Not tested: the password manager type, as `wl-copy` cannot offer two types.
- The app's paste button sets the device clipboard, waits 0.8 s and sends Ctrl-V; its menu chooses Ctrl-Shift-V for terminals.
- The desktop package list adds `wl-clipboard`, `xclip` and `python3`; the package only recommends them.
- `clipboard-check.py` (`uv run`, `make test-linux-clipboard`) boots a clone of the desktop image with `--share` and `HV_INPUT_FILE` (`clip TEXT` and `getclip`), and checks each of the points above, plus the X11 mode through XWayland. `--image`, `--tuxvm`, `--cpus` and `--work-dir` choose the run.

## Port forwards

Another device can reach a TCP port in the guest through a port on the phone (`host/net_forward.c`, applied by `host/net_slirp.c`).

- A Linux machine's settings have a list of forwards: each is a phone port (1024 to 65535; iOS binds no lower port) to a guest port (1 to 65535), with an optional name, and on or off. No two forwards have the same phone port; a machine has at most 16. Add SSH adds 2222 to 22, named SSH. A new machine has none. The guest needs a server on the port: for SSH, `sudo apt install openssh-server`.
- The app listens on the local networks only: the IPv4 addresses of Wi-Fi and Ethernet (`en*`), Personal Hotspot (`bridge*`) and VPNs (`utun*`, so Tailscale and WireGuard too). Never on cellular (`pdp_ip*`), and not on `ipsec*`: Wi-Fi Calling's tunnel to the carrier is one, so a VPN on `ipsec*` (the built-in IKEv2 VPN) gets no listener. A `169.254` address (Wi-Fi with no DHCP lease) does not count either. It also listens on 127.0.0.1, so an app on the same device (an SSH client, Safari) can connect while the machine runs (in Split View, or a machine that plays sound in the background). iOS has no listen on one interface, so there is one libslirp forward for each forward and address. They follow the device's addresses: the app refreshes them when `NWPathMonitor` reports a change, and the network thread looks again every 5 s.
- IPv4 only. libslirp makes the guest's side of a connection in the listener's family, and the guest has no IPv6 network, so an IPv6 listener would need IPv6 in the guest.
- Details shows, while the machine runs, what to connect with for each forward and network, with a copy button: `ssh -p 2222 tux@192.168.1.20` (the machine's own `guestUser`) for a forward to port 22, else `192.168.1.20:8000`. On cellular only it says that there is no local network. A phone port that cannot be opened (another app has it) is an error on that forward; the machine starts anyway, and the app tries the port again every 5 s. libslirp binds each address with `SO_REUSEADDR`, which BSD allows next to another app's listener on `0.0.0.0` (or a dual-stack `::`); that app's clients on the address would then reach the guest. So before each bind the app tries `0.0.0.0` on the port (with `SO_REUSEADDR`, so its own listeners and old `TIME_WAIT` connections do not count), and a taken port is the same error. A listener on all addresses that another app opens after the forward is up is not seen. Settings saves a typed port after a pause of 0.6 s, and when the page closes, so a port typed on the way to another (2222 on the way to 22222) is not opened; a blank port field keeps the saved port and says so.
- The forwards come up with the machine's network and go when it stops. In the background the listeners stay, but a paused machine (graphics acceleration, or no sound) does not answer: a connection waits until the app is back, or the client gives up.
- `tuxvm --forward HOSTPORT:GUESTPORT` (up to 16) listens on 127.0.0.1; `--forward-addr IPV4` chooses another address, and `--forward-addr local` does what the app does. `HV_NET_FWD=HOSTPORT:GUESTPORT` still works: it is one more `--forward`. tuxvm logs each forward (`net: forward ADDR:PORT -> guest port N`) and each that failed (`net: no forward from ADDR:PORT: ...`). On a Mac with the application firewall on, connections from other addresses to an unsigned `tuxvm` wait and never reach it; 127.0.0.1 always works.
- `forward-check.py` (`make test-linux-forward`, `uv run`) boots a clone of `debian-console.img` with `--forward` to 22, to 8000, to a port the Mac holds on 127.0.0.1 and to one it holds on `0.0.0.0`. It installs `openssh-server` in the clone and a key pair made for the run (in its temporary folder), logs in with `ssh` through the forward and sends 16 MB each way, gets a `python3 -m http.server` page with `curl`, checks the error for each held port and that the forward comes up once the port is free, and that nothing listens on the Mac's LAN address. A second boot has `--forward-addr local` and `HV_NET_FWD`. `--image`, `--tuxvm`, `--cpus`, `--work-dir` and `--keep-logs DIR` go in `FORWARD_ARGS`.
- `test_net_forward` (in `make test`) checks the table with fake interface lists and a fake libslirp: which interfaces count, the order, what a refresh adds and removes when a VPN comes up, Wi-Fi changes its address, the phone goes to cellular only, or a rule changes, and a port in use; a rule's state by its phone port while the table still has the old list; and the `0.0.0.0` probe on real sockets.

## Device status (LINUX-PLAN-13)

The guest shows the device's battery, charging state, screen brightness, volume, time and time zone. Most of it needs no helper, because the `virt` board has devices that Debian's kernel drives:

- Battery: an SBS battery (`sbs-battery`) at address 0x0b on an OpenCores I2C bus (`i2c-ocores`, `0x090c0000`, SPI 10), with its presence on PL061 pin 5. It is `/sys/class/power_supply/sbs-0-000b`. The capacity (4000 mAh), voltage and temperature are nominal; the current and run times come from how fast the level changes. A device that does not know its battery state (the simulator, or `tuxvm` with no `battery` line) shows a battery that is not present.
- Mains: `gpio-charger` on PL061 pin 4, `/sys/class/power_supply/ac-power`. It is online while the device charges or is full.
- Brightness: a TI LP8556 backlight (`lp855x_bl`) at 0x2c, `/sys/class/backlight/tux-backlight` (type `platform`, 0 to 255). A guest write sets the device's screen.
- Clock: the PL031 is the host's time, and the `virt` board ignores the guest's writes to it: Linux writes its clock back every 11 minutes while it thinks it is in sync, and after a pause that clock is behind.
- Volume: virtio-snd has the controls "Master Playback Volume" (0 to 100, no dB scale, so the guest's percent is the device's) and "Master Playback Switch". The device's volume reaches the guest as a control event; a guest change (`amixer`, PipeWire, the Plasma applet) sets the device's volume. Mute is the guest's own: the host then plays silence. The Mac's virtio-snd has no controls.
- `tux-status` (`/usr/lib/tux/`, the system unit `tux-status.service`, both images) waits on `GET /.tux/status` (`host/share.c`) and follows the rest: it steps the clock when it is 0.5 s or more off (after a pause it is behind), runs `timedatectl set-timezone` when the zone changes, and writes the backlight when the device's brightness changes. Without the share server it tries again every 30 s.
- A saved or default guest level must not set the device at boot. So `customize.sh` masks `alsa-restore.service`, `alsa-state.service` and `systemd-backlight@backlight:tux-backlight.service`, and an empty `/etc/udev/rules.d/90-alsa-restore.rules` hides the alsa-utils rule that runs `alsactl restore` (or `init`, which sets Master to 75 %) when the card appears.
- WirePlumber sets a route's volume when it turns the route on: the stored one, or 40 % by default. On the desktop, `/usr/share/wireplumber/scripts/tux/keep-device-volume.lua` (loaded by `/etc/wireplumber/wireplumber.conf.d/50-tux.conf`) keeps the card's own volume and mute instead, so a login does not change the device's volume. It matches the card by `alsa.driver_name` `virtio_snd`. PipeWire writes one channel at a time, so the device passes on the louder channel.
- At a critical battery the guest does nothing: `tux-guest` gives `upower.service` its own `/etc/tux/UPower.conf` (`CriticalPowerAction=Ignore`) through `UPOWER_CONF_FILE_NAME`, and the desktop's `/etc/xdg/powerdevilrc` sets Plasma's critical action to nothing. Plasma still shows its low and critical notices. The same file turns off Plasma's dimming when idle and its low-battery brightness, because the backlight is the device's screen.
- The Plasma install line brings `powerdevil` and `plasma-pa` as recommends and `upower` as a dependency. The Additions install uses `--no-install-recommends`, so its Plasma list names `kscreen` (the Display page, only a Recommends of `plasma-desktop`) and `upower` itself.
- `tuxvm` lines in `HV_INPUT_FILE`: `battery LEVEL unplugged|charging|full|unknown`, `brightness F`, `volume F`, `tz NAME` and `status`. `HV_STATUS_LOG=1` logs each guest request on stderr.

## Packaging and catalogue (G7)

- `package-image.sh --image FILE --kind console|desktop` packs the raw image with `build/hvsparse`, compresses it with `compression_tool -encode -a lzfse` to `debian-<kind>-<date>.hvsparse.lzfse`, then decodes and unpacks the result and checks the SHA-256 against the image (`--no-verify` skips this). It copies the firmware to `u-boot-<sha12>.bin` and adds or replaces the entry `debian-<kind>` in `linux-images.json`. Output goes to `build/linux/dist/`; `--out DIR` changes it. The manifest next to the image gives the kernel string and is checked against `image_sha256`. `--firmware`, `--date` and `--min-build` override the defaults (`build/linux/u-boot.bin`, today in GMT+12, the Info.plist build plus one).
- `linux-images.json` is `{"images": [...]}`. Each entry has `id`, `name`, `version`, `kind`, `diskURL`, `diskBytes` (download), `diskSHA256`, `unpackedBytes` (the `.hvsparse` file, the data to write), `logicalBytes` (the disk), `firmwareURL`, `firmwareBytes`, `firmwareSHA256`, `kernel`, `minBuild`, and `guestUser` (the manifest's `guest_user`; `package-image.sh` stops if the manifest has none). `minBuild` is the build in `Info.plist` unless `--min-build` gives one. The app refuses an entry with no `guestUser`: it is a Henge image. A machine made from an entry stores its `guestUser`; an imported machine folder with none logs in as the legacy name. The two URLs are relative to the catalogue's URL.
- `serve.sh` serves `build/linux/dist/` on the LAN address (`--bind`, `--port`, `--dir`). It asks before it opens the port; `--yes` skips the question. It answers `Range` requests, which `http.server` does not, because the app resumes downloads with them. Stop it with Ctrl-C.

## Wallet: KDE Wallet and the Secret Service in the Keychain

A Linux machine keeps its saved passwords in the device's Keychain, not in a wallet file in the guest. `tux-secrets` (`/usr/lib/tux/`, the command `/usr/bin/tux-secrets`, the user unit `tux-secrets.service`, enabled for every user in `default.target`) owns three names on the session bus:

- `org.freedesktop.secrets`, the freedesktop Secret Service: libsecret (`secret-tool`, GNOME and GTK programs, Chromium and Electron with `--password-store=gnome-libsecret`), QtKeychain programs (they try libsecret first), and kwalletd from KDE Frameworks 6.14 and later.
- `org.kde.kwalletd6` and `org.kde.kwalletd5`, the KWallet API (`/modules/kwalletd6`, `org.kde.KWallet`): KDE programs, plasma-nm, KIO, and Chromium and Electron on KDE (their default store there).

Why both, and not kwalletd6 itself: Debian trixie has KDE Frameworks 6.13. Its kwalletd6 keeps its own `.kwl` files and can only be a Secret Service provider, not a client of one. From 6.14, kwalletd is a client of any Secret Service provider (`kwalletrc`: `[KSecretD] Enabled=false`, `[Migration] MigrateTo3rdParty=true`), but trixie does not have it. So `tux-secrets` does what kwalletd 6.14 does: it serves the KWallet API from the Secret Service items (attributes `server` = folder, `user` = key, `type` = `plaintext`, `base64` or `map`; maps as JSON). A KWallet entry is the same item through both APIs. Without Plasma (labwc), nothing else is needed.

- The package diverts the D-Bus activation files `org.freedesktop.secrets.service` (gnome-keyring), `org.kde.kwalletd6.service` and `org.kde.kwalletd5.service` (kwallet6) to `*.service.tux`, and puts its own in their place (`tux-secrets --activated`).
- The unit starts with the user's systemd, before Plasma. When `pam_kwallet_init` or D-Bus starts kwalletd6 later, kwalletd6 finds `org.kde.kwalletd6` taken (`KDBusService::Unique`) and exits.
- Without the device's wallet (an older app, or no share server) `tux-secrets` takes no name. Started by D-Bus (`--activated`), it runs `/usr/bin/kwalletd6` in its place when that is installed, else gnome-keyring's secrets part.
- Sessions: `plain`, and `dh-ietf1024-sha256-aes128-cbc-pkcs7` when `python3-cryptography` is installed (in the desktop image). libsecret falls back to `plain` without it.
- Collections: `login` (alias `default`), `session` (alias `session`, in memory only), and those that programs make. KWallet's `kdewallet` is the `default` collection. Lock does nothing: only the device locks.
- It keeps no secret on disk and logs no secret, label or attribute.

The protocol (`host/secrets.c`, under `/.tux/secrets` on its own port, `10.0.2.4:81`; port 80 answers 404 there): `GET /state[?since=N]` (`locked` or `unlocked`, long poll), `GET /items` (one line per item: id and base64 metadata), `GET`, `PUT` (base64 metadata, a newline, the secret) and `DELETE /items/ID`. Ids are `c.NAME` for a collection and `i.COLLECTION.HEX32` for an item.

Security:

- The host chooses the scope: the machine's id. The guest cannot name another machine's items. On iOS each machine has its own Keychain service, `nz.jackgreenhill.tuxedo.linux-wallet.v2.<machine id>`, and each item is an account in it. Deleting a machine deletes its items.
- Only the guest reaches the share server: the network hands 10.0.2.4:80, and the wallet's 10.0.2.4:81, to two Unix sockets in the app's storage (mode 0600). The wallet's socket serves only `/.tux/secrets`, and port 80 does not serve it, so `tux-status` (root) and the clipboard and keyboard helpers keep port 80 as before.
- In the guest, `tux-secrets-firewall.service` (nftables, table `inet tux_secrets`, loaded before logins) lets only root and the user `tux` connect to 10.0.2.4:81. Another user (`nobody`, a service with its own user) gets a TCP reset, and a connection routed for a container or VM in the guest is dropped. The unit then follows `nft monitor` and puts the rule back, in one transaction, whenever the table or a rule in it changes: `nftables.service` (its start, reload and stop flush the whole ruleset), `nft flush ruleset`, or a change to the table. Between such a flush and the rule's return (a few milliseconds) the port is open. Stopping or restarting the unit keeps the rule; removing the package takes it away.
- What it does not stop: root, or any program that runs as `tux`. Those can read the secrets while the machine is unlocked, as with an unlocked KWallet or GNOME keyring. Root can also stop the unit and then delete the table, add an earlier rule of its own, or connect itself. `tux` has `sudo` with no password, so a program that runs as `tux` can become root and do the same.
- Locked: until the person passes the app's Face ID check (the device passcode is the fallback), while the app is in the background, while the machine is stopped, and after the session ends. The app asks for a Linux machine at every start (a restart too) and every return from the background; a Mac has no wallet and does not ask. Until the check passes the guest is hidden on the phone and on an external screen, and also while the app is inactive, so the app switcher's picture does not show it. `TUX_AUTOPILOT` in the launch environment (`devicectl device process launch -e`, not the `tux-autopilot-once.txt` file) skips the check and logs it; the wallet then stays locked, unless `TUX_AUTOPILOT_WALLET=unlocked` is in the launch environment too (and then the secrets read as after a passed check). While locked, labels and attributes show (a Secret Service search lists the items as locked) and secrets do not: `GetSecret` gives `IsLocked`, `GetSecrets` leaves the items out, the host answers 423, KWallet's `open` gives -1, and `Unlock` gives a prompt that completes when the device unlocks (up to 120 s). `openAsync` waits for the same.
- Keychain: service `nz.jackgreenhill.tuxedo.linux-wallet.v2.<machine>`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with no Face ID rule on the items. So an item never leaves the device (no iCloud Keychain, no backup to another device), no other app reads it, and the session's Face ID check is the lock: the app gives no secret while the session is locked. An item rule (`.userPresence`) was tried first: iOS then refused even the listing of the metadata without a new prompt (-25308), so every write failed.
- Limits: ids of 64 characters, 16 KB of metadata, 64 KB of secret, 1024 items for each machine.
- `tuxvm` (no Face ID): `--secrets DIR` keeps each item in `DIR/MACHINE/ID` (mode 0600), `--machine-id ID` (default `tuxvm`) is the scope. It starts unlocked; `HV_SECRETS_LOCKED=1` starts it locked, and the `HV_INPUT_FILE` lines `secrets lock`, `secrets unlock` and `secrets` change and print the state.

An existing KWallet (`~/.local/share/kwalletd/*.kwl`) stays as it is. To copy it into the device's wallet once, run `tux-secrets --import` (`--wallet NAME`, default `kdewallet`) while the machine is unlocked:

- It starts the real kwalletd6 (kwallet6 must be installed) on a private bus of its own, with a `kwalletrc` that has no prompts, so it does not touch the session's names.
- kwalletd6 opens the wallet. In a desktop session kwalletd6 asks for the wallet's password in its own window. Without a display, or with `--password-stdin` (the password on the first line of stdin), the command takes the password and opens the wallet as `pam_kwallet` does (PBKDF2-SHA512 with the wallet's `.salt`; a GPG wallet needs the window).
- It copies every folder and entry (passwords, maps, binary data) through the KWallet API into `tux-secrets`, prints the counts, and writes `~/.local/share/tux/kwallet-imported-NAME`. A second run needs `--force`. The `.kwl` and `.salt` files stay.

To use the old wallet again instead, `systemctl --user disable --now tux-secrets`.

Not tested: a full Plasma session in the guest (the KWallet API was tested with `kwallet-query` from kwallet6 6.13 in a Debian trixie container), and the Keychain on a device.

`secrets-check.py` (`uv run`, `make test-linux-secrets`) boots a clone of the desktop image with `--share`, `--secrets` and `--machine-id` and drives `secrets-probe.py` in the guest: `secret-tool` store, lookup, search and clear, a Diffie-Hellman session, the KWallet API (passwords, maps, lists, remove) and a KWallet entry read through `secret-tool`. Each item must be in the folder under the machine, mode 0600. Locked (`secrets lock`): the item shows as locked, no secret comes, the host answers 423, and an `Unlock` prompt completes after `secrets unlock`. No secret may be in the journal or tuxvm's log. A second boot with another machine id must not see the first machine's items. `--container` (`make test-linux-secrets-container`) runs the probe in a Debian trixie container against `secrets-mock-host.py`, with kwallet6: `kwallet-query`, a second kwalletd6, and the fallback to kwalletd6. `tests/test_secrets.c` (in `make test`) checks the endpoint and the folder store, and `make test-session-gate` the app's Face ID policy and the Keychain names.

## Keyboard follows the focus

The device shows its on-screen keyboard when the focused program in the desktop wants text, and hides it after. Keys still arrive through the virtio keyboard.

Wayland has one event for "this program wants text": a client enables its `text-input` object when a text field gets the focus (`zwp_text_input_v3.enable`, and the same in v1 and v2), and disables it when the focus leaves. No protocol gives that event to an ordinary client. Each compositor gives it to one place:

- wlroots (labwc 0.8.3): the seat's input method, `zwp_input_method_v2` (`activate`, `deactivate`, applied on `done`). Any client can ask for it; there is one for each seat. labwc has text-input-v3 only.
- KWin 6.3: `InputMethod::setActive` (`src/inputmethod.cpp`) follows text-input v1, v2 and v3 and shows as the property `active` (signal `activeChanged`) of `org.kde.kwin.VirtualKeyboard` at `/VirtualKeyboard` on `org.kde.KWin`. It changes with no input method installed, so the helper does not take KWin's input method place (`kwinrc` `InputMethod`), and Maliit or Fcitx 5 can stay. It needs `VirtualKeyboardEnabled` (the default). `KWIN_IM_SHOW_ALWAYS` and the last input device only decide if KWin shows its own panel; they do not change `active`.

`tux-keyboard` (`/usr/lib/tux/`, the user unit `tux-keyboard.service`) uses the first of these that it finds:

- It speaks the Wayland wire protocol itself, as `wlprobe.py` does, and binds `zwp_input_method_manager_v2`. It sends no text and takes no keyboard grab, so typing is not changed. If the seat has an input method already (`unavailable`), it stops and exit status 0 keeps systemd from a restart.
- On KWin, when it is not KWin's input method, it runs `busctl --user monitor` for `activeChanged` and reads `active` with `busctl get-property`. When it is the input method, see "Plasma: windows stay above the keyboard" below.
- It sends `PUT /.tux/keyboard` with the body `show` or `hide` to `host/share.c`. A `hide` waits 0.3 s, because focus that moves between two fields is `deactivate` then `activate`. A send with no answer or a 5xx status is tried again after 2 s. A 4xx status (an app with no such endpoint) is not tried again until the state changes, and is logged once. It sends `hide` when it stops.
- labwc's `autostart` starts the unit; in Plasma `/etc/xdg/autostart/tux-keyboard.desktop` (KDE only) does.

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

### Plasma: windows stay above the keyboard

In Plasma, KWin makes the active window shorter (or moves it up) while the device's keyboard is up, so its text fields stay in view. The window gets its size back when the keyboard goes down. labwc has nothing like this, and is not changed.

KWin does this only for the panel of its own input method (`InputMethod::updateInputPanelState` gives the panel's frame to `Window::setVirtualKeyboardGeometry`; not for fullscreen or desktop windows). So `tux-keyboard` is KWin's input method here:

- `/etc/xdg/kwinrc` in the image sets `[Wayland] InputMethod` to `/usr/share/applications/tux-keyboard.desktop` (in the package). KWin starts the program with `WAYLAND_SOCKET` and gives it `zwp_input_method_v1` and `zwp_input_panel_v1`.
- `activate` and `deactivate` of `zwp_input_method_v1` are the `show` and `hide` for the host; the `busctl` path is not used. The helper that the desktop's autostart runs sees the input method's lock (`$XDG_RUNTIME_DIR/tux-keyboard.im`) and waits, so one program sends. When the input method stops (the person chose a different one), the lock goes and that helper takes over on the `busctl` path.
- The panel is one clear pixel, stretched (`wp_viewporter`) to the output's width, as a `set_toplevel` input panel surface. KWin takes the surface's input region as the keyboard's place (as for Maliit), so the region is the keyboard's height, and empty when the keyboard is down. It sends no text and takes no keys.
- The height comes from the app. `KeyboardPanelProbe` lies over the picture in `SessionView`, hears the keyboard notifications and gives `tux_share_set_keyboard_height` the part of the picture under the keyboard (`KeyboardPanel.fraction`, 0 to 1; 0 on the console, on an external screen and while zoomed). The helper reads `GET /.tux/keyboard` ("height F"; `?since=N` waits up to 25 s for a change) and multiplies by the output's logical height (xdg-output).

What KWin needs to show the panel (KWin 6.3.6 source, and the check below):

- `InputPanelV1Window::maybeShow` wants three things: the surface has a buffer and `set_toplevel`; `allow()`; and `show()`.
- `allow()` comes only when `InputMethod::shouldShowOnActive()` is true: the last input was a touch or a tablet tool, or `KWIN_IM_SHOW_ALWAYS=1` is in KWin's environment. The trackpad and a hardware mouse are not a touch, so the package has `/etc/xdg/plasma-workspace/env/tux-keyboard.sh`, which `startplasma` sources. Without the variable the window keeps its size (checked).
- `show()` comes from a text-input-v3 `enable`, from `show_input_panel` of v1 and v2, and from the D-Bus method `forceActivate`. So when the height goes above 0 and KWin does not show the panel (the property `visible`), the helper calls `forceActivate`. That is also how a keyboard that the person opens by hand, with no text field, moves the window. The context that `forceActivate` makes is not a request to the host; KWin sends `surrounding_text` only for a real text field, which is how the helper tells them apart. When the height goes back to 0 the helper ends its own context (`active` = false), so the next text field is news.
- KWin hides the panel on `hide_input_panel` (v1, v2) and on the screen lock. While the height is above 0 the helper looks at `visible` every 5 s and calls `forceActivate` again.

The KWin script (`/usr/lib/tux/kwin-keyboard.js`; the helper loads it through `org.kde.kwin.Scripting` when it starts as the input method):

- The room of Plasma's panel. KWin puts the input panel's bottom edge at the bottom of the area for maximized windows (`InputPanelV1Window::resetPosition`), which is above a Plasma panel at the bottom edge. A panel as high as the keyboard then put its top edge, and the window's end, that much above the keyboard. The script reads `workspace.clientArea(KWin.MaximizeArea, ...)` and gives the room at the top and the bottom; the panel's height is the keyboard's less the bottom room, never below 0. The script looks again on window changes and once a second.
- A script cannot answer the helper. It calls a method that nothing has (`nz.jackgreenhill.tuxedo.Keyboard.area` on `org.freedesktop.DBus`; Qt keeps a call to KWin's own name inside KWin), and the helper hears the call with `busctl monitor`. Any program on the session bus can send such a call, so the helper keeps the numbers inside the screen's height, and the script sends the true ones again every 10 s.
- X11 windows. KWin finds the window to move by its Wayland surface (`InputMethod::setTrackedWindow`, `WaylandServer::findWindow`), so a window of an XWayland program (many Electron programs) is never moved. The script does for the active X11 window what `Window::setVirtualKeyboardGeometry` does: it ends the window at the panel's top edge, and gives the place back when the keyboard goes down or another window gets the focus. It acts only when the keyboard or the active window changes, as KWin does. A window that the person moves, or takes out of the maximized state, while the keyboard is up is theirs: the script forgets it and does not put it back. Not for fullscreen windows, and not for windows that cannot change size.
- The least height. When the keyboard is very high (a phone on its side), the panel stops where the area for windows would go below 180 units (`MIN_ROOM` in the helper). The window then keeps 180, with its end under the keyboard. KWin has no setting for this, and none to leave a kind of window alone: it moves each window that has the focus except fullscreen and desktop windows, so a Plasma popup that takes the focus (the application launcher) is made shorter too.

Costs and limits:

- This takes KWin's input method place. Maliit (the Plasma on-screen keyboard) and Fcitx 5 or IBus through KWin cannot run at the same time. A person who needs one of them chooses it in System Settings, Virtual Keyboard (that writes `~/.config/kwinrc`, which wins); the helper then goes back to the `busctl` path: the keyboard still follows the focus, and windows are not moved.
- The room of a panel is known up to a second late. A keyboard that comes up in that second moves the window twice.
- When the helper starts again while the keyboard is up, an X11 window that the script moved keeps its small size. Maximize it again.
- The height is right when the picture's bottom edge is under the keyboard. A zoomed picture and a floating iPad keyboard give 0.
- Not tested: a full Plasma session in the guest (the env script through `startplasma`, the Plasma panel), and the app on a device.

To turn it on in a machine that has Plasma already (after tux-guest 1.5.0 or later is installed), then reboot:

```sh
kwriteconfig6 --file kwinrc --group Wayland --key InputMethod /usr/share/applications/tux-keyboard.desktop
```

To turn it off: `kwriteconfig6 --file kwinrc --group Wayland --key InputMethod ""`.

`keyboard-panel-check.sh` (`make test-linux-keyboard-panel`, needs Docker) runs `kwin_wayland --virtual` 6.3.6 at 1280x800 in a Debian trixie container with the package's files and the image's `kwinrc` in place, a stand-in for the host (`kwin-panel/host.py`) and a maximized test window (`kwin-panel/window.py`, which writes each size KWin gives it). It checks: KWin starts the helper from `kwinrc`; a text field gives `show`; a height of 0.4 makes the window 1280x480, 0.25 makes it 1280x600, and 0 gives 1280x800 back; the same with no text field, with no request to the host, and a text field after that gives `show`; a window that opens with the keyboard up; with a stand-in for Plasma's panel (`kwin-panel/dock.py`, a layer-shell surface that keeps 44 px) at the bottom, 0.4 still gives 1280x480, and at the top 1280x436; 0.9 leaves 180; a maximized X11 window (xterm) goes to 480 and 600 high, gets 800 back while another window has the focus and when the keyboard goes down; a false area on the bus heals; an X11 window that is taken out of the maximized state while the keyboard is up keeps its place, also when the keyboard goes down; a second helper waits, and sends `show` and `hide` after the input method stops; and KWin without `KWIN_IM_SHOW_ALWAYS` leaves the window at 1280x800.

## Video decode (VA-API)

A Linux machine with graphics acceleration can decode video on the host's hardware decoder (VideoToolbox) through VA-API. It is off by default. Turn it on with the machine's "Video decode" switch in the iOS app (under "Graphics acceleration"), or with `tuxvm --gpu-accel --gpu-video` on the Mac. The host's decoder then parses video data that the guest controls. Details and measurements: `docs/guest-video-decode-research.md`.

The images have `tux-ffmpeg`, so a plain `ffmpeg` is the Tuxedo build, which has no VA-API (it decodes with `-hwaccel tux`). For VA-API, use Debian's `/usr/bin/ffmpeg`, or a player such as mpv, which uses Debian's libraries.

In the guest:

```sh
sudo apt-get install -y mesa-va-drivers vainfo mpv ffmpeg
vainfo --display drm --device /dev/dri/renderD128
```

`vainfo` names `Mesa Gallium driver ... for virgl` and lists the profiles with `VAEntrypointVLD` that the host has in hardware: `VAProfileH264Main` and `VAProfileH264High`, `VAProfileVP9Profile0` and `VAProfileVP9Profile2` (10 bits), and `VAProfileAV1Profile0` (8 and 10 bits). Without the switch it lists none.

- mpv: `mpv --hwdec=vaapi --vo=gpu FILE`. The decoded frames stay on the host GPU. `hwdec-current` in mpv's statistics (`i`) says `vaapi`.
- FFmpeg: `/usr/bin/ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi -i FILE ...` keeps the frames on the GPU; without `-hwaccel_output_format vaapi` each frame comes back to guest RAM.
- Firefox: it uses VA-API with no setting, for H.264 (Debian's `libavcodec`), VP9 and AV1 (its own `ffvpx`), and shows the frames as DMABuf surfaces with no copy. It needs `tux-va` (below). `about:support` shows the hardware decoders under "Media".
- GStreamer: the `va` plugin in `gstreamer1.0-plugins-bad` (`vah264dec`, `vavp9dec`, `vaav1dec`; not tested on Tuxedo).
- Not in hardware: HEVC (VA-API does not carry the reference picture sets that VideoToolbox needs), MPEG-2, VC-1, JPEG, VP9 profiles 1 and 3, AV1 profiles 1 and 2, and AV1 with film grain. Players fall back to software decode for those, except AV1 with film grain: its frames fail, so turn hardware decode off in the player (`--hwdec=no`).
- A stream that fails on the host gives no error in the guest: the frame keeps its old pixels until the next key frame. `tuxvm`'s log (`HV_VIRGL_VERBOSE=1`) has a line for each failure and, when the player closes, a total for each codec.
- The phone pauses an accelerated machine in the background, and the decoder with it.

### tux-va

Mesa's VA-API driver for virgl offers NV12, YV12 and I420 surfaces for each 8-bit decode config. FFmpeg's VA-API decoder (`vaapi_decode_find_best_format`) takes the last format that is equal to the stream's `yuv420p`, which is I420. Firefox takes NV12, YV12, P010 and P016 surfaces only (`VideoFramePool::GetVideoFrameSurface`). So Firefox started VA-API, decoded one frame, logged `Unsupported VA-API surface format 808596553` (I420), and went to software decode. The host cannot change that list: Mesa's virgl driver asks only if R8 and R8G8 textures exist, and does not read the host's preferred format.

`tux-va` (`tux-va/tux_va.c`; a 10 KB package) installs `/usr/lib/aarch64-linux-gnu/dri/virtio_gpu_drv_video.so`, the file that libva loads for virtio-gpu. It loads Mesa's driver and removes YV12 and I420 from the surface formats of a decode config that has NV12. That is the list radeonsi and the Intel drivers give. FFmpeg, mpv and Firefox then all use NV12, the format VideoToolbox decodes to. Video processing configs and 10-bit formats are not changed.

- The package diverts Mesa's link to `mesa_virtio_gpu_drv_video.so` with `dpkg-divert`, so an update of `mesa-va-drivers` goes to that name, and `apt remove tux-va` puts Mesa's link back. It does not depend on `mesa-va-drivers`: without it, the driver finds nothing to load and libva reports no driver, as before.
- `LIBVA_DRIVER_NAME=mesa_virtio_gpu` uses Mesa's driver with no filter, for a test.
- With `/usr/bin/ffmpeg -hwaccel vaapi` and no `-hwaccel_output_format`, the frames now come back as `nv12`, not `yuv420p`. The pixels are the same. Add `-vf format=yuv420p` or `-pix_fmt yuv420p` where the output must be planar.
- An existing machine gets it with `tux-guest` 1.11.0 (it is in `Recommends`), from the Tuxedo repository or the Tuxedo Additions media, or with `sudo apt install tux-va`.

`build-va-pkg.sh` (`make linux-va-pkg`, needs Docker) builds the driver with `-Werror`, runs it against a stand-in for Mesa's driver (`tux-va/test`: a decode config, a decode config with no NV12, a video processing config), then installs the package over `mesa-va-drivers` in the container, reinstalls `mesa-va-drivers`, and removes the package; Mesa's link must move, stay moved, and come back.

## ffmpeg with the device's codecs (tux-ffmpeg)

`tux-ffmpeg` gives the guest an `ffmpeg` that decodes and encodes on the device's hardware, with the frames on the device (`docs/guest-video-encode-plan.md`). The host must offer the codec service: `tuxvm --vcodec` or `--vcodec-dma` on the Mac, or the machine's "Video encode" setting in the iOS app (the TCP service and the device). `man ffmpeg-tux` gives the commands, the encoders and their options, and the limits.

What the package does:

- The binaries go in `/usr/lib/tux/ffmpeg/bin/`. `postinst` makes the links `/usr/local/bin/ffmpeg` and `/usr/local/bin/ffprobe`, so `ffmpeg` on the default `PATH` is the Tuxedo build. It does not replace a file there that it did not make; it says so, and that command stays the admin's.
- Debian's `ffmpeg` stays at `/usr/bin/ffmpeg`, and `man ffmpeg` stays Debian's page. The two packages do not depend on each other.
- `apt remove tux-ffmpeg` runs `prerm`, which removes the links only if they still point into `/usr/lib/tux`. Then `ffmpeg` is Debian's again (run `hash -r` in a shell that used it). An upgrade keeps the links.
- `tux-codec-info` is in `/usr/bin`. The man page is `ffmpeg-tux(7)`. The package recommends `man-db`. Both images have the package and `man-db`, so on a new machine `ffmpeg` is the Tuxedo build and `man ffmpeg-tux` opens.
- `Depends` comes from `dpkg-shlibdeps`: `libx264`, `libx265`, `libdav1d`, `libopus`, `libmp3lame` and GnuTLS are Debian's shared libraries.

Build it:

```sh
make linux-ffmpeg          # build-ffmpeg.sh, about 2 to 3 min
make linux-ffmpeg-pkg      # build-ffmpeg-pkg.sh, about 1 min
make linux-apt             # publish-apt.sh: build/linux/apt and build/linux/source, signed, local only
make test-linux-ffmpeg-pkg # both packages from build/linux/apt in a clone of the desktop image
```

`build-ffmpeg-pkg.sh` refuses a build that is not from the current patch, `libhvcodec` and `versions.env`. It renders the man page with `pandoc`, and `hvcodec/manpage-check.py` must find each `*_tux` encoder, each of its options and named values, and each `scale_tux` option in it. Add an option to the patch, and the package does not build until the page has it. Two builds from the same inputs give the same `.deb`, byte for byte.

### The repository

`publish-apt.sh` adds the current `tux-ffmpeg` and a fresh `tux-guest` to `build/linux/apt/pool`, writes `Packages` for `arm64` and `all` with `apt-ftparchive` in a container, and signs `Release` on the Mac (`InRelease` and `Release.gpg`). It also writes `build/linux/source/ffmpeg-<release>-tux<N>/`: the FFmpeg tarball, the patch, `build-ffmpeg.sh`, `ffmpeg.manifest`, `tux-ffmpeg-src.tar.xz` (the Tuxedo files of the build at their places in this repository), `README.txt` and `SHA256SUMS`. The package's `copyright` file gives that directory's URL. This is the source offer that the GPL needs (see `docs/licensing.md`).

Published files never change. The script stops if a package in the pool has the same name and other content: raise `Version` in `tux-guest/DEBIAN/control`, or `FFMPEG_TUX_REV` in `versions.env`. It also stops if the source directory of the current `tux-ffmpeg` has another `ffmpeg.manifest` (the hashes of the binaries and of their inputs): raise `FFMPEG_TUX_REV`. A change to other files of the offer only, for example `LICENSE`, `snapshot-apt.sh` or the U-Boot line of `versions.env`, does not stop it. The published directory stays as it is, because it is still the source of those binaries, and the script names the files that changed. A changed man page or package script changes the `.deb`, so the pool check stops that. It also stops if a `tux-ffmpeg` in the pool has no source directory with its own manifest. Old versions stay in the pool, and their source directories stay with them.

The key: an ed25519 key with no passphrase and no expiry, `Tuxedo apt repository <tux@localhost>`, fingerprint `60E3070A44CF4B9F1F4B27E8FA32ECDBA657D9FF`. The private part is only in `~/.tux-apt-key` on the Mac (`TUX_APT_GNUPGHOME` changes the place). Keep a copy of that directory somewhere safe: without it, no new version can be signed, and each guest needs a new `tux-guest` with a new key. Its revocation certificate is in `openpgp-revocs.d/` there. `gpg --homedir ~/.tux-apt-key --passwd` adds a passphrase; then the script asks for it. `publish-apt.sh --new-key` makes a key only when there is none, and writes the public part to `tools/linux/tux-archive.asc` and `tux-guest/usr/share/keyrings/tux-archive.gpg`. The script stops if those two are not the key in the keyring.

Publication is a separate step, and only the owner runs it:

```sh
tools/linux/publish-apt.sh --rsync
```

It copies `apt/` and `source/` to `root@walkies.site:/home/USER/tux-linux-catalogue/files` with `rsync` over `ssh` (`TUX_APT_REMOTE`): the pool and the source first, the `dists/` index last, so `InRelease` never names a file that is not there yet. It deletes nothing on the server. Then it downloads `InRelease` from `https://walkies.site/tux-linux-catalogue` (`TUX_APT_URL`), checks the signature with the guest's key, and compares `Packages`, the SHA-256 of each `.deb` and each `SHA256SUMS` with the local files. `--check-remote` does only that check.

### Turning the repository on in a guest

`tux-guest` 1.9.1 writes `/etc/apt/sources.list.d/tux.sources` with `Enabled: no`, so `apt update` does not try the server before the repository is there. After the publication, in each guest:

```sh
sudo sed -i 's/^Enabled: no/Enabled: yes/' /etc/apt/sources.list.d/tux.sources
sudo apt update
sudo apt install tux-ffmpeg
```

The file is not a conffile. `postinst` copies it from `/usr/share/tux/tux.sources` at the first install, and at an upgrade from a version before 1.9.0, if the file is not there. After that it is your file: no upgrade changes it or asks about it, and it does not come back if you delete it. `apt purge tux-guest` deletes it. To go back to the default, run `sudo cp /usr/share/tux/tux.sources /etc/apt/sources.list.d/`. On a guest that had 1.9.0, which shipped the file as a conffile, the file stays and `dpkg` marks it obsolete. A guest with an older `tux-guest` has no key and no source yet. A new machine from an image with `tux-guest` 1.9.0 or later has them. On an existing machine, put `build/linux/apt/pool/main/t/tux-guest/tux-guest_1.9.1_all.deb` in the shared folder and run `sudo apt install ~/Tux/tux-guest_1.9.1_all.deb`.

### The package check

`vcodec-check.py --apt build/linux/apt` (`make test-linux-ffmpeg-pkg`) boots a clone of the desktop image with `tuxvm --vcodec` and serves the repository through `--share` at `http://10.0.2.4/apt`. It checks, in order: `apt update` with the local repository and its signature; `tux-guest` from it, with its key and `tux.sources` (`Enabled: no`); `apt update` with that file gives no new warning or error and does not contact walkies.site; the same file with `Enabled: yes` and the local URI works with the shipped key; `tux.sources` is not a conffile, and after the README's edit an upgrade to a test build with another default does not ask and keeps the edit; then `tux-ffmpeg`: `ffmpeg` and `ffprobe` resolve to the links, `ffmpeg -version` is the Tuxedo build, `/usr/bin/ffmpeg` is Debian's and unchanged, `tux-codec-info --json`, `man ffmpeg-tux` opens and `manpage-check.py` passes on the installed page, `man ffmpeg` is still Debian's page, the main command with `ffmpeg` on each clip (frames, PSNR and audio sync, as with `--ffmpeg`), a reinstall keeps the links, `apt remove` gives Debian's `ffmpeg` back, and an admin's own `/usr/local/bin/ffprobe` stays through an install and a remove. Give `--linux-dir` and `--image` for an image that is not in `build/linux`, in `VCODEC_ARGS`.

## The DMA channel (tux-codec-dkms)

`tux-codec-dkms` gives the guest `/dev/hvcodec`, a channel to the codec service through Tuxedo's hvcodec device (`docs/guest-video-encode-plan.md`, stage VE4). Raw frames for `hwupload`, `hwdownload` and the encoders' own uploads then cross from the caller's pages with no copy in the guest. Compressed data is small on either channel, so the main transcode does not need it; a chain with a software filter does. The machine must run with the device on: `tuxvm --vcodec-dma` (it implies `--vcodec`). Without that flag the device does not exist. The iOS app does not offer it yet.

What the package does:

- The module source goes in `/usr/src/tux-codec-<version>/` with `dkms.conf`. `postinst` has DKMS build and install it for each kernel that has headers, then loads it, so `/dev/hvcodec` is there at once. DKMS builds it again for each new kernel whose headers are installed (its own kernel hooks).
- `Depends: dkms, gcc, make, linux-headers-arm64-16k`. So the compiler and the headers come only with this package (decision 11), and the headers metapackage follows each kernel update. The metapackage gives the newest headers in the sources. If the running kernel is older, also install its headers: `sudo apt install linux-headers-$(uname -r) tux-codec-dkms`.
- A udev rule (`/usr/lib/udev/rules.d/60-tux-codec.rules`) gives `/dev/hvcodec` to the group `video`, mode 0660. The desktop image's user `tux` is in `video`; `customize.sh` now adds it to the console image's user too.
- `apt remove tux-codec-dkms` unloads the module and removes it from DKMS. `libhvcodec` then uses TCP, and `ffmpeg` writes a warning at the first raw frame.
- The module has no signature. The kernel accepts it (`CONFIG_MODULE_SIG_FORCE` is off) and records a taint. If `openssl` is there, DKMS signs it with its own key, which the kernel does not know: the same result.

`libhvcodec` takes `/dev/hvcodec` when it opens, and TCP when it does not. `TUX_VCODEC=10.0.2.4:8470` keeps TCP; `ffmpeg -v verbose` names the channel.

Build and check it:

```sh
make linux-codec-dkms      # build-codec-dkms-pkg.sh: -Werror against the pinned 16 KB kernel's headers, then DKMS in the container
make test-linux-codec-dma  # codec-dma-check.py: a clone booted through U-Boot with --vcodec-dma
```

`codec-dma-check.py` installs the package with `apt`, checks `/dev/hvcodec`, measures 4K NV12 and P010 transfers on it and on TCP with `hvcodec/hvxfer.c`, runs the main command and a `hwdownload`, software filter, `hwupload` chain on both channels (each output checked on the Mac), unloads the module for the fallback, opens a ninth context, kills a process during transfers, and with `--kernel-update` installs the newest 16 KB kernel, powers off, boots again and uses the device on the new kernel. The image's sources are the pinned snapshot, which has no newer kernel, so the check then adds the same snapshot's `trixie-security`.

## Tuxedo Additions

Tuxedo Additions is the app's "Insert Tuxedo Additions CD". The design is `docs/guest-additions-design.md`. It is the contract, and it wins over `docs/guest-additions-plan.md` where the two differ. Nothing here has run on an iPhone (`docs/iphone-checklist.md`, part 5b).

What the media is:

- A folder, not a disc. The app carries it as `Tuxedo.app/TuxAdditions/` and gives it to the guest as one more folder of the `tux-files` device, read only, named `tux-additions`. The guest sees it at `/media/tux/tux-additions`.
- It has the four Tuxedo packages (`tux-guest`, `tux-va`, `tux-ffmpeg`, `tux-codec-dkms`), the Debian packages that a minimal trixie guest lacks (and `openssh-server`), an installer (`install`), an agent (`agent`) and a catalogue of what the agent may do (`actions.json`). The guest installs from it with no network.
- `tux-guest` 1.11.0 or later in the guest starts the agent by itself when the app inserts the media. It first checks `SHA256SUMS.gpg` with the key that `tux-guest` installed (`/usr/share/keyrings/tux-archive.gpg`). A guest with no `tux-guest` cannot do this: the app shows a command to type.

Build it (`make linux-additions` needs Docker, `gpg`, and the signing key in `~/.tux-apt-key` or `TUX_APT_GNUPGHOME`):

```sh
make linux-ffmpeg-pkg linux-va-pkg linux-codec-dkms      # the three debs it takes from build/linux
make linux-additions                                      # build/linux/additions/tux-additions/, about 39 MB
```

`package-additions.sh` builds `tux-guest` itself (`build-guest-pkg.sh`). It stops if a deb is missing or if the key in `tux-guest` is not the key in the keyring. It downloads the Debian packages from the snapshot in `versions.env` into `build/linux/additions/cache`, so a second build needs no network for them. The media is the same on every build, apart from the signatures, because `SOURCE_DATE_EPOCH` is the time of the last commit. After the build, a container with no network installs from the media into a minimal root and checks the result. Nothing leaves the Mac. The app build copies the folder (`ios/project.yml`, Copy Tuxedo Additions). With no media it only warns.

`tux-additions-report` in `tux-guest` is a byte copy of `additions/tux_additions_caps.py`. A builder test checks it. After you change the script, copy it again to `tux-guest/usr/lib/tux/tux-additions-report` and build the media again.

The files in the media:

| File | What it is |
| --- | --- |
| `install` | The bootstrap (POSIX `sh`). It runs `sudo` on itself when it is not root. It installs `tux-guest`, `tux-va` and `tux-ffmpeg`. Exit codes: 0 done, 1 failed, 2 wrong system, 3 old `henge-*` packages, 4 the media check failed. |
| `agent` | The agent (Python 3, standard library only). It runs as root and runs only what `actions.json` names. |
| `tux_additions_caps.py` | What the agent tells the app about the guest (the `caps` of a report). |
| `actions.json` | The catalogue: protocol, desktops, applications and their groups, packages and sizes, and the limits for SSH. The app reads its bundled copy for labels and sizes. |
| `versions.json` | The versions in this build, the Debian snapshot and the install order of the Debian packages. |
| `install-order.txt` | The order for `dpkg`, for when `apt` does not work. |
| `desktop-labwc/` | The session files of the Tuxedo desktop, copied from `rootfs-desktop`, and `files.json` as their map. |
| `desktop-plasma/` | The Plasma settings files, copied from `rootfs-desktop`, and `files.json` as their map. |
| `apt/` | A signed apt repository: `main` (the four Tuxedo packages) and `deps` (the Debian packages). `Release` has no `Valid-Until`. |
| `SHA256SUMS`, `SHA256SUMS.gpg`, `tux-archive.gpg` | The sums of every other file, the signature, and the public key (the same bytes as in `tux-guest`). |
| `README.txt`, `source/SOURCES.txt` | The commands, the licences and the source offer (see `docs/licensing.md`). |

The media holds no private key, no password and no path of the Mac that built it. The builder test checks this.

### Tests and make targets

| Target | What it checks | Needs |
| --- | --- | --- |
| `make test-additions-engine` | The engine: the reserved folder entry, the JSON check, the event ring, the job wipe, the link (`GET` and `POST /.tux/additions`, with the 400 and 413 answers) and the virtio-fs device with no folders. | Nothing beyond `make` |
| `make test-additions-builder` | The built media: the tree, the sums, the signatures against the key in `tux-guest`, the catalogue against the packages, the size limit, the secrets check, and that `tux-guest` has the same report script. `ADDITIONS_ARGS="--tree DIR --offline --rebuild --other DIR"` chooses the tree, skips the check against the Debian index (it needs `snapshot.debian.org`), builds a second time and compares, or compares with another tree. | The media (`make linux-additions`) |
| `make test-additions-agent` | The agent against a fake root and a fake host, with every program replaced by a recorder: validation, order, failure and skip, cancel, and no password in a log. | Nothing, no Docker or network |
| `make test-tux-files-additions` | The part of `tux-files` that starts the agent by media number. | Nothing |
| `make test-tux-guest-scripts` | The launcher (a bad signature gives exit 4 and a `bad-media` event), the console login for each marker, the report script, and `tux-status`. The launcher tests skip with a message when `gpg` or `gpgv` is missing. | `gpg` and `gpgv` for the launcher |
| `make test-additions-policy` | The app's logic: version order, input checks, events, job JSON and the wizard's rules (`ios/Tuxedo/Additions*.swift`). | Xcode |
| `uv run tools/linux/additions-check.py` | The whole flow in a guest (below). | A built `tuxvm`, a console image, the media |

### additions-check.py

It boots a clone of the console image and runs the flow from the design (section 10): the bootstrap on a guest with `tux-guest` removed and no network; autorun after an `additions` insert; the agent's report; a job with `user.setup`, `ssh.configure` and `additions.install`; `apt-get -s` for one desktop and one application; one small real `apps.install` when the guest has network; eject; bad media (one byte changed) gives `bad-media`; and writes to the media fail. A fresh guest must give a root shell on the serial console with no login. After `user.setup` the marker must exist, root must be locked and the console must follow `autologin`.

Run it from the root of a checkout, after `make` and `make linux-additions`:

```sh
make && make linux-additions
uv run tools/linux/additions-check.py
```

`additions-check.py --help` lists its options. It was not in the tree when this section was written (15/11/2026), so nothing here says it passed. A clone of a 1.10.2 console image from `build/linux` is the right start for the bootstrap case, because that guest has no `tux-additions-launch`.

### How the app inserts it

- `hv_additions_insert(dir)` (`host/additions.h`) puts the folder in the reserved slot of the `tux-files` table (`HV_FS_ADDITIONS`, after the 8 user folders) and adds one to its number `n`. The slot is never saved, and it does not count as one of the user's folders.
- Every Linux machine of the app has the virtio-fs device (`fs_always`), so insert and eject need no restart. `tuxvm` has the device only with `--folder`, `--fs-device` or `--additions`.
- `tux-files` in the guest sees the new `n`, mounts the folder read only, and starts `tux-additions-agent@<n>`. The launcher checks the signature, copies the tree to `/var/lib/tux/additions/`, and runs the agent. The agent posts a report to `http://10.0.2.4/.tux/additions` and then waits for the job that the wizard sets (`hv_additions_job_set`). The password is only in that job, in memory, on both sides.
- Eject (`hv_additions_eject`) removes the folder. The agent stops when no job runs.

### The root console and the account marker

- With `tux-guest` 1.11.0, the serial console (`ttyAMA0`, the console that the app shows) and `tty1` of a guest with no desktop run `/usr/lib/tux/tux-console-login` (vendor drop-ins for `serial-getty@ttyAMA0` and `getty@tty1`). With no `/var/lib/tux/account.json`, it signs in as root with no password. The app takes this as the sign that the machine is new, and opens the wizard at the Account step.
- A guest with a desktop keeps its own `tty1` sign-in for the desktop user.
- The Account step (`user.setup`) writes the marker (`{"configured":true,"name":...,"autologin":...,"sudo":...}`, no password). From then on the wrapper reads the marker at each start: `autologin` true signs in as the account, and false shows a login prompt. The root sign-in ends in both cases. By default the step also locks root (`passwd -l root`).
- An image built before 1.11.0 signs in as `tux` through an auto-login setting in its own `/etc`, and `tux` has an empty password. Installing 1.11.0 on such a machine gives it no marker, so its console becomes a root auto-login until the Account step runs. The 1.11.0 `postinst` writes a marker, with a login prompt as the console, only when the uid-1000 user already has a password.
- To see the state in a guest: `cat /var/lib/tux/account.json`, `cat /var/lib/tux/additions.json` (the last report) and `systemctl status 'tux-additions-agent@*'`.

### Build a media by hand and look at it

```sh
M=build/linux/additions/tux-additions
cat $M/versions.json                                  # versions, snapshot, install order
cat $M/README.txt $M/source/SOURCES.txt               # licences and source offer
(cd $M && shasum -a 256 -c --quiet SHA256SUMS) && gpgv --keyring $M/tux-archive.gpg $M/SHA256SUMS.gpg $M/SHA256SUMS
less $M/apt/dists/trixie/main/binary-arm64/Packages   # the four Tuxedo packages
python3 -m json.tool $M/actions.json | less           # what the agent may install
```

To run the media on the Mac tool, give it a clone of the console image and the share server (the link needs it):

```sh
cp -c build/linux/debian-console.img /tmp/tux-add.img
mkdir -p /tmp/tux-share
build/tuxvm --firmware build/linux/u-boot.bin --disk /tmp/tux-add.img --ram 2048 --cpus 2 \
  --share /tmp/tux-share --additions $M
```

`--additions DIR` inserts the media at boot. Lines in `HV_INPUT_FILE` drive it later: `additions DIR`, `additions -` (eject), `additions-nudge`, `additions-job FILE` and `additions-cancel`. Each event from the guest prints on stderr as `additions-event: <json>`. A job file is the JSON of section 5.5 of the design. `tuxvm` has no wizard, so this is the way to run a job by hand.

## Checks on the Mac

- `dtb-compare.py` (T2, `make test-linux-dtb`) compares Tuxedo's device tree with QEMU's.
- `smoke.py --direct` (E8, `make test-linux-direct`) boots `Image` and `initrd.img` on `build/tuxvm` to the `(initramfs)` prompt, runs `cat /proc/cpuinfo` and `uname -m`, restarts with `reboot -f` to the prompt again, and powers off. `--no-reboot` checks that `reboot -f` ends `tuxvm` with status 3, and `--fatal` that a SIGILL still prints the crash report; the make target runs all three. It reads the artefacts from `TUX_LINUX_OUT`, or from `build/linux` in the main checkout. `--cpus`, `--ram`, `--phone` and `--runs` pass through; `--qemu` runs the same checks on QEMU, and `--qemu --tux-dtb` boots QEMU with Tuxedo's tree. Extra options for the make target go in `SMOKE_ARGS`.
- `smoke.py --direct --disk` (E9, `make test-linux-disk`) boots the same kernel with `root=PARTUUID=` from `debian-console.partuuid` and an APFS clone (`/bin/cp -c`) of `debian-console.img` as `--disk`, so the shared image never changes. The clone goes in a temporary directory, or in `--work-dir`, which must be on the image's volume. After autologin it checks `systemctl is-system-running`, the root on `vda1`, the page size, `nproc`, `uname -m`, the RTC's year, the virtio entropy device (`rng_current` and bytes from `/dev/hwrng`), `10.0.2.15`, `sudo ping 10.0.2.2`, `getent hosts deb.debian.org` and `dmesg --level=err` against an allow list. It then writes 256 MB, syncs, powers off (status 0), boots the clone again and compares the checksum. `--qemu` runs the same checks on QEMU with a virtio disk, network and entropy device.
- `smoke.py --uboot` (E10, `make test-linux-uboot`) runs the same checks on the same kind of clone, but `tuxvm --firmware u-boot.bin` boots it through U-Boot and `extlinux.conf`. The first boot is unattended. It checks that U-Boot uses its default environment and times each step: the banner, the devices, the countdown (only with the stock build), the extlinux step, and the kernel to login. The second boot uses the stock build and stops the countdown. At the `=>` prompt it checks `pci` (bridge, virtio block, network and entropy, xHCI), `virtio info` (the disk size) and `bootflow scan -l` (extlinux on `virtio 1`, DHCP to `10.0.2.15`, every bootflow valid). It then runs `boot` and compares the checksum. `/proc/cmdline` must hold the disk's `root=PARTUUID=`. `--qemu` runs it on QEMU with TCG, with limits four times longer.
- `smoke.py --uboot --stress --cpus 4` (E11, `make test-linux-smp`) boots one clone through U-Boot and checks the several-CPU path. `nproc` must match `--cpus`, and `dmesg` must say `smp: Brought up 1 node, 4 CPUs` with no CPU that failed to come online. It then runs `stress-ng --cpu 4 --vm 2 --vm-bytes 256M --timeout 60s --metrics-brief` and `make -j4` of the project that `cproject.sh` writes (48 C files). The program must print the checksum that the same project gives on the Mac. No kernel warning (`WARNING:`, `BUG:`, an oops, a stall, a lockup, a segfault) and no `dmesg` line at warning level or above may appear. The console image has no `stress-ng` or `gcc`, so the check installs `stress-ng` and `build-essential` in the clone with `apt-get` (about 105 s at 4 CPUs, through slirp to snapshot.debian.org). `--image FILE` clones a disk that has them already, which saves the install and the network. It also works with `--direct --disk`. Set `HV_BIG_LOCK=1` to run one CPU at a time, which separates a race in the engine from a logic fault.
- `smoke.py --uboot --power` (E12, T3, `make test-linux-smoke`) runs the `--uboot` checks and then four boots of a fresh clone. Each writes 64 MB without `sync` and ends the machine another way. Before a key case the test waits until logind watches `gpio-keys`; an earlier key is lost. The next boot must find the file whole and no journal recovery in `dmesg`. The four ways: `sudo reboot` (tuxvm builds the machine again, U-Boot and Debian come back in the same process), the power key as `SIGTERM` (Debian shuts down by itself, exit status 0), the power key as `Ctrl-A p`, and two `SIGTERM`s (the second stops the machine at once, status 0, "stopped: interrupted"). `--power` also works with `--direct --disk`. With `--qemu` there is no power key (on the `-bios` path QEMU builds an ACPI GED, not gpio-keys, so `system_powerdown` does not reach this guest) and no `Ctrl-A p` or second-`SIGTERM` case; `sudo poweroff` takes the key's place. `--cpus`, `--ram`, `--phone` and `--runs` pass through; set them in `SMOKE_ARGS`, for example `make test-linux-smoke SMOKE_ARGS="--runs 5 --cpus 4"`.
- `input-check.py` (D5, `make test-linux-input`) boots a clone of `debian-desktop.img` and drives `tuxvm` through `HV_INPUT_FILE`. It checks that U-Boot's xHCI keyboard stops the countdown and types, that dmesg shows a clean xHCI probe, the USB keyboard, the Magic Trackpad 2 and `magicmouse` bound to it, and that `libinput debug-events` in the guest records keys, virtio mouse moves, left and right buttons, wheel, one-finger moves, two-finger scroll and a trackpad click. The image needs `libinput-tools`; the check installs it in the clone with apt unless `--image` names a disk that has it. `HV_INPUT_FILE` lines on the virt board: `key N`, `type TEXT`, `rel DX DY`, `click 0 0`, `rclick`, `scroll X Y`, `btn CODE 1|0`, `tp ID PHASE X Y`, `tpframe`, `tpclick 1|0`, `msleep MS`, `wait S`.
- `touch-check.py` (TS3, `make test-linux-touch`) boots a clone of `debian-desktop.img` with `--share` and drives the virtio touchscreen with `ts SLOT PHASE X Y` (0 to 32767 on each axis), `tsframe`, `tscancel` and `tsmode 0|1` lines in `HV_INPUT_FILE`. It checks that dmesg names `TuxVM Touchscreen` in PCI slot 9, that udev marks it `ID_INPUT_TOUCHSCREEN=1` and libinput lists it with the capability `touch`, that `evtest` shows one contact's raw events in TS1's order, and that `libinput debug-events` shows a centre tap at 50%/50%, a drag, two contacts that move apart and a cancel. A full-screen Wayland client (`touchprobe.py`) then checks that taps at 10% and 90% of each axis land within 2 logical pixels, at 1920x1080 scale 1 and after `mode 1200x2616 2`. Unless `--no-qemu`, `evcaps.py` compares the device with QEMU's `virtio-multitouch-pci` in the same image (hvf). The check installs `libinput-tools` and `evtest` in the clone unless `--image` names a disk that has them. `tuxvm --window --touch` makes a click one contact, for a check by eye.
- `balloon-check.py` (P10, `make test-linux-balloon`) boots a clone with `HV_BALLOON=0` and drives the target with `balloon MB` and `balloonstat` lines in `HV_INPUT_FILE` (the second prints actual, given back and taken back MB, partial pages, pages outside RAM and failures). It checks that `virtio_balloon` is bound, that inflating by `--mb` (default 512) lowers the guest's free memory by that much, that the device's counters show the same amount given back with no partial page or failure, that the host process's `footprint` falls after the guest dirtied and freed memory, and that deflate restores it. `--ram-file` puts guest RAM in a file (as on iOS; the footprint check is skipped, because the unlinked file cannot be seen). `--load` also installs `build-essential` and `stress-ng`, then inflates by half of `MemAvailable` during `make -j4` of `cproject.sh` (three times) and a stress run; `--overshoot` then asks for almost all of RAM under stress and fails on any OOM message. `--save-image FILE` keeps the disk with the packages for `--image`. On the virt board the device offers `VIRTIO_BALLOON_F_DEFLATE_ON_OOM`, so Linux deflates before it kills a process; Linux then keeps `MemTotal` and takes the pages from `MemFree`.
- `sound-check.py` (P8, `make test-linux-sound`) boots a clone with `HV_SND_CAPTURE=path`, which makes the host's audio backend (`host/audio_mac.c`) write every byte its render callback plays to `path` (silence too, while the stream runs; `path.fmt` holds channels, virtio format and rate). It checks that `snd_virtio` binds with no probe error, that ALSA lists one playback card and no capture, that `speaker-test -c2 -t sine -f 440 -l 1` arrives as 440 Hz, left then right, and that a 60 s file (440 Hz left, 660 Hz right) played by `aplay` arrives whole: 60.0 s, right level and pitch, no zero run over 1 ms, zero crossings on a straight line to 0.5 ms (a lost or repeated buffer would show), and 60 s of host wall time (the guest's audio clock does not drift). `--pipewire` repeats the file with `pw-play` through pipewire and wireplumber (user services). Images built before `alsa-utils` joined the console list lack it, so the check installs `alsa-utils` and `sox` (and the pipewire packages, `libpam-systemd`, `dbus-user-session`, and enables linger and starts `user@1000` for `tux` because the serial login has no user session) in the clone with apt, adds `tux` to group `audio` (`/dev/snd` is group audio; `customize.sh` now does this) waits for systemd and apt to settle after the reboot; `--image` uses a disk that has them, `--save-image` keeps one. `--keep-capture FILE` keeps the host's capture. The check hears nothing: it reads what the host played, so the Mac's speakers may be silent or muted.
- `status-check.py` (DS6, `make test-linux-status`) boots a clone of `debian-desktop.img` with `--share`, `HV_INPUT_FILE`, `HV_STATUS_LOG` and `HV_SND_CAPTURE`, and installs `upower` and `brightnessctl` in it. It checks the drivers and `tux-status`, that nothing sets the device's volume or brightness at boot or when WirePlumber starts, the battery in sysfs and UPower (no battery before a `battery` line, then level, state, mains and the current from two level steps), the backlight both ways (one request, no echo), Master and PipeWire's volume both ways, mute as silence at the host, the clock within 0.5 s after a 60 s pause (`--pause`), an RTC that ignores guest writes, and `tz` lines (a bad name refused). `--image`, `--tuxvm`, `--cpus` and `--work-dir` choose the run; set them in `STATUS_ARGS`. The image needs `tux-guest` 1.3.1.
- `kernel-boot-time.py` (K2, `uv run`) times what the initrd costs: it boots Debian's kernel from a clone of `debian-console.img` on QEMU (TCG) and on `tuxvm`, by direct boot or through U-Boot (`ext4load` and `booti`), with and without the initrd, and reads the kernel's own timestamps (`Freeing initrd memory`, `Run /init`, the root mount, the first `systemd[1]` line). Without the initrd Debian's kernel cannot mount the root (`virtio_blk` and `ext4` are modules), so that run stops at `VFS: Cannot open root device`; its kernel time is what a kernel with the drivers built in would need. `--machine`, `--boot`, `--initrd on|off`, `--runs`, `--cpus`, `--tuxvm`, `--work-dir`, `--console-dir` and `--json` select and keep results.
- tuxvm on the virt board: `SIGTERM` and `Ctrl-A p` press the guest's power key (GPIO pin 3, high for 100 ms). A second `SIGTERM` stops the machine at once. `SIGINT` and `SIGHUP` still stop it at once. `Ctrl-A s` pauses and resumes the machine (`hv_vm_pause`, what the iOS app does in the background); `SIGTSTP` pauses it and stops the process, and `SIGCONT` resumes it. The guest's clock skips the paused time. `Ctrl-A b` enters and leaves the app's background (`hv_vm_set_background`): a machine started with `--gpu-accel` pauses there even while its guest plays sound. A pause also stops the Metal presenter, and with `--gpu-accel` it first waits up to 1.5 s for the renderer to finish what it holds.
- `video-decode-check.py` (`make test-linux-video`) boots a clone of `debian-desktop.img` with `--gpu-accel --gpu-video` and checks VA-API decode for each codec: `vainfo`'s profiles, the frame checksum test (`ffmpeg -hwaccel vaapi -f framemd5` against `-hwaccel none`, every frame equal, for two H.264, two VP9 and three AV1 clips made on the Mac), the speed against software decode, `mpv --hwdec=vaapi`, and `tuxvm`'s log (each run's frames on VideoToolbox's hardware decoder, and copied to the guest's textures on the GPU). `--codecs`, `--bench N`, `--clips DIR` and `--image FILE` (a disk with the packages) go in `VIDEO_ARGS`; `--no-video` checks that without `--gpu-video` nothing is offered.
- `gpu-pause-check.py` (A9c, `make test-linux-gpu-pause`) boots a clone of `debian-desktop.img` with `--gpu-accel`, runs glmark2, and pauses `tuxvm` with `Ctrl-A s`, `SIGTSTP` and `Ctrl-A b` (with `aplay` playing). tuxvm prints the renderer's request count after each pause and before the resume; they must be equal, the GPU must read `held`, glmark2 must go on, and dmesg must stay clean. It then restarts the guest, pauses the new machine and ends it with two `SIGTERM`s while paused: it must end within 15 s with no renderer time-out. `--seconds` sets the length of each pause (`GPU_PAUSE_ARGS`; the plan's step 5 says 60).
- `suspend-check.py` (E15, `make test-linux-suspend`) boots a clone of `debian-console.img` at 4 CPUs and pauses it for 30 s (`Ctrl-A s`, then `SIGSTOP`) and 120 s (`SIGTSTP`). After each pause the guest must report no RCU stall or kernel warning, its boot-time clock must have moved by the host's time less the pause (2 s slack, no step over 2 s), and its wall clock may step only forward, by what timesyncd puts back. A paused `tuxvm` must use under 1% of a core. `--no-pause --expect-stall` shows the old behaviour (`SIGSTOP` alone gives the stall). `--seconds`, `--cpus`, `--sync-wait`, `--image` and `--work-dir` choose the run; set them in `SUSPEND_ARGS`.

## Desktop

The desktop image is variant A of G6: labwc on Wayland and one foot terminal. It runs with pixman, or with gles2 when the GPU is virgl.

- Autologin on tty1 runs `/usr/local/bin/tux-session` from `/etc/profile.d/tux-desktop.sh`. The serial console stays a plain shell (since `tux-guest` 1.11.0 it signs in as root until the account is set up; see Tuxedo Additions). If labwc stops, tty1 keeps a shell.
- The renderer is chosen at every session start: `gles2` if `/dev/dri/renderD128` exists and `eglinfo -B` names virgl, else `pixman`. To force one, write `gles2` or `pixman` into `/etc/tux/renderer`. The choice is printed on tty1 and written to `$XDG_RUNTIME_DIR/tux-session.log` as `renderer=...`.
- labwc runs `/etc/xdg/labwc/autostart`. It starts foot and, if `/etc/tux/bench.sh` is executable, runs it once in the background with `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` and `WLR_RENDERER` set. Its output goes to `$XDG_RUNTIME_DIR/tux-bench.log`. The user `tux` is in the `dialout` group, so the script can also write to `/dev/ttyAMA0`.
- `$XDG_RUNTIME_DIR/tux-times` (`/run/user/1000/tux-times`) holds the guest uptime in seconds at login, when labwc is up and when the terminal's shell starts.
- The touchpad has tap to click and natural scrolling (`/etc/xdg/labwc/rc.xml`).
- The `labwc` package depends on `xwayland`, so it is installed. labwc starts it only when an X11 program asks, so a normal session has no Xwayland process.

### Plasma (optional)

The image does not include KDE Plasma, but it is ready for it. To install it in the guest (about 1,100 packages and 4 GB, so make the disk at least 12 GB):

```sh
sudo apt-get update
sudo apt-get install -y plasma-desktop plasma-workspace kwin-wayland konsole systemsettings sddm-
echo plasma | sudo tee /etc/tux/session
sudo reboot
```

- `tux-session` runs `startplasma-wayland` when the first line of `/etc/tux/session` is `plasma`. Any other value, or no file, gives labwc.
- Reboot after you change the session. `systemctl restart getty@tty1` leaves the old tty1 session in State=closing, and KWin then fails to get the seat.
- `/etc/xdg/startkderc` sets `systemdBoot=false`. With the systemd start, KWin runs as a user unit outside the tty1 session. logind then gives it the user's display session, which can be the serial console session (no seat), and polkit refuses `Activate`. KWin prints "Failed to activate ... session. Maybe another compositor is running?" and cannot open `/dev/dri/card0`.
- Start Plasma from tty1 (the screen), not from the serial console. The serial console session has no seat.
- `/etc/xdg/autostart/tux-plasma.desktop` (KDE only) starts the clipboard helper and `tux-display`, which sets the size and scale with `kscreen-doctor`.
- Touch (TS4): KWin maps the touchscreen to the output with no setting (no entry in `kcminputrc`; one output only). A wl_touch probe on a full-screen window got taps at 10 % and 90 % of each axis within 0.01 logical pixels at 1920x1080 scale 1 and at 1200x2616 scale 2 (600x1308 logical). A tap on the launcher opened it, and a drag on a title bar moved Konsole by exactly the drag. libinput and the udev tags are the same as on labwc. Not tested: a second output.
- Brightness (DS7): Plasma 6.3's powerdevil gives the backlight to KWin when KWin offers `kde_external_brightness_v1`, and KWin attaches it only to an internal output (eDP, LVDS, DSI). The virtio-gpu output is `Virtual-1`, so it never gets the backlight, and KWin offers its own software dimming for `Virtual-1` instead: a drag on that slider never reached `tux-backlight` or the device. Two settings fix this. `tux-session` sets `QT_WAYLAND_DISABLED_INTERFACES=kde_external_brightness_v1` before `startplasma-wayland` (a Qt Wayland setting: the client does not see that global). Only powerdevil uses the interface, so powerdevil keeps the backlight and writes it through its KAuth helper. The "Brightness and Color" applet then has one slider, "Built-in Screen". A drag on it writes `tux-backlight`, and the host logs one `guest brightness` request for each step. A host `brightness` line moves it, with no request back. The desktop's `/etc/xdg/kwinoutputconfig.json` keeps KWin's software dimming off (`allowSdrSoftwareBrightness` false for `Virtual-1`, with an empty `setups` list: KWin ignores the file without both keys), so there is no second slider. KWin reads this file only until the user has a `~/.config/kwinoutputconfig.json`; in a Plasma that has run already, set `allowSdrSoftwareBrightness` to `false` there while KWin is stopped (KWin writes its own state back when it quits). powerdevil's display range is 0 to 254 for sysfs 1 to 255.
- Polkit and the display session (DS7): with `systemdBoot=false`, Plasma's user services (powerdevil, plasmashell) run in the user manager, and polkit gives them the user's display session. When the serial console logs in first, that is the serial session (no seat), and polkit treats the services as not local: powerdevil's `org.kde.powerdevil.backlighthelper` actions are refused (`pkcheck` says "Not authorized"), so powerdevil cannot read or set the backlight. The desktop's `/etc/polkit-1/rules.d/50-tux-backlight.rules` allows those actions for the user `tux` only. polkitd, installed with Plasma, sets the directory to `root:polkitd` 0750 and keeps the rule.
- `/dev/i2c-0` is the device's I2C bus (battery and backlight). It is `root` only. powerdevil starts libddcutil, which tries to open it and logs "lacks R/W permissions". Keep it that way: with a group rule for `i2c`, ddcutil would probe the battery's bus.
- Screen lock (DS7): Plasma locked the screen after 5 minutes without input. The user has no password, so the desktop's `/etc/xdg/kscreenlockerrc` turns off `Autolock` and `LockOnResume`. With it, the screen did not lock in 7 minutes without input, and the backlight did not change.
- Applets (DS7): the battery applet shows "Charging 40%" or "Discharging 39%" and "Remaining Time: Estimating…" (UPower has no time to empty at ±0 mA; after level steps it gave 17 s at 2 %). There is no "Plugged in" text. A drag on the volume slider logs one request per step and a host `volume` line moves it with no request and no loop; the OSD shows once for a drag. `tz Asia/Tokyo` changes the clock applet within 12 s. At 9 % Plasma shows "Battery Low", at 4 % and 2 % "Battery Critical, please save your work"; UPower says `critical` at 4 % and `action` at 2 %, and the guest stays up (checked for 75 s).
- Plasma on software rendering (llvmpipe, 4 CPUs): plasmashell grows to about 800 MB, so give the guest 4 GB (2 GB ran out of memory and thrashed, with soft-lockup messages while the Mac swapped). The journal shows `eglSwapBuffers failed with 0x300d` and `Failed to recreate shadow` for popup surfaces; the popups still work. The Plasma panel moves between y 1050 (floating) and 1058 (a window touches it), so a tap script must not hard-code its row. `--gpu-accel` was not checked (the graphics libraries are not built here).
