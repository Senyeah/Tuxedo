#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""P7 check: tux-clipboard in the desktop image shares the clipboard with the host (host/share.c).

Boots a clone of the desktop image on tuxvm with --share and HV_INPUT_FILE. The input file's
"clip TEXT" sets the device's clipboard and "getclip" prints what the guest sent (and when the helper
was last heard) on tuxvm's stderr. It checks: the service runs, text from before the helper started
is not applied, device to guest (with non-ASCII text), guest to device (newlines, 1 MB), no echo in
either direction, a clipboard that is not text is not sent, and the same agent on X11 through XWayland.
The image needs tux-guest 1.2 and wl-clipboard (--image FILE names a rebuilt copy). The shared image
never changes: the guest writes to a clone. Exit 1 on a failed check.
"""
import argparse
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
BIG = 1_000_000


class Host:
    """tuxvm's input file and stderr."""

    def __init__(self, inp, err):
        self.inp, self.err = inp, err

    def line(self, text):
        with open(self.inp, "a") as f:
            f.write(text + "\n")

    def getclip(self, limit=15, want=None):
        """Asks what the guest sent; returns the text, or None for nothing new. want: wait until it is not None."""
        end = time.monotonic() + limit
        while True:
            before = len(open(self.err, errors="replace").read())
            self.line("getclip")
            for _ in range(40):
                time.sleep(0.25)
                rest = open(self.err, errors="replace").read()[before:]
                m = re.search(r"guest clipboard: (.*) \(helper seen (-?\d+) s ago\)\n", rest, re.S)
                if m:
                    break
            else:
                raise Fail("getclip: tuxvm did not answer")
            text = None if m.group(1) == "(nothing new)" else m.group(1)
            self.seen = int(m.group(2))
            if text is not None or want is None or time.monotonic() > end:
                return text
            time.sleep(0.5)


def guest_clip(p, env=WL, limit=15, want=None):
    """The guest's text clipboard (None when empty), waiting until it equals want."""
    end = time.monotonic() + limit
    while True:
        out, rc = sh(p, f"{env} wl-paste --no-newline --type text 2>/dev/null", 20)
        got = out if rc == 0 else None
        if want is None or got == want or time.monotonic() > end:
            return got
        time.sleep(0.5)


