# Licensing

Tuxedo is GPL-2.0-or-later ([LICENSE](../LICENSE)). The shipped binary is a combined
GPL work because code from Husk (GPL-2.0-or-later) is compiled into it, so it cannot
go on the App Store.

| Code | Licence | Where |
| --- | --- | --- |
| Tuxedo | GPL-2.0-or-later | `core/`, `devices/`, `host/`, `ios/`, `tools/` |
| Code from Husk | GPL-2.0-or-later | `ios/Tuxedo/JIT/`, `TuxLog.swift`, `Native/tux-ios-jit.*`, `tux-brk.S`, `TuxJITHelper/` |
| QEMU's `tcg-apple-jit.h` | LGPL-2.1-or-later | `ios/Tuxedo/Native/` |
| StikJIT (the Bitrise build applies `ci/stikjit-high-address.patch`) | MPL-2.0 | `ios/Tuxedo/Resources/legal/` |
| idevice | MIT | `ios/Tuxedo/Resources/legal/` |
| Pairing library's Rust crates | Listed per crate | `ios/Tuxedo/Resources/legal/LICENSES-rppairing-crates.txt` |
| QEMU's `virt` machine, as a reference for the Linux board's layout and device tree | GPL-2.0-or-later | `devices/virt.c`, `devices/virt_fdt.c` |
| ANGLE (built from source, static) | BSD-3-Clause | `ios/Tuxedo/Resources/legal/LICENSES-ANGLE.txt` |
| Code inside ANGLE's static libraries | abseil, astc-encoder: Apache-2.0. zlib: zlib. xxhash: BSD-2-Clause. volk: MIT (iOS and simulator libraries only) | same file |
| libepoxy (UTM's fork, patched), virglrenderer (UTM's fork) | MIT | `ios/Tuxedo/Resources/legal/LICENSE-libepoxy-MIT.txt`, `LICENSE-virglrenderer-MIT.txt` |
| SwiftTerm 1.99.1 (the Linux console) | MIT | `ios/Tuxedo/Resources/legal/LICENSE-SwiftTerm-MIT.txt` |
| U-Boot `v2026.10` (Linux guest firmware, not in the app) | GPL-2.0, most files also under later versions | the Linux image catalogue; see below |
| Debian packages in the Linux images, and their kernel | each package's own licence | the Linux image catalogue; see below |
| FFmpeg 9.0.2 with the Tuxedo patch, in the `tux-ffmpeg` package: in the Linux images, in the Tuxedo apt repository, and in the Tuxedo Additions media inside the app | GPL-2.0-or-later as built; FFmpeg's own code is LGPL-2.1-or-later with GPL parts | the Tuxedo apt repository and `ios/Tuxedo/Resources/legal/LICENSES-TuxedoAdditions.txt`; see below |
| Tuxedo Additions media in the app (`Tuxedo.app/TuxAdditions/`): the four Tuxedo packages, the agent, and about 70 Debian packages | Tuxedo files GPL-2.0-or-later; `tux-ffmpeg` as in the row above; each Debian package has its own licence | `ios/Tuxedo/Resources/legal/LICENSES-TuxedoAdditions.txt`, `README.txt` and `source/SOURCES.txt` on the media; see below |
| `libhvcodec`, `tux-codec-info`, and the files that the FFmpeg patch adds | LGPL-2.1-or-later | `tools/linux/hvcodec/` |
| libslirp, pcre2 | BSD | Prebuilt from Husk |
| glib, libintl | LGPL-2.1-or-later | Prebuilt from Husk |

The licence files in `ios/Tuxedo/Resources/legal/` are in the root of `Tuxedo.app`. The app has no screen that shows them yet. When it gets one, it must list `LICENSES-TuxedoAdditions.txt` too, because that file holds the source offer for the media (see Tuxedo Additions below).

## Linux guests

A Linux machine needs two things that are not in the repository or in the app: a U-Boot binary and a Debian disk image. The app does carry one set of Linux packages, the Tuxedo Additions media (see below). `tools/linux` builds both ([README](../tools/linux/README.md)). The app downloads them from a catalogue, or imports them from a folder. Whoever hosts them hands out GPL binaries, so that person must also hand out, or offer, the source. The repository holds no U-Boot or Debian source and applies no patch to either. FFmpeg is different: the repository has a patch to it, and the source offer is part of the apt repository (see FFmpeg below).

