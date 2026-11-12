#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Guest smoke test over the serial console.

--direct: direct kernel boot (Image and initrd.img) to the (initramfs) prompt,
then cat /proc/cpuinfo, uname -m and poweroff -f, which must end hengevm with
status 0. --qemu runs the same checks on QEMU's virt machine (hvf), and
--qemu --henge-dtb gives QEMU Henge's device tree (E8 step 1).
Exit 1 on any failed check; the last 200 lines of console output go to stderr.
"""
import argparse
import collections
import os
import re
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU = os.environ.get("QEMU", "/opt/homebrew/bin/qemu-system-aarch64")
APPEND = "console=ttyAMA0 earlycon=pl011,0x9000000 break=top"
PROMPT = r"\(initramfs\) "

# Seconds: three times the slowest of five runs (prompt 2.8 s), at least 5 s per step (E8 findings).
LIMITS = {"prompt": 9, "command": 5, "poweroff": 5}


def linux_dir():
    """HENGE_LINUX_OUT, else build/linux in the main checkout (worktrees share it)."""
    if os.environ.get("HENGE_LINUX_OUT"):
        return os.environ["HENGE_LINUX_OUT"]
    try:
        common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
        return os.path.join(os.path.dirname(common), "build", "linux")
    except (OSError, subprocess.CalledProcessError):
        return os.path.join(ROOT, "build", "linux")


class Tail:
    """Keeps the last lines of the console for a failure report."""

    def __init__(self, n=200):
        self.lines, self.part = collections.deque(maxlen=n), ""

    def write(self, s):
        s = self.part + s.replace("\r", "")
        *done, self.part = s.split("\n")
        self.lines.extend(done)

    def flush(self):
        pass

    def text(self):
        return "\n".join(list(self.lines) + [self.part])


class Fail(Exception):
    pass


def command(args, kernel, initrd, tmp):
    """argv for the machine under test. hengevm's stderr goes to a file so the console stays clean."""
    if args.qemu:
        argv = [QEMU, "-M", "virt,gic-version=3,highmem=off", "-accel", "hvf", "-cpu", "host",
                "-smp", str(args.cpus), "-m", str(args.ram), "-nographic", "-no-reboot",
                "-kernel", kernel, "-initrd", initrd]
        if not args.henge_dtb:
            return argv + ["-append", APPEND]
        # Henge's tree carries the command line; QEMU adds only the initrd range.
        dtb = os.path.join(tmp, "henge.dtb")
        r = subprocess.run([args.hengevm, "--board", "virt", "--dump-dtb", dtb, "--append", APPEND,
                            "--ram", str(args.ram), "--cpus", str(args.cpus)], capture_output=True, text=True)
        if r.returncode != 0:
            raise Fail(f"hengevm --dump-dtb failed: {r.stderr.strip()}")
        return argv + ["-dtb", dtb]
    argv = [args.hengevm, "--board", "virt", "--kernel", kernel, "--initrd", initrd, "--append", APPEND,
            "--ram", str(args.ram), "--cpus", str(args.cpus), "--log", str(args.log), "--no-reboot"]
    if args.phone:
        argv.append("--phone")
    return ["/bin/sh", "-c", 'exec "$@" 2>"$0"', os.path.join(tmp, "stderr")] + argv


def expect(p, pattern, limit, what):
    try:
        p.expect(pattern, timeout=limit)
    except pexpect.TIMEOUT:
        raise Fail(f"{what}: no match for {pattern!r} within {limit} s")
    except pexpect.EOF:
        raise Fail(f"{what}: the machine stopped before {pattern!r}")


def run_cmd(p, cmd, limit):
    """Sends cmd at the prompt and returns its output."""
    p.sendline(cmd)
    expect(p, re.escape(cmd) + r"\r*\n", limit, cmd)
    expect(p, PROMPT, limit, cmd)
    return p.before.replace("\r", "")


