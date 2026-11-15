#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Tuxedo Additions end to end (docs/guest-additions-design.md): the media, the guest package and the agent in a booted guest.

The host side of the app is tuxvm: the input file (additions DIR, additions -, additions-job FILE, additions-cancel) and the
"additions-event: JSON" lines on its stderr. Every boot is a clone of --image (default build/linux/debian-console.img, a
tux-guest 1.10.2 image), so the shared image never changes. Needs build/tuxvm, and the media from `make linux-additions`
(build/linux/additions/tux-additions, or --media DIR).

Boot 1, old image (the console is the tux user):
  a  bootstrap: the design's mount command, then `sh install` as tux (it must start sudo itself) with no network; it installs
     tux-guest 1.11.0 from the local repository (exit 0); a second run says "nothing to do" (exit 0); tux-files starts the
     agent for that n and a report arrives with the new caps shape (account.configured false)
  b  the serial console is a root shell with no login (after a restart of the getty)
  j  the exit-3 path of install, with a faked henge-guest entry in the dpkg status file
Boot 2, the clone of boot 1 (root console after a reboot, no account):
  c  a job (user.setup, ssh.configure, hostname.set, additions.install): step events in order, done ok, the account marker,
     the password works (su), sshd -T, authorized_keys once (also after a second job), root locked, the console follows
     autologin, and the password is in no event, no host line, no guest log and not in additions.json
Boot 5 (k): the old image with a password for tux: the upgrade writes the marker and the console keeps its login prompt
Boot 3 (d): a job with sudo false (and autologin false): the console asks for a login, sudo -n true fails afterwards
Boot 4:
  g  the media is Read-only for root (touch, rm, chmod, mkdir; also after a rw remount)
  e  no network: apps.install ends failed with "No network" and the later step is skipped; with network: a real apps.install
     of htop, and the catalogue's desktop packages have a candidate after apt update
  i  cancel: the remaining steps are skipped
  f  bad media (one changed byte; one unlisted file): a bad-media event, `sh install` exits 4, no job runs; good media again
  h  eject while a job runs (the job finishes), then eject while idle (the agent exits and the mount goes)
Exit 1 on a failed scenario. The password and the key of the test are made for the run.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
MARK = "TUX_RC_"
PROMPT = r"(?:\x1b\[\?2004h)?([a-z_][a-z0-9_-]*)@([\w.-]+):[^\r\n]*([#$]) "
MEDIA_MOUNT = "/media/tux/tux-additions"
PASSWORD = "Tx9-add!tions-PW-71"
PASSWORD2 = "Qr4-sudo!off-PW-38"
PASSWORD3 = "Hm2-old!image-PW-55"
NFT_BLOCK = ("nft add table inet adcheck && nft 'add chain inet adcheck out { type filter hook output priority 0; "
             "policy accept; }' && nft add rule inet adcheck out ip daddr != 10.0.2.4 oifname != lo drop")
NFT_FREE = "nft delete table inet adcheck"


class Fail(Exception):
    pass


def linux_dir():
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
    common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


def ok(msg):
    print(f"ok: {msg}", flush=True)


def note(msg):
    print(f"..: {msg}", flush=True)


