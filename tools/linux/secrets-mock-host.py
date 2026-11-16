#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in for host/secrets.c, for secrets-check.py --container: the same /.tux/secrets protocol on
127.0.0.1, items in memory, plus PUT /control ("lock" or "unlock") and GET /control/dump (the store as JSON)
in place of the app's Face ID check and the Keychain."""
import base64
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ITEMS = "/.tux/secrets/items/"
ID = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}")
state = {"locked": True, "seq": 1, "items": {}}
cond = threading.Condition()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self, status, body=b"", headers=()):
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/control/dump":
            with cond:
                dump = {k: {"meta": json.loads(m or b"{}"), "secret": base64.b64encode(s).decode()} for k, (m, s) in state["items"].items()}
            return self.answer(200, json.dumps(dump).encode())
        if path == "/.tux/secrets/state":
            with cond:
                m = re.search(r"since=(\d+)", query)
                if m:
                    cond.wait_for(lambda: state["seq"] > int(m[1]), timeout=25)
                text = b"locked\n" if state["locked"] else b"unlocked\n"
                return self.answer(200, text, [("X-Tux-Seq", str(state["seq"]))])
        if path == "/.tux/secrets/items":
            with cond:
                lines = [f"{k} {base64.b64encode(m).decode()}\n" for k, (m, _) in state["items"].items()]
            return self.answer(200, "".join(lines).encode())
        if path.startswith(ITEMS):
            iid = path[len(ITEMS):]
            with cond:
                if state["locked"]:
                    return self.answer(423)
                if iid not in state["items"]:
                    return self.answer(404)
                return self.answer(200, state["items"][iid][1])
        self.answer(404)

    def do_PUT(self):
        data = self.body()
        if self.path == "/control":
            with cond:
                state["locked"] = data.strip() == b"lock"
                state["seq"] += 1
                cond.notify_all()
            return self.answer(204)
        if not self.path.startswith(ITEMS) or not ID.fullmatch(self.path[len(ITEMS):]):
            return self.answer(400)
        meta64, nl, secret = data.partition(b"\n")
        if not nl:
            return self.answer(400)
        with cond:
            if state["locked"]:
                return self.answer(423)
            new = self.path[len(ITEMS):] not in state["items"]
            state["items"][self.path[len(ITEMS):]] = (base64.b64decode(meta64), secret)
        self.answer(201 if new else 204)

    def do_DELETE(self):
        iid = self.path[len(ITEMS):]
        with cond:
            if state["locked"]:
                return self.answer(423)
            if state["items"].pop(iid, None) is None:
                return self.answer(404)
        self.answer(204)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
