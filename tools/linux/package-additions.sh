#!/bin/sh
# The Tuxedo Additions media, built on the Mac (docs/guest-additions-design.md, section 4):
#   $TUX_LINUX_OUT/additions/tux-additions/   install, agent, tux_additions_caps.py, actions.json, versions.json,
#     install-order.txt, README.txt, desktop-labwc/, desktop-plasma/, SHA256SUMS, SHA256SUMS.gpg, tux-archive.gpg, source/SOURCES.txt,
#     apt/ (a signed apt repository: main = the four Tuxedo debs, deps = the Debian debs a minbase guest with systemd lacks, plus
#     openssh-server and what it needs, from the pinned snapshot; no Valid-Until in Release)
# The debs come from where the other scripts put them: tux-ffmpeg (build-ffmpeg-pkg.sh), tux-va, tux-codec-dkms, and a
# tux-guest that is built now. The media is the same on every build apart from the signatures: SOURCE_DATE_EPOCH is
# the time of the last commit, unless you set it. The Debian downloads are kept in $OUT/additions/cache.
# The private key is only in $TUX_APT_GNUPGHOME (default ~/.tux-apt-key); it never goes into the tree.
# Nothing leaves the Mac. After the build, a container with no network installs from the media into a minbase root.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/versions.env"
SUITE=$DEBIAN_SUITE
ADDITIONS_REV=1
DEPS_MAX_BYTES=25000000
EXTRA_DEPS="openssh-server"
die() { echo "package-additions.sh: $*" >&2; exit 1; }