def one(args):
    image = args.image
    smoke.gu.use(image)
    kernel, initrd = (os.path.join(smoke.linux_dir(), f) for f in ("Image", "initrd.img"))
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    share = tempfile.mkdtemp(prefix="clip-", dir="/tmp")  # a short path: the share socket's path is limited
    with tempfile.TemporaryDirectory(prefix="clipcheck-", dir=args.work_dir) as tmp:
        clone, err, inp = (os.path.join(tmp, f) for f in ("disk.img", "stderr", "input"))
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        host = Host(inp, err)
        host.line("clip from before the helper started")  # the device's clipboard is set at boot
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel,
                "--initrd", initrd, "--append", append, "--disk", clone, "--ram", "2048",
                "--cpus", str(args.cpus), "--display", "1280x720", "--share", share]
        env = dict(os.environ, HV_INPUT_FILE=inp)
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200), env=env)
        try:
            login(p, None, 300)

            def need(cmd, ok=lambda o: True, what="", limit=30):
                out, rc = sh(p, cmd, limit)
                if rc != 0 or not ok(out.strip()):
                    raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out.strip()[-1500:]!r}")
                return out.strip()

            # The service starts with labwc
            end = time.monotonic() + 120
            while True:
                out, _ = sh(p, "systemctl --user is-active tux-clipboard", 20)
                if out.strip() == "active":
                    break
                if time.monotonic() > end:
                    raise Fail("tux-clipboard is not active 120 s after login: " + out.strip()
                               + "\n" + sh(p, "journalctl --user -u tux-clipboard --no-pager | tail -n 20", 20)[0])
                time.sleep(1)
            print("ok: the service is active", flush=True)

            # It is heard from within the helper's poll window
            host.getclip()
            for _ in range(20):
                if 0 <= host.seen <= 26:
                    break
                time.sleep(1)
                host.getclip()
            if not 0 <= host.seen <= 26:
                raise Fail(f"the helper was last heard {host.seen} s ago")
            print(f"ok: the helper was heard {host.seen} s ago", flush=True)

            got = guest_clip(p)
            if got:
                raise Fail(f"text from before the helper started was applied: {got!r}")
            print("ok: text from before the helper started is not applied", flush=True)

            # Device to guest, at once after the helper is up
            text = "from the device: héllo wörld ✓ 日本語 -n $HOME 'quoted'"
            host.line("clip " + text)
            t = time.monotonic()
            got = guest_clip(p, want=text)
            if got != text:
                raise Fail(f"device to guest: the guest has {got!r}")
            print(f"ok: device to guest, non-ASCII ({time.monotonic() - t:.1f} s)", flush=True)

            time.sleep(3)
            got = host.getclip()
            if got is not None:
                raise Fail(f"the guest echoed the device's text back: {got!r}")
            print("ok: no echo from the device's text", flush=True)

            # Guest to device
            need(f"printf 'guest ✓ ü\\nline two\\n\\n' | {WL} wl-copy", what="wl-copy")
            got = host.getclip(want=True)
            if got != "guest ✓ ü\nline two\n\n":
                raise Fail(f"guest to device: the host has {got!r}")
            print("ok: guest to device, newlines and non-ASCII", flush=True)
            time.sleep(1)
            got = host.getclip()
            if got is not None:
                raise Fail(f"the same text was sent twice: {got!r}")
            print("ok: no echo from the guest's text", flush=True)

            need(f"head -c {BIG * 3 // 4} /dev/urandom | base64 -w0 | {WL} wl-copy", what="wl-copy 1 MB", limit=60)
            got = host.getclip(want=True, limit=30)
            if got is None or len(got) != BIG:
                raise Fail(f"1 MB: the host has {None if got is None else len(got)} characters")
            print("ok: guest to device, 1 MB", flush=True)

            # Not text
            need(f"head -c 100 /dev/urandom | {WL} wl-copy --type application/octet-stream", what="wl-copy binary")
            time.sleep(3)
            got = host.getclip()
            if got is not None:
                raise Fail(f"a clipboard that is not text was sent: {got!r}")
            print("ok: a clipboard that is not text is not sent", flush=True)

            # The X11 mode through XWayland
            need("systemctl --user stop tux-clipboard", what="stop the service")
            x11 = f"{WL} DISPLAY=:0 TUX_CLIPBOARD=x11"
            need(f"{x11} setsid /usr/lib/tux/tux-clipboard > /tmp/x11.log 2>&1 < /dev/null & sleep 3; true", what="x11 agent")
            host.line("clip x11 from the device ✓")
            got = guest_clip(p, env=f"{WL} DISPLAY=:0", want="x11 from the device ✓")
            xout, _ = sh(p, f"{x11} xclip -selection clipboard -out", 20)
            if xout.strip() != "x11 from the device ✓":
                raise Fail(f"x11, device to guest: xclip has {xout.strip()!r}, wl-paste {got!r}; log: {sh(p, 'cat /tmp/x11.log', 10)[0]}")
            print("ok: device to guest on X11 (and through XWayland to Wayland)", flush=True)
            need(f"printf 'x11 from the guest ü' | {x11} xclip -selection clipboard -in", what="xclip -in")
            got = host.getclip(want=True)
            if got != "x11 from the guest ü":
                raise Fail(f"x11, guest to device: the host has {got!r}; log: {sh(p, 'cat /tmp/x11.log', 10)[0]}")
            print("ok: guest to device on X11", flush=True)

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
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    args = ap.parse_args()
    one(args)
    print("clipboard-check: all checks passed")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