class Machine:
    """One tuxvm on a disk: the serial console in pexpect, the input file and the stderr events on the host side."""

    def __init__(self, args, disk, tmp, tag):
        self.args, self.disk, self.tmp, self.tag = args, disk, tmp, tag
        self.share = tempfile.mkdtemp(prefix="adc-", dir="/tmp")  # tuxvm's share socket path is limited to 103 characters
        self.input = os.path.join(tmp, tag + ".input")
        self.err = os.path.join(tmp, tag + ".stderr")
        self.console_log = os.path.join(tmp, tag + ".console")
        open(self.input, "w").close()
        self.events, self.err_pos, self.err_text = [], 0, ""
        self.p = None
        self.who = None

    # ---- the host side ----
    def pump(self):
        try:
            with open(self.err, errors="replace") as f:
                f.seek(self.err_pos)
                chunk = f.read()
        except OSError:
            return
        cut = chunk.rfind("\n") + 1  # only whole lines
        if not cut:
            return
        self.err_pos += len(chunk[:cut].encode())
        for line in chunk[:cut].splitlines():
            self.err_text += line + "\n"
            if line.startswith("additions-event: "):
                try:
                    self.events.append(json.loads(line[len("additions-event: "):]))
                except ValueError:
                    raise Fail(f"an event that is not JSON: {line[:200]}")

    def host_log(self):
        self.pump()
        return self.err_text

    def input_line(self, line):
        with open(self.input, "a") as f:
            f.write(line + "\n")

    def wait_log(self, text, limit=20, since=0):
        end = time.monotonic() + limit
        while True:
            self.pump()
            i = self.err_text.find(text, since)
            if i >= 0:
                return i + len(text)
            if time.monotonic() > end:
                raise Fail(f"tuxvm did not print {text!r} within {limit} s: {self.err_text[-600:]!r}")
            time.sleep(0.1)

    def wait_event(self, pred, limit, what, since=0):
        end = time.monotonic() + limit
        while True:
            self.pump()
            for e in self.events[since:]:
                if pred(e):
                    return e
            if time.monotonic() > end:
                raise Fail(f"no {what} within {limit} s; events since: {[self.brief(e) for e in self.events[since:]][-12:]}")
            time.sleep(0.2)

    @staticmethod
    def brief(e):
        t = e.get("t")
        if t == "step":
            return f"step {e['i']} {e['status']} {e['msg'][:60]!r}"
        if t == "log":
            return "log"
        return t

    def mark(self):
        self.pump()
        return len(self.events)

    def insert(self, media):
        at = len(self.host_log())
        self.input_line(f"additions {media}")
        self.wait_log("additions: inserted, n ", 10, at)
        m = re.search(r"additions: inserted, n (\d+)", self.err_text[at:])
        return int(m.group(1))

    def eject(self):
        at = len(self.host_log())
        self.input_line("additions -")
        self.wait_log("additions: ejected", 10, at)

    def job(self, steps, limit=180, wait=True, jid=None):
        """Sets a job as the app does. Returns (id, first event index, done event or None)."""
        jid = jid or "j-" + uuid.uuid4().hex[:8]
        path = os.path.join(self.tmp, f"job-{jid}.json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"id": jid, "steps": steps}, f)
        k, at = self.mark(), len(self.host_log())
        self.input_line(f"additions-job {path}")
        try:
            self.wait_log("additions: job set", 10, at)
        finally:
            os.unlink(path)
        done = self.wait_event(lambda e: e["t"] == "done" and e["job"] == jid, limit, f"done of {jid}", k) if wait else None
        return jid, k, done

    def steps_of(self, jid, k):
        return [(e["i"], e["status"], e["msg"]) for e in self.events[k:] if e["t"] == "step" and e["job"] == jid]

    def expect_steps(self, jid, k, finals, what):
        """The step events of the job: running then the final status, one step after the other, in order."""
        got = self.steps_of(jid, k)
        want = []
        for i, st in enumerate(finals):
            if st != "skipped":
                want.append((i, "running"))
            want.append((i, st))
        if [(i, s) for i, s, _ in got] != want:
            raise Fail(f"{what}: step events {[(i, s, m[:50]) for i, s, m in got]}, want {want}")
        return {i: m for i, s, m in got if s != "running"}

    def wait_report(self, since, n, limit=120):
        """A report from the agent of media n (a report of the boot or of dpkg says agent 0)."""
        want = self.args.agent_version
        return self.wait_event(lambda e: e["t"] == "report" and e["n"] == n and e["agent"] == want, limit, f"agent report of n {n}", since)

    # ---- the console ----
    def boot(self, extra=()):
        a = self.args
        cmd = ["/bin/sh", "-c", 'exec "$@" 2>>"$0"', self.err, a.tuxvm, "--firmware", a.firmware, "--ram", str(a.ram),
               "--cpus", str(a.cpus), "--disk", self.disk, "--share", self.share, "--fs-device"] + list(extra)
        env = dict(os.environ, HV_INPUT_FILE=self.input)
        self.p = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", codec_errors="replace", timeout=60, env=env, maxread=65536,
                               dimensions=(50, 250))
        self.p.logfile_read = open(self.console_log, "a")
        t = time.monotonic()
        self.login(300)
        return round(time.monotonic() - t, 1)

    def login(self, limit=60):
        """Waits for the console's login. Returns the shell's prompt as (user, host, '#' or '$'), or None for a login prompt."""
        p = self.p
        p.expect(r"login: ", timeout=limit)  # "tux login: tux (automatic login)" or "tux login: "
        if p.expect([r"\(automatic login\)", pexpect.TIMEOUT], timeout=4) == 1:
            self.who = None
            return None
        p.expect(PROMPT, timeout=60)
        self.who = (p.match.group(1), p.match.group(2), p.match.group(3))
        self.quiet()
        return self.who

    def type_login(self, user, password, limit=30):
        p = self.p
        p.sendline(user)
        p.expect(r"Password: ", timeout=limit)
        p.sendline(password)
        p.expect(PROMPT, timeout=limit)
        self.who = (p.match.group(1), p.match.group(2), p.match.group(3))
        self.quiet()
        return self.who

    def quiet(self):
        self.p.sendline("stty -echo; set +m +H; bind 'set enable-bracketed-paste off'; PS1=; "
                        f"(dmesg -n 1 || sudo -n dmesg -n 1) >/dev/null 2>&1; echo {MARK}$((6 * 7))")
        self.p.expect(MARK + r"42\r*\n", timeout=30)

    def sh(self, cmd, limit=60):
        p = self.p
        p.sendline(f"{cmd}; echo {MARK}$?")
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
        out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
        return out.strip(), int(p.match.group(1))

    def need(self, cmd, ok=lambda o: True, what="", limit=60):
        out, rc = self.sh(cmd, limit)
        if rc != 0 or not ok(out):
            raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
        return out

    def must_fail(self, cmd, what, limit=60):
        out, rc = self.sh(cmd, limit)
        if rc == 0:
            raise Fail(f"{what}: {cmd!r} worked and must not: {out[-300:]!r}")
        return out

    def wait_guest(self, cmd, what, limit=30):
        t = time.monotonic()
        out, rc = self.sh(f"for i in $(seq {limit * 5}); do {cmd} && break; sleep 0.2; done >/dev/null 2>&1; {cmd}", limit + 30)
        if rc != 0:
            raise Fail(f"{what}: not within {limit} s ({out[-400:]!r})")
        return round(time.monotonic() - t, 1)

    def sudo(self):
        return "" if self.who and self.who[2] == "#" else "sudo "

    def poweroff(self):
        self.p.sendline(f"{self.sudo()}poweroff")
        self.p.expect(pexpect.EOF, timeout=180)
        self.p.close()

    def alive(self):
        return self.p is not None and self.p.isalive()

    def kill(self):
        if self.alive():
            self.p.terminate(force=True)
        shutil.rmtree(self.share, ignore_errors=True)


class Run:
    def __init__(self, args):
        self.args = args
        self.results = {}
        self.tmp = args.tmp
        self.snap = None

    def clone(self, src, tag):
        disk = os.path.join(self.tmp, tag + ".img")
        subprocess.run(["/bin/cp", "-c", src, disk], check=True)
        os.truncate(disk, max(os.path.getsize(disk), 6 << 30))  # tux-grow takes the room at boot
        return disk

    def want(self, key):
        return not self.args.only or key[0] in self.args.only

    def scenario(self, key, m, fn, *a):
        """Runs one scenario. A failed check ends the scenario; the next one gets a console that answers, or is not run."""
        if not self.want(key):
            return
        t = time.monotonic()
        try:
            if not m.alive():
                raise Fail("not run: the machine is gone")
            m.p.sendline("")
            m.sh("true", 20)
        except (pexpect.TIMEOUT, pexpect.EOF, Fail):
            self.results[key] = ("not run", 0, "the console does not answer")
            print(f"NOT RUN {key}: the console does not answer", flush=True)
            return
        try:
            fn(m, *a)
            self.results[key] = ("pass", time.monotonic() - t, "")
        except (Fail, pexpect.TIMEOUT, pexpect.EOF) as e:
            msg = str(e) if isinstance(e, Fail) else f"{type(e).__name__}: {str(e)[:700]}"
            self.results[key] = ("FAIL", time.monotonic() - t, msg)
            print(f"FAIL {key}: {msg}", file=sys.stderr, flush=True)
            for log in (m.console_log,):
                if os.path.exists(log):
                    print(f"--- console tail ({m.tag}):", open(log, errors="replace").read()[-1800:], file=sys.stderr)
            print("--- tuxvm stderr tail:", m.host_log()[-1200:], file=sys.stderr, flush=True)

    def failed(self, key):
        return self.results.get(key, ("",))[0] == "FAIL"


# ---------------------------------------------------------------- scenarios

def precondition_old_image(m):
    v = m.need("dpkg-query -W -f='${Version}' tux-guest", what="the image's tux-guest")
    if not v.startswith("1.10"):
        raise Fail(f"the image has tux-guest {v}, and this check needs the 1.10 image (--image)")
    if m.who[0] != "tux" or m.who[2] != "$":
        raise Fail(f"the old image's console is {m.who}, want the tux user")
    return v


