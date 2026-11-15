#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""R3: a `mode WxH` line in HV_INPUT_FILE changes the guest's display mode (make test-linux-mode).

Boots a clone of debian-console.img at --display 1920x1080. With no compositor fbcon is the DRM
client, so the connector's first mode must follow each line. A bad line must change nothing.
fbcon probes with its current buffer size as the limit, so the test stays at or under 1920x1080:
a larger mode needs a compositor (the R5 follower).
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, sh  # noqa: E402

MODES = "head -n 1 /sys/class/drm/card0-Virtual-1/modes"


def first_mode(p):
    out, rc = sh(p, MODES, 5)
    return out.strip() if rc == 0 else ""


def wait_mode(p, want, limit=15):
    end, got = time.monotonic() + limit, ""
    while time.monotonic() < end:
        got = first_mode(p)
        if got == want:
            return
        time.sleep(0.5)
    allm, _ = sh(p, "head -n 6 /sys/class/drm/card0-Virtual-1/modes | tr '\\n' ' '", 5)
    raise Fail(f"first mode is {got!r}, expected {want!r} within {limit} s; modes: {allm.strip()}")


FETCH = ("python3 -c 'import urllib.request;print(urllib.request.urlopen"
         "(\"http://10.0.2.4/.tux/display\").read().decode().strip())'")


def wait_display(p, want, limit=15):
    end, got = time.monotonic() + limit, ""
    while time.monotonic() < end:
        out, rc = sh(p, FETCH, 10)
        got = out.strip().splitlines()[-1] if rc == 0 and out.strip() else out.strip()
        if got == want:
            return
        time.sleep(0.5)
    raise Fail(f"/.tux/display is {got!r}, expected {want!r} within {limit} s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    args = ap.parse_args()
    d = args.linux_dir or smoke.linux_dir()
    kernel, initrd, image = (os.path.join(d, f) for f in ("Image", "initrd.img", "debian-console.img"))
    for f in (args.tuxvm, kernel, initrd, image, image[:-4] + ".partuuid"):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    with tempfile.TemporaryDirectory(prefix="mode-", dir=args.work_dir) as tmp:
        clone, infile, err = (os.path.join(tmp, n) for n in ("disk.img", "input", "stderr"))
        open(infile, "w").close()
        share = os.path.join(tmp, "share")
        os.mkdir(share)
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel,
                "--initrd", initrd, "--append", append, "--disk", clone, "--ram", "1024", "--display", "1920x1080", "--share", share]
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                          env=dict(os.environ, HV_INPUT_FILE=infile))
        try:
            login(p, None, 150)
            wait_mode(p, "1920x1080", 5)
            print("ok   boot mode 1920x1080")
            wait_display(p, "1920 1080 1", 10)
            print("ok   /.tux/display is '1920 1080 1'")
            for line, want, disp in (("mode 1280x800", "1280x800", "1280 800 1"),
                                     ("mode 1024x768 2", "1024x768", "1024 768 2"),
                                     ("mode 1280x800", "1280x800", "1280 800 2")):  # scale stays until set
                with open(infile, "a") as f:
                    f.write(line + "\n")
                wait_mode(p, want)
                print(f"ok   '{line}' -> {want}")
                wait_display(p, disp, 5)
                print(f"ok   /.tux/display is '{disp}'")
            for bad in ("mode 0x0", "mode junk", "mode 640"):
                with open(infile, "a") as f:
                    f.write(bad + "\n")
            time.sleep(1.5)
            wait_mode(p, "1280x800", 5)
            print("ok   bad mode lines change nothing")
            log = open(err, errors="replace").read()
            if log.count("want mode WxH") != 3:
                raise Fail("expected three 'want mode WxH' lines on stderr:\n" + log[-1500:])
            p.sendline("sudo poweroff")
            p.expect(pexpect.EOF, timeout=60)
            p.close()
            if p.exitstatus != 0:
                raise Fail(f"power off gave exit status {p.exitstatus}")
            print("PASS")
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:])
        finally:
            if p.isalive():
                p.terminate(force=True)


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
