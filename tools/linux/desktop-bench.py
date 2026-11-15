#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""G6: desktop timings on tuxvm (not part of make test).

Each run boots a clone of debian-desktop.img (direct kernel boot, 1920x1080 unless --display) and reads
/run/user/1000/tux-times: guest uptime at tty1 login, labwc up and the terminal's shell start.
Then it runs `seq 1 20000` in a full-screen foot, --seqs times, timed in the guest's own clock.
Pass --gpu-accel to add tuxvm's --gpu-accel. The shared image never changes.
"""
import argparse
import os
import statistics
import subprocess
import sys
import tempfile
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, sh  # noqa: E402

WL = "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
FOOT = 's=$EPOCHREALTIME; seq 1 20000; e=$EPOCHREALTIME; echo $s $e >> /tmp/seq.times'


def one(args, d, n):
    image = os.path.join(d, "debian-desktop.img")
    smoke.gu.use(image)
    kernel, initrd = (os.path.join(d, f) for f in ("Image", "initrd.img"))
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    with tempfile.TemporaryDirectory(prefix="deskbench-", dir=args.work_dir) as tmp:
        clone, err = os.path.join(tmp, "disk.img"), os.path.join(tmp, "stderr")
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel,
                "--initrd", initrd, "--append", append, "--disk", clone, "--ram", "2048",
                "--cpus", str(args.cpus), "--display", args.display]
        if args.window:
            argv.append("--window")
        if args.gpu_accel:
            argv.append("--gpu-accel")
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
        t0 = time.monotonic()
        try:
            login(p, None, 300)
            serial = time.monotonic() - t0
            end = time.monotonic() + 120
            times = {}
            while time.monotonic() < end:
                out, _ = sh(p, "cat /run/user/1000/tux-times 2>/dev/null; true", 30)
                times = {l.split()[0]: float(l.split()[1]) for l in out.split("\n") if len(l.split()) == 2}
                if "terminal" in times:
                    break
                time.sleep(0.5)
            else:
                raise Fail(f"no terminal in 120 s; tux-times: {times}")
            renderer, _ = sh(p, "cat /run/user/1000/tux-session.log", 15)
            seqs = []
            for _ in range(args.seqs):
                sh(p, "rm -f /tmp/seq.times.one", 15)
                _, rc = sh(p, f"{WL} timeout 120 foot --fullscreen bash -c '{FOOT}'", 150)
                if rc:
                    raise Fail(f"foot gave status {rc}")
                out, _ = sh(p, "tail -n 1 /tmp/seq.times", 15)
                s, e = out.split()
                seqs.append(float(e) - float(s))
            if args.churn:  # a full-screen terminal scrolling without pause: every frame is a big dirty rectangle
                loop = "while :; do seq 1 5000; done"
                sh(p, f"{WL} timeout {args.churn + 60} foot --fullscreen bash -c 'timeout {args.churn} sh -c \"{loop}\"'", args.churn + 90)
            p.sendline("sudo poweroff")
            p.expect(pexpect.EOF, timeout=90)
            stats = [l for l in open(err).read().split("\n") if "vgpu-stats" in l]
            return dict(serial=serial, stats=stats[-1] if stats else "", login=times["login"], labwc=times["labwc-up"] - times["login"],
                        term=times["terminal"] - times["login"], renderer=renderer.strip(), seqs=seqs)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:] + "\n" + open(err).read()[-1500:])
        finally:
            if p.isalive():
                p.terminate(force=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--seqs", type=int, default=3)
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--gpu-accel", action="store_true")
    ap.add_argument("--churn", type=int, default=0, metavar="SECONDS", help="then scroll a full-screen terminal for this long")
    ap.add_argument("--display", default="1920x1080", help="WxH")
    ap.add_argument("--window", action="store_true", help="show a window, so the presenter draws (HV_VGPU_STATS=1 prints its times)")
    args = ap.parse_args()
    d = args.linux_dir or smoke.linux_dir()
    res = []
    for n in range(args.runs):
        r = one(args, d, n)
        res.append(r)
        print(f"run {n + 1}: serial login {r['serial']:.1f} s, guest login at {r['login']:.1f} s, labwc up "
              f"+{r['labwc']:.2f} s, terminal +{r['term']:.2f} s ({r['renderer']}); seq " +
              " ".join(f"{s:.3f}" for s in r["seqs"]), flush=True)
        if r["stats"]:
            print("  " + r["stats"], flush=True)
    allseq = [s for r in res for s in r["seqs"]]
    terms = ", ".join("%.2f" % r["term"] for r in res)
    firsts = ", ".join("%.3f" % r["seqs"][0] for r in res)
    print("login to terminal: median %.2f s (runs %s)" % (statistics.median(r["term"] for r in res), terms))
    print("seq 1 20000: median %.3f s, min %.3f, max %.3f (%d runs); per-boot first runs %s"
          % (statistics.median(allseq), min(allseq), max(allseq), len(allseq), firsts))


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
