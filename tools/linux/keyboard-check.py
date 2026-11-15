#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Check: tux-keyboard in the desktop image tells the host when the focused program wants text (host/share.c).

Boots a clone of the desktop image on tuxvm with --share and HV_INPUT_FILE. The input file's "getkbd" prints
what the guest last asked for ("show" or "hide") and the request count on tuxvm's stderr. In the labwc session
it checks: the service runs; foot with the focus gives "show" and still gets keys; a window with no text field (wlprobe.py) gives
"hide", and "show" comes back when it closes; no window gives "hide"; the helper says "hide" when it stops, and
"show" when it starts with a text field in focus; the guest reads the height that "kbdheight F" sets. --gtk also installs zenity in the clone (needs the network):
a GTK entry gives "show", a GTK dialog with no entry does not.
The image needs tux-guest 1.2.2 or later (--image FILE names a rebuilt copy). The shared image never changes: the guest
writes to a clone. Exit 1 on a failed check.
"""
import argparse
import base64
import os
import re
import subprocess
import sys
import tempfile
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, sh  # noqa: E402

WL = "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wlprobe.py")


class Host:
    """tuxvm's input file and stderr."""

    def __init__(self, inp, err):
        self.inp, self.err = inp, err
        self.count = 0  # the request count at the last state a check accepted

    def line(self, text):
        with open(self.inp, "a") as f:
            f.write(text + "\n")

    def getkbd(self):
        """What the guest last asked for, and the request count."""
        before = len(open(self.err, errors="replace").read())
        self.line("getkbd")
        for _ in range(40):
            time.sleep(0.25)
            m = re.search(r"guest keyboard: (show|hide) \(request (\d+)\)\n", open(self.err, errors="replace").read()[before:])
            if m:
                return m.group(1), int(m.group(2))
        raise Fail("getkbd: tuxvm did not answer")

    def wait(self, want, what, limit=30):
        """Waits for want from a request newer than the last accepted one; returns the seconds it took."""
        t = time.monotonic()
        while True:
            got, n = self.getkbd()
            if got == want and n > self.count:
                self.count = n
                return time.monotonic() - t
            if time.monotonic() - t > limit:
                raise Fail(f"{what}: the host has {got!r} (request {n}, last accepted {self.count}), not a new {want!r}, after {limit} s")
            time.sleep(0.25)

    def stays(self, want, what, secs=4):
        """The state and the request count do not change for secs."""
        first = self.getkbd()
        if first[0] != want:
            raise Fail(f"{what}: the host has {first[0]!r}, not {want!r}")
        end = time.monotonic() + secs
        while time.monotonic() < end:
            got = self.getkbd()
            if got != first:
                raise Fail(f"{what}: the host went from {first} to {got}")
            time.sleep(0.5)


def upload(p, local, remote):
    data = base64.b64encode(open(local, "rb").read()).decode()
    sh(p, f": > {remote}.b64", 20)
    for i in range(0, len(data), 600):
        sh(p, f"printf %s '{data[i:i + 600]}' >> {remote}.b64", 20)
    out, rc = sh(p, f"base64 -d {remote}.b64 > {remote}", 20)
    if rc:
        raise Fail(f"upload of {local} failed: {out.strip()}")


