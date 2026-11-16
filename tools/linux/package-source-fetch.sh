#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Download the Debian source of the Tuxedo images. It is copied to fetch-source.sh in the offer
# directory by package-source.sh, which fills in the three @...@ values.
# Usage: sh fetch-source.sh DEST [SOURCE-PACKAGE ...]
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DEST=${1:?usage: sh fetch-source.sh DEST [SOURCE-PACKAGE ...]}
shift
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lists/partial" "$T/cache/archives/partial"
KEY=/usr/share/keyrings/debian-archive-keyring.gpg
[ -f "$KEY" ] || { echo "install the debian-archive-keyring package first" >&2; exit 1; }
cat > "$T/sources.list" <<EOF
deb-src [signed-by=$KEY check-valid-until=no] @SNAP_URL@ @SUITE@ main
deb-src [signed-by=$KEY check-valid-until=no] @SNAP_URL@ @SUITE@-updates main
deb-src [signed-by=$KEY check-valid-until=no] @SEC_URL@ @SUITE@-security main
EOF
APT="-o Dir::Etc::sourcelist=$T/sources.list -o Dir::Etc::sourceparts=/dev/null -o Dir::State::lists=$T/lists -o Dir::Cache=$T/cache -o Acquire::Check-Valid-Until=false -o Acquire::Retries=5"

# shellcheck disable=SC2086
apt-get -q $APT update >/dev/null

# one "name=version" per source package, from the lists next to this script
awk -F'\t' '!/^#/ && $3 != "-" {print $3 "=" $4}' "$HERE"/SOURCES-*.txt | sort -u > "$T/want"
if [ "$#" -gt 0 ]; then
    for p in "$@"; do grep "^$p=" "$T/want" || { echo "no source package $p in the lists" >&2; exit 1; }; done > "$T/want.sel"
    mv "$T/want.sel" "$T/want"
fi

n=$(wc -l < "$T/want")
i=0
cd "$DEST"
while read -r pv; do
    i=$((i + 1))
    echo "[$i/$n] $pv"
    # shellcheck disable=SC2086
    apt-get -q $APT source --download-only "$pv" >/dev/null 2>"$T/err" ||
        { cat "$T/err" >&2; echo "failed: $pv" >&2; exit 1; }
done < "$T/want"
echo "done: $n source packages in $DEST"
