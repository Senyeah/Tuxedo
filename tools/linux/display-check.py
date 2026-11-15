#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""R5: the desktop follows a host display change (make test-linux-display).

Boots a clone of debian-desktop.img at --display 1920x1080 with --share. A `mode WxH SCALE` line in
HV_INPUT_FILE must, within 3 s, give labwc a framebuffer of that size and make wlr-randr report the
scale (tux-display in the guest does this). A guest process samples the DRM framebuffer list every
100 ms; the test prints the peak number of scanout-sized framebuffers for each change.
The image needs wlr-randr (--image FILE names a rebuilt copy). The shared image never changes.
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
from smoke import Fail, login  # noqa: E402
from smoke import sh as _sh  # noqa: E402


def sh(p, cmd, limit=30):
    return _sh(p, cmd, limit)

WATCH = r'''
import re, time
log = open("/tmp/fbwatch.log", "w", buffering=1)
while True:
    try:
        txt = open("/sys/kernel/debug/dri/0/framebuffer").read()
    except OSError:
        txt = ""
    fbs = []
    for blk in txt.split("framebuffer[")[1:]:
        who = re.search(r"allocated by = (\S+)", blk)
        size = re.search(r"^\tsize=(\d+)x(\d+)", blk, re.M)
        if who and size:
            fbs.append((who.group(1), int(size.group(1)), int(size.group(2))))
    big = [f for f in fbs if f[1] * f[2] >= 500000]
    log.write("%.3f %d %s\n" % (time.time(), len(big), " ".join("%s:%dx%d" % f for f in fbs)))
    time.sleep(0.1)
'''

# wlr-randr needs the compositor's socket; the serial shell has no session
RANDR = "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 wlr-randr"

STEPS = (  # mode line, size, scale as wlr-randr prints it
    ("mode 1200x2616 2", "1200x2616", "2.000000"),
    ("mode 1920x1080 1", "1920x1080", "1.000000"),
    ("mode 3840x2160 2", "3840x2160", "2.000000"),
)


def randr(p):
    out, rc = sh(p, RANDR + " 2>&1", 15)
    return out if rc == 0 else ""


def current(out):
    m = re.search(r"^\s+(\d+x\d+) px(?:, [\d.]+ Hz)? \(.*current\)", out, re.M)
    s = re.search(r"Scale: ([\d.]+)", out)
    return (m.group(1) if m else None), (s.group(1) if s else None)


def wait_randr(p, size, scale, limit):
    end, got = time.monotonic() + limit, (None, None)
    while True:
        raw = randr(p)
        got = current(raw)
        if got == (size, scale):
            return
        if time.monotonic() > end:
            raise Fail(f"wlr-randr reports {got}, expected {(size, scale)} within {limit} s; raw:\n{raw[:200]}\n{chr(10).join(l for l in raw.splitlines() if "current" in l or "Scale" in l)}")
        time.sleep(0.2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--image", help="desktop disk to clone (default debian-desktop.img in the linux dir)")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--limit", type=float, default=3.0, help="seconds from the mode line to labwc's framebuffer")
    ap.add_argument("--cpus", type=int, default=2)
    args = ap.parse_args()
    d = args.linux_dir or smoke.linux_dir()
    image = args.image or os.path.join(d, "debian-desktop.img")
    smoke.gu.use(image)
    kernel, initrd = (os.path.join(d, f) for f in ("Image", "initrd.img"))
    pu = image[:-4] + ".partuuid"
    if not os.path.exists(pu):
        pu = os.path.join(d, "debian-desktop.partuuid")
    for f in (args.tuxvm, kernel, initrd, image, pu):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    partuuid = open(pu).read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    with tempfile.TemporaryDirectory(prefix="display-", dir=args.work_dir) as tmp:
        clone, infile, err, share = (os.path.join(tmp, n) for n in ("disk.img", "input", "stderr", "share"))
        open(infile, "w").close()
        os.mkdir(share)
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel,
                "--initrd", initrd, "--append", append, "--disk", clone, "--ram", "2048", "--cpus", str(args.cpus),
                "--display", "1920x1080", "--share", share]
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                          env=dict(os.environ, HV_INPUT_FILE=infile))
        try:
            login(p, None, 200)
            run(p, args, infile, err)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:])
        finally:
            if p.isalive():
                p.terminate(force=True)


def run(p, args, infile, err):
    _, rc = sh(p, "command -v wlr-randr")
    if rc:
        raise Fail("the image has no wlr-randr; rebuild it (build-image.sh --desktop) and pass --image")
    end = time.monotonic() + 60
    while time.monotonic() < end:  # labwc and tux-display settle
        out = randr(p)
        if current(out) == ("1920x1080", "1.000000"):
            break
        time.sleep(1)
    else:
        raise Fail("labwc is not up at 1920x1080 scale 1 within 60 s; wlr-randr says:\n" + out)
    print("ok   boot: labwc at 1920x1080, scale 1")
    out, _ = sh(p, "pgrep -a -f tux-display | head -n 3; cat /run/user/1000/tux-display.log")
    print("--- tux-display ---\n" + out.strip())

    b64 = base64.b64encode(WATCH.encode()).decode()
    sh(p, f"echo {b64} | base64 -d > /tmp/fbwatch.py; : > /tmp/fbwatch.log; chmod 644 /tmp/fbwatch.log")
    sh(p, "sudo sh -c 'nohup python3 /tmp/fbwatch.py >/dev/null 2>&1 &'; sleep 0.5")
    for line, size, scale in STEPS:
        sh(p, "date +%s.%N >/dev/null")  # warm the shell
        mark = time.time()
        with open(infile, "a") as f:
            f.write(line + "\n")
        t0 = time.monotonic()
        _, rc = sh(p, f"timeout {args.limit} sh -c 'until grep -q \"labwc:{size}\" /tmp/fbwatch.log; do sleep 0.1; done'",
                   args.limit + 20)
        took = time.monotonic() - t0
        if rc:
            tail, _ = sh(p, "tail -n 5 /tmp/fbwatch.log")
            raise Fail(f"'{line}': labwc has no framebuffer of {size} after {args.limit} s; log tail:\n{tail}")
        wait_randr(p, size, scale, max(0.5, args.limit - took))
        print(f"ok   '{line}': labwc framebuffer {size} and wlr-randr scale {scale} after {time.monotonic() - t0:.2f} s")
        time.sleep(1.0)  # the old buffers go
        log, _ = sh(p, "cat /tmp/fbwatch.log")
        peak = peak_since(log, mark, size)
        print(f"     peak scanout-sized framebuffers during '{line}': {peak[0]} ({peak[1]})")
        stale, _ = sh(p, "tail -n 1 /tmp/fbwatch.log")
        print(f"     steady state: {stale.strip().split(' ', 2)[1:]}")
    log = open(err, errors="replace").read()
    bad = [l for l in log.splitlines() if re.search(r"out of memory|ERR_|fail", l, re.I)]
    if bad:
        raise Fail("host errors on stderr:\n" + "\n".join(bad[:10]))
    p.sendline("sudo poweroff")
    p.expect(pexpect.EOF, timeout=60)
    p.close()
    if p.exitstatus != 0:
        raise Fail(f"power off gave exit status {p.exitstatus}")
    print("PASS")


def peak_since(log, mark, size):
    best = (0, "")
    for l in log.splitlines():
        f = l.split(" ", 2)
        if len(f) < 3 or float(f[0]) < mark - 0.5:
            continue
        if int(f[1]) > best[0]:
            best = (int(f[1]), f[2])
    return best


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