def sc_j(m, media):
    """The exit-3 path of install: a henge-guest entry in the dpkg status file."""
    m.need("sudo cp /var/lib/dpkg/status /var/tmp/status.good", what="backup of the dpkg status")
    stanza = r"Package: henge-guest\nStatus: install ok installed\nPriority: optional\nSection: admin\nMaintainer: x\nArchitecture: all\nVersion: 1.0\nDescription: fake\n\n"
    m.need(f"printf '{stanza}' | sudo tee -a /var/lib/dpkg/status >/dev/null && dpkg-query -W -f='${{Status}}' henge-guest",
           lambda o: o == "install ok installed", "fake henge-guest")
    try:
        out, rc = m.sh(f"sh {MEDIA_MOUNT}/install 2>&1", 120)
        if rc != 3 or "old Henge guest packages" not in out:
            raise Fail(f"install with henge-guest: status {rc} (want 3), output {out[-400:]!r}")
        m.need("dpkg-query -W -f='${Version}' tux-guest", lambda o: o.startswith("1.10"), "tux-guest is unchanged")
    finally:
        m.sh("sudo cp /var/tmp/status.good /var/lib/dpkg/status")
    m.must_fail("dpkg-query -W henge-guest 2>/dev/null", "the fake entry is gone")
    ok("j: install with a fake henge-guest exits 3 (\"old Henge guest packages\") and changes nothing")


def sc_a(m, media, n):
    # the mount part of the app's bootstrap command (design section 6), typed as the tux user: it must use sudo itself
    m.need('s=; [ "$(id -u)" = 0 ] || s=sudo; $s mkdir -p /mnt/tux && $s mount -t virtiofs -o ro tux-files /mnt/tux', what="mount tux-files at /mnt/tux")
    m.need("ls /mnt/tux/tux-additions/install /mnt/tux/tux-additions/SHA256SUMS.gpg", what="the media under /mnt/tux")
    m.need("[ $(id -u) -ne 0 ]", what="the console is not root before the install")
    # no network: only the link to the app stays
    m.need(f"sudo sh -c \"{NFT_BLOCK}\"", what="block the network")
    m.must_fail("python3 -c \"import socket; socket.create_connection(('deb.debian.org', 80), 3)\" 2>/dev/null", "the network is blocked")
    mk = m.mark()
    t = time.monotonic()
    out, rc = m.sh("sh /mnt/tux/tux-additions/install >/var/tmp/install1.log 2>&1; rc=$?; cat /var/tmp/install1.log; (exit $rc)", 900)
    took = time.monotonic() - t
    if rc != 0:
        raise Fail(f"bootstrap: install exited {rc}: {out[-1500:]!r}")
    if "The media is good." not in out or not re.search(r"tux-guest 1\.10\.\d+ -> 1\.11\.0", out):
        raise Fail(f"bootstrap: no 'The media is good.' or 'tux-guest 1.10.x -> 1.11.0' in the output: {out[-1200:]!r}")
    m.need("dpkg-query -W -f='${Version}' tux-guest", lambda o: o == "1.11.0", "tux-guest 1.11.0 is installed")
    out, rc = m.sh("sh /mnt/tux/tux-additions/install 2>&1", 300)
    if rc != 0 or "nothing to do" not in out or "->" in out:
        raise Fail(f"second install: status {rc}, output {out[-700:]!r}")
    m.need("sudo " + NFT_FREE, what="unblock the network")
    ok(f"a: sh install as tux (it started sudo) with no network installed tux-guest 1.11.0 from the media in {took:.0f} s, exit 0; "
       "the second run says nothing to do, exit 0")
    # tux-files of 1.11.0 starts the agent for n by itself
    ev = m.wait_report(mk, n, 150)
    c = ev["caps"]
    if (c["installed"]["tux-guest"] != "1.11.0" or c["account"]["configured"] is not False or c["account"]["autologin"] != "root"
            or c["account"]["exists"] is not True or c["root"] is not True or c["legacy"] is not False):
        raise Fail(f"the agent's report: {json.dumps(c)[:800]}")
    for key in ("installed", "legacy", "account", "root", "network", "desktop", "ssh", "apps", "hostname", "disk_free_mb",
                "image", "ips", "kernel"):
        if key not in c:
            raise Fail(f"caps has no {key}")
    if ev["protocol"] != 1 or "firefox" not in c["apps"]:
        raise Fail(f"report fields: {ev['protocol']}, apps {list(c['apps'])[:5]}")
    m.need(f"systemctl is-active tux-additions-agent@{n}", lambda o: o == "active", "the agent unit is active")
    m.need("readlink /var/lib/tux/additions/current", lambda o: o == str(n), "current points at n")
    m.need("test -s /var/lib/tux/additions.json", what="additions.json")
    m.need("pgrep -af 'additions/current/agent run'", lambda o: f"--n {n}" in o, "the agent process")
    ok(f"a: tux-files started the agent for n {n}; its report has the new caps shape (account.configured false, console autologin root, "
       f"ips {c['ips']}, network {c['network']})")


def sc_b(m, media):
    """The console of the upgraded machine is a root shell with no login."""
    m.p.sendline("sudo systemctl restart --no-block serial-getty@ttyAMA0.service")  # it ends this shell
    who = m.login(60)
    if who is None or who[0] != "root" or who[2] != "#":
        raise Fail(f"after the getty restart the console is {who}, want a root shell with no login")
    m.need("id -u", lambda o: o == "0", "id -u")
    m.need("grep -c '^root:' /etc/shadow", what="root is here")
    m.need("test ! -e /var/lib/tux/account.json", what="there is no account marker yet")
    ok("b: after the upgrade and a getty restart the serial console is a root shell with no login (root@..#, id -u 0)")


def sc_boot2_root(m):
    who = m.who
    if who[0] != "root" or who[2] != "#":
        raise Fail(f"after a reboot the console is {who}, want a root shell")
    m.need("id -u", lambda o: o == "0", "id -u")
    ok("b: after a reboot of the upgraded clone the serial console is a root shell (id -u 0)")


def sc_r(m):
    """tux-status posts a report at boot, with no media in: the app's auto-trigger needs it."""
    ev = m.wait_event(lambda e: e["t"] == "report" and e["n"] == 0, 90, "the boot report (n 0)")
    c = ev["caps"]
    if c["account"]["configured"] is not False or c["account"]["autologin"] != "root" or c["installed"]["tux-guest"] != "1.11.0":
        raise Fail(f"the boot report: {json.dumps(c['account'])} {c['installed']}")
    ok("r: tux-status posted a report at boot with no media in (n 0, account.configured false, autologin root)")