### ANGLE, libepoxy and virglrenderer

`tools/gfx/build-deps.sh` builds these from source as static libraries and writes their licence files to `build/gfx/<target>/share/licenses`. `ios/Tuxedo/Resources/legal/LICENSES-ANGLE.txt` is those ANGLE files joined, in the same order and with the same text, and the other two files are copies of `libepoxy/COPYING` and `virglrenderer/COPYING`. The three targets (`macos`, `ios`, `sim`) have the same licence files.

ANGLE's own licence is BSD-3-Clause. Its static `libGLESv2.a` also holds code from its `third_party` folder. Reading the archive members shows abseil, astc-encoder, zlib and xxhash in all three targets, and volk in the iOS and simulator targets only. The licence file also carries jsoncpp, the SPIR-V headers and tools, ceval and libXNVCtrl, which no member of the archives matches. They are kept so that a later ANGLE pin cannot drop a notice by accident. The libepoxy patch (`tools/gfx/libepoxy-static-gl.patch`) and the pins in `tools/gfx/versions.env` are the source offer for those two libraries: both come from UTM's forks, at the commits named there.

The Mac tool links these libraries only with `make GFX=1`. The app links them only when `TUX_GFX` is 1 (`ios/scripts/gfx_env.sh`),.

### SwiftTerm

SwiftTerm is MIT and is the app's only Swift package. The package graph also lists swift-png, swift-argument-parser and `h` (swift-png's own dependency), all Apache-2.0. SwiftTerm's manifest uses swift-png only on Linux, Windows, WASI and Android, and swift-argument-parser only for its own tools, so neither goes into the iOS app. A simulator build holds neither. A device build was not inspected.

### U-Boot

U-Boot's top-level `Licenses/README` says it is GPL-2.0, and that most of it can also be used under any later version. Some files carry other licences (the `Licenses/` folder has BSD, ISC, MIT, LGPL, OFL and others). Do not describe the binary as GPL-2.0-or-later without that qualification.

The build takes the tag and settings from `tools/linux/versions.env` and `tools/linux/build-uboot.sh`, and writes `build/linux/u-boot.manifest`. This is what a shipped binary was built from. Record it with the release:

| Item | Value |
| --- | --- |
| Source | `https://source.denx.de/u-boot/u-boot.git`, tag `v2026.10`, commit `5508406582f6f7120dce0c4b3059819a41788db2` |
| Patches | none |
| Config | `qemu_arm64_defconfig`, then `tools/linux/u-boot-tux.config` merged with `scripts/kconfig/merge_config.sh` and `make olddefconfig`. The fragment sets `CONFIG_BOOTDELAY=0` and turns off `CONFIG_BOOTMETH_EFI_BOOTMGR`. |
| Binary of this build | `build/linux/u-boot.bin`, SHA-256 `7b9486aed668717b8fa0b1d9d3d62516f96588993f0eccb3e8d8d7d5e4fe283e` (1,506,312 bytes) |
| Toolchain | the `debian:trixie` image of `tools/linux/Dockerfile`, which is not pinned by digest |

`build-uboot.sh --stock` builds the unmodified defconfig as `u-boot-stock.bin`, which tests use. The catalogue serves the binary as `u-boot-<first 12 hex digits of the SHA-256>.bin`. A bit-for-bit rebuild has not been tried: the compiler comes from whatever `debian:trixie` is on the day.

To hand out the source with a binary, publish a tarball of that tag next to it, with the fragment, `build-uboot.sh` and `versions.env`. Whether a link to DENX's server is enough is a legal question for the host to settle. The tarball avoids it.

### The Debian image

The image is made by `mmdebstrap` from Debian trixie, component `main` only, so it holds no `contrib` or `non-free` package and no firmware blob. The mirror is a `snapshot.debian.org` snapshot, set by `DEBIAN_SNAPSHOT` in `tools/linux/versions.env` (now `20261110T000000Z`), so the package set does not move between builds. Each package has its own licence, and its text is in `/usr/share/doc/<package>/copyright` inside the image. The kernel is Debian's `linux-image-arm64-16k`, GPL-2.0 with the Linux syscall exception. The `tux-guest` package (`tools/linux/tux-guest`) is Tuxedo's, so GPL-2.0-or-later as in the table above. It has no `copyright` file yet.