if [ "${1:-}" = --inner ]; then
    # In an arm64 debian:trixie container: /add the work folder (stage/ the debs, cache/, new/ the tree), /src the repository.
    APT_PKGS="apt-utils xz-utils mmdebstrap python3"
    . /src/tools/linux/snapshot-apt.sh
    export LC_ALL=C
    A=/src/tools/linux/additions
    T=/add/new
    D=$T/apt/dists/$SUITE
    rm -rf "$T"
    mkdir -p "$T/apt/pool/main" "$T/apt/pool/deps" "$T/source"

    # the files of the agent and the session files
    cp "$A/install" "$A/agent" "$A/actions.json" "$A/tux_additions_caps.py" "$T/"
    (cd "$A" && find desktop-labwc desktop-plasma -type f ! -name .DS_Store | LC_ALL=C sort | while read -r f; do
        mkdir -p "$T/$(dirname "$f")" && cp "$f" "$T/$f"; done)

    # main: the four Tuxedo debs and nothing else
    n=0
    for deb in /add/stage/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package)
        case $pkg in tux-guest|tux-va|tux-ffmpeg|tux-codec-dkms) ;; *) die "$deb is not a Tuxedo package" ;; esac
        mkdir -p "$T/apt/pool/main/$(echo "$pkg" | cut -c1)/$pkg"
        cp "$deb" "$T/apt/pool/main/$(echo "$pkg" | cut -c1)/$pkg/"
        n=$((n + 1))
    done
    [ $n -eq 4 ] || die "/add/stage has $n debs, not 4 (tux-guest, tux-va, tux-ffmpeg, tux-codec-dkms)"

    index() {
        for arch in arm64 all; do
            mkdir -p "$D/$1/binary-$arch"
            (cd "$T/apt" && apt-ftparchive --arch "$arch" packages "pool/$1") > "$D/$1/binary-$arch/Packages"
            xz -9 -k -T1 -f "$D/$1/binary-$arch/Packages"
        done
    }
    release() {
        apt-ftparchive -o APT::FTPArchive::Release::Origin=Tuxedo -o APT::FTPArchive::Release::Label=Tuxedo \
            -o APT::FTPArchive::Release::Suite="$SUITE" -o APT::FTPArchive::Release::Codename="$SUITE" \
            -o APT::FTPArchive::Release::Architectures="arm64 all" -o APT::FTPArchive::Release::Components="$1" \
            -o APT::FTPArchive::Release::Description="Tuxedo Additions" release "$D" > /tmp/Release
        # the date of the build, so two builds give the same file (the hashes do not cover this line)
        sed -i "s/^Date: .*/Date: $(date -u -R -d "@$SOURCE_DATE_EPOCH")/" /tmp/Release
        mv /tmp/Release "$D/Release"
    }
    index main
    release main

    # The Debian closure. The cache key is everything that decides it.
    KEY=$( (for deb in /add/stage/*.deb; do dpkg-deb -f "$deb" Package Version Depends Pre-Depends; done | LC_ALL=C sort
            echo "$DEBIAN_SNAPSHOT $DEBIAN_SUITE $EXTRA_DEPS minbase+systemd-sysv v2") | sha256sum | cut -c1-16)
    C=/add/cache/$KEY
    echo "$KEY" > /add/cache-key
    if [ ! -f "$C/done" ]; then
        echo "computing the Debian closure ($KEY)"
        rm -rf "$C" && mkdir -p "$C/deps"
        W=$(mktemp -d)
        # minbase plus the init system: a guest that boots has systemd, and tux-guest needs it
        mmdebstrap --mode=root --variant=minbase --include=systemd-sysv --arch=arm64 --aptopt='Acquire::Check-Valid-Until "false"' \
            "$DEBIAN_SUITE" "$C/minbase.tar" "deb $SNAP $DEBIAN_SUITE main" >/dev/null
        tar -xOf "$C/minbase.tar" ./var/lib/dpkg/status > "$C/minbase.status"
        mkdir -p "$W/lists/partial" "$W/cache/archives/partial"
        KR=/usr/share/keyrings/debian-archive-keyring.gpg
        cat > "$W/sources.list" <<EOF
deb [trusted=yes] file:$T/apt $SUITE main
deb [signed-by=$KR] $SNAP $SUITE main
deb [signed-by=$KR] $SNAP $SUITE-updates main
deb [signed-by=$KR] $SNAP_SEC $SUITE-security main
EOF
        aptq() {
            apt-get -o Dir::State::status="$C/minbase.status" -o Dir::State::lists="$W/lists" -o Dir::Cache="$W/cache" \
                -o Dir::Etc::sourcelist="$W/sources.list" -o Dir::Etc::sourceparts=- -o Debug::NoLocking=1 \
                -o Acquire::Check-Valid-Until=false -o APT::Color=0 -o Acquire::Retries=5 "$@"
        }
        aptq update >/dev/null
        # the order apt would install the three packages in: the order for dpkg
        aptq -s install --no-install-recommends tux-guest tux-va tux-ffmpeg | awk '/^Inst / { print $2 }' > "$C/order.txt"
        aptq install --print-uris -y --no-install-recommends tux-guest tux-va tux-ffmpeg $EXTRA_DEPS |
            sed -n "s/^'\\(http[^']*\\)' .*/\\1/p" | LC_ALL=C sort > "$C/uris.txt"
        aptq install --download-only -y --no-install-recommends tux-guest tux-va tux-ffmpeg $EXTRA_DEPS >/dev/null
        for deb in "$W"/cache/archives/*.deb; do
            pkg=$(dpkg-deb -f "$deb" Package)
            case $pkg in tux-*) continue ;; esac
            ver=$(dpkg-deb -f "$deb" Version | sed 's/^[0-9]*://')
            cp "$deb" "$C/deps/${pkg}_${ver}_$(dpkg-deb -f "$deb" Architecture).deb"
        done
        rm -rf "$W"
        touch "$C/done"
    fi

    # deps: the cached debs, in the pool by package name
    for deb in "$C"/deps/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package)
        case $pkg in lib?*) pre=$(echo "$pkg" | cut -c1-4) ;; *) pre=$(echo "$pkg" | cut -c1) ;; esac
        mkdir -p "$T/apt/pool/deps/$pre/$pkg"
        cp "$deb" "$T/apt/pool/deps/$pre/$pkg/"
    done
    DEPS_BYTES=$(find "$T/apt/pool/deps" -type f -name '*.deb' -exec stat -c %s {} + | awk '{ s += $1 } END { print s + 0 }')
    echo "deps: $(find "$T/apt/pool/deps" -type f | wc -l) debs, $DEPS_BYTES bytes (limit $DEPS_MAX_BYTES)"
    if [ "$DEPS_BYTES" -gt "$DEPS_MAX_BYTES" ]; then
        find "$T/apt/pool/deps" -type f -exec stat -c '%s %n' {} + | sort -rn | head -n 10 >&2
        die "the Debian packages are $DEPS_BYTES bytes, more than $DEPS_MAX_BYTES"
    fi
    index deps
    release "main deps"

    DEPS_BYTES=$DEPS_BYTES CACHE=$C python3 - <<'PY'
import json, os, subprocess, re, datetime
T, C = "/add/new", os.environ["CACHE"]
epoch = int(os.environ["SOURCE_DATE_EPOCH"])
built = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%d/%m/%Y")
snap, rev = os.environ["DEBIAN_SNAPSHOT"], os.environ["ADDITIONS_REV"]

def field(deb, f):
    return subprocess.check_output(["dpkg-deb", "-f", deb, f], text=True).strip()

debs = {}  # package -> (relative path in the tree, version, arch, source)
for comp in ("main", "deps"):
    for dp, _, fs in os.walk(os.path.join(T, "apt/pool", comp)):
        for f in fs:
            p = os.path.join(dp, f)
            debs[field(p, "Package")] = (os.path.relpath(p, os.path.join(T, "apt")), field(p, "Version"),
                                         field(p, "Architecture"), p)
order = [l.strip() for l in open(C + "/order.txt") if l.strip()]
missing = [n for n in order if n not in debs]
if missing:
    raise SystemExit("package-additions.sh: the install order names debs that are not in the pool: %s" % missing)
# a package apt would upgrade in minbase is in the pool; a tux package comes last, in apt's order
rel_order = [debs[n][0] for n in order]
guest = debs["tux-guest"][1]
versions = {
    "additions": "%s+%s" % (guest, rev),
    "arch": "arm64",
    "built": built,
    "deps_baseline": "mmdebstrap minbase + systemd-sysv, %s @ %s" % (os.environ["DEBIAN_SUITE"], snap),
    "deps_bytes": int(os.environ["DEPS_BYTES"]),
    "deps_count": sum(1 for v in debs.values() if v[0].startswith("pool/deps/")),
    "deps_order": rel_order,
    "optional": ["tux-codec-dkms"],  # install skips it on a stock image (it needs dkms, gcc and the headers): never "missing"
    "packages": {p: debs[p][1] for p in ("tux-guest", "tux-va", "tux-ffmpeg", "tux-codec-dkms")},
    "protocol": json.load(open(T + "/actions.json"))["protocol"],
    "snapshot": snap,
    "suite": os.environ["DEBIAN_SUITE"],
}
with open(T + "/versions.json", "w") as f:
    json.dump(versions, f, indent=1, sort_keys=True)
    f.write("\n")
with open(T + "/install-order.txt", "w") as f:
    f.write("".join(r + "\n" for r in rel_order))

uris = {}
for u in open(C + "/uris.txt"):
    u = u.strip()
    m = re.match(r"^(http\S*/)([^/]+)_([^/_]+)_[^/_]+\.deb$", u)
    if m:
        uris[m.group(2)] = m.group(1)
lines = ["Tuxedo Additions %s: where the source of each package is." % versions["additions"], "",
         "Tuxedo packages (GPL-2.0-or-later; the tux-ffmpeg binaries are GPL because of libx264 and libx265):",
         "  tux-guest, tux-va, tux-codec-dkms   the Tuxedo repository, and the files inside each package (scripts and C source)",
         "  tux-ffmpeg %s   %s/source/ffmpeg-%s/" % (debs["tux-ffmpeg"][1], os.environ["TUX_APT_URL"], debs["tux-ffmpeg"][1]),
         "", "Debian packages in apt/pool/deps, from the snapshot of %s (snapshot.debian.org)." % snap,
         "Each folder below holds the binary and the source of its package (the .dsc, the original tarball and the Debian changes).",
         "To get one source: apt-get source <source package>=<version> with a deb-src line for the snapshot, or download from the folder.", ""]
for name in sorted(n for n, v in debs.items() if v[0].startswith("pool/deps/")):
    rel, ver, arch, p = debs[name]
    try:
        src = field(p, "Source").split(" ")[0]
    except subprocess.CalledProcessError:
        src = name
    lines.append("  %s %s (source package %s): %s" % (name, ver, src or name, uris.get(name, "https://snapshot.debian.org/archive/debian/%s/pool/main/" % snap)))
with open(T + "/source/SOURCES.txt", "w") as f:
    f.write("\n".join(lines) + "\n")
PY

    GUEST_VER=$(dpkg-deb -f "$T"/apt/pool/main/t/tux-guest/*.deb Version)
    FFMPEG_VER=$(dpkg-deb -f "$T"/apt/pool/main/t/tux-ffmpeg/*.deb Version)
    sed -e "s|@ADDITIONS_VERSION@|$GUEST_VER+$ADDITIONS_REV|g" -e "s|@BUILT@|$(date -u -d "@$SOURCE_DATE_EPOCH" +%d/%m/%Y)|g" \
        -e "s|@FFMPEG_RELEASE@|$FFMPEG_VERSION|g" -e "s|@FFMPEG_VERSION@|$FFMPEG_VER|g" \
        -e "s|@SOURCE_URL@|$TUX_APT_URL|g" "$A/README.txt" > "$T/README.txt"

    # modes: the same on every build
    find "$T" -type d -exec chmod 0755 {} +
    find "$T" -type f -exec chmod 0644 {} +
    chmod 0755 "$T/install" "$T/agent" "$T/tux_additions_caps.py"
    exit 0
fi

if [ "${1:-}" = --inner-verify ]; then
    # In an arm64 debian:trixie container with no network: the media installs into a minbase root. /add/new is the media.
    export LC_ALL=C
    T=/add/new
    C=/add/cache/$(cat /add/cache-key)
    cd "$T"
    sqv --keyring ./tux-archive.gpg SHA256SUMS.gpg SHA256SUMS >/dev/null || die "SHA256SUMS.gpg does not verify"
    sha256sum -c --strict --quiet SHA256SUMS || die "SHA256SUMS does not match the tree"
    R=/tmp/root
    mkdir -p "$R" && tar -xf "$C/minbase.tar" -C "$R"
    mkdir -p "$R/mnt/tux" && cp -R "$T" "$R/mnt/tux/tux-additions"
    # old henge-* packages stop it with exit 3, another system with exit 2; neither changes anything
    cp "$R/var/lib/dpkg/status" /tmp/status.orig
    printf 'Package: henge-guest\nStatus: install ok installed\nPriority: optional\nSection: admin\nMaintainer: x\nArchitecture: all\nVersion: 1.0\nDescription: fake\n\n' >> "$R/var/lib/dpkg/status"
    rc=0
    chroot "$R" sh /mnt/tux/tux-additions/install > /tmp/legacy.log 2>&1 || rc=$?
    [ "$rc" = 3 ] || { cat /tmp/legacy.log >&2; die "old henge packages gave exit $rc, not 3"; }
    cp /tmp/status.orig "$R/var/lib/dpkg/status"
    rm "$R/etc/os-release" && printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$R/etc/os-release"
    rc=0
    chroot "$R" sh /mnt/tux/tux-additions/install > /tmp/os.log 2>&1 || rc=$?
    [ "$rc" = 2 ] || { cat /tmp/os.log >&2; die "another system gave exit $rc, not 2"; }
    rm "$R/etc/os-release" && ln -s ../usr/lib/os-release "$R/etc/os-release"
    [ ! -e "$R/var/lib/dpkg/info/tux-guest.list" ] || die "a refused install changed the system"
    # a fresh minbase has no key: install trusts the media's key once
    chroot "$R" sh /mnt/tux/tux-additions/install > /tmp/install1.log 2>&1 || { cat /tmp/install1.log >&2; die "install failed in the minbase root"; }
    cat /tmp/install1.log
    for p in tux-guest tux-va tux-ffmpeg; do
        chroot "$R" dpkg-query -W -f='${Status}' "$p" | grep -q 'install ok installed' || die "$p is not installed"
    done
    [ -e "$R/usr/share/keyrings/tux-archive.gpg" ] || die "the key is not installed"
    [ ! -e "$R/var/lib/tux-additions" ] || die "install left /var/lib/tux-additions"
    # a second run changes nothing
    chroot "$R" sh /mnt/tux/tux-additions/install > /tmp/install2.log 2>&1 || { cat /tmp/install2.log >&2; die "the second install failed"; }
    grep -q 'nothing to do' /tmp/install2.log || { cat /tmp/install2.log >&2; die "the second install did not say nothing to do"; }
    # one changed byte stops it with exit 4
    printf 'x' >> "$R/mnt/tux/tux-additions/agent"
    rc=0
    chroot "$R" sh /mnt/tux/tux-additions/install > /tmp/install3.log 2>&1 || rc=$?
    [ "$rc" = 4 ] || { cat /tmp/install3.log >&2; die "a changed file gave exit $rc, not 4"; }
    truncate -s -1 "$R/mnt/tux/tux-additions/agent"
    # a link (or any file that is not plain) stops it with exit 4, even when it is not in SHA256SUMS
    ln -s /etc/passwd "$R/mnt/tux/tux-additions/apt/evil"
    rc=0
    chroot "$R" sh /mnt/tux/tux-additions/install > /tmp/install4.log 2>&1 || rc=$?
    [ "$rc" = 4 ] || { cat /tmp/install4.log >&2; die "a link in the media gave exit $rc, not 4"; }
    grep -q 'not a plain file' /tmp/install4.log || { cat /tmp/install4.log >&2; die "the link was not refused for being a link"; }
    rm "$R/mnt/tux/tux-additions/apt/evil"
    [ ! -e "$R/var/lib/tux-additions" ] || die "a refused install left /var/lib/tux-additions"
    # openssh-server from the media's repository, with no network
    mkdir -p "$R/var/lib/tux-additions/lists/partial"
    echo "deb [signed-by=/usr/share/keyrings/tux-archive.gpg] file:/mnt/tux/tux-additions/apt $SUITE main deps" > "$R/tmp/sources.list"
    chroot "$R" apt-get -q -o Dir::Etc::sourcelist=/tmp/sources.list -o Dir::Etc::sourceparts=- \
        -o Dir::State::lists=/var/lib/tux-additions/lists update >/dev/null || die "apt update from the media failed"
    chroot "$R" env DEBIAN_FRONTEND=noninteractive apt-get -q -y -o Dir::Etc::sourcelist=/tmp/sources.list \
        -o Dir::Etc::sourceparts=- -o Dir::State::lists=/var/lib/tux-additions/lists \
        install --no-install-recommends openssh-server >/dev/null || die "openssh-server did not install from the media"
    chroot "$R" dpkg-query -W -f='${Status}\n' openssh-server | grep -q 'install ok installed' || die "openssh-server is not installed"
    # the caps of the guest, on a real Debian
    chroot "$R" python3 /mnt/tux/tux-additions/tux_additions_caps.py --print > /tmp/caps.json || die "tux_additions_caps.py --print failed"
    chroot "$R" python3 -c "
import json, sys
c = json.load(sys.stdin)
assert c['installed']['tux-guest'] and c['installed']['tux-ffmpeg'], c['installed']
assert c['ssh']['installed'] is True and c['legacy'] is False, c
print('caps ok:', c['installed'], 'ssh', c['ssh'])" < /tmp/caps.json
    echo "verified: the media installs into a minbase root with no network"
    exit 0
fi

OUT=${TUX_LINUX_OUT:-$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
ADD=$OUT/additions
TREE=$ADD/tux-additions
GNUPGHOME=${TUX_APT_GNUPGHOME:-$HOME/.tux-apt-key}
TUX_APT_URL=${TUX_APT_URL:-https://walkies.site/tux-linux-catalogue}
KEYRING=$HERE/tux-guest/usr/share/keyrings/tux-archive.gpg
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)}
FFDEB=$OUT/ffmpeg/tux-ffmpeg_${FFMPEG_VERSION}-tux${FFMPEG_TUX_REV}_arm64.deb
CODECDEB=$OUT/codec/tux-codec-dkms_$(sed -n 's/^Version: //p' "$HERE/tux-codec-dkms/DEBIAN/control")_all.deb
VADEB=$OUT/va/tux-va_$(sed -n 's/^Version: //p' "$HERE/tux-va/DEBIAN/control")_arm64.deb
hgpg() { gpg --homedir "$GNUPGHOME" --batch "$@"; }

FPR=$(hgpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
[ -n "$FPR" ] || die "no signing key in $GNUPGHOME; set TUX_APT_GNUPGHOME (publish-apt.sh --new-key makes one)"
KFPR=$(gpg --with-colons --show-keys "$KEYRING" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
[ "$KFPR" = "$FPR" ] || die "$KEYRING is not the key in $GNUPGHOME ($FPR)"
[ -f "$FFDEB" ] || die "no $FFDEB; run make linux-ffmpeg-pkg"
[ -f "$CODECDEB" ] || die "no $CODECDEB; run make linux-codec-dkms"
[ -f "$VADEB" ] || die "no $VADEB; run make linux-va-pkg"

mkdir -p "$ADD"
STAGE=$ADD/stage
rm -rf "$STAGE" "$ADD/new" && mkdir -p "$STAGE"
TUX_LINUX_OUT=$STAGE "$HERE/build-guest-pkg.sh" >/dev/null
cp "$FFDEB" "$CODECDEB" "$VADEB" "$STAGE/"

drun() {
    docker run --rm -i --platform linux/arm64 -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e TUX_APT_URL="$TUX_APT_URL" \
        -e ADDITIONS_REV="$ADDITIONS_REV" -e DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" -e DEBIAN_SUITE="$DEBIAN_SUITE" \
        -v "$ADD":/add -v "$ROOT":/src:ro "$@"
}
drun debian:trixie sh /src/tools/linux/package-additions.sh --inner

# Signatures and sums: on the Mac, with the key
N=$ADD/new
D=$N/apt/dists/$SUITE
hgpg --yes --local-user "$FPR" --digest-algo SHA512 --clearsign -o "$D/InRelease" "$D/Release"
hgpg --yes --local-user "$FPR" --digest-algo SHA512 --armor --detach-sign -o "$D/Release.gpg" "$D/Release"
gpgv --keyring "$KEYRING" "$D/InRelease" 2>/dev/null || die "InRelease does not verify against $KEYRING"
gpgv --keyring "$KEYRING" "$D/Release.gpg" "$D/Release" 2>/dev/null || die "Release.gpg does not verify against $KEYRING"
cp "$KEYRING" "$N/tux-archive.gpg"
(cd "$N" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.gpg | sed 's|^\./||' | LC_ALL=C sort |
    while read -r f; do shasum -a 256 "$f"; done > SHA256SUMS)
hgpg --yes --local-user "$FPR" --digest-algo SHA512 --detach-sign -o "$N/SHA256SUMS.gpg" "$N/SHA256SUMS"
gpgv --keyring "$KEYRING" "$N/SHA256SUMS.gpg" "$N/SHA256SUMS" 2>/dev/null || die "SHA256SUMS.gpg does not verify against $KEYRING"
(cd "$N" && shasum -a 256 -c --quiet SHA256SUMS) || die "SHA256SUMS does not match the tree"
gpgconf --homedir "$GNUPGHOME" --kill gpg-agent 2>/dev/null || true

drun --network none debian:trixie sh /src/tools/linux/package-additions.sh --inner-verify

rm -rf "$TREE" "$STAGE"
mv "$N" "$TREE"
echo "signed with $FPR"
echo "the media is in $TREE"
echo "size: $(du -sk "$TREE" | cut -f1) kB in all; apt/pool/main $(du -sk "$TREE/apt/pool/main" | cut -f1) kB; apt/pool/deps $(du -sk "$TREE/apt/pool/deps" | cut -f1) kB"