def sc_k(m, media):
    """The upgrade rule: a uid-1000 user that has a password gets a marker, and the console keeps its login prompt."""
    m.need(f"echo 'tux:{PASSWORD3}' | sudo chpasswd", what="a password for tux")
    n = m.insert(media)
    m.wait_guest(f"[ -r {MEDIA_MOUNT}/install ]", "the media in the old guest", 40)
    mk = m.mark()
    out, rc = m.sh(f"sh {MEDIA_MOUNT}/install 2>&1", 900)
    if rc != 0:
        raise Fail(f"install exited {rc}: {out[-800:]!r}")
    m.need("cat /var/lib/tux/account.json", lambda o: json.loads(o) == {"configured": True, "name": "tux", "autologin": False, "sudo": True},
           "the marker the upgrade writes")
    ev = m.wait_report(mk, n, 150)
    a = ev["caps"]["account"]
    if (a["configured"], a["autologin"], a["password_set"]) != (True, "none", True):
        raise Fail(f"the report after the upgrade: {a}")
    m.p.sendline("sudo systemctl restart --no-block serial-getty@ttyAMA0.service")
    if m.login(60) is not None:
        raise Fail("after the upgrade of a machine with a password the console must keep its login prompt")
    who = m.type_login("tux", PASSWORD3)
    if who[0] != "tux" or who[2] != "$":
        raise Fail(f"login gave {who}")
    ok("k: upgrading a machine whose tux user has a password writes the marker (configured, autologin false), the report says autologin none, "
       "and the console still asks for a login (it is not a root shell)")


def sc_n(m, media):
    """The app's nudge: n goes up by one and the agent starts again for the new n."""
    n = int(m.need("readlink /var/lib/tux/additions/current"))
    k, at = m.mark(), len(m.host_log())
    m.input_line("additions-nudge")
    m.wait_log("additions: nudged, n ", 10, at)
    n2 = int(re.search(r"nudged, n (\d+)", m.host_log()[at:]).group(1))
    if n2 != n + 1:
        raise Fail(f"nudge gave n {n2}, want {n + 1}")
    m.wait_report(k, n2, 90)
    m.need(f"systemctl is-active tux-additions-agent@{n2}", lambda o: o == "active", "the agent of the new n")
    m.need(f"systemctl is-active tux-additions-agent@{n}; test $? -ne 0", what="the agent of the old n has stopped")
    ok(f"n: a nudge made n {n2}; the agent started again for it, with a report, and the old agent stopped")


def pw_leaks(m, pws, guest=True):
    """Where the password must not be: the host's output and events, and the guest's logs and state."""
    bad = []
    blob = m.host_log() + json.dumps(m.events)
    for pw in pws:
        if pw in blob:
            bad.append("tuxvm's stderr or the events")
    if guest:
        # The patterns go in a file out of the scanned folders: a pattern on a sudo command line is itself logged in the journal
        parts = " ".join(f"'{pw[:len(pw) // 2]}' '{pw[len(pw) // 2:]}'" for pw in pws)
        m.need(f"printf '%s%s\\n' {parts} > /dev/shm/adcheck.pat", what="the pattern file")
        try:
            out, rc = m.sh("sudo grep -rIlF -f /dev/shm/adcheck.pat /var/log /var/lib/tux /var/lib/apt /run /tmp /var/tmp /root /home /etc "
                           "2>/dev/null | grep -v '^/run/tux/files/'; true", 180)
            if out.strip():
                bad.append("guest files " + out.strip().replace("\n", " "))
            out, rc = m.sh("sudo journalctl -a --no-pager 2>/dev/null | grep -F -f /dev/shm/adcheck.pat | cut -c1-240; true", 120)
            if out.strip():
                for pw in pws:
                    out = out.replace(pw, "<password>")
                bad.append("the journal: " + out.strip()[:400])
        finally:
            m.sh("rm -f /dev/shm/adcheck.pat")
    return bad


def sc_c(m, media, ssh_key):
    key_text = open(ssh_key + ".pub").read().strip()
    m.need("id -u", lambda o: o == "0", "root console before the job")
    steps = [
        {"action": "user.setup", "name": "tux", "password": PASSWORD, "sudo": True, "autologin": True},
        {"action": "ssh.configure", "enabled": True, "port": 2222, "password_auth": False, "authorized_key": key_text},
        {"action": "hostname.set", "name": "tuxcheck"},
        {"action": "additions.install"},
    ]
    t = time.monotonic()
    jid, k, done = m.job(steps, 600)
    took = time.monotonic() - t
    msgs = m.expect_steps(jid, k, ["ok"] * 4, "job c")
    if done["ok"] is not True or done["reboot"] is not False:
        raise Fail(f"done: {done}")
    info = done["info"]
    if info["user"] != "tux" or not info["ssh_fingerprints"] or not info["ips"]:
        raise Fail(f"done info: {info}")
    if not all(f.startswith(("256 SHA256:", "3072 SHA256:", "384 SHA256:", "521 SHA256:")) or "SHA256:" in f for f in info["ssh_fingerprints"]):
        raise Fail(f"fingerprints: {info['ssh_fingerprints']}")
    ok(f"c: user.setup, ssh.configure, hostname.set, additions.install all ok in order in {took:.0f} s; done ok; ips {info['ips']}; "
       f"{len(info['ssh_fingerprints'])} host key fingerprints; messages {[msgs[i] for i in range(4)]}")
    # the agent restarts the getty after done: the console follows the new account
    who = m.login(90)
    if who is None or who[0] != "tux" or who[2] != "$" or who[1] != "tuxcheck":
        raise Fail(f"after the job the console is {who}, want tux@tuxcheck with no login (autologin true)")
    m.need("id -u", lambda o: o == "1000", "the console user is uid 1000")
    ok("c: after the getty restart the console signs in as tux (autologin), not as root; the host name is tuxcheck")
    m.need("cat /var/lib/tux/account.json",
           lambda o: json.loads(o) == {"configured": True, "name": "tux", "autologin": True, "sudo": True}, "the account marker")
    m.need("sudo passwd -S root", lambda o: o.split()[1] == "L", "passwd -S root shows L")
    m.need("sudo -n true", what="sudo works for tux (sudo true)")
    m.need("hostnamectl --static", lambda o: o == "tuxcheck", "hostname")
    m.need("grep -c tuxcheck /etc/hosts", lambda o: int(o) >= 1, "/etc/hosts has the name")
    ok("c: account.json has the choices and no password; root is locked (passwd -S root: L); sudo works; /etc/hosts names the host")
    # sshd -T
    out = m.need("sudo sshd -T 2>&1", what="sshd -T")
    cfg = {}
    for line in out.splitlines():
        kw, _, val = line.partition(" ")
        cfg.setdefault(kw, val)
    want = {"port": "2222", "passwordauthentication": "no", "permitrootlogin": "no", "kbdinteractiveauthentication": "no"}
    if {k: cfg.get(k) for k in want} != want:
        raise Fail(f"sshd -T: {({k: cfg.get(k) for k in want})} want {want}")
    m.need("systemctl is-enabled ssh.service; systemctl is-active ssh.service", lambda o: o.split() == ["enabled", "active"], "ssh runs")
    m.need("sudo ss -ltn | grep -c ':2222 '", lambda o: int(o) >= 1, "sshd listens on 2222")
    body = key_text.split()[1]
    m.need(f"grep -cF '{body}' /home/tux/.ssh/authorized_keys", lambda o: o == "1", "the key is in authorized_keys once")
    m.need("stat -c '%a %U' /home/tux/.ssh /home/tux/.ssh/authorized_keys", lambda o: o.split() == ["700", "tux", "600", "tux"], "key file modes")
    ok("c: sshd -T has port 2222, passwordauthentication no, permitrootlogin no, kbdinteractiveauthentication no; ssh runs; authorized_keys has the key once (mode 600)")
    # the password works for su, a wrong one does not
    p = m.p
    p.sendline("su tux -c 'echo SU_GOOD_$((1+1))'")
    p.expect(r"Password: ", timeout=20)
    p.sendline(PASSWORD)
    p.expect(r"SU_GOOD_2", timeout=20)
    m.sh("true")
    p.sendline("su tux -c 'echo SU_BAD_$((1+1))'")
    p.expect(r"Password: ", timeout=20)
    p.sendline("wrong-password-1")
    p.expect(r"Authentication failure|incorrect password", timeout=30)
    m.sh("true")
    ok("c: su tux accepts the password the job set and refuses another")
    # the second job: the same key again must not double
    jid2, k2, done2 = m.job([steps[1]], 120)
    m.expect_steps(jid2, k2, ["ok"], "job c2")
    m.need(f"grep -cF '{body}' /home/tux/.ssh/authorized_keys", lambda o: o == "1", "the key is still there once after a second job")
    ok("c: the same ssh.configure again leaves the key once")
    # no password anywhere; the search must find a canary in a file and in the journal first
    m.need("echo canary-Zk5-7731 > /var/tmp/adcheck.canary; logger -t adcheck canary-Zk5-7731")
    found = pw_leaks(m, ["canary-Zk5-7731"])
    m.sh("rm -f /var/tmp/adcheck.canary")
    if not (any("guest files /var/tmp/adcheck.canary" in b for b in found) and any("the journal" in b for b in found)):
        raise Fail(f"the leak search does not find a canary in a file and the journal: {found}")
    bad = pw_leaks(m, [PASSWORD])
    if bad:
        raise Fail("the password is in " + "; ".join(bad))
    logs = "".join(e["text"] for e in m.events if e["t"] == "log")
    ok(f"c: the password is in no event ({len(m.events)} events, {len(logs)} log bytes), no tuxvm stderr line, no guest log or file under /var/log, /var/lib/tux, /run, /tmp, /root, /home, /etc, and not in the journal")
    m.need("cat /var/lib/tux/additions.json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"t\"]==\"report\"; print(\"report\")'",
           lambda o: o == "report", "additions.json is the last report")
    return ssh_key


