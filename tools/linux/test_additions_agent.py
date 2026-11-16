#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tests of tools/linux/additions/agent and tux_additions_caps.py (docs/guest-additions-design.md 5 and 6).
The agent runs against a fake host (a local HTTP server with the /.tux/additions contract), a fake root folder
and a runner that records each program call instead of starting it. Nothing here needs a guest, Docker or a network."""
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.dont_write_bytecode = True
ADD = Path(__file__).resolve().parent / "additions"
sys.path.insert(0, str(ADD))
import tux_additions_caps as caps_mod  # noqa: E402


def load_agent(path):
    loader = importlib.machinery.SourceFileLoader("tux_agent_under_test", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


agent = load_agent(ADD / "agent")
PASSWORD = "S3cret-pass-ZZ9"
KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDKh0pVEWfXvQmMUzfJ1dG1Ny0KkdlC7uZ3a5r2oV8Ox me@phone"
EVENT_TYPES = {"report", "ack", "step", "log", "done", "bad-media"}
CAPS_KEYS = {"installed", "legacy", "account", "root", "network", "desktop", "desktops", "ssh", "apps", "hostname", "disk_free_mb",
             "image", "ips", "kernel"}
ACCOUNT_KEYS = {"name", "uid", "exists", "password_set", "configured", "sudo", "autologin"}
SSH_KEYS = {"installed", "enabled", "port", "password_auth"}


class FakeHost:
    """The host side of /.tux/additions. It checks each event against the wire contract."""

    def __init__(self):
        self.cond = threading.Condition()
        self.seq = 1
        self.inserted, self.n, self.cancel_job, self.job, self.taken = True, 1, None, None, None
        self.events, self.bodies, self.violations = [], [], []
        self.after = {}  # event type -> function, called once the host has the event (a test's way to act at that moment)
        host = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def send(self, status, body, extra=()):
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Content-Type", "application/json")
                for k, v in extra:
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                u = urlparse(self.path)
                if u.path != "/.tux/additions":
                    return self.send(404, b"{}")
                since = parse_qs(u.query).get("since")
                with host.cond:
                    if since and int(since[0]) == host.seq:
                        host.cond.wait(timeout=6)
                    body = json.dumps({"inserted": host.inserted, "n": host.n if host.inserted else 0,
                                       "cancel": host.cancel_job is not None, "cancel_job": host.cancel_job,
                                       "job": host.job, "taken": host.taken}).encode()
                    self.send(200, body, [("X-Tux-Seq", str(host.seq))])

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                if length > 64 * 1024:
                    self.rfile.read(length)
                    return self.send(413, b'{"error":"too big"}')
                raw = self.rfile.read(length)
                try:
                    ev = json.loads(raw)
                    ok = isinstance(ev, dict) and isinstance(ev.get("t"), str)
                except ValueError:
                    ok = False
                with host.cond:
                    host.bodies.append(raw)
                    if not ok:
                        return self.send(400, b'{"error":"bad"}')
                    host.check(ev)
                    host.events.append(ev)
                    host.seq += 1
                    if ev["t"] == "ack" and host.job and ev.get("job") == host.job.get("id"):
                        host.job, host.taken = None, ev["job"]  # the job and its password leave the host
                    if ev["t"] == "done" and ev.get("job") in (host.taken, (host.job or {}).get("id")):
                        host.job, host.taken = None, None
                    host.cond.notify_all()
                    self.send(200, json.dumps({"seq": host.seq}).encode())
                    if ev["t"] in host.after:
                        host.after[ev["t"]]()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.02), daemon=True).start()

    def check(self, ev):
        t, bad = ev["t"], self.violations.append
        if t not in EVENT_TYPES:
            bad("unknown event type %r" % t)
        if t == "report":
            c = ev.get("caps", {})
            if not (isinstance(ev.get("n"), int) and isinstance(ev.get("agent"), str) and isinstance(ev.get("protocol"), int)):
                bad("report fields")
            if set(c) != CAPS_KEYS or set(c.get("account", {})) != ACCOUNT_KEYS or set(c.get("ssh", {})) != SSH_KEYS:
                bad("caps keys %s" % sorted(set(c) ^ CAPS_KEYS))
            if c.get("account", {}).get("autologin") not in ("root", "user", "none"):
                bad("account.autologin")
        elif t == "ack":
            if not (isinstance(ev.get("job"), str) and set(ev) == {"t", "job"}):
                bad("ack fields %r" % ev)
            if any(e["t"] == "step" for e in self.events):
                bad("ack after a step")
        elif t == "step":
            if not (isinstance(ev.get("job"), str) and isinstance(ev.get("i"), int) and isinstance(ev.get("msg"), str)
                    and ev.get("status") in ("running", "ok", "failed", "skipped") and "\n" not in ev["msg"]):
                bad("step fields %r" % ev)
        elif t == "log":
            if not (isinstance(ev.get("job"), str) and isinstance(ev.get("text"), str)
                    and len(ev["text"].encode()) <= 4096):
                bad("log fields")
        elif t == "done":
            if not (isinstance(ev.get("ok"), bool) and isinstance(ev.get("reboot"), bool)
                    and set(ev.get("info", {})) == {"ips", "ssh_fingerprints", "user"}):
                bad("done fields %r" % ev)

    def notify(self):
        with self.cond:
            self.seq += 1
            self.cond.notify_all()

    def set_job(self, job):
        with self.cond:
            self.job = job
        self.notify()

    def set_cancel(self):
        """The app's Cancel: a job the agent has not taken is forgotten, one it has taken is named in cancel_job."""
        with self.cond:
            if self.job:
                self.cancel_job, self.job = self.job["id"], None
            elif self.taken:
                self.cancel_job = self.taken
        self.notify()

    def eject(self):
        with self.cond:
            self.inserted = False
        self.notify()

    def wait_for(self, pred, timeout=20):
        end = time.time() + timeout
        with self.cond:
            while not pred():
                left = end - time.time()
                if left <= 0:
                    raise AssertionError("timeout; events so far: %s" % [e["t"] for e in self.events])
                self.cond.wait(left)

    def of(self, t):
        return [e for e in self.events if e["t"] == t]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Call:
    def __init__(self, argv, input, env, at):
        self.argv, self.input, self.env, self.at = argv, input, env, at


class FakeRunner:
    """Records each program call. It plays the parts of useradd, dpkg-query and the others that change what the agent sees."""

    def __init__(self, root, host=None):
        self.root, self.host = root, host
        self.calls, self.rules = [], []
        self.packages = {}
        self.sshd_rc = 0
        self.ssh_enabled = False
        self.apt_output = ""
        self.hooks = []

    def when(self, prefix, rc=0, out="", fn=None):
        self.rules.append((list(prefix), rc, out, fn))

    def called(self, *prefix):
        return [c for c in self.calls if c.argv[: len(prefix)] == list(prefix)]

    def run(self, argv, input=None, timeout=None, env=None, on_output=None):
        self.calls.append(Call(list(argv), input, dict(env or {}), len(self.host.events) if self.host else 0))
        for h in self.hooks:
            h(argv)
        rc, out = 0, ""
        for prefix, r, o, fn in self.rules:
            if argv[: len(prefix)] == prefix:
                rc, out = r, o
                if fn:
                    fn(argv, input)
                break
        else:
            rc, out = self.default(argv, input)
        if on_output and out:
            on_output(out)
        return caps_mod.Result(rc, out)

    def default(self, argv, input):
        a = argv[0]
        if a == "dpkg-query":
            return 0, "".join("ii \t%s\t%s\n" % (n, v) for n, v in sorted(self.packages.items()))
        if a == "useradd":
            name = argv[-1]
            uid = argv[argv.index("--uid") + 1] if "--uid" in argv else "1001"
            self.append("etc/passwd", "%s:x:%s:%s::/home/%s:/bin/bash\n" % (name, uid, uid, name))
            if "--groups" in argv:
                for g in argv[argv.index("--groups") + 1].split(","):
                    self.add_member(g, name)
            return 0, ""
        if a == "usermod" and argv[1] == "-aG":
            for g in argv[2].split(","):
                self.add_member(g, argv[3])
            return 0, ""
        if a == "gpasswd" and argv[1] == "-d":
            self.add_member(argv[3], argv[2], remove=True)
            return 0, ""
        if a == "pgrep":
            return 1, ""
        if a == "usermod" and argv[1] == "-l":
            new, old = argv[2], argv[-1]
            for rel in ("etc/passwd", "etc/shadow"):
                p = Path(self.root) / rel
                p.write_text(p.read_text().replace("%s:" % old, "%s:" % new, 1).replace("/home/%s:" % old, "/home/%s:" % new))
            g = Path(self.root) / "etc/group"
            g.write_text(g.read_text().replace(":%s\n" % old, ":%s\n" % new))
            if (Path(self.root) / "home" / old).exists():
                (Path(self.root) / "home" / old).rename(Path(self.root) / "home" / new)
            return 0, ""
        if a == "groupmod" and argv[1] == "-n":
            g = Path(self.root) / "etc/group"
            g.write_text(g.read_text().replace("%s:x:1000:" % argv[3], "%s:x:1000:" % argv[2]))
            return 0, ""
        if a == "systemd-escape":
            path = argv[-1].strip("/").replace("-", "\\x2d").replace("/", "-")
            return 0, "%s.%s\n" % (path, argv[2].split("=")[1])
        if a == "ip":
            return 0, "2: eth0    inet 10.0.2.15/24 brd 10.0.2.255 scope global eth0\n"
        if a == "systemctl" and argv[1] == "is-enabled":
            return (0, "enabled\n") if self.ssh_enabled else (1, "disabled\n")
        if a == "ssh-keygen":
            return 0, "256 SHA256:abcdefghijklmnop root@fake (ED25519)\n"
        if a == "sshd":
            return self.sshd_rc, "bad config\n" if self.sshd_rc else ""
        if a == "apt-get" and "install" in argv and "update" not in argv:
            for p in argv[argv.index("install") + 1:]:
                if not p.startswith("-") and "=" not in p:
                    self.packages[p] = "1"
            return 0, self.apt_output
        if a == "apt-get":
            return 0, self.apt_output
        return 0, ""

    def append(self, rel, text):
        p = Path(self.root) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a") as f:
            f.write(text)

    def add_member(self, group, name, remove=False):
        p = Path(self.root) / "etc/group"
        lines = p.read_text().splitlines()
        for i, line in enumerate(lines):
            f = line.split(":")
            if f[0] == group:
                m = [x for x in f[3].split(",") if x and x != name]
                if not remove:
                    m.append(name)
                lines[i] = ":".join(f[:3] + [",".join(m)])
        p.write_text("\n".join(lines) + "\n")