`build-image.sh` writes `build/linux/debian-console.manifest` and `debian-desktop.manifest`. Each has the snapshot URL, the kernel version, the `extlinux.conf`, the image's SHA-256 and a `[packages]` list of every binary package and version, from `dpkg-query -W`. The list is also in the guest (`dpkg -l`). The build of 13/11/2026 has 164 packages in the console image and 338 in the desktop image, with kernel `6.12.107+deb13-arm64-16k`. Keep both manifests with the release.

To get the source of a package, add a source line for the same snapshot and ask `apt-get source` for it. This was run on 13/11/2026 against the snapshot above:

```sh
echo 'deb-src [check-valid-until=no] https://snapshot.debian.org/archive/debian/20261110T000000Z/ trixie main' \
  > /etc/apt/sources.list
apt-get update -o Acquire::Check-Valid-Until=false
apt-get source bash=5.2.37-2+b10   # a binary version is accepted, and a +bN suffix is dropped
apt-get source linux=6.12.107-1    # the kernel image's source package is linux
apt-cache showsrc PACKAGE          # names the source package of a binary package
```

The binary package `linux-image-6.12.107+deb13-arm64-16k` does not resolve by its own name. Its source is `linux`, and `linux-image-arm64-16k` is a metapackage whose source is `linux-signed-arm64`. The build passes `mmdebstrap` only a `deb` line, so the image has no source line, and a person who has only the image needs the lines above. `snapshot.debian.org` is run by Debian, and Tuxedo does not control it.

### FFmpeg (tux-ffmpeg)

`tux-ffmpeg` is an `ffmpeg` for the Linux guest with the device's codecs (`docs/guest-video-encode-plan.md`). Both Linux images install it, and the app carries it in the Tuxedo Additions media (see below). `tools/linux/build-ffmpeg.sh` builds it, `build-ffmpeg-pkg.sh` packages it, and `publish-apt.sh` puts it in the Tuxedo apt repository with its source.

| Item | Value |
| --- | --- |
| Upstream | `https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz`, SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` (`FFMPEG_VERSION`, `FFMPEG_SHA256` in `tools/linux/versions.env`). The release signature was checked against FFmpeg's release key when it was pinned. |
| Patch | `tools/linux/hvcodec/ffmpeg-tux.patch`, SHA-256 `949e760cf014a8eec4144470113048d5b3db9c9789c438dcabfc3fcfadca3dd5`. It adds `libavutil/hwcontext_tux.*`, `libavcodec/tux*.c`, `libavcodec/tuxenc.c` and `libavfilter/vf_scale_tux.c`, each with FFmpeg's LGPL-2.1-or-later header, and changes FFmpeg files to register them. |
| Tuxedo code linked in | `libhvcodec` (`tools/linux/hvcodec/libhvcodec/`) and `tux-codec-info.c`, LGPL-2.1-or-later. Both include `host/vcodec_proto.h`, which has no licence line, so it has the repository's GPL-2.0-or-later. A `libhvcodec` that is LGPL on its own needs an LGPL line on that header. |
| Configure | `--enable-gpl` with `libx264` and `libx265`, so the binaries are GPL-2.0-or-later. The `libav*` libraries are static. The full line is in `ffmpeg.manifest`. |
| Shared libraries | x264, x265, dav1d, Opus, LAME, GnuTLS and their dependencies come from Debian at run time. Each has its own `copyright` file in the guest, and its source comes from the snapshot as for the image (above). |
| Build record | `build/linux/ffmpeg/ffmpeg.manifest`: the release, the hashes of the tarball, the patch, `libhvcodec` and each binary, the configure line, and the version of each Debian build and run-time package. The package has a copy at `/usr/share/doc/tux-ffmpeg/ffmpeg.manifest`. Two builds from the same inputs gave the same binaries and the same `.deb` on 14/11/2026. |
| In the package | `/usr/share/doc/tux-ffmpeg/copyright` (machine-readable, with the source URL) and FFmpeg's `LICENSE.md`. The GPL and LGPL texts are Debian's `/usr/share/common-licenses/`. |

The source offer. Whoever hosts the `.deb` hands out a GPL binary, so that person must also hand out the source. `publish-apt.sh` writes `build/linux/source/ffmpeg-<release>-tux<N>/` next to the repository, and the server gets it at `https://walkies.site/tux-linux-catalogue/source/ffmpeg-9.0.2-tux2/` (the directory name follows the package version), the URL in the package's `copyright` file. It holds the unmodified tarball, the patch, `build-ffmpeg.sh`, `ffmpeg.manifest`, `tux-ffmpeg-src.tar.xz` (the Tuxedo files of the build: `libhvcodec`, `tux-codec-info.c`, `vcodec_proto.h`, the man page, the package scripts, `versions.env` and the repository's `LICENSE`), `README.txt` with the build steps, and `SHA256SUMS`. The script does not publish a `tux-ffmpeg` whose source directory is missing or has another manifest, and it does not let a source directory change under the same version. A later change only to a file of the offer that does not change the binaries, such as `LICENSE`, keeps the published directory as it was. Keep each source directory on the server for as long as its `.deb` is in the pool. Whether this offer is enough in law is for the host to decide; it gives the complete source of the binary from the same place.