def sc_ssh_real(m, ssh_key, port):
    """A real login through a forward with the key (only when boot 2 had --forward)."""
    r = subprocess.run(["ssh", "-p", str(port), "-i", ssh_key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "tux@127.0.0.1",
                        "id -un; hostname"], capture_output=True, text=True, timeout=60)
    if r.returncode != 0 or r.stdout.split() != ["tux", "tuxcheck"]:
        raise Fail(f"ssh with the key through the forward: status {r.returncode}, {r.stdout!r} {r.stderr[-300:]!r}")
    r2 = subprocess.run(["ssh", "-p", str(port), "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password",
                         "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes",
                         "-o", "ConnectTimeout=15", "tux@127.0.0.1", "true"], capture_output=True, text=True, timeout=60)
    if r2.returncode == 0 or "Permission denied" not in r2.stderr:
        raise Fail(f"ssh with a password must be refused (password_auth false): {r2.returncode} {r2.stderr[-300:]!r}")
    ok("c: a real ssh login with the key through --forward works (tux@tuxcheck) and password login is refused")


def sc_d(m, media):
    m.need("id -u", lambda o: o == "0", "root console before the job")
    m.need("test -e /etc/sudoers.d/tux && cat /etc/sudoers.d/tux", lambda o: o == "tux ALL=(ALL) NOPASSWD:ALL", "the stock sudoers file")
    # sudo off with root locked leaves nobody to become root: the agent refuses and changes nothing
    bad = [{"action": "user.setup", "name": "tux", "password": PASSWORD2, "sudo": False, "autologin": False}]
    jid0, k0, _ = m.job(bad, 60)
    m.expect_steps(jid0, k0, ["failed"], "job d (sudo off, root locked)")
    m.need("test -e /etc/sudoers.d/tux && ! test -e /var/lib/tux/account.json && passwd -S tux | cut -d' ' -f2",
           lambda o: o == "NP", "the refused job changed nothing (stock sudo file, no marker, the tux password still empty)")
    steps = [{"action": "user.setup", "name": "tux", "password": PASSWORD2, "sudo": False, "autologin": False, "lock_root": False}]
    jid, k, done = m.job(steps, 120)
    msgs = m.expect_steps(jid, k, ["ok"], "job d")
    if done["ok"] is not True:
        raise Fail(f"done: {done}")
    if "moved aside" not in msgs[0]:
        raise Fail(f"the step message must say the stock sudo file moved: {msgs[0]!r}")
    who = m.login(90)
    if who is not None:
        raise Fail(f"after the job (autologin false) the console is {who}, want a login prompt")
    who = m.type_login("tux", PASSWORD2)
    if who[0] != "tux" or who[2] != "$":
        raise Fail(f"login as tux gave {who}")
    m.must_fail("sudo -n true 2>&1", "sudo -n true for tux (sudo false)")
    out, rc = m.sh("id -nG")
    if "sudo" in out.split():
        raise Fail(f"tux is still in the sudo group: {out}")
    ok("d: user.setup with sudo false and autologin false: the step says the stock sudo file moved aside; the console asks for a login "
       "(no autologin), the password works at it, and sudo -n true fails for tux")
    bad = pw_leaks(m, [PASSWORD2], guest=False)
    if bad:
        raise Fail("the password is in " + "; ".join(bad))