class Case(unittest.TestCase):
    """One fake host, one fake root, one runner, and a way to run a job through a real agent."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="tux-agent-test-")
        self.root = Path(self.tmp) / "root"
        self.make_root()
        self.host = FakeHost()
        self.runner = FakeRunner(self.root, self.host)
        self.runner.packages = {"tux-guest": "1.11.0", "python3": "3.13"}
        self.net = True
        os.environ["TUX_ADDITIONS_HOST"], os.environ["TUX_ADDITIONS_PORT"] = "127.0.0.1", str(self.host.port)

    def tearDown(self):
        self.host.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    job_extra = {}

    def make_root(self, tux_user=False):
        r = self.root
        for d in ("etc/apt", "etc/ssh/sshd_config.d", "etc/sudoers.d", "var/lib/tux", "home", "run/tux"):
            (r / d).mkdir(parents=True, exist_ok=True)
        (r / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/bash\n" + (
            "tux:x:1000:1000::/home/tux:/bin/bash\n" if tux_user else ""))
        (r / "etc/group").write_text("root:x:0:\naudio:x:29:\nvideo:x:44:\nsudo:x:27:%s\nrender:x:105:\ninput:x:106:\n"
                                     "dialout:x:20:\n" % ("tux" if tux_user else ""))
        (r / "etc/shadow").write_text("root:*:20000:0:99999:7:::\n" + ("tux::20000:0:99999:7:::\n" if tux_user else ""))
        (r / "etc/hostname").write_text("tux\n")
        (r / "etc/hosts").write_text("127.0.0.1\tlocalhost\n127.0.1.1\ttux\n::1\tlocalhost ip6-localhost\n")
        (r / "etc/apt/sources.list").write_text("deb http://mirror.example/debian trixie main\n")
        if tux_user:
            (r / "home/tux").mkdir(parents=True, exist_ok=True)

    def agent(self, **kw):
        a = agent.Agent(1, runner=self.runner, tree=str(ADD), root=str(self.root), sleep=lambda s: None, min_poll=0,
                        connect=lambda h, p, t: self.net, version="1.11.0+1", **kw)
        a.version = "1.11.0+1"
        return a

    def run_job(self, steps, jid="j-1", **kw):
        """Runs the agent in a thread until the job is done, then ejects the media. Returns the stderr text."""
        err = io.StringIO()
        a = self.agent(**kw)
        result = {}

        def go():
            try:
                with redirect_stderr(err):
                    result["rc"] = a.serve()
            except BaseException as e:  # noqa: BLE001
                result["exc"] = e

        self.host.set_job(dict({"id": jid, "steps": steps}, **self.job_extra))
        t = threading.Thread(target=go, daemon=True)
        t.start()
        self.host.wait_for(lambda: self.host.of("done"))
        self.host.eject()
        t.join(10)
        self.assertFalse(t.is_alive(), "the agent did not end after the eject")
        if "exc" in result:
            raise result["exc"]
        self.assertEqual(result["rc"], 0)
        self.assertEqual(self.host.violations, [])
        self.stderr = err.getvalue()
        self.agent_obj = a
        return self.stderr

    def setUp_again(self):
        self.tearDown()
        self.setUp()
        self.make_root(tux_user=True)

    def steps(self):
        return [(e["i"], e["status"], e["msg"]) for e in self.host.of("step")]

    def final(self):
        return {i: (s, m) for i, s, m in self.steps() if s != "running"}

    def read(self, rel):
        return (self.root / rel).read_text()


class Validation(unittest.TestCase):
    cat = agent.load_catalogue(str(ADD))

    def bad(self, step, text=None):
        with self.assertRaises(agent.StepError) as cm:
            agent.validate_step(step, self.cat)
        if text:
            self.assertIn(text.lower(), str(cm.exception).lower())

    def test_host_names(self):
        for ok in ("a", "tuxbox", "a-b", "a1", "x" * 63, "9lives"):
            self.assertEqual(agent.validate_step({"action": "hostname.set", "name": ok}, self.cat)["name"], ok)
        for bad in ("", "-a", "a-", "A", "a_b", "x" * 64, "a.b", "a b", "a\n", 5, None, ["a"], "tux box"):
            self.bad({"action": "hostname.set", "name": bad})
        self.bad({"action": "hostname.set"})

    def test_user_names(self):
        for ok in ("tux", "_x", "a-b_c", "x" * 32):
            self.assertEqual(agent.validate_step({"action": "user.setup", "name": ok}, self.cat)["name"], ok)
        for bad in ("", "1a", "A", "a b", "x" * 33, "a:b", "a\n", "root:x", "-x", 7):
            self.bad({"action": "user.setup", "name": bad})

    def test_user_setup_defaults_and_types(self):
        c = agent.validate_step({"action": "user.setup"}, self.cat)
        self.assertEqual((c["sudo"], c["autologin"], c["lock_root"], c["name"], c["password"]), (True, True, True, None, None))
        for k in ("sudo", "autologin", "lock_root"):
            self.bad({"action": "user.setup", k: "true"})
            self.bad({"action": "user.setup", k: 1})
        self.bad({"action": "user.setup", "password": "a\nb"})
        self.bad({"action": "user.setup", "password": "x" * 129})
        self.bad({"action": "user.setup", "password": 12345678})
        self.bad({"action": "user.setup", "shell": "/bin/sh"}, "unexpected")
        self.assertIsNone(agent.validate_step({"action": "user.setup", "password": ""}, self.cat)["password"])

    def test_ports(self):
        for ok in (1, 22, 2222, 65535):
            self.assertEqual(agent.validate_step({"action": "ssh.configure", "enabled": True, "port": ok}, self.cat)["port"], ok)
        for bad in (0, -1, 65536, 70000, "22", 22.0, True, None, [22]):
            self.bad({"action": "ssh.configure", "enabled": True, "port": bad})
        self.assertEqual(agent.validate_step({"action": "ssh.configure", "enabled": False}, self.cat)["port"], 22)

    def test_keys(self):
        c = agent.validate_step({"action": "ssh.configure", "enabled": True, "authorized_key": KEY}, self.cat)
        self.assertEqual(c["authorized_key"], KEY)
        t, body = KEY.split()[:2]
        for bad in (KEY + "\nssh-rsa AAAA", KEY.replace(" me@phone", "\n"), "x " + body, "ssh-dss " + body, t + " !!!!",
                    'command="id" ' + KEY, t + " " + body[:-8], "ssh-rsa " + body, t, "A" * 5000, t + " " + body + " \x07"):
            self.bad({"action": "ssh.configure", "enabled": True, "authorized_key": bad})
        import base64
        shapes = {"ssh-ed25519": [b"k" * 32], "sk-ssh-ed25519@openssh.com": [b"k" * 32, b"ssh:"],
                  "ecdsa-sha2-nistp256": [b"nistp256", b"p" * 65], "ecdsa-sha2-nistp384": [b"nistp384", b"p" * 97],
                  "ecdsa-sha2-nistp521": [b"nistp521", b"p" * 133], "ssh-rsa": [b"\x01\x00\x01", b"\x00" + b"n" * 256]}
        for typ, rest in shapes.items():
            blob = b"".join(len(f).to_bytes(4, "big") + f for f in [typ.encode()] + rest)
            k = typ + " " + base64.b64encode(blob).decode()
            self.assertEqual(agent.check_key(k)[0], typ)
            self.assertEqual(agent.check_key(k + " a comment")[2], "a comment")
            with self.assertRaises(agent.StepError):  # one byte more than the fields use
                agent.check_key(typ + " " + base64.b64encode(blob + b"\x00").decode())

    def test_unknown_ids_and_actions(self):
        self.bad({"action": "desktop.install", "id": "gnome"}, "unknown id")
        self.bad({"action": "desktop.install"})
        self.bad({"action": "apps.install", "ids": ["firefox", "nope"]}, "unknown id")
        self.bad({"action": "apps.install", "ids": []})
        self.bad({"action": "apps.install", "ids": "firefox"})
        self.bad({"action": "apps.install", "ids": ["firefox", 3]})
        self.bad({"action": "rm.everything"}, "unknown action")
        self.bad({"action": None})
        self.bad({})
        self.bad("apps.install")
        self.bad({"action": "system.update", "extra": 1}, "unexpected")
        self.bad({"action": "apps.install", "ids": ["firefox"], "packages": ["x"]}, "unexpected")
        self.assertEqual(agent.validate_step({"action": "apps.install", "ids": ["git", "git", "firefox"]}, self.cat)["ids"],
                         ["git", "firefox"])

    def test_job_shape(self):
        for bad in (None, [], {"steps": [{}]}, {"id": "a b", "steps": [{}]}, {"id": "x", "steps": []},
                    {"id": "x", "steps": "a"}, {"id": "x", "steps": [{}] * 33}, {"id": 5, "steps": [{}]}):
            with self.assertRaises(agent.JobError):
                agent.parse_job(bad)
        self.assertEqual(agent.parse_job({"id": "j-8f3a", "steps": [{}]})[0], "j-8f3a")

    def test_catalogue(self):
        cat = json.loads((ADD / "actions.json").read_text())
        agent.validate_catalogue(cat)
        for mutate in (lambda c: c.update(protocol=2), lambda c: c["apps"][0].update(packages=["-oBad"]),
                       lambda c: c["apps"][0].update(packages=["a b"]), lambda c: c["apps"].append(dict(c["apps"][0])),
                       lambda c: c.pop("ssh"), lambda c: c["desktops"][0].update(files="../x")):
            c = json.loads(json.dumps(cat))
            mutate(c)
            with self.assertRaises(agent.CatalogueError):
                agent.validate_catalogue(c)

    def test_pure_builders(self):
        self.assertEqual(agent.apt_install_argv(["a", "b"])[:3], ["apt-get", "install", "--no-install-recommends"])
        self.assertEqual(agent.useradd_argv("tux", ["audio", "video", "sudo"], True),
                         ["useradd", "--create-home", "--shell", "/bin/bash", "--uid", "1000", "--groups", "audio,video,sudo", "tux"])
        self.assertNotIn("--uid", agent.useradd_argv("bob", [], False))
        self.assertEqual(agent.account_marker("tux", True, False), {"configured": True, "name": "tux", "autologin": True, "sudo": False})
        conf = agent.sshd_conf(2222, False, False)
        for line in ("Port 2222", "PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no"):
            self.assertIn(line, conf)
        self.assertEqual(agent.fix_hosts("127.0.0.1\tlocalhost\n127.0.1.1\told\n", "old", "new"), "127.0.0.1\tlocalhost\n127.0.1.1\tnew\n")
        self.assertEqual(agent.fix_hosts("127.0.0.1\tlocalhost old\n", "old", "new"), "127.0.0.1\tlocalhost new\n")
        self.assertIn("127.0.1.1\tnew", agent.fix_hosts("127.0.0.1\tlocalhost\n", "old", "new"))
        t1, added1 = agent.authorized_keys_add("", KEY)
        t2, added2 = agent.authorized_keys_add(t1, KEY.replace("me@phone", "other"))
        self.assertEqual((added1, added2, t2), (True, False, t1))
        self.assertEqual(agent.authorized_keys_add("ssh-rsa AAAA x", KEY)[0], "ssh-rsa AAAA x\n" + KEY + "\n")

    def test_split_utf8(self):
        text = "aé€😀" * 2000
        parts = agent.split_utf8(text, 4000)
        self.assertEqual("".join(parts), text)
        self.assertTrue(all(len(p.encode()) <= 4000 for p in parts))
        self.assertEqual(agent.split_utf8("", 10), [])

    def test_file_map_refuses_paths(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            (tmp / "d").mkdir()
            (tmp / "d/a").write_text("x")
            (tmp / "secret").write_text("y")
            for entry in ({"src": "../secret", "dst": "/etc/x", "mode": "0644"}, {"src": "a", "dst": "/root/x", "mode": "0644"},
                          {"src": "a", "dst": "/etc/../root/x", "mode": "0644"}, {"src": "a", "dst": "/etc/x", "mode": "644"},
                          {"src": "/etc/passwd", "dst": "/etc/x", "mode": "0644"}, {"src": "missing", "dst": "/etc/x", "mode": "0644"}):
                (tmp / "d/files.json").write_text(json.dumps([entry]))
                with self.assertRaises(agent.StepError):
                    agent.load_file_map(str(tmp), "d")
            (tmp / "d/files.json").write_text(json.dumps([{"src": "a", "dst": "/etc/x", "mode": "0644"}]))
            self.assertEqual(agent.load_file_map(str(tmp), "d")[0][1:], ("/etc/x", 0o644, False))
        finally:
            shutil.rmtree(tmp)

    def test_no_shell_in_source(self):
        src = (ADD / "agent").read_text() + (ADD / "tux_additions_caps.py").read_text()
        for bad in ("shell=True", "os.system", "os.popen", "eval(", "exec(", "pickle"):
            self.assertNotIn(bad, src)
        self.assertNotRegex(src, r"^import (requests|yaml|numpy)", "third-party import")


class Caps(Case):
    def caps(self, **kw):
        return caps_mod.build_caps(self.runner, str(self.root), connect=lambda h, p, t: self.net, **kw)

    def test_fresh_image_is_root_console(self):
        self.make_root(tux_user=True)
        c = self.caps()
        a = c["account"]
        self.assertEqual((a["name"], a["uid"], a["exists"], a["password_set"], a["configured"], a["sudo"], a["autologin"]),
                         ("tux", 1000, True, False, False, True, "root"))
        self.assertEqual(c["installed"], {"tux-guest": "1.11.0", "tux-va": None, "tux-ffmpeg": None, "tux-codec-dkms": None})
        self.assertEqual((c["desktop"], c["image"], c["legacy"]), ("none", "console", False))
        self.assertEqual(set(c), CAPS_KEYS)
        self.assertIn("firefox", c["apps"])
        self.assertEqual(c["ips"], ["10.0.2.15"])
        self.assertEqual(c["hostname"], "tux")

    def test_marker_decides_configured_and_autologin(self):
        self.make_root(tux_user=True)
        for autologin, want in ((True, "user"), (False, "none")):
            (self.root / "var/lib/tux/account.json").write_text(json.dumps(
                {"configured": True, "name": "tux", "autologin": autologin, "sudo": True}))
            a = self.caps()["account"]
            self.assertEqual((a["configured"], a["autologin"]), (True, want))

    def test_autologin_agrees_with_the_console_login(self):
        # tux-console-login: a literal true, a name of the allowed shape, and an account that exists
        self.make_root(tux_user=True)
        marker = self.root / "var/lib/tux/account.json"
        for text, want in (('{"configured": true, "name": "tux", "autologin": true}', "user"),
                           ('{"autologin":true,"name":"tux"}', "user"),
                           ('{"configured": true, "name": "ghost", "autologin": true}', "none"),
                           ('{"configured": true, "name": "tux", "autologin": "true"}', "none"),
                           ('{"configured": true, "name": "tux", "autologin": 1}', "none"),
                           ('{"configured": true, "name": "tux", "autologin": false}', "none"),
                           ('{"configured": true, "autologin": true}', "none"),
                           ('{"configured": true, "name": "Tux", "autologin": true}', "none"),
                           ('{"configured": true, "name": "' + "a" * 33 + '", "autologin": true}', "none"),
                           ('{"configured": true, "name": 5, "autologin": true}', "none"),
                           ("not json", "none"), ("[]", "none"), ("", "none")):
            marker.write_text(text)
            a = self.caps()["account"]
            self.assertEqual((a["configured"], a["autologin"]), (True, want), text)
        marker.unlink()
        self.assertEqual(self.caps()["account"]["autologin"], "root")

    def test_passwd_has_the_shell(self):
        u = caps_mod.parse_passwd("a:x:1:1::/h:/usr/sbin/nologin\nb:x:2:2::/h\n")
        self.assertEqual((u["a"]["shell"], u["b"]["shell"]), ("/usr/sbin/nologin", ""))

    def test_password_and_no_account(self):
        self.make_root(tux_user=True)
        (self.root / "etc/shadow").write_text("tux:$y$j9T$abc:20000::::::\n")
        self.assertTrue(self.caps()["account"]["password_set"])
        (self.root / "etc/shadow").write_text("tux:!:20000::::::\n")
        self.assertFalse(self.caps()["account"]["password_set"])
        self.make_root(tux_user=False)
        a = self.caps()["account"]
        self.assertEqual((a["name"], a["exists"], a["sudo"], a["configured"]), ("tux", False, False, False))

    def test_network_follows_the_mirror(self):
        self.net = False
        self.assertFalse(self.caps()["network"])
        self.net = True
        self.assertTrue(self.caps()["network"])
        (self.root / "etc/apt/sources.list").write_text("# nothing\n")
        self.assertFalse(self.caps()["network"])
        seen = []
        (self.root / "etc/apt/sources.list").write_text("deb [signed-by=/x] https://deb.example:8443/d trixie main\n")
        (self.root / "etc/apt/sources.list.d").mkdir()
        (self.root / "etc/apt/sources.list.d/tux.sources").write_text(
            "Types: deb\nURIs: https://off.example/apt\nEnabled: no\n")
        caps_mod.have_network(str(self.root), lambda h, p, t: seen.append((h, p)) or False)
        self.assertEqual(seen, [("deb.example", 8443)])

    FIB = """Main:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 10.0.2.0/24 2 0 2
        |-- 10.0.2.0
           /32 link BROADCAST
           /24 link UNICAST
        |-- 10.0.2.15
           /32 host LOCAL
        |-- 10.0.2.255
           /32 link BROADCAST
