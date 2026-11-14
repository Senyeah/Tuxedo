#!/bin/sh
# The Tuxedo apt repository and the source offer, built on the Mac (docs/guest-video-encode-plan.md, VE3.3):
#   $OUT/apt     dists/trixie/{Release,InRelease,Release.gpg}, main/binary-{arm64,all}, pool/main/h/<package>/,
#                henge-archive.asc
#   $OUT/source  ffmpeg-<release>-henge<N>/: the FFmpeg tarball, the patch, build-ffmpeg.sh, ffmpeg.manifest, the Tuxedo
#                files of the build (henge-ffmpeg-src.tar.xz), README.txt, SHA256SUMS
# It adds henge-ffmpeg (build-ffmpeg-pkg.sh), henge-codec-dkms (build-codec-dkms-pkg.sh), henge-va (build-va-pkg.sh)
# and henge-guest (built now)
# to the pool. A pool file is never replaced
# with other content: raise the version instead. Each henge-ffmpeg in the pool must have its source directory.
# The private key is only in $TUX_APT_GNUPGHOME (default ~/.henge-apt-key), never in the repository.
#
#   publish-apt.sh [--new-key] [--rsync] [--check-remote]
#     --new-key       make the signing key if there is none, and write its public part into the repository
#     --rsync         copy apt/ and source/ to $TUX_APT_REMOTE with rsync over ssh, then --check-remote
#     --check-remote  download InRelease from $TUX_APT_URL, check its signature, and compare each .deb and SHA256SUMS
# Without --rsync or --check-remote nothing leaves the Mac.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/versions.env"
SUITE=$DEBIAN_SUITE
VER=$FFMPEG_VERSION-henge$FFMPEG_TUX_REV
die() { echo "publish-apt.sh: $*" >&2; exit 1; }