def sc_g(m, media):
    m.need("id -u", lambda o: o == "0", "root")
    m.need(f"mountpoint -q {MEDIA_MOUNT}", what="the media is mounted")
    m.need(f"findmnt -n -o OPTIONS {MEDIA_MOUNT}", lambda o: "ro" in o.split(","), "mounted ro")
    for what, cmd in (("touch", f"touch {MEDIA_MOUNT}/new"), ("rm", f"rm -f {MEDIA_MOUNT}/README.txt"),
                      ("chmod", f"chmod 600 {MEDIA_MOUNT}/agent"), ("mkdir", f"mkdir {MEDIA_MOUNT}/newdir"),
                      ("write", f"echo x >> {MEDIA_MOUNT}/agent"), ("mv", f"mv {MEDIA_MOUNT}/README.txt {MEDIA_MOUNT}/R2")):
        out = m.must_fail(cmd + " 2>&1", f"g: {what}")
        if "Read-only file system" not in out:
            raise Fail(f"g: {what} failed with {out!r}, want a Read-only file system error")
    m.need("sudo mount -o remount,bind,rw " + MEDIA_MOUNT, what="remount rw")
    for what, cmd in (("touch", f"touch {MEDIA_MOUNT}/new"), ("rm", f"rm -f {MEDIA_MOUNT}/README.txt"),
                      ("chmod", f"chmod 600 {MEDIA_MOUNT}/agent"), ("mkdir", f"mkdir {MEDIA_MOUNT}/newdir")):
        m.must_fail(cmd + " 2>&1", f"g: {what} after a rw remount")
    m.need("mount -o remount,bind,ro " + MEDIA_MOUNT, what="remount ro")
    m.need(f"test -f {MEDIA_MOUNT}/README.txt && test ! -e {MEDIA_MOUNT}/new && test ! -e {MEDIA_MOUNT}/newdir", what="the media is unchanged")
    ok("g: touch, rm, chmod, mkdir, write and mv in /media/tux/tux-additions fail as root with 'Read-only file system', also after a rw remount; the media is unchanged")


def apt_sources_line(m):
    return m.need("cat /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -E '^(deb |URIs:)' | head -3")


def sc_e(m, media):
    m.need("id -u", lambda o: o == "0", "root")
    # no network: only the link to the app stays
    m.need(f"sh -c \"{NFT_BLOCK}\"", what="block the network")
    try:
        steps = [{"action": "apps.install", "ids": ["htop"]}, {"action": "hostname.set", "name": "never"}]
        t = time.monotonic()
        jid, k, done = m.job(steps, 120)
        msgs = m.expect_steps(jid, k, ["failed", "skipped"], "no network job")
        took = time.monotonic() - t
        if "No network" not in msgs[0] or done["ok"] is not False:
            raise Fail(f"want failed 'No network' and done ok false: {msgs}, {done}")
        m.need("hostnamectl --static", lambda o: o != "never", "the later step did not run")
        ok(f"e: with no network apps.install ends failed with 'No network' (job ended in {took:.1f} s) and the next step is skipped")
        rep = [e for e in m.events[k:] if e["t"] == "report"]
        if not rep or rep[-1]["caps"]["network"] is not False:
            raise Fail(f"the report after the job must say network false: {[r['caps']['network'] for r in rep]}")
    finally:
        m.sh(NFT_FREE)
    # with network
    m.need("python3 -c \"import socket; socket.create_connection(('deb.debian.org', 80), 5)\"", what="the guest has network (slirp)")
    m.must_fail("dpkg -s htop >/dev/null 2>&1", "htop is not installed yet")
    t = time.monotonic()
    jid, k, done = m.job([{"action": "apps.install", "ids": ["htop"]}], 900)
    msgs = m.expect_steps(jid, k, ["ok"], "network job")
    took = time.monotonic() - t
    if done["ok"] is not True:
        raise Fail(f"done: {done}")
    m.need("dpkg-query -W -f='${Status}' htop", lambda o: o == "install ok installed", "htop is installed")
    m.need("command -v htop", what="htop is on the path")
    rep = [e for e in m.events[k:] if e["t"] == "report"]
    if not rep or rep[-1]["caps"]["apps"].get("htop") is not True or rep[-1]["caps"]["network"] is not True:
        raise Fail("the report after the job must say htop true and network true")
    ok(f"e: apps.install htop from the network is ok in {took:.0f} s ({msgs[0]}); dpkg has it, and the report says apps.htop true")
    # desktop.install: the plan
    cat = json.loads(m.need("cat /var/lib/tux/additions/current/actions.json", what="actions.json"))
    miss = []
    for d in cat["desktops"]:
        out = m.need("apt-cache policy " + " ".join(d["packages"]) + " | awk '/^[^ ]/{p=$1} /Candidate:/{print p, $2}'", what="apt-cache policy", limit=120)
        got = {line.split()[0].rstrip(":"): line.split()[1] for line in out.splitlines() if line.strip()}
        for p in d["packages"]:
            if got.get(p, "(none)") == "(none)":
                miss.append(f"{d['id']}:{p}")
    if miss:
        raise Fail(f"desktop packages with no candidate after apt update: {miss}")
    ok(f"e: every package of the desktops {[d['id'] for d in cat['desktops']]} has an apt candidate in the guest after apt update")


def sc_i(m, media):
    steps = [{"action": "additions.install"} for _ in range(4)]
    jid, k, _ = m.job(steps, 10, wait=False)
    m.wait_event(lambda e: e["t"] == "step" and e["job"] == jid and e["i"] == 0 and e["status"] == "running", 60, "step 0 running", k)
    m.wait_event(lambda e: e["t"] == "ack" and e["job"] == jid, 30, "ack for the job", k)
    out, _ = m.sh("python3 -c \"import urllib.request as u; print(u.urlopen('http://10.0.2.4/.tux/additions').read().decode())\"")
    if '"job":null' not in out.replace(" ", "") or f'"taken":"{jid}"' not in out.replace(" ", ""):
        raise Fail(f"after the ack the link must not serve the job and must name it as taken: {out!r}")
    m.input_line("additions-cancel")
    done = m.wait_event(lambda e: e["t"] == "done" and e["job"] == jid, 300, "done after the cancel", k)
    got = m.steps_of(jid, k)
    fin = {i: (s, msg) for i, s, msg in got if s != "running"}
    if done["ok"] is not False:
        raise Fail(f"done after cancel must be ok false: {done}")
    skipped = [i for i, (s, _) in fin.items() if s == "skipped"]
    if not skipped or len(fin) != 4 or fin[3][0] != "skipped" or any(fin[i][0] == "ok" for i in skipped):
        raise Fail(f"cancel: final steps {fin}")
    if "Cancel" not in fin[3][1]:
        raise Fail(f"the skipped steps must say Cancelled: {fin}")
    # a new job runs again (the cancel flag ends with the next job)
    jid2, k2, d2 = m.job([{"action": "hostname.set", "name": "after-cancel"}], 60)
    m.expect_steps(jid2, k2, ["ok"], "the job after a cancel")
    m.need("hostnamectl --static", lambda o: o == "after-cancel", "hostname after the cancel")
    ok("i: after the ack the link serves job null and names the job as taken (the job and its password cross the link once)")
    ok(f"i: cancel while step 0 ran: the steps after it ended skipped ({[(i, s) for i, (s, _) in sorted(fin.items())]}), done ok false; the next job runs")


