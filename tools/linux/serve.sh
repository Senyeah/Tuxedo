#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# G7: serve build/linux/dist over HTTP for a LAN install. Opens a port, so it asks first.
# Usage: serve.sh [--dir DIR] [--bind ADDR] [--port N] [--yes]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

DIR=${TUX_LINUX_OUT:-$(cd "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)/build/linux}/dist
BIND= PORT=8000 YES=0
while [ $# -gt 0 ]; do
    case $1 in
        --dir) DIR=$2; shift 2 ;;
        --bind) BIND=$2; shift 2 ;;
        --port) PORT=$2; shift 2 ;;
        --yes) YES=1; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[ -d "$DIR" ] || { echo "no directory $DIR" >&2; exit 2; }
[ -n "$BIND" ] || BIND=$(ipconfig getifaddr en0 || ipconfig getifaddr en1) || { echo "no LAN address; use --bind" >&2; exit 2; }

if [ "$YES" != 1 ]; then
    printf 'Serve %s on http://%s:%s/ ? [y/N] ' "$DIR" "$BIND" "$PORT"
    read -r ANSWER
    [ "$ANSWER" = y ] || { echo "not serving"; exit 1; }
fi
echo "catalogue URL: http://$BIND:$PORT/linux-images.json"

# http.server ignores Range, and the app resumes downloads with it
exec python3 - "$DIR" "$BIND" "$PORT" <<'PY'
import http.server, os, re, sys


class Handler(http.server.SimpleHTTPRequestHandler):
    left = None

    def send_head(self):
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        path = self.translate_path(self.path)
        if not m or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        a, b = m.groups()
        if a:
            start, end = int(a), min(int(b) if b else size - 1, size - 1)
        else:
            start, end = max(size - int(b or 0), 0), size - 1
        if start >= size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self.left = end - start + 1
        return f

    def copyfile(self, src, dst):
        left, self.left = self.left, None
        if left is None:
            return super().copyfile(src, dst)
        while left > 0:
            chunk = src.read(min(1 << 20, left))
            if not chunk:
                break
            dst.write(chunk)
            left -= len(chunk)

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()


os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer((sys.argv[2], int(sys.argv[3])), Handler).serve_forever()
PY
