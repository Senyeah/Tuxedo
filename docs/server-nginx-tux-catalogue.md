# The Tuxedo catalogue on walkies.site

Written 15/11/2026 (GMT+12). This is the record of the server change for the Tuxedo apt repository and image catalogue. The server holds the only copy of the configuration, so keep this file correct when the server changes.

**This file is not complete.** The writer of this file did not read the server. The two blocks marked "TO FILL" must hold the exact text from the server. Do not guess them.

## What was changed (15/11/2026)

1. A new folder: `/home/USER/tux-linux-catalogue/files`. `tools/linux/publish-apt.sh --rsync` copies `apt/` and `source/` into it.
2. A new container: `tux-linux-catalogue`, image `nginx:alpine`. It serves that folder.
3. A new `location` block in `/home/USER/nginx/default.conf` sends `https://walkies.site/tux-linux-catalogue/` to the container.
4. The backup of the file before the change: `/home/USER/nginx/default.conf.bak-before-tux-20261115`.

The Henge route (`https://walkies.site/henge-linux-catalogue/`) and its container were not changed.

## The location block

TO FILL: the exact block that was added to `/home/USER/nginx/default.conf`.

```nginx
# TO FILL
```

## The container

TO FILL: the exact `docker run` command for `tux-linux-catalogue` (name, image, volume, network, restart policy).

```sh
# TO FILL
```

## To undo

1. Copy `default.conf.bak-before-tux-20261115` over `default.conf`. Check that no other change was made to `default.conf` after the backup.
2. Run `nginx -t` in the front nginx container, then reload it.
3. Stop and remove the container `tux-linux-catalogue`. Keep `/home/USER/tux-linux-catalogue/files` until the owner says delete.

## What the server gives from outside

Checked on 15/11/2026 with `curl` only.

| Request | Answer |
|---|---|
| `/tux-linux-catalogue/apt/dists/trixie/InRelease` | 200. The signature is good for key `60E3070A44CF4B9F1F4B27E8FA32ECDBA657D9FF`. |
| `/tux-linux-catalogue/apt/dists/trixie/main/binary-arm64/Packages` | 200 |
| `/tux-linux-catalogue/apt/tux-archive.asc` | 200. The same file as `tools/linux/tux-archive.asc`. |
| `/tux-linux-catalogue/`, `/apt/`, `/apt/pool/`, `/source/` | 403 (no directory list) |
| `/tux-linux-catalogue` | 301 to `/tux-linux-catalogue/` |
| `/tux-linux-catalogue../` and paths with `../` | 404 |
| `/tux-linux-catalogue/linux-images.json` | 404. The image catalogue is not uploaded yet. |
| `/henge-linux-catalogue/linux-images.json` | 200. The old route still works. |

## Risks

- The edit was made by hand in a file that other sites share. A syntax error stops the front nginx at its next reload. Run `nginx -t` before each reload.
- The backup is on the same server as the file.
- A new build of the front nginx container from an older `default.conf` loses the block.
- The upload uses `root@walkies.site`. A user that can write only `/home/USER/tux-linux-catalogue/files` is safer.