def sc_f(m, media, tmp):
    results = []
    # media 2: one byte changed in a deb
    d2 = os.path.join(tmp, "media-badbyte")
    shutil.copytree(media, d2)
    deb = [os.path.join(r, f) for r, _, fs in os.walk(os.path.join(d2, "apt/pool/main")) for f in fs if f.startswith("tux-va_")][0]
    with open(deb, "r+b") as f:
        f.seek(200)
        b = f.read(1)
        f.seek(200)
        f.write(bytes([b[0] ^ 0xFF]))
    # media 3: a file SHA256SUMS does not list
    d3 = os.path.join(tmp, "media-extra")
    shutil.copytree(media, d3)
    with open(os.path.join(d3, "extra.txt"), "w") as f:
        f.write("not listed\n")
    for label, d, want in (("a changed byte", d2, "sums do not match"), ("an unlisted file", d3, "does not list")):
        k = m.mark()
        n = m.insert(d)
        ev = m.wait_event(lambda e: e["t"] == "bad-media", 120, f"bad-media for {label}", k)
        if ev["n"] != n or want not in ev["why"]:
            raise Fail(f"{label}: bad-media {ev}, want n {n} and {want!r}")
        out = m.need(f"systemctl is-failed tux-additions-agent@{n}.service; systemctl show -p ExecMainStatus tux-additions-agent@{n}.service", what="unit state")
        if "ExecMainStatus=4" not in out:
            raise Fail(f"{label}: the launcher must exit 4: {out!r}")
        m.need("ls /var/lib/tux/additions", lambda o: "current" in o.split() and not any(x.endswith(".new") for x in o.split()),
               "no half copy is left")
        m.need("pgrep -f 'additions/current/agent run'; test $? -ne 0", what="no agent runs")
        # install on the same media refuses too (exit 4)
        out, rc = m.sh(f"sh {MEDIA_MOUNT}/install 2>&1", 120)
        if rc != 4:
            raise Fail(f"{label}: sh install exited {rc}, want 4: {out[-300:]!r}")
        # a job set now must not run: no agent
        k2 = m.mark()
        jid = "j-bad-" + uuid.uuid4().hex[:6]
        path = os.path.join(tmp, "badjob.json")
        with open(path, "w") as f:
            json.dump({"id": jid, "steps": [{"action": "hostname.set", "name": "badmedia"}]}, f)
        at = len(m.host_log())
        m.input_line(f"additions-job {path}")
        m.wait_log("additions: job set", 10, at)
        os.unlink(path)
        time.sleep(12)
        m.pump()
        if any(e["t"] in ("step", "log", "done") for e in m.events[k2:]):
            raise Fail(f"{label}: a job ran on bad media: {[m.brief(e) for e in m.events[k2:]]}")
        m.need("hostnamectl --static", lambda o: o != "badmedia", "the job did not run")
        m.input_line("additions-cancel")  # drops the job from the host
        m.wait_log("additions: cancel sent", 10, at)
        results.append((label, n, ev["why"][:70], rc))
    # good media again
    k = m.mark()
    n = m.insert(media)
    m.wait_report(k, n, 150)
    m.need("readlink /var/lib/tux/additions/current", lambda o: o == str(n), "current is the good media again")
    jid, k2, done = m.job([{"action": "hostname.set", "name": "good-again"}], 60)
    m.expect_steps(jid, k2, ["ok"], "job after the bad media")
    ok("f: bad media gives a bad-media event, the launcher exits 4, no half copy, no agent, `sh install` exits 4, a job set meanwhile "
       f"does not run: {results}; the good media runs a job again")


def sc_h(m, media):
    # eject while a job runs
    k = m.mark()
    jid, k, _ = m.job([{"action": "apps.install", "ids": ["tmux"]}, {"action": "hostname.set", "name": "after-eject"}], 10, wait=False)
    m.wait_event(lambda e: e["t"] == "step" and e["job"] == jid and e["i"] == 0 and e["status"] == "running", 60, "step 0 running", k)
    m.eject()
    done = m.wait_event(lambda e: e["t"] == "done" and e["job"] == jid, 600, "done after the eject", k)
    m.expect_steps(jid, k, ["ok", "ok"], "job with an eject")
    if done["ok"] is not True:
        raise Fail(f"done: {done}")
    m.need("dpkg-query -W -f='${Status}' tmux", lambda o: o == "install ok installed", "tmux is installed")
    m.need("hostnamectl --static", lambda o: o == "after-eject", "the second step ran")
    ok("h: eject while a job ran: both steps finished ok, done ok true, tmux is installed")
    t = m.wait_guest("[ -z \"$(systemctl list-units 'tux-additions-agent@*' --no-legend --state=active,activating)\" ] && ! mountpoint -q " + MEDIA_MOUNT,
                     "the agent ends and the mount goes after the job", 90)
    ok(f"h: after the job the agent exited and {MEDIA_MOUNT} was gone within {t} s")
    # eject while idle
    k = m.mark()
    n = m.insert(media)
    m.wait_report(k, n, 150)
    m.need(f"mountpoint -q {MEDIA_MOUNT}", what="the media is mounted again")
    m.need("systemctl is-active tux-additions-agent@" + str(n), lambda o: o == "active", "agent active")
    m.eject()
    t = m.wait_guest("[ -z \"$(systemctl list-units 'tux-additions-agent@*' --no-legend --state=active,activating)\" ] && ! mountpoint -q " + MEDIA_MOUNT,
                     "the agent ends and the mount goes after an idle eject", 60)
    m.need("pgrep -f 'additions/current/agent run'; test $? -ne 0", what="no agent process")
    ok(f"h: eject while idle: the agent exited and the mount was gone within {t} s")


# ---------------------------------------------------------------- main

