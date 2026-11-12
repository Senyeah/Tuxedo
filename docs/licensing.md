# Licensing

Henge is GPL-2.0-or-later ([LICENSE](../LICENSE)). The shipped binary is a combined
GPL work because usbmuxd and code from Husk are compiled into it, so it cannot go on
the App Store.

| Code | Licence | Where |
| --- | --- | --- |
| Henge | GPL-2.0-or-later | `core/`, `devices/`, `host/`, `ios/`, `tools/` |
| Code from Husk | GPL-2.0-or-later | `ios/Henge/JIT/`, `HengeLog.swift`, `Native/henge-ios-jit.*`, `henge-brk.S`, `HengeJITHelper/` |
| QEMU's vmapple AES device, as a reference | GPL-2.0-or-later | `devices/aes.c` |
| QEMU's `tcg-apple-jit.h` | LGPL-2.1-or-later | `ios/Henge/Native/` |
| usbmuxd | GPL-2.0 or GPL-3.0 | `third_party/usbmuxd` |
| idevicerestore | LGPL (see below) | `third_party/idevicerestore` |
| libimobiledevice, libplist | LGPL-2.1, with GPL-2.0 for their tools | `third_party/` |
| libimobiledevice-glue, libirecovery, libtatsu, libusbmuxd | LGPL-2.1 | `third_party/` |
| libzip | BSD | `third_party/libzip` |
| Mbed TLS | Apache-2.0 or GPL-2.0-or-later | `third_party/mbedtls` |
| StikJIT (the Bitrise build applies `ci/stikjit-high-address.patch`) | MPL-2.0 | `ios/Henge/Resources/legal/` |
| idevice | MIT | `ios/Henge/Resources/legal/` |
| Pairing library's Rust crates | Listed per crate | `ios/Henge/Resources/legal/LICENSES-rppairing-crates.txt` |
| QEMU's `virt` machine, as a reference for the Linux board's layout and device tree | GPL-2.0-or-later | `devices/virt.c`, `devices/virt_fdt.c` |
| ANGLE (built from source, static) | BSD-3-Clause | `ios/Henge/Resources/legal/LICENSES-ANGLE.txt` |
| Code inside ANGLE's static libraries | abseil, astc-encoder: Apache-2.0. zlib: zlib. xxhash: BSD-2-Clause. volk: MIT (iOS and simulator libraries only) | same file |
| libepoxy (UTM's fork, patched), virglrenderer (UTM's fork) | MIT | `ios/Henge/Resources/legal/LICENSE-libepoxy-MIT.txt`, `LICENSE-virglrenderer-MIT.txt` |
| SwiftTerm 1.99.1 (the Linux console) | MIT | `ios/Henge/Resources/legal/LICENSE-SwiftTerm-MIT.txt` |
| libusb's header | LGPL-2.1-or-later | `third_party/libusb-1.0/libusb.h` |
| U-Boot `v2026.10` (Linux guest firmware, not in the app) | GPL-2.0, most files also under later versions | the Linux image catalogue; see below |
| Debian packages in the Linux images, and their kernel | each package's own licence | the Linux image catalogue; see below |
| libslirp, pcre2 | BSD | Prebuilt from Husk |
| glib, libintl | LGPL-2.1-or-later | Prebuilt from Husk |

The licence files in `ios/Henge/Resources/legal/` are in the root of `Henge.app`. The app has no screen that shows them yet.

idevicerestore's `COPYING` file is LGPL-3.0, while its source headers say LGPL-2.1
or later. If the `COPYING` file governs, the combined binary is GPL-3.0, which
GPL-2.0-or-later allows.

## Not covered

These are Apple's, and none of the licences above apply to them:

- **macOS**, which Henge downloads from Apple when you install it.
- **The boot ROM**, `AVPBooter.vmapple2.bin`. Henge fetches it on the device, from Apple's
  macOS 14.6.1 restore image, when you install. It isn't in this repository or in the app.

An exported Mac is a copy of that Mac, so its folder contains macOS and the ROM, as does
one made by `tools/export_ios.sh`. Those folders are for your own devices, not for sharing.

## Linux guests

A Linux machine needs two things that are not in the repository or in the app: a U-Boot binary and a Debian disk image. `tools/linux` builds both ([README](../tools/linux/README.md)). The app downloads them from a catalogue, or imports them from a folder. Whoever hosts them hands out GPL binaries, so that person must also hand out, or offer, the source. The repository holds no U-Boot or Debian source and applies no patch to either.

### ANGLE, libepoxy and virglrenderer