Local:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 10.0.2.0/24 2 0 2
        |-- 10.0.2.0
           /32 link BROADCAST
           /24 link UNICAST
        |-- 10.0.2.15
           /32 host LOCAL
        |-- 10.0.2.255
           /32 link BROADCAST
     +-- 127.0.0.0/8 2 0 2
        +-- 127.0.0.0/31 1 0 0
           |-- 127.0.0.0
              /8 host LOCAL
           |-- 127.0.0.1
              /8 host LOCAL
        |-- 127.255.255.255
           /32 link BROADCAST
     |-- 169.254.3.4
        /32 host LOCAL
     |-- 192.168.64.7
        /32 host LOCAL
"""

    def test_ips_come_from_the_kernel_table_with_no_ip_program(self):
        self.make_root(tux_user=True)
        (self.root / "proc/net").mkdir(parents=True)
        (self.root / "proc/net/fib_trie").write_text(self.FIB)
        self.runner.when(["ip"], rc=127, out="ip: not found\n")
        self.assertEqual(self.caps()["ips"], ["10.0.2.15", "192.168.64.7"])
        self.assertEqual(self.runner.called("ip"), [])
        self.assertEqual(caps_mod.fib_trie_ips("Main:\n  +-- 0.0.0.0/0 3 0 5\n"), [])
        self.assertEqual(caps_mod.fib_trie_ips(""), [])

    def test_ips_fall_back_to_ip_when_there_is_no_table(self):
        self.make_root(tux_user=True)
        self.assertEqual(self.caps()["ips"], ["10.0.2.15"])
        self.assertEqual(len(self.runner.called("ip")), 1)
        self.runner.when(["ip"], rc=127, out="")
        self.assertEqual(self.caps()["ips"], [])

    def test_the_real_kernel_table_parses_when_there_is_one(self):
        if not os.path.exists("/proc/net/fib_trie"):
            self.skipTest("no /proc/net/fib_trie here")
        for ip in caps_mod.fib_trie_ips(open("/proc/net/fib_trie").read()):
            self.assertRegex(ip, r"^\d+\.\d+\.\d+\.\d+$")
            self.assertFalse(ip.startswith("127."))

    def test_name_lookup_stays_in_the_budget(self):
        import socket
        orig = socket.getaddrinfo
        stop = threading.Event()
        socket.getaddrinfo = lambda *a, **k: (stop.wait(30), [])[1]
        try:
            t = time.monotonic()
            self.assertFalse(caps_mod.have_network(str(self.root), caps_mod.tcp_connect, budget=0.6))
            took = time.monotonic() - t
        finally:
            stop.set()
            socket.getaddrinfo = orig
        self.assertLess(took, 2.0)
        self.assertGreaterEqual(took, 0.5)

    def test_tcp_connect_takes_numbers_and_names(self):
        import socket
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(4)
        port = srv.getsockname()[1]
        try:
            self.assertTrue(caps_mod.tcp_connect("127.0.0.1", port, 2))
            self.assertTrue(caps_mod.tcp_connect("localhost", port, 2))
            self.assertFalse(caps_mod.tcp_connect("no-such-name.invalid", port, 2))
        finally:
            srv.close()
        self.assertFalse(caps_mod.tcp_connect("127.0.0.1", port, 2))

    def test_desktop_ssh_and_apps(self):
        self.runner.packages.update({"labwc": "1", "firefox-esr": "1", "git": "1", "openssh-server": "1"})
        (self.root / "etc/ssh/sshd_config.d/10-tux.conf").write_text("Port 2222\nPasswordAuthentication no\n")
        (self.root / "etc/ssh/sshd_config").write_text("Include /etc/ssh/sshd_config.d/*.conf\nPort 22\nPasswordAuthentication yes\n")
        self.runner.ssh_enabled = True
        c = self.caps()
        self.assertEqual((c["desktop"], c["image"]), ("labwc", "desktop"))
        self.assertEqual(c["ssh"], {"installed": True, "enabled": True, "port": 2222, "password_auth": False})
        self.assertTrue(c["apps"]["firefox"] and c["apps"]["git"] and not c["apps"]["vim"])
        self.runner.packages.update({"plasma-workspace": "1"})
        self.assertEqual(self.caps()["desktop"], "labwc")
        (self.root / "etc/tux").mkdir()
        (self.root / "etc/tux/session").write_text("plasma\n")
        self.assertEqual(self.caps()["desktop"], "plasma")

    def test_legacy(self):
        self.runner.packages["henge-guest"] = "1.0"
        self.assertTrue(self.caps()["legacy"])

    def test_report_script_print_and_post(self):
        self.make_root(tux_user=True)
        # --print builds and sends nothing
        saved, orig = sys.stdout, caps_mod.build_caps
        sys.stdout = io.StringIO()
        try:
            caps_mod.build_caps = lambda *a, **k: orig(self.runner, str(self.root), connect=lambda h, p, t: True)
            rc = caps_mod.main(["--print"])
            printed = sys.stdout.getvalue()
        finally:
            sys.stdout = saved
            caps_mod.build_caps = orig
        self.assertEqual(rc, 0)
        self.assertEqual(set(json.loads(printed)), CAPS_KEYS)
        self.assertEqual(self.host.events, [])
        # a report event reaches the host
        ev = caps_mod.report_event(3, "1.11.0+1", self.caps())
        self.assertEqual(caps_mod.post_event(ev), self.host.seq)
        self.assertEqual(self.host.of("report")[0]["n"], 3)
        # a failure to post is only logged, and the exit code stays 0
        self.host.close()
        os.environ["TUX_ADDITIONS_PORT"] = "1"
        err = io.StringIO()
        saved_save = caps_mod.save_last_report
        caps_mod.build_caps = lambda *a, **k: orig(self.runner, str(self.root), connect=lambda h, p, t: False)
        caps_mod.save_last_report = lambda ev, root="/": None
        try:
            with redirect_stderr(err):
                self.assertEqual(caps_mod.main([]), 0)
        finally:
            caps_mod.build_caps = orig
            caps_mod.save_last_report = saved_save
        self.assertIn("not sent", err.getvalue())


class Jobs(Case):
    def test_order_and_events(self):
        self.make_root(tux_user=True)
        self.run_job([{"action": "hostname.set", "name": "tuxbox"},
                      {"action": "apps.install", "ids": ["git", "htop"]},
                      {"action": "system.update"}])
        self.assertEqual([(i, s) for i, s, _ in self.steps()],
                         [(0, "running"), (0, "ok"), (1, "running"), (1, "ok"), (2, "running"), (2, "ok")])
        types = [e["t"] for e in self.host.events]
        self.assertEqual(types[0], "report")
        self.assertEqual(types[-2:], ["report", "done"])
        done = self.host.of("done")[0]
        self.assertEqual((done["job"], done["ok"], done["reboot"]), ("j-1", True, False))
        self.assertEqual(done["info"]["ips"], ["10.0.2.15"])
        self.assertEqual(done["info"]["user"], "tux")
        self.assertEqual(done["info"]["ssh_fingerprints"], [])
        order = [c.argv[:2] for c in self.runner.calls if c.argv[0] in ("hostnamectl", "apt-get")]
        self.assertEqual(order[0], ["hostnamectl", "set-hostname"])
        self.assertEqual([o[1] for o in order[1:]], ["update", "install", "update", "upgrade"])
        # one apt call for all packages of the ids, no recommends
        inst = self.runner.called("apt-get", "install")[0].argv
        self.assertEqual(inst[inst.index("--no-install-recommends") + 1:][-2:], ["git", "htop"])
        self.assertEqual(self.runner.called("apt-get", "install")[0].env.get("DEBIAN_FRONTEND"), "noninteractive")
        self.assertEqual(self.read("etc/hosts"), "127.0.0.1\tlocalhost\n127.0.1.1\ttuxbox\n::1\tlocalhost ip6-localhost\n")
        self.assertEqual(self.read("var/lib/tux/additions.json").count('"t": "report"'), 1)

    def test_failed_then_skipped(self):
        self.make_root(tux_user=True)
        self.runner.when(["hostnamectl"], rc=1)
        self.run_job([{"action": "additions.install"}, {"action": "hostname.set", "name": "x"},
                      {"action": "apps.install", "ids": ["git"]}, {"action": "system.update"}])
        f = self.final()
        self.assertEqual([f[i][0] for i in range(4)], ["ok", "failed", "skipped", "skipped"])
        self.assertTrue(f[2][1].startswith("Skipped"))
        self.assertFalse(self.host.of("done")[0]["ok"])
        self.assertEqual(self.runner.called("apt-get"), [])
        self.assertEqual([i for i, s, _ in self.steps() if s == "running"], [0, 1])

    def test_validation_reject_fails_that_step_and_skips_the_rest(self):
        self.make_root(tux_user=True)
        self.run_job([{"action": "hostname.set", "name": "good"}, {"action": "hostname.set", "name": "Bad_Name"},
                      {"action": "ssh.configure", "enabled": True, "port": 22}])
        f = self.final()
        self.assertEqual([f[i][0] for i in range(3)], ["ok", "failed", "skipped"])
        self.assertEqual(len(self.runner.called("hostnamectl")), 1)
        self.assertEqual(self.runner.called("sshd"), [])

    def test_unknown_ids_and_actions_fail(self):
        for step, word in (({"action": "desktop.install", "id": "gnome"}, "unknown id"),
                           ({"action": "apps.install", "ids": ["nope"]}, "unknown id"),
                           ({"action": "format.disk"}, "unknown action"),
                           ({"action": "ssh.configure", "enabled": True, "port": 99999}, "port")):
            self.setUp_again()
            self.run_job([step, {"action": "system.update"}])
            f = self.final()
            self.assertEqual(f[0][0], "failed", step)
            self.assertIn(word, f[0][1].lower())
            self.assertEqual(f[1][0], "skipped")
            self.assertEqual(self.runner.called("apt-get"), [])

    def test_bad_job_shape_ends_with_done_false(self):
        self.run_job("steps?", jid="j-bad")
        self.assertFalse(self.host.of("done")[0]["ok"])
        self.assertIn("Bad job", "".join(e["text"] for e in self.host.of("log")))
        self.assertEqual(self.host.of("step"), [])

    def test_no_network_fails_the_steps_that_need_it(self):
        self.make_root(tux_user=True)
        self.net = False
        for step in ({"action": "desktop.install", "id": "labwc"}, {"action": "apps.install", "ids": ["git"]},
                     {"action": "system.update"}):
            self.setUp_again()
            self.net = False
            t0 = time.time()
            self.run_job([step])
            self.assertEqual(self.final()[0], ("failed", "No network"))
            self.assertEqual(self.runner.called("apt-get"), [])
            self.assertLess(time.time() - t0, 5, "the step waited")

    def test_steps_without_network_still_run(self):
        self.make_root(tux_user=True)
        self.net = False
        self.runner.packages["openssh-server"] = "1"
        self.run_job([{"action": "hostname.set", "name": "offline"}, {"action": "ssh.configure", "enabled": True}])
        self.assertEqual([s for _, (s, _) in sorted(self.final().items())], ["ok", "ok"])

    def test_cancel_between_apt_calls(self):
        self.make_root(tux_user=True)
        self.runner.hooks.append(lambda argv: self.host.set_cancel() if argv[:2] == ["apt-get", "update"] else None)
        self.run_job([{"action": "hostname.set", "name": "x"}, {"action": "apps.install", "ids": ["git"]},
                      {"action": "system.update"}])
        f = self.final()
        self.assertEqual([f[i][0] for i in range(3)], ["ok", "failed", "skipped"])
        self.assertEqual(f[1][1], "Cancelled")
        self.assertEqual(f[2][1], "Cancelled")
        self.assertEqual(self.runner.called("apt-get", "install"), [])
        self.assertFalse(self.host.of("done")[0]["ok"])

    def test_cancel_between_steps_and_before_start(self):
        self.make_root(tux_user=True)
        self.runner.hooks.append(lambda argv: self.host.set_cancel() if argv[:1] == ["hostnamectl"] else None)
        self.run_job([{"action": "hostname.set", "name": "x"}, {"action": "hostname.set", "name": "y"}])
        f = self.final()
        self.assertEqual((f[0][0], f[1]), ("ok", ("skipped", "Cancelled")))
        self.assertEqual(len(self.runner.called("hostnamectl")), 1)

    def test_cancel_right_after_the_ack_skips_every_step(self):
        self.make_root(tux_user=True)
        self.host.after["ack"] = self.host.set_cancel
        self.run_job([{"action": "hostname.set", "name": "x"}, {"action": "hostname.set", "name": "y"}])
        self.assertEqual(self.final(), {0: ("skipped", "Cancelled"), 1: ("skipped", "Cancelled")})
        self.assertEqual(self.runner.called("hostnamectl"), [])
        self.assertFalse(self.host.of("done")[0]["ok"])

    def test_a_cancel_of_another_job_is_ignored(self):
        self.make_root(tux_user=True)
        self.host.cancel_job = "j-old"  # the cancel flag is true too, as the host sets it
        self.run_job([{"action": "hostname.set", "name": "x"}, {"action": "hostname.set", "name": "y"}])
        self.assertEqual([s for _, (s, _) in sorted(self.final().items())], ["ok", "ok"])
        self.assertTrue(self.host.of("done")[0]["ok"])

    def test_the_job_comes_from_the_job_field_only(self):
        self.make_root(tux_user=True)
        a = self.agent()
        self.host.taken = "j-1"  # a job that is taken is not in "job"; nothing to run
        t = threading.Thread(target=lambda: a.serve(), daemon=True)
        with redirect_stderr(io.StringIO()):
            t.start()
            time.sleep(0.3)
            self.host.eject()
            t.join(10)
        self.assertEqual([e["t"] for e in self.host.events], ["report"])

    def test_a_job_that_is_already_taken_is_not_run(self):
        self.make_root(tux_user=True)
        a = self.agent()
        self.host.taken = "j-1"
        self.host.set_job({"id": "j-1", "steps": [{"action": "hostname.set", "name": "x"}]})
        t = threading.Thread(target=lambda: a.serve(), daemon=True)
        with redirect_stderr(io.StringIO()):
            t.start()
            time.sleep(0.3)
            self.host.eject()
            t.join(10)
        self.assertEqual([e["t"] for e in self.host.events], ["report"])
        self.assertEqual(self.runner.called("hostnamectl"), [])

    def test_ack_is_the_first_event_after_the_report_and_the_host_drops_the_job(self):
        self.make_root(tux_user=True)
        seen = []
        self.host.after["ack"] = lambda: seen.append((self.host.job, self.host.taken))
        self.run_job([{"action": "hostname.set", "name": "x"}])
        types = [e["t"] for e in self.host.events]
        self.assertEqual(types[:3], ["report", "ack", "step"])
        self.assertEqual(self.host.of("ack"), [{"t": "ack", "job": "j-1"}])
        self.assertEqual(seen, [(None, "j-1")])
        self.assertIsNone(self.host.taken)  # done wipes the taken id

    def test_ack_for_a_bad_job_that_has_an_id(self):
        self.run_job("steps?", jid="j-bad")
        self.assertEqual([e["t"] for e in self.host.events][:2], ["report", "ack"])

    def test_busy_file_names_this_process_and_job_while_the_job_runs_and_goes_after(self):
        self.make_root(tux_user=True)
        busy = self.root / "run/tux/additions-busy"
        seen = []
        self.runner.hooks.append(lambda argv: seen.append(json.loads(busy.read_text())) if argv[:1] == ["hostnamectl"] else None)
        self.run_job([{"action": "hostname.set", "name": "x"}])
        self.assertEqual(seen, [{"pid": os.getpid(), "job": "j-1"}])
        self.assertFalse(busy.exists())

    def test_busy_file_goes_on_any_exit_path(self):
        self.make_root(tux_user=True)
        busy = self.root / "run/tux/additions-busy"

        def boom(argv):
            if argv[:1] == ["hostnamectl"]:
                raise KeyboardInterrupt()
        self.runner.hooks.append(boom)
        a = self.agent()
        with redirect_stderr(io.StringIO()), self.assertRaises(KeyboardInterrupt):
            a.run_job({"id": "j-9", "steps": [{"action": "hostname.set", "name": "x"}]})
        self.assertFalse(busy.exists())
        self.assertFalse(a.busy)
        # the SIGTERM path: the job ends, then the agent exits
        a = self.agent()
        a.stopping = True
        self.runner.hooks.clear()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            a.run_job({"id": "j-10", "steps": [{"action": "hostname.set", "name": "y"}]})
        self.assertFalse(busy.exists())

    def test_busy_file_of_another_process_stays(self):
        busy = self.root / "run/tux/additions-busy"
        busy.write_text(json.dumps({"pid": os.getpid() + 1, "job": "j-x"}))
        self.agent().busy_end()
        self.assertTrue(busy.exists())

    def test_same_job_does_not_run_twice(self):
        self.make_root(tux_user=True)
        self.run_job([{"action": "hostname.set", "name": "x"}])
        self.assertEqual(len(self.runner.called("hostnamectl")), 1)
        self.assertEqual(len(self.host.of("done")), 1)

    def test_additions_install_exit_codes(self):
        self.make_root(tux_user=True)
        for rc, word in ((0, "installed"), (3, "henge"), (4, "media check"), (2, "not supported"), (1, "failed")):
            self.setUp_again()
            self.runner.when(["sh"], rc=rc)
            self.run_job([{"action": "additions.install"}])
            s, m = self.final()[0]
            self.assertEqual(s, "ok" if rc == 0 else "failed", m)
            self.assertIn(word, m.lower())
            self.assertEqual(self.runner.called("sh")[0].argv, ["sh", str(ADD / "install")])

    def test_log_events_are_chunked(self):
        self.make_root(tux_user=True)
        big = "".join("line %05d é€\n" % i for i in range(1200))
        self.runner.apt_output = big
        self.run_job([{"action": "system.update"}])
        logs = self.host.of("log")
        self.assertGreater(len(logs), 2)
        self.assertTrue(all(len(e["text"].encode()) <= 4096 for e in logs))
        joined = "".join(e["text"] for e in logs)
        self.assertEqual(joined.count(big), 2)  # update and upgrade print it
        self.assertIn("$ apt-get update", joined)


class User(Case):
    def job(self, **kw):
        return [dict({"action": "user.setup"}, **kw)]

    def test_fresh_machine_creates_the_account(self):
        self.run_job(self.job(name="tux", password=PASSWORD))
        self.assertEqual(self.final()[0][0], "ok")
        add = self.runner.called("useradd")[0].argv
        self.assertEqual(add, ["useradd", "--create-home", "--shell", "/bin/bash", "--uid", "1000", "--groups",
                               "audio,video,sudo", "tux"])
        ch = self.runner.called("chpasswd")[0]
        self.assertEqual((ch.argv, ch.input), (["chpasswd"], "tux:%s\n" % PASSWORD))
        self.assertEqual(self.runner.called("passwd")[0].argv, ["passwd", "-l", "root"])
        marker = json.loads(self.read("var/lib/tux/account.json"))
        self.assertEqual(marker, {"configured": True, "name": "tux", "autologin": True, "sudo": True})
        rep = self.host.of("report")[-1]["caps"]["account"]
        self.assertEqual((rep["exists"], rep["configured"], rep["autologin"], rep["sudo"], rep["password_set"]),
                         (True, True, "user", True, False))
        self.assertEqual(self.host.of("done")[0]["info"]["user"], "tux")

    def test_getty_restarts_after_the_done_event(self):
        self.run_job(self.job(name="tux"))
        calls = self.runner.called("systemctl", "restart", "serial-getty@ttyAMA0.service")
        self.assertEqual(len(calls), 1)
        done_index = next(i for i, e in enumerate(self.host.events) if e["t"] == "done")
        self.assertGreater(calls[0].at, done_index)

    def test_choices_autologin_off_sudo_off_root_unlocked(self):
        self.make_root(tux_user=True)
        (self.root / "etc/sudoers.d/tux").write_text("tux ALL=(ALL) NOPASSWD:ALL\n")
        self.run_job(self.job(autologin=False, sudo=False, lock_root=False))
        self.assertEqual(self.runner.called("useradd"), [])
        self.assertEqual(self.runner.called("gpasswd")[0].argv, ["gpasswd", "-d", "tux", "sudo"])
        self.assertEqual(self.runner.called("passwd"), [])
        self.assertEqual(self.runner.called("chpasswd"), [])
        self.assertEqual(json.loads(self.read("var/lib/tux/account.json"))["autologin"], False)
        self.assertIn("moved aside", self.final()[0][1])
        self.assertFalse((self.root / "etc/sudoers.d/tux").exists())
        self.assertEqual(self.read("etc/sudoers.d/tux.tux-disabled"), "tux ALL=(ALL) NOPASSWD:ALL\n")
        self.assertNotIn("still gives sudo", self.final()[0][1])
        self.assertEqual(self.host.of("report")[-1]["caps"]["account"]["autologin"], "none")

    def sudoers_stays(self, text):
        self.make_root(tux_user=True)
        (self.root / "etc/sudoers.d/tux").write_text(text)
        self.run_job(self.job(sudo=False, lock_root=False))
        self.assertEqual(self.read("etc/sudoers.d/tux"), text)
        self.assertFalse((self.root / "etc/sudoers.d/tux.tux-disabled").exists())
        self.assertIn("/etc/sudoers.d/tux still gives sudo", self.final()[0][1])

    def test_sudo_false_leaves_a_sudoers_file_with_other_rules(self):
        self.sudoers_stays("tux ALL=(ALL) ALL\n")

    def test_sudo_false_leaves_a_sudoers_file_with_a_comment_added(self):
        self.sudoers_stays("tux ALL=(ALL) NOPASSWD:ALL\n# mine\n")

    def test_sudo_false_leaves_a_sudoers_file_with_no_final_newline(self):
        self.sudoers_stays("tux ALL=(ALL) NOPASSWD:ALL")

    def test_sudo_true_keeps_the_stock_sudoers_file(self):
        self.make_root(tux_user=True)
        (self.root / "etc/sudoers.d/tux").write_text("tux ALL=(ALL) NOPASSWD:ALL\n")
        self.run_job(self.job(sudo=True))
        self.assertTrue((self.root / "etc/sudoers.d/tux").exists())
        self.assertFalse((self.root / "etc/sudoers.d/tux.tux-disabled").exists())

    def test_sudo_false_other_account_name_still_moves_the_stock_file_while_tux_has_no_password(self):
        self.make_root(tux_user=True)
        (self.root / "etc/sudoers.d/tux").write_text("tux ALL=(ALL) NOPASSWD:ALL\n")
        self.run_job(self.job(name="sam", sudo=False, lock_root=False))
        self.assertFalse((self.root / "etc/sudoers.d/tux").exists())

    def test_other_name_and_uid_taken(self):
        self.make_root()
        (self.root / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/bash\npat:x:1000:1000::/home/pat:/bin/bash\n")
        self.run_job(self.job(name="sam"))
        add = self.runner.called("useradd")[0].argv
        self.assertNotIn("--uid", add)
        self.assertIn("~/Tux still uses /home/tux", self.final()[0][1])

    def test_another_name_renames_the_stock_tux(self):
        self.make_root(tux_user=True)
        (self.root / "etc/group").write_text((self.root / "etc/group").read_text() + "tux:x:1000:\n")
        (self.root / "etc/sudoers.d/tux").write_text("tux ALL=(ALL) NOPASSWD:ALL\n")
        (self.root / "etc/systemd/system/getty@tty1.service.d").mkdir(parents=True)
        tty1 = self.root / "etc/systemd/system/getty@tty1.service.d/autologin.conf"
        tty1.write_text("[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin tux --noclear %I $TERM\n")
        (self.root / "usr/lib/systemd/system").mkdir(parents=True)
        (self.root / "usr/lib/systemd/system/home-tux-Tux.mount").write_text(
            "[Mount]\nWhere=/home/tux/Tux\nOptions=noauto,uid=tux,gid=tux,conf=/etc/tux/davfs2.conf\n")
        (self.root / "usr/lib/systemd/system/home-tux-Tux.automount").write_text("[Automount]\nWhere=/home/tux/Tux\n")
        self.run_job(self.job(name="sam", password=PASSWORD))
        s, m = self.final()[0]
        self.assertEqual(s, "ok", m)
        self.assertIn("renamed to sam", m)
        self.assertEqual(self.runner.called("useradd"), [])
        self.assertEqual(self.runner.called("usermod")[0].argv, ["usermod", "-l", "sam", "-d", "/home/sam", "-m", "tux"])
        self.assertEqual(self.runner.called("groupmod")[0].argv, ["groupmod", "-n", "sam", "tux"])
        passwd = (self.root / "etc/passwd").read_text()
        self.assertIn("sam:x:1000:1000", passwd)
        self.assertNotIn("tux:", passwd)
        self.assertEqual(self.runner.called("passwd", "-l", "tux"), [])
        # the account is signed in on tty1 by name, and the stock sudo file is out of the way
        self.assertIn("--autologin sam ", tty1.read_text())
        self.assertFalse((self.root / "etc/sudoers.d/tux").exists())
        # the shared folder mount follows the account
        mount = (self.root / "etc/systemd/system/home-sam-Tux.mount").read_text()
        self.assertIn("Where=/home/sam/Tux", mount)
        self.assertIn("uid=sam,gid=sam", mount)
        self.assertTrue((self.root / "etc/systemd/system/home-sam-Tux.automount").exists())
        self.assertEqual([c.argv[2] for c in self.runner.called("systemctl", "restart")],
                         ["serial-getty@ttyAMA0.service", "getty@tty1.service"])

    def test_no_autologin_removes_the_tty1_login_of_a_desktop_image(self):
        self.make_root(tux_user=True)
        (self.root / "etc/systemd/system/getty@tty1.service.d").mkdir(parents=True)
        tty1 = self.root / "etc/systemd/system/getty@tty1.service.d/autologin.conf"
        tty1.write_text("[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin tux --noclear %I $TERM\n")
        self.run_job(self.job(name="tux", password=PASSWORD, autologin=False))
        self.assertFalse(tty1.exists())

    def test_existing_account_gets_sudo_back(self):
        self.make_root(tux_user=True)
        self.runner.add_member("sudo", "tux", remove=True)
        self.run_job(self.job(sudo=True))
        self.assertEqual(self.runner.called("usermod")[0].argv, ["usermod", "-aG", "sudo", "tux"])

    def test_failures_do_not_write_the_marker(self):
        self.runner.when(["chpasswd"], rc=1)
        self.run_job(self.job(name="tux", password=PASSWORD))
        self.assertEqual(self.final()[0], ("failed", "The password was not set"))
        self.assertFalse((self.root / "var/lib/tux/account.json").exists())
        self.assertEqual(self.runner.called("systemctl", "restart", "serial-getty@ttyAMA0.service"), [])

    CHANGES = ("useradd", "usermod", "gpasswd", "chpasswd", "passwd")

    def refused(self, step, word):
        before = (self.root / "etc/passwd").read_text()
        self.run_job([step])
        s, m = self.final()[0]
        self.assertEqual(s, "failed", step)
        self.assertIn(word, m.lower())
        for prog in self.CHANGES:
            self.assertEqual(self.runner.called(prog), [], prog)
        self.assertEqual((self.root / "etc/passwd").read_text(), before)
        self.assertFalse((self.root / "var/lib/tux/account.json").exists())
        self.assertEqual(self.runner.called("systemctl", "restart", "serial-getty@ttyAMA0.service"), [])

    def test_a_name_with_another_uid_is_refused(self):
        for name in ("root", "daemon", "sshd", "www-data"):
            self.setUp_again()
            with open(self.root / "etc/passwd", "a") as f:
                f.write("daemon:x:1:1::/usr/sbin:/usr/sbin/nologin\nsshd:x:105:65534::/run/sshd:/usr/sbin/nologin\n"
                        "www-data:x:33:33::/var/www:/bin/sh\n")
            self.refused(dict(self.job(name=name)[0], lock_root=False), "not a login account")

    def test_an_account_with_no_login_shell_is_refused(self):
        for shell in ("/usr/sbin/nologin", "/bin/false", "/sbin/nologin"):
            self.setUp_again()
            (self.root / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/bash\ntux:x:1000:1000::/home/tux:%s\n" % shell)
            self.refused(self.job(name="tux")[0], "no login shell")

    def test_ending_root_sign_in_needs_sudo(self):
        self.make_root(tux_user=True)
        self.refused(self.job(name="tux", sudo=False, lock_root=True)[0], "no sudo")

    def test_ending_root_sign_in_needs_the_sudo_group_to_exist(self):
        self.make_root(tux_user=True)
        (self.root / "etc/group").write_text("root:x:0:\naudio:x:29:\nvideo:x:44:\n")
        self.refused(self.job(name="tux", sudo=True, lock_root=True)[0], "sudo group is missing")

    def test_root_stays_open_without_sudo_when_asked(self):
        self.make_root(tux_user=True)
        self.run_job(self.job(sudo=False, lock_root=False, autologin=False))
        self.assertEqual(self.final()[0][0], "ok")
        self.assertEqual(self.runner.called("passwd"), [])
        self.assertTrue((self.root / "var/lib/tux/account.json").exists())

    def test_order_is_password_then_marker_then_root_lock_then_getty_after_done(self):
        marker = self.root / "var/lib/tux/account.json"
        seen = []
        self.runner.hooks.append(lambda argv: seen.append((argv[0], marker.exists())) if argv[0] in ("chpasswd", "passwd") else None)
        self.run_job(self.job(name="tux", password=PASSWORD))
        self.assertEqual(seen, [("chpasswd", False), ("passwd", True)])
        names = [c.argv[0] for c in self.runner.calls if c.argv[0] in ("useradd", "chpasswd", "passwd", "systemctl")
                 and c.argv[:2] != ["systemctl", "is-enabled"]]
        self.assertEqual(names, ["useradd", "chpasswd", "passwd", "systemctl", "systemctl"])
        self.assertEqual([c.argv[2] for c in self.runner.called("systemctl", "restart")],
                         ["serial-getty@ttyAMA0.service", "getty@tty1.service"])
        done_index = next(i for i, e in enumerate(self.host.events) if e["t"] == "done")
        self.assertGreater(self.runner.called("systemctl", "restart")[0].at, done_index)

    def test_a_desktop_keeps_tty1(self):
        self.make_root(tux_user=True)
        (self.root / "usr/bin").mkdir(parents=True, exist_ok=True)
        (self.root / "usr/bin/labwc").write_text("")
        self.run_job(self.job(name="tux", password=PASSWORD))
        self.assertEqual([c.argv[2] for c in self.runner.called("systemctl", "restart")], ["serial-getty@ttyAMA0.service"])

    def test_a_marker_that_cannot_be_written_leaves_root_open(self):
        self.make_root(tux_user=True)
        (self.root / "var/lib/tux/account.json").mkdir()  # the rename over it fails
        self.run_job(self.job(name="tux", password=PASSWORD))
        s, m = self.final()[0]
        self.assertEqual(s, "failed")
        self.assertIn("root sign-in stays open", m.lower())
        self.assertEqual(self.runner.called("passwd"), [])
        self.assertEqual(self.runner.called("systemctl", "restart", "serial-getty@ttyAMA0.service"), [])
        self.assertNotIn(PASSWORD, m)

    def test_a_root_lock_that_fails_keeps_the_marker_and_the_getty_restart(self):
        self.make_root(tux_user=True)
        self.runner.when(["passwd", "-l", "root"], rc=1)
        self.run_job(self.job(name="tux"))
        self.assertEqual(self.final()[0], ("failed", "Root sign-in was not locked"))
        self.assertTrue((self.root / "var/lib/tux/account.json").exists())
        self.assertEqual(len(self.runner.called("systemctl", "restart", "serial-getty@ttyAMA0.service")), 1)

    def test_a_new_account_with_no_password_gets_an_empty_one(self):
        self.run_job(self.job(name="tux", autologin=False))
        self.assertEqual(self.runner.called("passwd", "-d")[0].argv, ["passwd", "-d", "tux"])
        self.assertEqual(self.runner.called("chpasswd"), [])

    def test_an_existing_account_with_no_password_given_keeps_its_password(self):
        self.make_root(tux_user=True)
        self.run_job(self.job(name="tux"))
        self.assertEqual(self.runner.called("passwd", "-d"), [])

    def test_a_new_account_with_a_password_does_not_get_an_empty_one(self):
        self.run_job(self.job(name="tux", password=PASSWORD))
        self.assertEqual(self.runner.called("passwd", "-d"), [])

    def test_another_name_replaces_the_stock_account_that_has_no_password(self):
        self.make_root(tux_user=True)
        (self.root / "etc/sudoers.d/tux").write_text("tux ALL=(ALL) NOPASSWD:ALL\n")
        self.run_job(self.job(name="sam", password=PASSWORD))
        s, m = self.final()[0]
        self.assertEqual(s, "ok", m)
        self.assertEqual([c.argv for c in self.runner.called("passwd")], [["passwd", "-l", "root"]])
        self.assertFalse((self.root / "etc/sudoers.d/tux").exists())
        self.assertEqual(self.read("etc/sudoers.d/tux.tux-disabled"), "tux ALL=(ALL) NOPASSWD:ALL\n")
        self.assertIn("renamed to sam", m)
        self.assertNotIn("tux:", self.read("etc/passwd"))
        self.assertEqual(json.loads(self.read("var/lib/tux/account.json"))["name"], "sam")

    def test_another_name_leaves_a_stock_account_that_has_a_password(self):
        self.make_root(tux_user=True)
        (self.root / "etc/shadow").write_text("root:*:1:::::\ntux:$6$x$y:1:::::\n")
        (self.root / "etc/sudoers.d/tux").write_text("tux ALL=(ALL) NOPASSWD:ALL\n")
        self.run_job(self.job(name="sam", password=PASSWORD))
        self.assertEqual([c.argv for c in self.runner.called("passwd")], [["passwd", "-l", "root"]])
        self.assertTrue((self.root / "etc/sudoers.d/tux").exists())

    def test_the_stock_account_is_not_locked_when_it_is_the_account(self):
        self.make_root(tux_user=True)
        self.run_job(self.job(name="tux", password=PASSWORD))
        self.assertEqual([c.argv for c in self.runner.called("passwd")], [["passwd", "-l", "root"]])

    def test_a_failed_rename_fails_the_step_and_root_stays_open(self):
        self.make_root(tux_user=True)
        self.runner.when(["usermod", "-l"], rc=1)
        self.run_job(self.job(name="sam", password=PASSWORD))
        self.assertEqual(self.final()[0], ("failed", "The stock account tux was not renamed"))
        self.assertNotIn(["passwd", "-l", "root"], [c.argv for c in self.runner.calls])

    def test_no_password_anywhere(self):
        self.runner.when(["chpasswd"], out="chpasswd echoes %s here\n" % PASSWORD)
        self.runner.apt_output = "after the password %s apt prints it\n" % PASSWORD
        self.runner.packages["openssh-server"] = "1"
        err = self.run_job([{"action": "user.setup", "name": "tux", "password": PASSWORD},
                            {"action": "apps.install", "ids": ["git"]},
                            {"action": "ssh.configure", "enabled": True, "authorized_key": KEY}])
        needle = PASSWORD.encode()
        for body in self.host.bodies:
            self.assertNotIn(needle, body)
        self.assertNotIn(PASSWORD, err)
        for c in self.runner.calls:
            self.assertNotIn(PASSWORD, " ".join(c.argv))
            self.assertNotIn(PASSWORD, json.dumps(c.env))
            if c.argv[0] != "chpasswd":
                self.assertFalse(c.input and PASSWORD in c.input)
        for p in self.root.rglob("*"):
            if p.is_file():
                self.assertNotIn(needle, p.read_bytes(), str(p))
        logs = "".join(e["text"] for e in self.host.of("log"))
        self.assertIn("***", logs)
        self.assertNotIn("$ chpasswd", logs)
        self.assertEqual(self.agent_obj.secrets, [])


class Ssh(Case):
    def setUp(self):
        super().setUp()
        self.make_root(tux_user=True)
        self.runner.packages["openssh-server"] = "1"
        self.conf = self.root / "etc/ssh/sshd_config.d/10-tux.conf"

    def step(self, **kw):
        return [dict({"action": "ssh.configure", "enabled": True}, **kw)]

    def test_writes_config_checks_and_enables(self):
        self.run_job(self.step(port=2222, password_auth=False, root_login=False, authorized_key=KEY))
        self.assertEqual(self.final()[0], ("ok", "SSH is on, port 2222"))
        self.assertEqual(self.conf.read_text(), agent.sshd_conf(2222, False, False))
        calls = [c.argv for c in self.runner.calls if c.argv[0] in ("sshd", "systemctl")]
        i = calls.index(["sshd", "-t"])
        self.assertLess(i, calls.index(["systemctl", "enable", "ssh.service"]))
        self.assertLess(calls.index(["systemctl", "enable", "ssh.service"]), calls.index(["systemctl", "restart", "ssh.service"]))
        ak = self.root / "home/tux/.ssh/authorized_keys"
        self.assertEqual(ak.read_text(), KEY + "\n")
        self.assertEqual(stat.S_IMODE(ak.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(ak.parent.stat().st_mode), 0o700)
        self.assertEqual(self.host.of("done")[0]["info"]["ssh_fingerprints"], [])  # no host key files in the fake root

    def test_fingerprints_in_done(self):
        (self.root / "etc/ssh/ssh_host_ed25519_key.pub").write_text("ssh-ed25519 AAAA root@fake\n")
        self.run_job(self.step())
        self.assertEqual(self.host.of("done")[0]["info"]["ssh_fingerprints"], ["256 SHA256:abcdefghijklmnop root@fake (ED25519)"])

    def test_rollback_when_sshd_t_fails(self):
        self.conf.write_text("# the old file\nPort 2200\n")
        self.runner.sshd_rc = 1
        self.run_job(self.step(port=2222, authorized_key=KEY) + [{"action": "system.update"}])
        self.assertEqual(self.conf.read_text(), "# the old file\nPort 2200\n")
        f = self.final()
        self.assertEqual((f[0][0], f[1][0]), ("failed", "skipped"))
        self.assertIn("old file is back", f[0][1])
        self.assertFalse((self.root / "home/tux/.ssh/authorized_keys").exists())
        self.assertEqual(self.runner.called("systemctl", "restart", "ssh.service"), [])

    def test_rollback_removes_a_new_file(self):
        self.runner.sshd_rc = 1
        self.run_job(self.step())
        self.assertFalse(self.conf.exists())

    def test_key_is_written_once(self):
        self.run_job(self.step(authorized_key=KEY), jid="j-a")
        self.setUp_again2()
        self.run_job(self.step(authorized_key=KEY), jid="j-b")
        self.assertEqual((self.root / "home/tux/.ssh/authorized_keys").read_text().count("AAAAC3NzaC1lZDI1NTE5"), 1)

    def setUp_again2(self):
        self.host.events.clear()
        self.host.inserted = True

    def test_disable(self):
        self.run_job(self.step(enabled=False))
        self.assertEqual(self.final()[0], ("ok", "SSH is off"))
        self.assertEqual(self.runner.called("systemctl", "disable", "--now", "ssh.service")[0].argv[-1], "ssh.service")
        self.assertEqual(self.runner.called("systemctl", "restart"), [])

    def test_installs_openssh_from_the_media_when_missing(self):
        del self.runner.packages["openssh-server"]
        self.net = False
        self.run_job(self.step())
        self.assertEqual(self.final()[0][0], "ok")
        argvs = [c.argv for c in self.runner.called("apt-get")]
        self.assertTrue(any("Dir::Etc::sourcelist=/var/lib/tux/additions/apt-work/sources.list" in a for a in argvs[0]))
        self.assertEqual(argvs[1][-1], "openssh-server")
        self.assertEqual(argvs[0][0], "apt-get")
        self.assertFalse((self.root / "var/lib/tux/additions/apt-work").exists())

    POLICY = "usr/sbin/policy-rc.d"

    def fresh(self):
        del self.runner.packages["openssh-server"]
        self.net = False

    def is_server_install(self, argv):
        return argv[:1] == ["apt-get"] and "install" in argv and argv[-1] == "openssh-server"

    def test_policy_rc_d_blocks_the_start_while_openssh_installs_and_goes_after(self):
        self.fresh()
        seen = []

        def look(argv):
            if self.is_server_install(argv):
                p = self.root / self.POLICY
                seen.append((p.read_text(), stat.S_IMODE(p.stat().st_mode)))
        self.runner.hooks.append(look)
        self.run_job(self.step())
        self.assertEqual(self.final()[0][0], "ok")
        self.assertEqual(seen, [("#!/bin/sh\nexit 101\n", 0o755)])
        self.assertFalse((self.root / self.POLICY).exists())
        self.assertEqual([p.name for p in (self.root / "usr/sbin").iterdir()], [])  # no temp file stays

    def test_an_existing_policy_rc_d_is_left_alone(self):
        self.fresh()
        (self.root / "usr/sbin").mkdir(parents=True)
        (self.root / self.POLICY).write_text("#!/bin/sh\nexit 0\n")
        self.run_job(self.step())
        self.assertEqual(self.final()[0][0], "ok")
        self.assertEqual((self.root / self.POLICY).read_text(), "#!/bin/sh\nexit 0\n")

    def test_policy_rc_d_goes_when_the_install_fails(self):
        self.fresh()
        orig = self.runner.default

        def default(argv, input):
            if self.is_server_install(argv):
                return 100, "E: failed\n"
            return orig(argv, input)
        self.runner.default = default
        self.run_job(self.step())
        self.assertEqual(self.final()[0], ("failed", "openssh-server was not installed"))
        self.assertFalse((self.root / self.POLICY).exists())
        self.assertEqual(self.runner.called("sshd"), [])

    def test_policy_rc_d_is_not_made_when_the_repository_does_not_load(self):
        self.fresh()
        self.runner.when(["apt-get", "-o"], rc=100)
        self.run_job(self.step())
        self.assertEqual(self.final()[0], ("failed", "The local repository did not load"))
        self.assertFalse((self.root / self.POLICY).exists())
        self.assertEqual(self.runner.called("systemctl", "disable"), [])  # nothing was installed

    DISABLE = ["systemctl", "disable", "--now", "ssh.service"]

    def test_a_failure_after_this_step_installed_sshd_stops_and_disables_it(self):
        for why in ("sshd -t", "restart", "key"):
            self.setUp_again()
            self.root.joinpath("home/tux/.ssh").mkdir(mode=0o700)
            self.fresh()
            kw = {}
            if why == "sshd -t":
                self.runner.sshd_rc = 1
            elif why == "restart":
                self.runner.when(["systemctl", "restart", "ssh.service"], rc=1)
            else:
                os.symlink("../../../etc/passwd", self.root / "home/tux/.ssh/authorized_keys")
                kw["authorized_key"] = KEY
            self.run_job(self.step(**kw))
            self.assertEqual(self.final()[0][0], "failed", why)
            self.assertEqual(len(self.runner.called(*self.DISABLE)), 1, why)
            self.assertFalse((self.root / self.POLICY).exists(), why)

    def test_a_failure_with_sshd_already_installed_does_not_stop_it(self):
        self.runner.sshd_rc = 1
        self.run_job(self.step())
        self.assertEqual(self.final()[0][0], "failed")
        self.assertEqual(self.runner.called("systemctl", "disable"), [])

    def test_a_good_install_does_not_disable_sshd(self):
        self.fresh()
        self.run_job(self.step())
        self.assertEqual(self.runner.called("systemctl", "disable"), [])
        self.assertEqual(self.runner.called("systemctl", "enable")[0].argv, ["systemctl", "enable", "ssh.service"])

    def test_key_without_account_fails(self):
        self.make_root(tux_user=False)
        self.run_job(self.step(authorized_key=KEY))
        self.assertEqual(self.final()[0][0], "failed")
        self.assertIn("account", self.final()[0][1].lower())
        self.assertEqual(self.runner.called("sshd"), [])


class Safety(Case):
    """The account owns its home, so it can plant links there. The agent runs as root and must not follow them."""

    def setUp(self):
        super().setUp()
        self.make_root(tux_user=True)
        self.runner.packages["openssh-server"] = "1"
        self.home = self.root / "home/tux"
        self.passwd_text = (self.root / "etc/passwd").read_text()
        self.etc_mode = stat.S_IMODE((self.root / "etc").stat().st_mode)

    def ssh_job(self):
        self.run_job([{"action": "ssh.configure", "enabled": True, "authorized_key": KEY}])
        return self.final()[0]

    def untouched(self):
        self.assertEqual((self.root / "etc/passwd").read_text(), self.passwd_text)
        self.assertEqual(stat.S_IMODE((self.root / "etc").stat().st_mode), self.etc_mode)
        self.assertEqual(sorted(p.name for p in (self.root / "etc").iterdir() if p.name.startswith((".", "authorized"))), [])

    def no_temp_files(self):
        left = [str(p) for p in self.root.rglob("*.tux-new")]
        self.assertEqual(left, [])

    def test_the_old_temp_name_as_a_link_to_passwd_is_not_written_through(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o700)
        os.symlink("../../../etc/passwd", ssh / "authorized_keys.tux-new")
        (ssh / "authorized_keys").write_text("root:x:0:0:evil:/root:/bin/sh\n")
        s, m = self.ssh_job()
        self.assertEqual(s, "ok", m)
        self.untouched()
        ak = ssh / "authorized_keys"
        self.assertEqual(ak.read_text(), "root:x:0:0:evil:/root:/bin/sh\n" + KEY + "\n")
        self.assertEqual(stat.S_IMODE(ak.stat().st_mode), 0o600)
        self.assertTrue((ssh / "authorized_keys.tux-new").is_symlink())

    def test_a_ssh_folder_that_is_a_link_to_etc_is_refused(self):
        os.symlink("../../etc", self.home / ".ssh")
        s, m = self.ssh_job()
        self.assertEqual(s, "failed")
        self.assertIn("link", m)
        self.untouched()

    def test_authorized_keys_that_is_a_link_to_passwd_is_refused(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o700)
        os.symlink("../../../etc/passwd", ssh / "authorized_keys")
        s, m = self.ssh_job()
        self.assertEqual((s, "link" in m), ("failed", True))
        self.untouched()
        self.no_temp_files()

    def test_a_home_that_is_a_link_is_refused(self):
        shutil.rmtree(self.home)
        os.symlink("../etc", self.home)
        s, m = self.ssh_job()
        self.assertEqual(s, "failed")
        self.untouched()
        self.assertFalse((self.root / "etc/.ssh").exists())

    def test_a_missing_home_fails_the_step(self):
        shutil.rmtree(self.home)
        s, m = self.ssh_job()
        self.assertEqual((s, m), ("failed", "The home folder of the account is missing"))
        self.assertFalse(self.home.exists())

    def test_a_ssh_that_is_a_file_is_refused(self):
        (self.home / ".ssh").write_text("x")
        self.assertEqual(self.ssh_job()[0], "failed")
        self.assertEqual((self.home / ".ssh").read_text(), "x")

    def test_authorized_keys_that_is_a_pipe_is_refused_and_does_not_block(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o700)
        os.mkfifo(ssh / "authorized_keys")
        t0 = time.time()
        s, m = self.ssh_job()
        self.assertEqual((s, "plain file" in m), ("failed", True))
        self.assertLess(time.time() - t0, 10)

    def test_authorized_keys_with_a_second_name_is_refused_and_the_other_name_is_not_read(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o700)
        os.link(self.root / "etc/shadow", ssh / "authorized_keys")
        shadow = (self.root / "etc/shadow").read_text()
        s, m = self.ssh_job()
        self.assertEqual((s, "plain file" in m), ("failed", True))
        self.assertEqual((self.root / "etc/shadow").read_text(), shadow)
        self.assertEqual(stat.S_IMODE((self.root / "etc/shadow").stat().st_mode), 0o644)

    def test_a_new_ssh_folder_is_made_with_mode_700(self):
        s, m = self.ssh_job()
        self.assertEqual(s, "ok", m)
        self.assertEqual(stat.S_IMODE((self.home / ".ssh").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.home / ".ssh/authorized_keys").stat().st_mode), 0o600)
        self.no_temp_files()

    def test_an_existing_key_file_gets_mode_600_through_the_open_file(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o755)
        (ssh / "authorized_keys").write_text(KEY + "\n")
        os.chmod(ssh / "authorized_keys", 0o666)
        s, m = self.ssh_job()
        self.assertEqual(s, "ok", m)
        self.assertEqual(stat.S_IMODE((ssh / "authorized_keys").stat().st_mode), 0o600)
        self.assertEqual((ssh / "authorized_keys").read_text(), KEY + "\n")
        self.assertEqual(stat.S_IMODE(ssh.stat().st_mode), 0o700)

    # the FS class on its own
    def fs(self):
        return agent.FS(str(self.root))

    def test_write_does_not_follow_a_link_in_the_path(self):
        os.symlink("../../etc", self.home / "d")
        with self.assertRaises(agent.StepError):
            self.fs().write("/home/tux/d/x", "text")
        self.assertFalse((self.root / "etc/x").exists())
        self.no_temp_files()

    def test_write_replaces_a_link_at_the_name_and_never_follows_it(self):
        os.symlink("../../etc/passwd", self.home / "f")
        self.fs().write("/home/tux/f", "mine\n", 0o600)
        self.assertEqual((self.root / "etc/passwd").read_text(), self.passwd_text)
        self.assertFalse((self.home / "f").is_symlink())
        self.assertEqual((self.home / "f").read_text(), "mine\n")
        self.assertEqual(stat.S_IMODE((self.home / "f").stat().st_mode), 0o600)

    def test_mkdir_does_not_chmod_through_a_link(self):
        os.symlink("../../etc", self.home / ".ssh")
        with self.assertRaises(agent.StepError):
            self.fs().mkdir("/home/tux/.ssh", 0o700, os.geteuid(), os.getegid())
        self.untouched()

    def test_dot_dot_is_refused(self):
        for path in ("/home/../etc/x", "/home/tux/./x"):
            with self.assertRaises(agent.StepError):
                self.fs().write(path, "t")
        with self.assertRaises(agent.StepError):
            self.fs().unlink("/home/tux/../../etc/passwd")
        self.untouched()

    def test_a_folder_of_another_owner_is_refused_unless_it_is_the_account(self):
        fs = self.fs()
        fs.trusted = {-5}  # as if root were someone else: the test's own user owns everything here
        with self.assertRaises(agent.StepError) as cm:
            fs.write("/home/tux/x", "t")
        self.assertIn("not owned", str(cm.exception))
        fs.write("/home/tux/x", "t", uid=os.geteuid(), gid=os.getegid())  # the account may own the folders
        self.assertEqual((self.home / "x").read_text(), "t")
        a = self.agent()
        a.fs.trusted = {-5}
        with self.assertRaises(agent.StepError):
            a.add_key("tux", {"uid": os.geteuid() + 1, "gid": 1, "home": "/home/tux"}, KEY)
        self.assertFalse((self.home / ".ssh").exists())

    def test_rename_and_unlink_stay_in_their_folders(self):
        os.symlink("../../etc", self.home / "d")
        for call in (lambda: self.fs().rename("/home/tux/d/passwd", "/home/tux/p"),
                     lambda: self.fs().unlink("/home/tux/d/passwd")):
            with self.assertRaises(agent.StepError):
                call()
        self.untouched()

    def test_a_failed_write_leaves_no_temp_file(self):
        (self.home / "dir").mkdir()
        with self.assertRaises(OSError):
            self.fs().write("/home/tux/dir", "t")  # a rename of a file over a folder fails
        self.no_temp_files()
        self.assertTrue((self.home / "dir").is_dir())


class Desktop(Case):
    AUTO = "etc/systemd/system/getty@tty1.service.d/autologin.conf"

    def marker(self, autologin, name="tux"):
        (self.root / "var/lib/tux/account.json").write_text(json.dumps(
            {"configured": True, "name": name, "autologin": autologin, "sudo": True}))

    def test_labwc_installs_packages_then_session_files(self):
        self.make_root(tux_user=True)
        self.marker(True)
        self.run_job([{"action": "desktop.install", "id": "labwc"}])
        self.assertEqual(self.final()[0][0], "ok", self.final())
        argvs = [c.argv for c in self.runner.called("apt-get")]
        self.assertEqual(argvs[0][:2], ["apt-get", "update"])
        pk = argvs[1][argvs[1].index("--no-install-recommends") + 1:]
        self.assertIn("labwc", pk)
        self.assertIn("foot", pk)
        auto = self.read("etc/systemd/system/getty@tty1.service.d/autologin.conf")
        self.assertIn("--autologin tux ", auto)
        self.assertNotIn("@USER@", auto)
        self.assertEqual(stat.S_IMODE((self.root / "usr/local/bin/tux-session").stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((self.root / "etc/xdg/labwc/rc.xml").stat().st_mode), 0o644)
        for rel in ("usr/local/bin/tux-display", "etc/xdg/labwc/autostart", "etc/profile.d/tux-desktop.sh",
                    "etc/wireplumber/wireplumber.conf.d/50-tux.conf",
                    "usr/share/wireplumber/scripts/tux/keep-device-volume.lua"):
            self.assertTrue((self.root / rel).is_file(), rel)
        self.assertEqual(self.runner.called("usermod")[0].argv, ["usermod", "-aG", "video,render,input,dialout,audio", "tux"])
        self.assertEqual(self.runner.called("systemctl", "enable")[0].argv, ["systemctl", "enable", "getty@tty1.service"])
        self.assertTrue(self.host.of("done")[0]["reboot"])
        self.assertEqual(self.host.of("report")[-1]["caps"]["desktop"], "labwc")  # the report after the job sees it

    def test_the_tty1_sign_in_is_written_only_when_the_marker_says_autologin(self):
        for marker in (False, None, "bad"):
            self.setUp_again()
            if marker == "bad":
                (self.root / "var/lib/tux/account.json").write_text('{"configured": true, "name": "tux", "autologin": "true"}')
            elif marker is not None:
                self.marker(marker)
            self.run_job([{"action": "desktop.install", "id": "labwc"}])
            self.assertEqual(self.final()[0][0], "ok", marker)
            self.assertFalse((self.root / self.AUTO).exists(), marker)
            self.assertFalse((self.root / "etc/systemd/system/getty@tty1.service.d").exists(), marker)
            self.assertTrue((self.root / "usr/local/bin/tux-session").is_file())  # the other session files stay
            self.assertEqual(self.runner.called("systemctl", "enable")[0].argv, ["systemctl", "enable", "getty@tty1.service"])

    def test_the_marker_names_an_account_that_must_exist_for_the_sign_in(self):
        self.make_root(tux_user=True)
        self.marker(True, "ghost")
        self.run_job([{"action": "desktop.install", "id": "labwc"}])
        self.assertFalse((self.root / self.AUTO).exists())

    def test_file_map_when_autologin(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            (tmp / "d").mkdir()
            (tmp / "d/a").write_text("x")
            (tmp / "d/b").write_text("y")
            (tmp / "d/files.json").write_text(json.dumps([
                {"src": "a", "dst": "/etc/a", "mode": "0644"},
                {"src": "b", "dst": "/etc/b", "mode": "0644", "when": "autologin"}]))
            self.assertEqual([e[1] for e in agent.load_file_map(str(tmp), "d")], ["/etc/a"])
            self.assertEqual([e[1] for e in agent.load_file_map(str(tmp), "d", True)], ["/etc/a", "/etc/b"])
            (tmp / "d/files.json").write_text(json.dumps([{"src": "a", "dst": "/etc/a", "mode": "0644", "when": "always"}]))
            with self.assertRaises(agent.StepError):
                agent.load_file_map(str(tmp), "d", True)
        finally:
            shutil.rmtree(tmp)

    def test_autologin_uses_the_account_name(self):
        self.make_root()
        (self.root / "etc/passwd").write_text("root:x:0:0:r:/root:/bin/bash\nsam:x:1000:1000::/home/sam:/bin/bash\n")
        self.marker(True, "sam")
        self.run_job([{"action": "desktop.install", "id": "labwc"}])
        self.assertIn("--autologin sam ", self.read("etc/systemd/system/getty@tty1.service.d/autologin.conf"))

    def test_labwc_needs_an_account(self):
        self.run_job([{"action": "desktop.install", "id": "labwc"}])
        s, m = self.final()[0]
        self.assertEqual(s, "failed")
        self.assertIn("account", m.lower())
        self.assertEqual(self.runner.called("apt-get"), [])

    def test_plasma_installs_packages_settings_and_the_session_choice(self):
        self.make_root(tux_user=True)
        self.marker(True)
        self.run_job([{"action": "desktop.install", "id": "plasma"}])
        self.assertEqual(self.final()[0][0], "ok", self.final())
        pk = self.runner.called("apt-get", "install")[0].argv
        for p in ("plasma-desktop", "kwin-wayland", "powerdevil", "pipewire-pulse", "kscreen", "upower"): # kscreen: Display settings; upower: the battery
            self.assertIn(p, pk)
        self.assertFalse({"sddm", "lightdm", "kde-plasma-desktop"} & set(pk))
        self.assertEqual(self.read("etc/tux/session"), "plasma\n")
        for rel in ("usr/local/bin/tux-session", "etc/xdg/kwinrc", "etc/xdg/powerdevilrc", "etc/xdg/startkderc",
                    "etc/xdg/autostart/tux-plasma.desktop", "etc/polkit-1/rules.d/50-tux-backlight.rules"):
            self.assertTrue((self.root / rel).is_file(), rel)
        rule = self.read("etc/polkit-1/rules.d/50-tux-backlight.rules")
        self.assertIn('subject.user == "tux"', rule)
        self.assertNotIn("@USER@", rule)
        self.assertIn("--autologin tux ", self.read(self.AUTO))
        self.assertEqual(self.host.of("report")[-1]["caps"]["desktop"], "plasma")
        self.assertTrue(self.host.of("done")[0]["reboot"])

    def test_xfce_installs_xorg_and_names_the_session(self):
        self.make_root(tux_user=True)
        self.marker(True)
        self.run_job([{"action": "desktop.install", "id": "xfce"}])
        self.assertEqual(self.final()[0][0], "ok", self.final())
        pk = self.runner.called("apt-get", "install")[0].argv
        for p in ("xfce4", "xserver-xorg-core", "xinit", "dbus-x11"):
            self.assertIn(p, pk)
        self.assertFalse({"sddm", "lightdm"} & set(pk))
        self.assertEqual(self.read("etc/tux/session"), "xfce\n")
        self.assertFalse((self.root / "etc/xdg/kwinrc").exists())  # Plasma settings only for Plasma

    def test_an_installed_desktop_is_only_made_the_default(self):
        self.make_root(tux_user=True)
        self.marker(True)
        self.net = False
        d = next(x for x in json.loads((ADD / "actions.json").read_text())["desktops"] if x["id"] == "plasma")
        self.runner.packages.update({p: "1" for p in d["packages"]})
        self.run_job([{"action": "desktop.install", "id": "plasma"}])
        self.assertEqual(self.final()[0][0], "ok", self.final())
        self.assertEqual(self.runner.called("apt-get"), [])
        self.assertEqual(self.read("etc/tux/session"), "plasma\n")
        self.assertTrue(self.host.of("done")[0]["reboot"])

    def test_switching_to_labwc_overwrites_the_session_choice(self):
        self.make_root(tux_user=True)
        self.marker(True)
        (self.root / "etc/tux").mkdir(parents=True)
        (self.root / "etc/tux/session").write_text("plasma\n")
        self.net = False
        d = next(x for x in json.loads((ADD / "actions.json").read_text())["desktops"] if x["id"] == "labwc")
        self.runner.packages.update({p: "1" for p in d["packages"]})
        self.run_job([{"action": "desktop.install", "id": "labwc"}])
        self.assertEqual(self.final()[0][0], "ok", self.final())
        self.assertEqual(self.read("etc/tux/session"), "labwc\n")

    def test_no_autologin_removes_an_old_tty1_drop_in_when_the_desktop_changes(self):
        self.make_root(tux_user=True)
        self.marker(False)
        p = self.root / self.AUTO
        p.parent.mkdir(parents=True)
        p.write_text("[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin tux --noclear %I $TERM\n")
        self.run_job([{"action": "desktop.install", "id": "xfce"}])
        self.assertEqual(self.final()[0][0], "ok", self.final())
        self.assertFalse(p.exists())

    def test_a_desktop_needs_an_account(self):
        self.run_job([{"action": "desktop.install", "id": "plasma"}])
        self.assertEqual(self.final()[0][0], "failed")
        self.assertEqual(self.runner.called("apt-get", "install"), [])

    def test_reboot_after_runs_systemctl_reboot_after_done(self):
        self.make_root(tux_user=True)
        self.job_extra = {"reboot_after": True}
        self.run_job([{"action": "hostname.set", "name": "later"}])
        self.assertEqual([c.argv for c in self.runner.called("systemctl", "reboot")], [["systemctl", "reboot"]])
        self.assertTrue(self.host.of("done")[0]["ok"])

    def test_reboot_after_does_not_run_when_the_job_failed_or_is_not_set(self):
        self.make_root(tux_user=True)
        self.run_job([{"action": "hostname.set", "name": "later"}])
        self.assertEqual(self.runner.called("systemctl", "reboot"), [])
        self.setUp_again()
        self.job_extra = {"reboot_after": True}
        self.run_job([{"action": "hostname.set", "name": "Bad Name!"}])
        self.assertFalse(self.host.of("done")[0]["ok"])
        self.assertEqual(self.runner.called("systemctl", "reboot"), [])

    def test_reboot_after_must_be_a_true_boolean(self):
        self.make_root(tux_user=True)
        for v in ("yes", 1, "true", None):
            self.setUp_again()
            self.job_extra = {"reboot_after": v}
            self.run_job([{"action": "hostname.set", "name": "later"}])
            self.assertEqual(self.runner.called("systemctl", "reboot"), [], repr(v))

    def test_apt_failure_fails_the_step(self):
        self.make_root(tux_user=True)
        self.runner.when(["apt-get", "install"], rc=100)
        self.run_job([{"action": "apps.install", "ids": ["git"]}])
        self.assertEqual(self.final()[0], ("failed", "apt-get install failed"))


class Process(Case):
    def test_idle_exit(self):
        a = self.agent(idle=0)
        with redirect_stderr(io.StringIO()):
            self.assertEqual(a.serve(), 0)
        self.assertEqual([e["t"] for e in self.host.events], ["report"])

    def test_media_out_ends_the_agent(self):
        self.host.eject()
        with redirect_stderr(io.StringIO()):
            self.assertEqual(self.agent().serve(), 0)

    def test_dead_link_ends_with_1(self):
        os.environ["TUX_ADDITIONS_PORT"] = "1"
        with redirect_stderr(io.StringIO()):
            self.assertEqual(self.agent().serve(), 1)

    def test_unknown_protocol_is_refused(self):
        tree = Path(self.tmp) / "tree"
        shutil.copytree(ADD, tree, ignore=shutil.ignore_patterns("__pycache__"))
        cat = json.loads((tree / "actions.json").read_text())
        cat["protocol"] = 2
        (tree / "actions.json").write_text(json.dumps(cat))
        mod = load_agent(tree / "agent")
        os.environ["TUX_ADDITIONS_ROOT"] = str(self.root)
        try:
            with redirect_stderr(io.StringIO()):
                rc = mod.main(["run", "--n", "7"])
        finally:
            del os.environ["TUX_ADDITIONS_ROOT"]
        self.assertEqual(rc, 2)
        bm = self.host.of("bad-media")
        self.assertEqual((len(bm), bm[0]["n"]), (1, 7))
        self.assertIn("protocol", bm[0]["why"])
        self.assertEqual(self.host.of("report"), [])

    def test_usage(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(agent.main([]), 2)
            self.assertEqual(agent.main(["run", "--n", "x"]), 2)
            self.assertEqual(agent.main(["walk"]), 2)

    def test_runner_runs_a_real_program(self):
        r = caps_mod.Runner()
        got = []
        res = r.run(["sh", "-c", "cat; echo err >&2; exit 3"], input="hello\n", on_output=got.append)
        self.assertEqual((res.rc, res.out), (3, "hello\nerr\n"))
        self.assertEqual("".join(got), "hello\nerr\n")
        self.assertEqual(r.run(["/no/such/program"]).rc, 127)
        self.assertEqual(r.run(["sleep", "5"], timeout=1).out.strip(), "[timeout]")

    def test_wire_errors_from_the_host_do_not_kill_the_agent(self):
        a = self.agent()
        with redirect_stderr(io.StringIO()):
            self.assertIsNone(a.post({"t": "log", "job": "j", "text": "x" * 70000}))  # 413 path: too big, not sent
        self.assertEqual(self.host.of("log"), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
