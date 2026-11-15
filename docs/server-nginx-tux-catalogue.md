# The Tuxedo catalogue on walkies.site

Written 15/11/2026 (GMT+12). This is the record of the server change for the Tuxedo apt repository and image catalogue. The server holds the only copy of the configuration, so keep this file correct when the server changes.

The text below is the exact text from the server, added on 15/11/2026. The old config is saved on the server as `/home/USER/nginx/default.conf.bak-before-tux-20261115`.

## What was changed (15/11/2026)

1. A new folder: `/home/USER/tux-linux-catalogue/files`. `tools/linux/publish-apt.sh --rsync` copies `apt/` and `source/` into it.
2. A new container: `tux-linux-catalogue`, image `nginx:alpine`. It serves that folder.
3. A new `location` block in `/home/USER/nginx/default.conf` sends `https://walkies.site/tux-linux-catalogue/` to the container.
4. The backup of the file before the change: `/home/USER/nginx/default.conf.bak-before-tux-20261115`.

The Henge route (`https://walkies.site/henge-linux-catalogue/`) and its container were not changed.

## The location block

The block was added to `/home/USER/nginx/default.conf`, after the `henge-linux-catalogue` blocks and before `location = /webmusic`. It copies them.

```nginx
location = /tux-linux-catalogue {
    return 301 /tux-linux-catalogue/;
}

location /tux-linux-catalogue/ {
    proxy_pass http://tux-linux-catalogue:80/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # Images are hundreds of MB: stream them, no temp files on the proxy
    proxy_buffering off;
    proxy_max_temp_file_size 0;
}
```

## The container

The container is a copy of the old `henge-linux-catalogue` container. The directory `/home/USER/tux-linux-catalogue/files` is `chmod 755`.

```sh
docker run -d --name tux-linux-catalogue --restart unless-stopped --network proxy-net \
  -v /home/USER/tux-linux-catalogue/files:/usr/share/nginx/html:ro nginx:alpine
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