def prep(run, m, media, key):
    """Inserts the media in a fresh machine and waits for the agent's report. Returns n, or None (the scenarios then are not run)."""
    try:
        n = m.insert(media)
        m.wait_report(0, n, 180)
        return n
    except (Fail, pexpect.TIMEOUT, pexpect.EOF) as e:
        for k in key:
            if run.want(k):
                run.results[k] = ("FAIL", 0, f"no agent report after the insert: {str(e)[:300]}")
        print(f"FAIL {m.tag}: no agent report after the insert: {str(e)[:500]}\n--- tuxvm stderr tail:\n{m.host_log()[-1500:]}", file=sys.stderr)
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", help="the disk to clone: a tux-guest 1.10.x console image (default debian-console.img)")
    ap.add_argument("--media", help="the media folder (default build/linux/additions/tux-additions)")
    ap.add_argument("--firmware", help="default u-boot.bin next to the image")
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--ram", type=int, default=2048)
    ap.add_argument("--only", default="", help="scenario letters to run, e.g. cd (after boot 1: with --boot1-disk)")
    ap.add_argument("--boot1-disk", help="a disk saved by --save-boot1: boot 1 (a, b, j) is skipped")
    ap.add_argument("--save-boot1", help="keep the disk after boot 1 (bootstrapped, no account) here")
    ap.add_argument("--no-ssh", action="store_true", help="no real ssh login through --forward")
    ap.add_argument("--work-dir", help="where the clones go (the image's APFS volume; default build/ in this checkout)")
    args = ap.parse_args()
    d = linux_dir()
    image = args.image or os.path.join(d, "debian-console.img")
    args.firmware = args.firmware or os.path.join(d, "u-boot.bin")
    media = os.path.abspath(args.media or os.path.join(d, "additions", "tux-additions"))
    for f in (args.tuxvm, image, args.firmware, os.path.join(media, "SHA256SUMS")):
        if not os.path.exists(f):
            sys.exit(f"additions-check: {f} is missing (make build/tuxvm, make linux-additions)")
    args.agent_version = json.load(open(os.path.join(media, "versions.json")))["additions"]
    args.only = set(args.only)
    work = args.work_dir or os.path.join(ROOT, "build")
    os.makedirs(work, exist_ok=True)
    args.tmp = tempfile.mkdtemp(prefix="additions-check-", dir=work)
    run = Run(args)
    machines = []
    t_start = time.monotonic()
    ssh_key = os.path.join(args.tmp, "adcheck_key")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "additions-check", "-f", ssh_key], check=True)
    try:
        boot1 = args.boot1_disk
        if not boot1 and not any(run.want(k) for k in "abj"):
            if args.only - set("k"):
                sys.exit("additions-check: --only without a, b or j needs --boot1-disk")
            boot1 = image  # only k: it starts from the old image itself
        if not boot1:
            # ---- boot 1: the old image
            disk = run.clone(image, "boot1")
            m = Machine(args, disk, args.tmp, "boot1")
            machines.append(m)
            t = m.boot()
            ver = precondition_old_image(m)
            ok(f"boot 1: the old image (tux-guest {ver}) is up in {t} s; the console is {m.who[0]}@{m.who[1]}")
            n = m.insert(media)
            # a 1.10.x tux-files mounts the entry as a plain Read-only folder
            m.wait_guest(f"[ -r {MEDIA_MOUNT}/install ]", "the media at /media/tux/tux-additions in the old guest", 40)
            run.scenario("j", m, sc_j, media)
            run.scenario("a", m, sc_a, media, n)
            if run.results.get("a", ("",))[0] == "pass":
                run.scenario("b", m, sc_b, media)
            elif run.want("b"):
                run.results["b"] = ("not run", 0, "needs scenario a")
            if m.alive():
                m.poweroff()
            ok("boot 1: powered off")
            if run.results.get("a", ("",))[0] != "pass":
                sys.exit(print("additions-check: the bootstrap failed, so there is no upgraded image for the next boots", file=sys.stderr) or 1)
            boot1 = os.path.join(args.tmp, "boot1-done.img")
            subprocess.run(["/bin/cp", "-c", disk, boot1], check=True)
            os.unlink(disk)
            if args.save_boot1:
                shutil.copy(boot1, args.save_boot1)
        # ---- boot 2: a reboot gives the root console; c
        if run.want("c") or run.want("b") or run.want("r"):
            fwd = None if args.no_ssh else 20000 + (os.getpid() % 20000)
            m = Machine(args, run.clone(boot1, "boot2"), args.tmp, "boot2")
            machines.append(m)
            t = m.boot(["--forward", f"{fwd}:2222"] if fwd else [])
            ok(f"boot 2: the upgraded clone is up in {t} s; the console is {m.who[0]}@{m.who[1]}")
            run.scenario("b-reboot", m, sc_boot2_root)
            run.scenario("r", m, sc_r)
            if run.want("c") and prep(run, m, media, "c"):
                run.scenario("c", m, sc_c, media, ssh_key)
                if fwd and run.results.get("c", ("",))[0] == "pass":
                    run.scenario("c-ssh", m, sc_ssh_real, ssh_key, fwd)
            if m.alive():
                m.poweroff()
        # ---- boot 3: sudo false
        if run.want("d"):
            m = Machine(args, run.clone(boot1, "boot3"), args.tmp, "boot3")
            machines.append(m)
            m.boot()
            if prep(run, m, media, "d"):
                run.scenario("d", m, sc_d, media)
            m.kill()  # tux has no sudo any more, so no poweroff; the disk is thrown away
        # ---- boot 4: the rest
        if any(run.want(k) for k in "gnefih"):
            m = Machine(args, run.clone(boot1, "boot4"), args.tmp, "boot4")
            machines.append(m)
            m.boot()
            if prep(run, m, media, "gnefih"):
                run.scenario("g", m, sc_g, media)
                run.scenario("n", m, sc_n, media)
                run.scenario("e", m, sc_e, media)
                run.scenario("i", m, sc_i, media)
                run.scenario("f", m, sc_f, media, args.tmp)
                run.scenario("h", m, sc_h, media)
            if m.alive():
                m.poweroff()
        # ---- boot 5: the upgrade rule, from the old image again
        if run.want("k"):
            m = Machine(args, run.clone(image, "boot5"), args.tmp, "boot5")
            machines.append(m)
            m.boot()
            run.scenario("k", m, sc_k, media)
            m.kill()
    except (Fail, pexpect.TIMEOUT, pexpect.EOF, subprocess.CalledProcessError) as e:
        print(f"FAIL: {type(e).__name__}: {e}", file=sys.stderr)
        for m in machines:
            for log in (m.err, m.console_log):
                if os.path.exists(log):
                    print(f"--- {os.path.basename(log)}:", open(log, errors="replace").read()[-2500:], file=sys.stderr)
        run.results.setdefault("setup", ("FAIL", 0, str(e)[:300]))
    finally:
        for m in machines:
            m.kill()
        if os.environ.get("ADDITIONS_CHECK_KEEP"):
            print("kept:", args.tmp)
        else:
            shutil.rmtree(args.tmp, ignore_errors=True)
    print("\nadditions-check results:")
    bad = 0
    for key in sorted(run.results):
        st, secs, msg = run.results[key]
        print(f"  {key:9} {st:8} {secs:6.0f} s  {msg[:160]}")
        bad += st != "pass"
    print(f"additions-check: {'FAIL' if bad else 'ok'} in {time.monotonic() - t_start:.0f} s")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
