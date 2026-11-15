Tuxedo Additions @ADDITIONS_VERSION@ (built @BUILT@)

This is the media of the Tuxedo app's "Insert Tuxedo Additions CD". It is a folder, not a disc.
It holds the Tuxedo guest packages and a small program (the agent) that the Tuxedo app drives.

How it starts
  1. A guest that has tux-guest 1.11.0 or later starts the agent by itself when the app inserts the media.
     The guest first checks SHA256SUMS.gpg with the key it already has. The app then shows its wizard.
  2. A guest with no tux-guest cannot start by itself. Log in as root (or run: sudo -i), then type:
       mkdir -p /mnt/tux && mount -t virtiofs -o ro tux-files /mnt/tux && sh /mnt/tux/tux-additions/install
     install checks the media, installs tux-guest, tux-va and tux-ffmpeg, and needs no network.
     After that the normal start in step 1 works with no second insert.

Files
  install            the bootstrap (POSIX sh). Exit codes: 0 done, 1 failed, 2 wrong system,
                     3 old henge-* packages are installed, 4 the media check failed.
  agent              the agent (Python 3, standard library only). It runs as root.
  tux_additions_caps.py   what the agent tells the app about the guest. The same code is the guest's
                     tux-additions-report.
  actions.json       the only things the agent can do: desktops, applications and the limits for SSH.
  versions.json      the versions in this build.
  install-order.txt  the order for dpkg when apt does not work.
  desktop-labwc/     the session files of the Tuxedo desktop (labwc), with files.json as their map.
  apt/               a signed apt repository: main (the Tuxedo packages) and deps (the Debian packages that a
                     minimal trixie guest lacks, with openssh-server).
  SHA256SUMS, SHA256SUMS.gpg, tux-archive.gpg
                     the sums of every other file, the signature, and the public key of the signature.
  source/SOURCES.txt where the source of each package is.

To check the media by hand:
  gpgv --keyring ./tux-archive.gpg SHA256SUMS.gpg SHA256SUMS && sha256sum -c --strict SHA256SUMS

The media has no private key, no password and no path of the machine that built it.

Licences
  Tuxedo (the agent, install, tux-guest, tux-va, tux-codec-dkms, and the files in desktop-labwc):
    GPL-2.0-or-later. The licence text is /usr/share/common-licenses/GPL-2 on Debian.
  tux-ffmpeg: FFmpeg @FFMPEG_RELEASE@ with the Tuxedo patch, built with --enable-gpl and with libx264 and libx265,
    so the binaries are GPL-2.0-or-later. The libhvcodec part is LGPL-2.1-or-later.
  The Debian packages in apt/pool/deps: each one has its own licence in /usr/share/doc/<package>/copyright
    after it is installed.

Source offer
  The source of tux-ffmpeg (the FFmpeg tarball, the Tuxedo patch, the build script, the hashes) is at:
    @SOURCE_URL@/source/ffmpeg-@FFMPEG_VERSION@/
  The source of the Debian packages is at snapshot.debian.org (see source/SOURCES.txt for the exact place).
  The source of the other Tuxedo packages is in the Tuxedo repository, and inside each package (they are scripts).
  This is also a written offer: whoever has these binaries from this media can ask the distributor of the
  media for the complete source of each GPL or LGPL part, for at least three years from the date above, for
  no more than the cost of the copy. If the URL above does not work, ask the distributor.