def direct(args, times):
    d = args.linux_dir or linux_dir()
    kernel, initrd = os.path.join(d, "Image"), os.path.join(d, "initrd.img")
    for f in (kernel, initrd):
        if not os.path.exists(f):
            raise Fail(f"missing {f} (set HENGE_LINUX_OUT or --linux-dir)")
    tail = Tail()
    with tempfile.TemporaryDirectory(prefix="smoke-") as tmp:
        argv = command(args, kernel, initrd, tmp)
        stderr = lambda: open(os.path.join(tmp, "stderr"), errors="replace").read() if not args.qemu else ""
        t0 = time.monotonic()
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
        p.logfile_read = tail
        try:
            expect(p, "Kernel command line: " + re.escape(APPEND) + r"\r*\n", LIMITS["prompt"], "boot")
            expect(p, PROMPT, LIMITS["prompt"], "boot")
            times["prompt"] = time.monotonic() - t0
            t = time.monotonic()
            info = run_cmd(p, "cat /proc/cpuinfo", LIMITS["command"])
            n = len(re.findall(r"^processor\s*:", info, re.M))
            if n != args.cpus:
                raise Fail(f"/proc/cpuinfo lists {n} processors, expected {args.cpus}")
            if not re.search(r"^Features\s*:.*\bfp\b", info, re.M):
                raise Fail("/proc/cpuinfo has no Features line")
            arch = run_cmd(p, "uname -m", LIMITS["command"]).strip()
            if arch != "aarch64":
                raise Fail(f"uname -m printed {arch!r}")
            times["commands"] = time.monotonic() - t
            t = time.monotonic()
            p.sendline("poweroff -f")
            expect(p, pexpect.EOF, LIMITS["poweroff"], "poweroff")
            p.close()
            times["poweroff"] = time.monotonic() - t
            status = p.exitstatus if p.exitstatus is not None else 128 + (p.signalstatus or 0)
            if status != 0:
                raise Fail(f"exit status {status} after poweroff, expected 0")
            if not args.qemu and "hengevm: stopped: guest shutdown" not in stderr():
                raise Fail("no 'hengevm: stopped: guest shutdown' line on stderr")
        except Fail:
            if p.isalive():
                p.terminate(force=True)
                p.close()
            tail.write("\n")
            print(f"--- last console lines ---\n{tail.text()}\n--- hengevm stderr (end) ---\n{stderr()[-4000:]}",
                  file=sys.stderr)
            raise


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--direct", action="store_true", help="direct kernel boot to the initramfs")
    ap.add_argument("--qemu", action="store_true", help="run the checks on QEMU instead of hengevm")
    ap.add_argument("--henge-dtb", action="store_true", help="with --qemu: boot QEMU with hengevm --dump-dtb's tree")
    ap.add_argument("--cpus", type=int, default=1)
    ap.add_argument("--ram", type=int, default=2048, help="MB")
    ap.add_argument("--phone", action="store_true", help="pass --phone to hengevm")
    ap.add_argument("--log", type=int, default=1, help="hengevm --log level")
    ap.add_argument("--runs", type=int, default=1, help="boot this many times; all must pass")
    ap.add_argument("--linux-dir", help="directory with Image and initrd.img")
    ap.add_argument("--hengevm", default=os.path.join(ROOT, "build", "hengevm"))
    args = ap.parse_args()
    if not args.direct:
        ap.error("only --direct exists so far")
    if args.henge_dtb and not args.qemu:
        ap.error("--henge-dtb needs --qemu")
    worst = {}
    for i in range(args.runs):
        times = {}
        try:
            direct(args, times)
        except Fail as e:
            print(f"smoke: run {i + 1}: FAIL: {e}", file=sys.stderr)
            sys.exit(1)
        print("smoke: run %d: pass (%s)" % (i + 1, ", ".join(f"{k} {v:.1f} s" for k, v in times.items())))
        for k, v in times.items():
            worst[k] = max(worst.get(k, 0), v)
    if args.runs > 1:
        print("smoke: slowest: " + ", ".join(f"{k} {v:.1f} s" for k, v in worst.items()))


if __name__ == "__main__":
    main()
