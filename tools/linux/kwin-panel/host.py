#!/usr/bin/python3
"""A stand-in for host/share.c's /.henge/keyboard, for keyboard-panel-check.sh: host.py PORT LOG.
PUT /.henge/keyboard: the body goes to LOG. GET /.henge/keyboard[?since=N]: "height F", held up to 25 s.
PUT /height sets F, as the app does."""
import http.server
import sys
import threading
import urllib.parse

cond = threading.Condition()
height, seq = 0.0, 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def answer(self, status, body=b"", seq=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if seq is not None:
            self.send_header("X-Henge-Seq", str(seq))
        try:
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass  # a helper that stopped while its GET waited

    def do_PUT(self):
        global height, seq
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path == "/height":
            with cond:
                height, seq = float(body), seq + 1
                cond.notify_all()
        elif self.path == "/.henge/keyboard":
            with open(sys.argv[2], "a") as f:
                f.write(body + "\n")
        else:
            return self.answer(404)
        self.answer(204)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path != "/.henge/keyboard":
            return self.answer(404)
        since = urllib.parse.parse_qs(url.query).get("since")
        with cond:
            if since:
                cond.wait_for(lambda: seq != int(since[0]), 25)
            self.answer(200, f"height {height:.3f}\n".encode(), seq)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
