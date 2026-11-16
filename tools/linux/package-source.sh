#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The source offers for the Linux guest binaries that publish-apt.sh does not cover, in build/linux/source:
#   u-boot-<tag>/                    the U-Boot tree of the pinned tag, the fragment, the build scripts, README.txt, SHA256SUMS
#   debian-images-<snapshot>/        the written offer for the Debian images, their manifests, the source package of each
#                                    binary package (SOURCES-*.txt), fetch-source.sh, SHA256SUMS
# Nothing leaves the Mac. publish-apt.sh --rsync copies build/linux/source with the FFmpeg offers.
# TUX_SOURCE_CONTACT names who to ask for the source (an email address or a URL); it goes into both offers.
# TUX_SOURCE_SUFFIX is added to the Debian directory name when the package list changes under the same snapshot.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--inner" ]; then
    exec "$HERE/run.sh" sh /tools/package-source.sh --inner
fi

. /tools/versions.env
die() { echo "package-source.sh: $*" >&2; exit 1; }

URL=${TUX_APT_URL:-https://walkies.site/tux-linux-catalogue}
CONTACT=${TUX_SOURCE_CONTACT:-}
# GMT+12, as the other dates of this build
TODAY=$(TZ=Etc/GMT-12 date +%d/%m/%Y)
if [ -n "$CONTACT" ]; then
    ASK="Ask $CONTACT, or whoever runs $URL."
else
    ASK="Ask whoever runs $URL."
fi

OFFER="This is also a written offer. Whoever has a binary that was built from this source can ask for a complete copy
of the source of that binary, for at least three years from $TODAY, for no more than the cost of making the copy.
$ASK"

# Put a finished directory in place. The first argument is the new directory, the second the published one,
# the third the file that decides whether the build changed.
publish_dir() {
    new=$1 old=$2 key=$3
    if [ -d "$old" ]; then
        cmp -s "$new/$key" "$old/$key" || die "$old has another $key; the source changed, so raise the version or set TUX_SOURCE_SUFFIX"
        cmp -s "$new/SHA256SUMS" "$old/SHA256SUMS" ||
            echo "kept $old (same $key; these files changed since:" \
                "$(grep -vxF -f "$old/SHA256SUMS" "$new/SHA256SUMS" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'))"
    else
        mkdir -p /out/source && mv "$new" "$old"
        echo "added $old"
    fi
}

# ---- U-Boot ----
SRC=/work/u-boot
if ! { [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" = "$UBOOT_TAG" ]; }; then
    rm -rf "$SRC"
    git clone -q --depth 1 --branch "$UBOOT_TAG" https://source.denx.de/u-boot/u-boot.git "$SRC"
fi
COMMIT=$(git -C "$SRC" rev-parse HEAD)
if [ -f /out/u-boot.manifest ]; then
    [ "$(sed -n 's/^commit=//p' /out/u-boot.manifest)" = "$COMMIT" ] ||
        die "build/linux/u-boot.manifest is another commit than $UBOOT_TAG; run tools/linux/build-uboot.sh"
fi

U=u-boot-$UBOOT_TAG
N=$(mktemp -d)/$U
mkdir -p "$N"
git -C "$SRC" archive --format=tar --prefix="$U/" HEAD | xz -9 -T1 > "$N/$U.tar.xz"
cp /tools/u-boot-tux.config /tools/build-uboot.sh /tools/run.sh /tools/Dockerfile /tools/versions.env "$N/"
{
    echo "tag=$UBOOT_TAG"
    echo "commit=$COMMIT"
    echo "tarball_sha256=$(sha256sum "$N/$U.tar.xz" | cut -d' ' -f1)"
    echo "fragment=u-boot-tux.config"
    echo "fragment_sha256=$(sha256sum "$N/u-boot-tux.config" | cut -d' ' -f1)"
    if [ -f /out/u-boot.bin ]; then
        echo "binary_sha256=$(sha256sum /out/u-boot.bin | cut -d' ' -f1)"
    fi
} > "$N/u-boot.manifest"
cat > "$N/README.txt" <<EOF
U-Boot $UBOOT_TAG for the Tuxedo Linux guest: the source of the u-boot-<hash>.bin files in the catalogue.

$U.tar.xz   the unmodified tree of tag $UBOOT_TAG, commit $COMMIT,
                  from https://source.denx.de/u-boot/u-boot.git (git archive of that commit)
u-boot-tux.config   the settings merged over qemu_arm64_defconfig: CONFIG_BOOTDELAY=0, and no EFI boot manager.
                  Earlier builds named it u-boot-henge.config. The contents are the same.
build-uboot.sh    the build script
run.sh, Dockerfile  the container the script builds in (debian:trixie, arm64)
versions.env      the pinned tag
u-boot.manifest   the tag, the commit, the SHA-256 of the tarball and the fragment, and of the binary if it is known
SHA256SUMS        the SHA-256 of each file here

Tuxedo applies no patch to U-Boot.

Licence. U-Boot is GPL-2.0, and most of its files also allow any later version. Some files carry other licences:
the Licenses/ folder in the tree has the texts. The file Licenses/README in the tree is the authority.

To build from the tarball, on an arm64 Linux with the packages in Dockerfile (build-essential, bc, bison, flex,
libssl-dev, libgnutls28-dev, python3, python3-setuptools, swig and device-tree-compiler), unpack $U.tar.xz and run
this in the tree:
  make qemu_arm64_defconfig
  ./scripts/kconfig/merge_config.sh -m .config /path/to/u-boot-tux.config
  make olddefconfig
  make -j\$(nproc)
The result is u-boot.bin. A rebuild gives a working binary, but its SHA-256 can differ, because the compiler is
whatever the debian:trixie image held on the day and the image is not pinned.

build-uboot.sh does the same steps in a container, and takes the tree from the DENX git server, not from the tarball.

$OFFER
EOF
(cd "$N" && sha256sum "$U.tar.xz" u-boot-tux.config build-uboot.sh run.sh Dockerfile versions.env u-boot.manifest README.txt > SHA256SUMS)
publish_dir "$N" "/out/source/$U" "$U.tar.xz"

# ---- Debian images ----
SNAP_URL=https://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT/
SEC_URL=https://snapshot.debian.org/archive/debian-security/$DEBIAN_SNAPSHOT/
KEY=/usr/share/keyrings/debian-archive-keyring.gpg
D=debian-images-$DEBIAN_SNAPSHOT${TUX_SOURCE_SUFFIX:-}
N=$(mktemp -d)/$D
mkdir -p "$N"

# deb-src lines for the snapshot; the container is thrown away afterwards
rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot-src.sources <<EOF
Types: deb-src
URIs: $SNAP_URL
Suites: $DEBIAN_SUITE $DEBIAN_SUITE-updates
Components: main
Signed-By: $KEY
Check-Valid-Until: no

Types: deb-src
URIs: $SEC_URL
Suites: $DEBIAN_SUITE-security
Components: main
Signed-By: $KEY
Check-Valid-Until: no
EOF
# the Docker image keeps indexes compressed; the parser below reads plain text
rm -rf /var/lib/apt/lists/*
apt-get -q -o Acquire::Retries=5 -o Acquire::GzipIndexes=false update >/dev/null

KINDS=
for k in console desktop; do
    m=/out/debian-$k.manifest
    [ -f "$m" ] || { echo "no $m, so no source list for the $k image"; continue; }
    [ "$(sed -n 's/^mirror=//p' "$m")" = "$SNAP_URL" ] || die "$m is not from the snapshot in versions.env"
    cp "$m" "$N/debian-$k.manifest"
    python3 - "$m" > "$N/SOURCES-$k.txt" <<'PY'
import functools, glob, re, subprocess, sys

# binary package -> [(source package, source version)] from the Sources indexes of the snapshot
by_bin = {}
versions_of = {}
for path in glob.glob("/var/lib/apt/lists/*_Sources"):
    stanza = {}
    def flush():
        if "Package" in stanza and "Binary" in stanza:
            versions_of.setdefault(stanza["Package"], set()).add(stanza["Version"])
            for b in re.split(r",\s*", stanza["Binary"].replace("\n", " ")):
                if b.strip():
                    by_bin.setdefault(b.strip(), []).append((stanza["Package"], stanza["Version"]))
    last = None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            flush(); stanza = {}; last = None
        elif line[0] in " \t":
            if last:
                stanza[last] += " " + line.strip()
        else:
            key, _, val = line.partition(":")
            last = key
            stanza[key] = val.strip()
    flush()

def cmp(a, b):
    for x, y in (("lt", -1), ("gt", 1)):
        if subprocess.run(["dpkg", "--compare-versions", a[1], x, b[1]]).returncode == 0:
            return y
    return 0

def noepoch(v):
    return v.split(":", 1)[1] if ":" in v else v

print("# binary package\tbinary version\tsource package\tsource version\tmatch")
in_pkgs = False
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("["):
        in_pkgs = line == "[packages]"
        continue
    if not in_pkgs or "\t" not in line:
        continue
    name, ver = line.split("\t", 1)
    name = name.split(":", 1)[0]  # dpkg-query adds :arm64 to multi-arch packages
    want = noepoch(re.sub(r"\+b\d+$", "", ver))
    cands = by_bin.get(name, [])
    # Debian's signed kernel sources are versioned X+N for the binaries' X-N
    exact = [c for c in cands if noepoch(c[1]) == want or re.sub(r"\+(\d+)$", r"-\1", c[1]) == want]
    if exact:
        print(f"{name}\t{ver}\t{exact[0][0]}\t{exact[0][1]}\texact")
    elif cands:
        # prefer a source whose version is part of the binary version (login 1:4.16.0-2+really2.41.5-0+deb13u1)
        inside = [c for c in cands if noepoch(c[1]) in ver]
        pool = inside or cands
        c = sorted(pool, key=functools.cmp_to_key(cmp))[-1]
        print(f"{name}\t{ver}\t{c[0]}\t{c[1]}\tversion-differs")
    else:
        print(f"{name}\t{ver}\t-\t-\ttuxedo-or-unknown")
        continue
    # the signed kernel package holds only signatures: its code is in the source package "linux"
    src = (exact or [c])[0][0] if exact else c[0]
    if src.startswith("linux-signed-") and want in versions_of.get("linux", ()):
        print(f"{name}\t{ver}\tlinux\t{want}\texact")
PY
    KINDS="$KINDS $k"
done
[ -n "$KINDS" ] || die "no image manifest in /out; run tools/linux/build-image.sh"

cp /tools/package-source-fetch.sh "$N/fetch-source.sh"
chmod 755 "$N/fetch-source.sh"
sed -i "s|@SNAP_URL@|$SNAP_URL|; s|@SEC_URL@|$SEC_URL|; s|@SUITE@|$DEBIAN_SUITE|" "$N/fetch-source.sh"

HASHES=
for k in $KINDS; do
    HASHES="$HASHES
  debian-$k: SHA-256 $(sed -n 's/^image_sha256=//p' "$N/debian-$k.manifest"), kernel $(sed -n 's/^kernel_version=//p' "$N/debian-$k.manifest")"
done
cat > "$N/README.txt" <<EOF
The Tuxedo Debian images: where the source of their software is.

The images are made by mmdebstrap from Debian $DEBIAN_SUITE (component main only), with every package taken from this
snapshot of the Debian archive:
  $SNAP_URL
The images this covers:$HASHES

Files here:
debian-<kind>.manifest   the build record of an image: the snapshot, the kernel, extlinux.conf, the image's SHA-256 and
                         every binary package with its version
SOURCES-<kind>.txt       for each binary package in the image, the Debian source package and version it came from
                         (the last column is "exact" when the versions agree, "version-differs" when the closest version in
                         the snapshot was taken, and "tuxedo-or-unknown" for a package that is not in Debian)
fetch-source.sh          downloads the source of every package in SOURCES-*.txt from the snapshot into a folder
SHA256SUMS               the SHA-256 of each file here

Licences. Each package has its own. The text is in /usr/share/doc/<package>/copyright inside the image. The kernel is
Debian's linux-image-arm64-16k (GPL-2.0 with the Linux syscall exception); its source package is linux.

Source of a Debian package. It comes from the same snapshot, from Debian, unchanged. To fetch all of it:
  sh fetch-source.sh DEST        (needs apt-get and the debian-archive-keyring package)
  sh fetch-source.sh DEST linux  (only the named source packages)
To fetch one package by hand, on a Debian system:
  echo 'deb-src [check-valid-until=no] ${SNAP_URL} $DEBIAN_SUITE main' | sudo tee /etc/apt/sources.list.d/tux-src.list
  sudo apt-get update -o Acquire::Check-Valid-Until=false
  apt-get source PACKAGE=VERSION
snapshot.debian.org is run by Debian. If it is down, ask for the source as described below.

Tuxedo packages. The source of tux-guest, tux-va and tux-codec-dkms is in the Tuxedo repository, under tools/linux.
tux-ffmpeg has its own offer, at $URL/source/.

$OFFER
EOF
(cd "$N" && sha256sum README.txt fetch-source.sh $(for k in $KINDS; do echo "debian-$k.manifest SOURCES-$k.txt"; done) > SHA256SUMS)
publish_dir "$N" "/out/source/$D" "SOURCES-$(echo $KINDS | cut -d' ' -f1).txt"

for k in $KINDS; do
    echo "$D: $k: $(grep -c 'exact$' "/out/source/$D/SOURCES-$k.txt" || true) exact," \
        "$(grep -c 'version-differs$' "/out/source/$D/SOURCES-$k.txt" || true) version-differs," \
        "$(grep -c 'tuxedo-or-unknown$' "/out/source/$D/SOURCES-$k.txt" || true) not in Debian"
done
[ -n "$CONTACT" ] || echo "TUX_SOURCE_CONTACT is not set: the offers say to ask whoever runs $URL"