if [ "${1:-}" = --inner ]; then
    # In an arm64 debian:trixie container: /out the artefacts, /stage the new debs, /src the repository.
    APT_PKGS="apt-utils xz-utils"
    . /src/tools/linux/snapshot-apt.sh
    export SOURCE_DATE_EPOCH=1762905600
    A=/out/apt
    for deb in /stage/*.deb; do
        pkg=$(dpkg-deb -f "$deb" Package)
        dest=$A/pool/main/$(echo "$pkg" | cut -c1)/$pkg/$(basename "$deb")
        if [ -e "$dest" ]; then
            cmp -s "$deb" "$dest" ||
                die "$dest is in the pool with other content; raise the version of $pkg (published files never change)"
        else
            mkdir -p "$(dirname "$dest")"
            cp "$deb" "$dest.part" && mv "$dest.part" "$dest"
            echo "added $dest"
        fi
    done

    # The source offer for this henge-ffmpeg: fixed names and times, so a rebuild gives the same files.
    S=/out/source/ffmpeg-$VER
    N=$(mktemp -d)/ffmpeg-$VER
    mkdir -p "$N"
    cp "/out/ffmpeg/src/ffmpeg-$FFMPEG_VERSION.tar.xz" /out/ffmpeg/ffmpeg.manifest "$N/"
    cp /src/tools/linux/hvcodec/ffmpeg-henge.patch /src/tools/linux/build-ffmpeg.sh "$N/"
    [ "$(sha256sum "$N/ffmpeg-$FFMPEG_VERSION.tar.xz" | cut -d' ' -f1)" = "$FFMPEG_SHA256" ] || die "the FFmpeg tarball is not FFMPEG_SHA256"
    [ "$(sed -n 's/^patch_sha256=//p' "$N/ffmpeg.manifest")" = "$(sha256sum "$N/ffmpeg-henge.patch" | cut -d' ' -f1)" ] ||
        die "ffmpeg.manifest is not from this patch; run make linux-ffmpeg linux-ffmpeg-pkg"
    (cd /src && tar --sort=name --mtime=@$SOURCE_DATE_EPOCH --owner=0 --group=0 --numeric-owner --mode=u+rwX,go+rX,go-w \
        -cf - LICENSE host/vcodec_proto.h host/vcodec_dev.h tools/linux/versions.env tools/linux/snapshot-apt.sh tools/linux/build-ffmpeg.sh \
        tools/linux/build-ffmpeg-pkg.sh tools/linux/henge-ffmpeg tools/linux/hvcodec/ffmpeg-henge.patch \
        tools/linux/hvcodec/ffmpeg-henge.7.md tools/linux/hvcodec/manpage-check.py tools/linux/hvcodec/henge-codec-info.c \
        tools/linux/hvcodec/libhvcodec) | xz -9 -T1 > "$N/henge-ffmpeg-src.tar.xz"
    cat > "$N/README.txt" <<EOF
henge-ffmpeg $VER: the source of the binaries in henge-ffmpeg_${VER}_arm64.deb.

ffmpeg-$FFMPEG_VERSION.tar.xz   the unmodified FFmpeg release (https://ffmpeg.org/releases/)
ffmpeg-henge.patch          the Henge patch to it
build-ffmpeg.sh             the build script
henge-ffmpeg-src.tar.xz     the Henge files of the build, at their places in the Henge repository:
                            libhvcodec, henge-codec-info, vcodec_proto.h, vcodec_dev.h, the man page, the package scripts
ffmpeg.manifest             the hashes of each part, the configure line, and the Debian package versions
SHA256SUMS                  the SHA-256 of each file here

To build: unpack henge-ffmpeg-src.tar.xz, put ffmpeg-$FFMPEG_VERSION.tar.xz in build/linux/ffmpeg/src/, and run
TUX_LINUX_OUT=\$PWD/build/linux tools/linux/build-ffmpeg.sh, then tools/linux/build-ffmpeg-pkg.sh. They need Docker
with arm64 containers. The Debian packages come from snapshot.debian.org at the time in versions.env.
EOF
    (cd "$N" && sha256sum ffmpeg-$FFMPEG_VERSION.tar.xz ffmpeg-henge.patch build-ffmpeg.sh henge-ffmpeg-src.tar.xz ffmpeg.manifest README.txt > SHA256SUMS)
    if [ -d "$S" ]; then
        # The manifest holds the binaries' hashes. A change only to other files of the offer (LICENSE, the U-Boot line
        # of versions.env) keeps the published directory: it is still the source of those binaries.
        # A changed man page or package script changes the .deb, and the pool step above stops that.
        cmp -s "$N/ffmpeg.manifest" "$S/ffmpeg.manifest" ||
            die "$S has another ffmpeg.manifest; the build changed, so raise FFMPEG_TUX_REV"
        cmp -s "$N/SHA256SUMS" "$S/SHA256SUMS" ||
            echo "kept $S (same binaries; these files of the offer changed since:" \
                "$(grep -vxF -f "$S/SHA256SUMS" "$N/SHA256SUMS" | awk '{print $2}' | tr '\n' ' '| sed 's/ $//'))"
    else
        mkdir -p /out/source && mv "$N" "$S"
        echo "added $S"
    fi

    # GPL: each henge-ffmpeg in the pool has the source directory of its own build
    for deb in "$A"/pool/main/h/henge-ffmpeg/*.deb; do
        [ -e "$deb" ] || continue
        m=$(mktemp)
        dpkg-deb --fsys-tarfile "$deb" | tar -xOf - ./usr/share/doc/henge-ffmpeg/ffmpeg.manifest > "$m"
        d=/out/source/ffmpeg-$(sed -n 's/^release=//p' "$m")-henge$(sed -n 's/^henge_rev=//p' "$m")
        cmp -s "$m" "$d/ffmpeg.manifest" || die "$(basename "$deb") has no source directory with its manifest ($d)"
    done

    D=$A/dists/$SUITE
    rm -rf "$D"
    for arch in arm64 all; do
        mkdir -p "$D/main/binary-$arch"
        (cd "$A" && apt-ftparchive --arch "$arch" packages pool/main) > "$D/main/binary-$arch/Packages"
        gzip -9n -k "$D/main/binary-$arch/Packages"
        xz -9 -k "$D/main/binary-$arch/Packages"
    done
    apt-ftparchive -o APT::FTPArchive::Release::Origin=Henge -o APT::FTPArchive::Release::Label=Henge \
        -o APT::FTPArchive::Release::Suite="$SUITE" -o APT::FTPArchive::Release::Codename="$SUITE" \
        -o APT::FTPArchive::Release::Architectures="arm64 all" -o APT::FTPArchive::Release::Components=main \
        -o APT::FTPArchive::Release::Description="Henge guest packages" release "$D" > /tmp/Release
    mv /tmp/Release "$D/Release"
    for arch in arm64 all; do
        echo "binary-$arch: $(grep -c '^Package:' "$D/main/binary-$arch/Packages") packages"
    done
    exit 0
fi

NEW_KEY=0 RSYNC=0 CHECK=0
for a in "$@"; do
    case $a in
        --new-key) NEW_KEY=1 ;;
        --rsync) RSYNC=1 CHECK=1 ;;
        --check-remote) CHECK=1 ;;
        *) die "unknown argument $a (see the top of $0)" ;;
    esac
done

OUT=${TUX_LINUX_OUT:-$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}
GNUPGHOME=${TUX_APT_GNUPGHOME:-$HOME/.henge-apt-key}
REMOTE=${TUX_APT_REMOTE:-root@walkies.site:/home/USER/henge-linux-catalogue/files}
URL=${TUX_APT_URL:-https://walkies.site/henge-linux-catalogue}
PUBKEY=$HERE/henge-archive.asc
KEYRING=$HERE/henge-guest/usr/share/keyrings/henge-archive.gpg
FFDEB=$OUT/ffmpeg/henge-ffmpeg_${VER}_arm64.deb
CODECDEB=$OUT/codec/henge-codec-dkms_$(sed -n 's/^Version: //p' "$HERE/henge-codec-dkms/DEBIAN/control")_all.deb
VADEB=$OUT/va/henge-va_$(sed -n 's/^Version: //p' "$HERE/henge-va/DEBIAN/control")_arm64.deb
hgpg() { gpg --homedir "$GNUPGHOME" --batch "$@"; }
fpr_of() { hgpg --with-colons --show-keys "$1" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}'; }

if [ $NEW_KEY = 1 ] && ! hgpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
    # No passphrase, so the script can sign; the directory is the protection. gpg --passwd adds one.
    hgpg --pinentry-mode loopback --passphrase '' --quick-gen-key "Henge apt repository <henge@localhost>" ed25519 sign never
    F=$(hgpg --list-secret-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')
    hgpg --armor --export "$F" > "$PUBKEY"
    mkdir -p "$(dirname "$KEYRING")"
    hgpg --export "$F" > "$KEYRING"
    echo "new key $F in $GNUPGHOME; its public part is in $PUBKEY and $KEYRING (commit those two)"
fi
FPR=$(hgpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
[ -n "$FPR" ] || die "no signing key in $GNUPGHOME; run with --new-key, or set TUX_APT_GNUPGHOME"
[ "$(fpr_of "$PUBKEY")" = "$FPR" ] && [ "$(fpr_of "$KEYRING")" = "$FPR" ] ||
    die "$PUBKEY or $KEYRING is not the key in $GNUPGHOME ($FPR)"

if [ $RSYNC = 0 ] && [ $CHECK = 1 ]; then
    :
else
    [ -f "$FFDEB" ] || die "no $FFDEB; run make linux-ffmpeg-pkg"
    [ -f "$CODECDEB" ] || die "no $CODECDEB; run make linux-codec-dkms"
    [ -f "$VADEB" ] || die "no $VADEB; run make linux-va-pkg"
    STAGE=$OUT/apt-stage
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    TUX_LINUX_OUT=$STAGE "$HERE/build-guest-pkg.sh" >/dev/null
    cp "$FFDEB" "$CODECDEB" "$VADEB" "$STAGE/"
    docker run --rm -i --platform linux/arm64 -v "$OUT":/out -v "$STAGE":/stage -v "$ROOT":/src:ro \
        debian:trixie sh /src/tools/linux/publish-apt.sh --inner
    rm -rf "$STAGE"

    D=$OUT/apt/dists/$SUITE
    hgpg --yes --local-user "$FPR" --digest-algo SHA512 --clearsign -o "$D/InRelease" "$D/Release"
    hgpg --yes --local-user "$FPR" --digest-algo SHA512 --armor --detach-sign -o "$D/Release.gpg" "$D/Release"
    gpgv --keyring "$KEYRING" "$D/InRelease" 2>/dev/null || die "InRelease does not verify against $KEYRING"
    gpgv --keyring "$KEYRING" "$D/Release.gpg" "$D/Release" 2>/dev/null || die "Release.gpg does not verify against $KEYRING"
    cp "$PUBKEY" "$OUT/apt/henge-archive.asc"
    gpgconf --homedir "$GNUPGHOME" --kill gpg-agent 2>/dev/null || true
    echo "signed $D/InRelease with $FPR"
    echo "the repository is in $OUT/apt and the source in $OUT/source"
fi

if [ $RSYNC = 1 ]; then
    # The pool and the source first, the index last: InRelease never names a file that is not there yet.
    # Modes set here: macOS's openrsync has no --chmod=D...,F...
    chmod -R u+rwX,go+rX,go-w "$OUT/apt" "$OUT/source"
    rsync -rlpt --delay-updates --exclude dists/ "$OUT/apt/" "$REMOTE/apt/"
    rsync -rlpt --delay-updates "$OUT/source/" "$REMOTE/source/"
    rsync -rlpt --delay-updates "$OUT/apt/dists/" "$REMOTE/apt/dists/"
fi

if [ $CHECK = 1 ]; then
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    curl -fsS -o "$T/InRelease" "$URL/apt/dists/$SUITE/InRelease"
    gpgv --keyring "$KEYRING" "$T/InRelease" 2>/dev/null || die "$URL/apt/dists/$SUITE/InRelease: bad signature"
    cmp -s "$T/InRelease" "$OUT/apt/dists/$SUITE/InRelease" || die "the server's InRelease is not this one"
    for arch in arm64 all; do
        curl -fsS -o "$T/Packages" "$URL/apt/dists/$SUITE/main/binary-$arch/Packages"
        cmp -s "$T/Packages" "$OUT/apt/dists/$SUITE/main/binary-$arch/Packages" || die "the server's binary-$arch/Packages is not this one"
        awk '/^Filename:/ {f=$2} /^SHA256:/ {print $2, f}' "$T/Packages" > "$T/sums"
        while read -r sum file; do
            curl -fsS -o "$T/deb" "$URL/apt/$file"
            got=$(shasum -a 256 "$T/deb" | cut -d' ' -f1)
            [ "$got" = "$sum" ] || die "$URL/apt/$file: SHA-256 $got, Packages says $sum"
            echo "ok $file"
        done < "$T/sums"
    done
    for d in "$OUT"/source/*/; do
        n=$(basename "$d")
        curl -fsS "$URL/source/$n/SHA256SUMS" | cmp -s - "$d/SHA256SUMS" || die "$URL/source/$n/SHA256SUMS is not this one"
        echo "ok source/$n"
    done
    echo "the server has this repository"
fi
