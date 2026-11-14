#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""CPU-bound guest timings on tuxvm (not part of make test).

Each run boots a clone of debian-console.img (direct kernel boot) and times, in the guest's clock:
  sha256  1024 MB from /dev/zero through sha256sum (user-space compute, page faults)
  loop    a 1,000,000-step bash arithmetic loop (interpreter, no syscalls)
  fork    1000 runs of /bin/true (fork, exec, exit: context switches, address-space churn)
Pass --tuxvm LABEL=PATH more than once to compare builds: the runs alternate between them,
so host load hits each build alike. Reports median and min-max per build.
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, sh  # noqa: E402

TESTS = {
    "sha256": "dd if=/dev/zero bs=1M count=1024 status=none | sha256sum >/dev/null",
    "loop": "i=0; while [ $i -lt 1000000 ]; do i=$((i+1)); done",
    "fork": "for i in $(seq 1000); do /bin/true; done",
}


def one(args, d, tuxvm, n):
    image = os.path.join(d, "debian-console.img")
    kernel, initrd = (os.path.join(d, f) for f in ("Image", "initrd.img"))
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    with tempfile.TemporaryDirectory(prefix="cpubench-", dir=args.work_dir) as tmp:
        clone = os.path.join(tmp, "disk.img")
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        a = argparse.Namespace(qemu=False, tux_dtb=False, cpus=args.cpus, ram=args.ram, log=1,
                               no_reboot=False, phone=False, tuxvm=tuxvm)
        argv = smoke.command(a, kernel, initrd, tmp, append, clone, None)
        t0 = time.monotonic()
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
        try:
            login(p, append, 300)
            res = {"login": time.monotonic() - t0}
            sh(p, "sleep 2", 30)
            for name, cmd in TESTS.items():
                out, rc = sh(p, f"s=$EPOCHREALTIME; {cmd}; e=$EPOCHREALTIME; echo T $s $e", 300)
                m = re.search(r"T (\d+\.\d+) (\d+\.\d+)", out)
                if not m or rc:
                    raise Fail(f"{name}: status {rc}, output {out[-300:]!r}")
                res[name] = float(m.group(2)) - float(m.group(1))
            p.sendline("sudo poweroff")
            p.expect(pexpect.EOF, timeout=120)
            return res
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:])
        finally:
            if p.isalive():
                p.terminate(force=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tuxvm", action="append", help="[LABEL=]PATH, repeatable")
    ap.add_argument("--linux-dir")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--cpus", type=int, default=1)
    ap.add_argument("--ram", type=int, default=2048)
    args = ap.parse_args()
    builds = []
    for spec in args.tuxvm or [os.path.join(smoke.ROOT, "build", "tuxvm")]:
        label, _, path = spec.rpartition("=")
        builds.append((label or os.path.basename(path), path))
    d = args.linux_dir or smoke.linux_dir()
    rows = {label: [] for label, _ in builds}
    for n in range(args.runs):
        for label, path in builds:
            r = one(args, d, path, n)
            rows[label].append(r)
            print(f"run {n + 1} {label}: " + " ".join(f"{k} {v:.3f}" for k, v in r.items()), flush=True)
    print(f"\nmedian (min-max) seconds, {args.runs} runs, {args.cpus} cpu, load {os.getloadavg()}")
    for label, rs in rows.items():
        print(f"{label}: " + ", ".join(
            f"{k} {statistics.median(r[k] for r in rs):.3f} ({min(r[k] for r in rs):.3f}-{max(r[k] for r in rs):.3f})"
            for k in rs[0]))


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
