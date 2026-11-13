# Sourced inside an arm64 debian:trixie container: apt from the pinned snapshot, then install $APT_PKGS.
# Needs versions.env sourced first.
SNAP=http://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT/
SNAP_SEC=http://snapshot.debian.org/archive/debian-security/$DEBIAN_SNAPSHOT/
rm -f /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<EOF
Types: deb
URIs: $SNAP
Suites: $DEBIAN_SUITE $DEBIAN_SUITE-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no

Types: deb
URIs: $SNAP_SEC
Suites: $DEBIAN_SUITE-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no
EOF
apt-get -q -o Acquire::Retries=5 update >/dev/null
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get -q -o Acquire::Retries=5 install -y --no-install-recommends $APT_PKGS >/dev/null