`tools/gfx/build-deps.sh` builds these from source as static libraries and writes their licence files to `build/gfx/<target>/share/licenses`. `ios/Henge/Resources/legal/LICENSES-ANGLE.txt` is those ANGLE files joined, in the same order and with the same text, and the other two files are copies of `libepoxy/COPYING` and `virglrenderer/COPYING`. The three targets (`macos`, `ios`, `sim`) have the same licence files.

ANGLE's own licence is BSD-3-Clause. Its static `libGLESv2.a` also holds code from its `third_party` folder. Reading the archive members shows abseil, astc-encoder, zlib and xxhash in all three targets, and volk in the iOS and simulator targets only. The licence file also carries jsoncpp, the SPIR-V headers and tools, ceval and libXNVCtrl, which no member of the archives matches. They are kept so that a later ANGLE pin cannot drop a notice by accident. The libepoxy patch (`tools/gfx/libepoxy-static-gl.patch`) and the pins in `tools/gfx/versions.env` are the source offer for those two libraries: both come from UTM's forks, at the commits named there.

The Mac tool links these libraries only with `make GFX=1`. The app links them only when `HENGE_GFX` is 1 (`ios/scripts/gfx_env.sh`),.

### SwiftTerm

SwiftTerm is MIT and is the app's only Swift package. The package graph also lists swift-png, swift-argument-parser and `h` (swift-png's own dependency), all Apache-2.0. SwiftTerm's manifest uses swift-png only on Linux, Windows, WASI and Android, and swift-argument-parser only for its own tools, so neither goes into the iOS app. A simulator build holds neither. A device build was not inspected.

### U-Boot

U-Boot's top-level `Licenses/README` says it is GPL-2.0, and that most of it can also be used under any later version. Some files carry other licences (the `Licenses/` folder has BSD, ISC, MIT, LGPL, OFL and others). Do not describe the binary as GPL-2.0-or-later without that qualification.

The build takes the tag and settings from `tools/linux/versions.env` and `tools/linux/build-uboot.sh`, and writes `build/linux/u-boot.manifest`. This is what a shipped binary was built from. Record it with the release:

| Item | Value |
| --- | --- |
| Source | `https://source.denx.de/u-boot/u-boot.git`, tag `v2026.10`, commit `5508406582f6f7120dce0c4b3059819a41788db2` |
| Patches | none |
| Config | `qemu_arm64_defconfig`, then `tools/linux/u-boot-henge.config` merged with `scripts/kconfig/merge_config.sh` and `make olddefconfig`. The fragment sets `CONFIG_BOOTDELAY=0` and turns off `CONFIG_BOOTMETH_EFI_BOOTMGR`. |
| Binary of this build | `build/linux/u-boot.bin`, SHA-256 `7b9486aed668717b8fa0b1d9d3d62516f96588993f0eccb3e8d8d7d5e4fe283e` (1,506,312 bytes) |
| Toolchain | the `debian:trixie` image of `tools/linux/Dockerfile`, which is not pinned by digest |

`build-uboot.sh --stock` builds the unmodified defconfig as `u-boot-stock.bin`, which tests use. The catalogue serves the binary as `u-boot-<first 12 hex digits of the SHA-256>.bin`. A bit-for-bit rebuild has not been tried: the compiler comes from whatever `debian:trixie` is on the day.

To hand out the source with a binary, publish a tarball of that tag next to it, with the fragment, `build-uboot.sh` and `versions.env`. Whether a link to DENX's server is enough is a legal question for the host to settle. The tarball avoids it.

### The Debian image

The image is made by `mmdebstrap` from Debian trixie, component `main` only, so it holds no `contrib` or `non-free` package and no firmware blob. The mirror is a `snapshot.debian.org` snapshot, set by `DEBIAN_SNAPSHOT` in `tools/linux/versions.env` (now `20261110T000000Z`), so the package set does not move between builds. Each package has its own licence, and its text is in `/usr/share/doc/<package>/copyright` inside the image. The kernel is Debian's `linux-image-arm64-16k`, GPL-2.0 with the Linux syscall exception. The `henge-guest` package (`tools/linux/henge-guest`) is Henge's, so GPL-2.0-or-later as in the table above. It has no `copyright` file yet.

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

The binary package `linux-image-6.12.107+deb13-arm64-16k` does not resolve by its own name. Its source is `linux`, and `linux-image-arm64-16k` is a metapackage whose source is `linux-signed-arm64`. The build passes `mmdebstrap` only a `deb` line, so the image has no source line, and a person who has only the image needs the lines above. `snapshot.debian.org` is run by Debian, and Henge does not control it.