def one(args):
    image = args.image
    kernel, initrd = (os.path.join(smoke.linux_dir(), f) for f in ("Image", "initrd.img"))
    for f in (args.tuxvm, kernel, initrd, image, image[:-4] + ".partuuid"):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    share = tempfile.mkdtemp(prefix="kbd-", dir="/tmp")  # a short path: the share socket's path is limited
    with tempfile.TemporaryDirectory(prefix="kbdcheck-", dir=args.work_dir) as tmp:
        clone, err, inp = (os.path.join(tmp, f) for f in ("disk.img", "stderr", "input"))
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        open(inp, "w").close()
        open(err, "w").close()  # getkbd reads it before the shell makes it
        host = Host(inp, err)
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel,
                "--initrd", initrd, "--append", append, "--disk", clone, "--ram", "2048",
                "--cpus", str(args.cpus), "--display", "1280x720", "--share", share]
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                          env=dict(os.environ, HV_INPUT_FILE=inp))
        try:
            # Before the guest runs: nothing asked
            first = host.getkbd()
            if first != ("hide", 0):
                raise Fail(f"before the guest runs the host has {first}, not ('hide', 0)")
            print("ok: before the guest runs: hide, no request", flush=True)
            login(p, None, 300)

            def need(cmd, what="", limit=30):
                out, rc = sh(p, cmd, limit)
                if rc != 0:
                    raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out.strip()[-1500:]!r}")
                return out.strip()

            def journal():
                return sh(p, "journalctl --user -u tux-keyboard --no-pager | tail -n 20", 20)[0]

            def start(cmd):
                need(f"{WL} setsid {cmd} > /dev/null 2>&1 < /dev/null & true", what=cmd)

            try:
                # The service starts with labwc
                end = time.monotonic() + 120
                while True:
                    out, _ = sh(p, "systemctl --user is-active tux-keyboard", 20)
                    if out.strip() == "active":
                        break
                    if time.monotonic() > end:
                        raise Fail("tux-keyboard is not active 120 s after login: " + out.strip())
                    time.sleep(1)
                print("ok: the service is active", flush=True)

                # labwc's autostart opens foot, which has the focus and takes text
                host.wait("show", "foot has the focus", 60)
                print("ok: foot has the focus: show", flush=True)
                host.stays("show", "foot keeps the focus")
                print("ok: no more requests while the focus stays", flush=True)

                # The helper is labwc's input method: keys must still reach the program
                host.line("type touch kbdtyped")
                host.line("key 28")  # Enter
                need("for i in $(seq 20); do test -e ~/kbdtyped && break; sleep 0.5; done; test -e ~/kbdtyped", what="keys reach foot")
                print("ok: keys still reach foot", flush=True)

                # A window with no text field takes the focus, then closes
                upload(p, PROBE, "/tmp/wlprobe.py")
                start("python3 /tmp/wlprobe.py 320 240 8")
                t = host.wait("hide", "a window with no text field has the focus", 20)
                print(f"ok: a window with no text field: hide ({t:.1f} s)", flush=True)
                t = host.wait("show", "the window closed and foot has the focus again", 30)
                print(f"ok: it closes, foot has the focus again: show ({t:.1f} s)", flush=True)

                # No window at all
                need("pkill -x foot", what="close foot")
                t = host.wait("hide", "no window", 20)
                print(f"ok: no window: hide ({t:.1f} s)", flush=True)
                start("foot")
                t = host.wait("show", "a new foot", 30)
                print(f"ok: a new foot: show ({t:.1f} s)", flush=True)

                # The helper stops and starts with a text field in focus
                need("systemctl --user stop tux-keyboard", what="stop the service")
                t = host.wait("hide", "the helper stopped", 20)
                print(f"ok: the helper stops: hide ({t:.1f} s)", flush=True)
                need("systemctl --user start tux-keyboard", what="start the service")
                t = host.wait("show", "the helper started with foot in focus", 30)
                print(f"ok: the helper starts with a text field in focus: show ({t:.1f} s)", flush=True)

                # The device keyboard's height reaches the guest (KWin's panel reads it; labwc has no use for it)
                get = ("python3 -c 'import urllib.request;print(urllib.request.urlopen"
                       "(\"http://10.0.2.4/.tux/keyboard\",timeout=5).read().decode().strip())'")
                for line, want in (("kbdheight 0.4", "height 0.400"), ("kbdheight 0", "height 0.000")):
                    host.line(line)
                    got = need(f"sleep 1; {get}", what="GET /.tux/keyboard")
                    if got != want:
                        raise Fail(f"after '{line}' the guest reads {got!r}, not {want!r}")
                print("ok: the guest reads the device keyboard's height", flush=True)

                if args.gtk:
                    need("sudo apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends zenity",
                         what="install zenity", limit=1500)
                    need("pkill -x foot", what="close foot")
                    host.wait("hide", "no window", 20)
                    start("zenity --info --text nothing-to-type")
                    need("for i in $(seq 60); do pgrep -x zenity > /dev/null && break; sleep 1; done; sleep 15", limit=120)
                    host.stays("hide", "a GTK dialog with no entry", 5)
                    print("ok: a GTK dialog with no entry: no request", flush=True)
                    need("pkill -x zenity", what="close zenity")
                    start("zenity --entry --text type-here")
                    t = host.wait("show", "a GTK entry has the focus", 90)
                    print(f"ok: a GTK entry has the focus: show ({t:.1f} s)", flush=True)
                    need("pkill -x zenity", what="close zenity")
                    t = host.wait("hide", "the GTK entry closed", 20)
                    print(f"ok: the GTK entry closes: hide ({t:.1f} s)", flush=True)
            except Fail as e:
                raise Fail(f"{e}\ntux-keyboard's journal:\n{journal()}")

            p.sendline("sudo poweroff")
            p.expect(pexpect.EOF, timeout=90)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:] + "\n" + open(err).read()[-1500:])
        finally:
            if p.isalive():
                p.terminate(force=True)
            subprocess.run(["rm", "-rf", share])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(smoke.linux_dir(), "debian-desktop.img"))
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--gtk", action="store_true", help="also install zenity in the clone and check a GTK entry")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    args = ap.parse_args()
    one(args)
    print("keyboard-check: all checks passed")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