`tux-ffmpeg` does not change Debian's `ffmpeg` package or its files. The two can be installed together.

The H.264 and HEVC patent position for a person who distributes this package is not verified. This is not legal advice. The codecs run in the device's hardware, which Apple sells with its licences.

### Tuxedo Additions (the media in the app)

The app carries the media of "Insert Tuxedo Additions CD" in its bundle, as `Tuxedo.app/TuxAdditions/` (a copy of `build/linux/additions/tux-additions/`, made by `tools/linux/package-additions.sh`; the design is `docs/guest-additions-design.md`). Before this, the app held no GPL or LGPL binary for Linux guests. Now every copy of the app hands out some. So the app's distributor must also offer the source.

| What is on the media | Licence | Source |
| --- | --- | --- |
| The agent, `install`, `tux-guest`, `tux-va`, `tux-codec-dkms`, the labwc session files | GPL-2.0-or-later (the repository's `LICENSE`) | This repository, and inside each package (scripts and C source) |
| `tux-ffmpeg` | GPL-2.0-or-later as built (FFmpeg is LGPL-2.1-or-later with GPL parts; `libhvcodec` is LGPL-2.1-or-later) | `https://walkies.site/tux-linux-catalogue/source/ffmpeg-9.0.2-tux2/`, the same offer as in FFmpeg above |
| The Debian packages in `apt/pool/deps` (x264, x265, dav1d, Opus, LAME, GnuTLS, `openssh-server`, Python 3 and others that a minimal Debian guest lacks) | Each package's own licence; the text is in `/usr/share/doc/<package>/copyright` once it is installed | `snapshot.debian.org`, the snapshot in `versions.env`; `source/SOURCES.txt` names the folder of each package |

Where the offer is:

- On the media: `README.txt` (the licences and the written offer) and `source/SOURCES.txt` (the place of each package's source). The builder test (`tools/linux/test_package_additions.py`) checks that `SOURCES.txt` names every Debian package, that `README.txt` has no placeholder left, and that no private key or host path is on the media.
- In the app: `ios/Tuxedo/Resources/legal/LICENSES-TuxedoAdditions.txt`, with the same FFmpeg source URL as `README.txt`. The app has no legal screen yet (see above), so that file is in the bundle and nowhere else. A screen must show it when there is one.
- The text is a written offer for at least three years, and it names the distributor as the contact. Whether this is enough in law is for the distributor to decide, as for FFmpeg above.

What the distributor must keep:

- The FFmpeg source directory on the server must stay for as long as an app build that has that `tux-ffmpeg` is in use. A new `tux-ffmpeg` revision (`FFMPEG_TUX_REV`) changes the URL in both text files, so change `LICENSES-TuxedoAdditions.txt` with it. The media's `README.txt` takes the URL from the build, but the app's file does not.
- The snapshot of Debian packages (`DEBIAN_SNAPSHOT`) must stay on `snapshot.debian.org`, or the distributor must hold a copy of the sources.

The media holds no `contrib` or `non-free` package. The key on the media is the repository's public key (`tux-archive.gpg`, the same bytes as in `tux-guest`). The H.264 and HEVC position for `tux-ffmpeg` is the same as above and is not verified.

The apt repository's public key is in the repository (`tools/linux/tux-archive.asc` and `tux-guest/usr/share/keyrings/tux-archive.gpg`). The private key is only on the owner's Mac.

