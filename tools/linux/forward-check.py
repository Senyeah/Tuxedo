#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Port forwards into the guest (tuxvm --forward, host/net_forward.c), on a clone of the console image.

Boot 1 listens on 127.0.0.1 (tuxvm's default) with three rules: SSH to the guest's port 22, HTTP to a
python3 -m http.server on 8000, and two whose ports the Mac holds already: one on 127.0.0.1, one on 0.0.0.0. It installs openssh-server and a
throwaway key in the guest, then: ssh logs in through the forward and carries 16 MB both ways; curl gets the page;
each held port is an error in tuxvm's log, the machine runs anyway, and the forward comes up once the port is
free; nothing listens on the Mac's other addresses. Boot 2 has --forward-addr local (the app's: every local network
address and loopback) and HV_NET_FWD (the old variable, an alias of --forward): ssh on 127.0.0.1 and on the Mac's
LAN address (only listed when the Mac's application firewall is on: it holds such connections to an unsigned
tuxvm), and curl through the alias's port. The key pair is made for the run in a temporary folder and goes
with it. Exit 1 on a failed check.
"""
import argparse
import hashlib
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import pexpect
import guest_user as gu

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, sh  # noqa: E402

PAGE = "tux forward check"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def lan_address():
    """The Mac's address on its default route, or None (a UDP connect sends nothing)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.0.2.1", 9))
            a = s.getsockname()[0]
        except OSError:
            return None
    return None if a.startswith("127.") or a == "0.0.0.0" else a


def firewall_on():
    """macOS's application firewall holds connections from other addresses to an unsigned listener such as tuxvm."""
    r = subprocess.run(["/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate"], capture_output=True, text=True)
    return "enabled" in r.stdout


def refused(addr, port):
    try:
        with socket.create_connection((addr, port), timeout=3):
            return False
    except OSError:
        return True


class Run:
    def __init__(self, args, tmp):
        self.args, self.tmp = args, tmp
        self.disk = os.path.join(tmp, "disk.img")
        self.key = os.path.join(tmp, "key")
        self.err = None
        self.p = None

    def boot(self, name, forwards, extra=(), env=None):
        self.err = os.path.join(self.tmp, f"{name}.stderr")
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', self.err, self.args.tuxvm, "--firmware",
                self.args.firmware, "--disk", self.disk, "--ram", "2048", "--cpus", str(self.args.cpus)]
        for f in forwards:
            argv += ["--forward", f]
        argv += list(extra)
        self.p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", timeout=60,
                               env=dict(os.environ, **(env or {})))
        login(self.p, None, 180)
        self.need("systemctl is-system-running --wait || true",
                  lambda o: o.splitlines()[-1] in ("running", "degraded"), "system state", 180)

    def need(self, cmd, ok=lambda o: True, what="", limit=60):
        out, rc = sh(self.p, cmd, limit)
        out = out.strip()
        if rc != 0 or not ok(out):
            raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
        return out

    def log(self):
        try:
            return open(self.err, errors="replace").read()
        except OSError:
            return ""

    def wait_log(self, pattern, limit, what):
        end = time.monotonic() + limit
        while time.monotonic() < end:
            if re.search(pattern, self.log()):
                return
            time.sleep(0.25)
        raise Fail(f"{what}: {pattern!r} not in tuxvm's log within {limit} s")

    def ssh(self, addr, port, command, data=None, limit=60):
        env = {k: v for k, v in os.environ.items() if k != "SSH_AUTH_SOCK"}  # only the run's own key
        cmd = ["ssh", "-F", "/dev/null", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
               "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes",
               "-o", "ConnectTimeout=15", "-o", "LogLevel=ERROR", "-p", str(port), f"{gu.user()}@{addr}", command]
        r = subprocess.run(cmd, input=data, capture_output=True, timeout=limit, env=env)
        if r.returncode:
            raise Fail(f"ssh to {addr}:{port} ({command!r}): status {r.returncode}, {r.stderr.decode(errors='replace')[-500:]!r}")
        return r.stdout

    def curl(self, addr, port):
        r = subprocess.run(["curl", "-sS", "--max-time", "15", f"http://{addr}:{port}/"], capture_output=True, text=True)
        if r.returncode or PAGE not in r.stdout:
            raise Fail(f"curl http://{addr}:{port}/: status {r.returncode}, {r.stdout[-200:]!r} {r.stderr[-300:]!r}")

    def serve(self):
        self.need(f"mkdir -p /tmp/www && echo '{PAGE}' > /tmp/www/index.html && "
                  "(cd /tmp/www && nohup python3 -m http.server 8000 >/tmp/www.log 2>&1 &) && "
                  "for i in $(seq 50); do (echo > /dev/tcp/127.0.0.1/8000) 2>/dev/null && break; sleep 0.2; done",
                  what="http.server on 8000", limit=30)

    def poweroff(self):
        self.p.sendline("sudo poweroff")
        self.p.expect(pexpect.EOF, timeout=90)
        self.p = None


def check(args, run):
    ssh_port, http_port, busy_port, wild_port, alias_port = free_port(), free_port(), free_port(), free_port(), free_port()
    lan = lan_address()
    held = socket.socket()
    held.bind(("127.0.0.1", busy_port))
    held.listen(1)
    wild = socket.socket()  # BSD lets libslirp's SO_REUSEADDR bind of 127.0.0.1 sit beside this one
    wild.bind(("0.0.0.0", wild_port))
    wild.listen(1)

    # Boot 1: 127.0.0.1
    run.boot("boot1", [f"{ssh_port}:22", f"{http_port}:8000", f"{busy_port}:9", f"{wild_port}:9"])
    run.wait_log(rf"net: forward 127\.0\.0\.1:{ssh_port} -> guest port 22\n", 10, "the SSH forward")
    run.wait_log(rf"net: forward 127\.0\.0\.1:{http_port} -> guest port 8000\n", 10, "the HTTP forward")
    run.wait_log(rf"net: no forward from 127\.0\.0\.1:{busy_port}: Address already in use", 10, "the held port")
    run.wait_log(rf"net: no forward from 127\.0\.0\.1:{wild_port}: Address already in use", 10, "the port held on 0.0.0.0")
    print(f"ok: forwards on 127.0.0.1:{ssh_port} and :{http_port}; :{busy_port} (held on 127.0.0.1) and :{wild_port} "
          "(held on 0.0.0.0) are in use, errors, and the machine runs")

    have, _ = sh(run.p, "command -v sshd /usr/sbin/sshd python3", 20)
    if "sshd" not in have or "python3" not in have:
        run.need("sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive "
                 "apt-get -y -qq install openssh-server python3 >/var/tmp/apt.log 2>&1; tail -2 /var/tmp/apt.log",
                 what="install openssh-server", limit=900)
    run.need("sudo systemctl enable --now ssh && systemctl is-active ssh", lambda o: o.splitlines()[-1] == "active",
             "sshd runs", 60)
    pub = open(run.key + ".pub").read().strip()
    run.need(f"mkdir -p -m 700 ~/.ssh && echo '{pub}' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")

    out = run.ssh("127.0.0.1", ssh_port, "echo forward-ok $(id -un) $(uname -m)").decode().strip()
    if out != f"forward-ok {gu.user()} aarch64":
        raise Fail(f"ssh through the forward said {out!r}")
    blob = os.urandom(16 << 20)
    want = hashlib.sha256(blob).hexdigest()
    t = time.monotonic()
    got = run.ssh("127.0.0.1", ssh_port, "sha256sum | cut -d' ' -f1", blob, 300).decode().strip()
    up = time.monotonic() - t
    if got != want:
        raise Fail(f"16 MB to the guest over ssh: sha256 {got} not {want}")
    run.need("head -c 16777216 /dev/urandom > /tmp/blob && sha256sum /tmp/blob > /tmp/blob.sha")
    t = time.monotonic()
    back = run.ssh("127.0.0.1", ssh_port, "cat /tmp/blob", limit=300)
    down = time.monotonic() - t
    if hashlib.sha256(back).hexdigest() != run.need("cut -d' ' -f1 /tmp/blob.sha"):
        raise Fail("16 MB from the guest over ssh arrived damaged")
    print(f"ok: ssh -p {ssh_port} {gu.user()}@127.0.0.1 logs in with the run's key; 16 MB in {16 / up:.1f} MB/s, out {16 / down:.1f} MB/s")

    run.serve()
    run.curl("127.0.0.1", http_port)
    print(f"ok: curl http://127.0.0.1:{http_port}/ gets the guest's python3 -m http.server page")

    if lan:
        if not refused(lan, ssh_port) or not refused(lan, http_port):
            raise Fail(f"a forward listens on {lan}: tuxvm's default is 127.0.0.1 only")
        print(f"ok: nothing listens on the Mac's {lan}")
    else:
        print("note: the Mac has no LAN address; the 127.0.0.1-only check is skipped")

    held.close()
    wild.close()
    run.wait_log(rf"net: forward 127\.0\.0\.1:{busy_port} -> guest port 9\n", 15, "the held port, once free")
    run.wait_log(rf"net: forward 127\.0\.0\.1:{wild_port} -> guest port 9\n", 15, "the port held on 0.0.0.0, once free")
    print(f"ok: :{busy_port} and :{wild_port} listen within a refresh of being freed")
    run.poweroff()

    # Boot 2: the app's local networks, and HV_NET_FWD
    run.boot("boot2", [f"{ssh_port}:22"], ["--forward-addr", "local"], {"HV_NET_FWD": f"{alias_port}:8000"})
    run.wait_log(rf"net: forward 127\.0\.0\.1:{ssh_port} -> guest port 22\n", 10, "the SSH forward on loopback")
    run.wait_log(rf"net: forward 127\.0\.0\.1:{alias_port} -> guest port 8000\n", 10, "HV_NET_FWD's forward")
    out = run.ssh("127.0.0.1", ssh_port, "echo forward-ok").decode().strip()
    if out != "forward-ok":
        raise Fail(f"ssh on 127.0.0.1 with --forward-addr local said {out!r}")
    if lan:
        run.wait_log(rf"net: forward {re.escape(lan)}:{ssh_port} -> guest port 22\n", 10, "the SSH forward on the LAN")
    if lan and firewall_on():
        print(f"ok: --forward-addr local listens on {lan} and 127.0.0.1; ssh on 127.0.0.1 (the Mac's application firewall "
              f"holds connections to {lan} for tuxvm, so that one is not tried)")
    elif lan:
        out = run.ssh(lan, ssh_port, "echo forward-ok").decode().strip()
        if out != "forward-ok":
            raise Fail(f"ssh on {lan} said {out!r}")
        print(f"ok: --forward-addr local: ssh -p {ssh_port} {gu.user()}@{lan} and {gu.user()}@127.0.0.1")
    else:
        print("ok: --forward-addr local: ssh on 127.0.0.1 (no LAN address to try)")
    run.serve()
    run.curl("127.0.0.1", alias_port)
    print(f"ok: HV_NET_FWD={alias_port}:8000 still forwards, as an alias of --forward")
    run.poweroff()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", default=os.path.join(smoke.linux_dir(), "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(smoke.linux_dir(), "u-boot.bin"))
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--cpus", type=int, default=2)
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    ap.add_argument("--keep-logs", help="copy tuxvm's logs here")
    args = ap.parse_args()
    gu.use(args.image)
    tmp = tempfile.mkdtemp(prefix="forward-check-", dir=args.work_dir)
    run = Run(args, tmp)
    try:
        subprocess.run(["/bin/cp", "-c", args.image, run.disk], check=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "forward-check", "-f", run.key], check=True)
        check(args, run)
        print("forward-check: PASS")
        return 0
    except (Fail, pexpect.ExceptionPexpect, subprocess.SubprocessError) as e:
        print(f"forward-check: FAIL: {e}", file=sys.stderr)
        if run.p is not None:
            print("console tail:\n" + (run.p.before or "")[-3000:], file=sys.stderr)
        print("tuxvm stderr tail:\n" + run.log()[-2000:], file=sys.stderr)
        return 1
    finally:
        if run.p is not None and run.p.isalive():
            run.p.terminate(force=True)
        if args.keep_logs:
            os.makedirs(args.keep_logs, exist_ok=True)
            for f in os.listdir(tmp):
                if f.endswith(".stderr"):
                    shutil.copy(os.path.join(tmp, f), args.keep_logs)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
