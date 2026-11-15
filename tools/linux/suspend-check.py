#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""E15 check: the guest does not see a suspended tuxvm.

The iOS app pauses the machine (hv_vm_pause) when its scene goes to the background, and iOS then freezes
the process while the host counter keeps running. This check does the same on the Mac. It boots a clone
of --image through U-Boot at --cpus CPUs, starts a sampler in the guest that logs its boot-time clock and
its wall clock twice a second, and then, for each length in --seconds:

  odd runs:  Ctrl-A s (pause), 10 s of host CPU measured while paused, SIGSTOP for the rest, SIGCONT, Ctrl-A s;
  even runs: SIGTSTP (tuxvm pauses, then stops itself) and SIGCONT (it continues and resumes).

After each run the guest must show no RCU stall or other kernel warning, its boot-time clock must have
advanced by the host's time less the pause (within --slack s) with no step over 2 s between samples, and
its wall clock may step only forward and only by about the pause: the step systemd-timesyncd makes.
The paused tuxvm must use under --max-cpu percent of one core. --no-pause sends only SIGSTOP and SIGCONT
(the old behaviour): with --expect-stall the check passes only if the guest reports the stall.
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHELL = r"henge@henge:\S*\$ "
MARK = "TUX_RC_"
KERNEL_BAD = (r"WARNING:|BUG:|Oops|Call trace:|soft lockup|hard LOCKUP|rcu: INFO|detected stall|"
              r"blocked for more than|watchdog|clocksource|Unable to handle|Internal error")
SAMPLES = "/tmp/tux-clock"


class Fail(Exception):
    pass


def linux_dir():
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
    try:
        common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
        return os.path.join(os.path.dirname(common), "build", "linux")
    except (OSError, subprocess.CalledProcessError):
        return os.path.join(ROOT, "build", "linux")


def sh(p, cmd, limit=60):
    p.sendline(f"{cmd}; echo {MARK}$?")
    try:
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    except pexpect.TIMEOUT:
        raise Fail(f"{cmd!r}: no answer within {limit} s")
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    out = re.sub(r"^henge@henge:[^\n$]*\$ ", "", out)
    return out.strip(), int(p.match.group(1))


def need(p, cmd, ok, what, limit=60):
    out, rc = sh(p, cmd, limit)
    if rc != 0 or not ok(out):
        raise Fail(f"{what}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
    return out


def cpu_seconds(pid):
    """User plus system time of pid so far, from ps (10 ms steps)."""
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    parts = [float(x) for x in t.replace("-", ":").split(":")]
    s = 0.0
    for x in parts:
        s = s * 60 + x
    return s


def clocks(p):
    """The guest's boot-time clock and wall clock, and the host's monotonic and wall clocks at the answer."""
    out = need(p, f"echo CLK $(cut -d' ' -f1 /proc/uptime) $(date +%s.%N)", lambda o: "CLK " in o, "clocks")
    host_mono, host_wall = time.monotonic(), time.time()
    m = re.search(r"CLK ([\d.]+) ([\d.]+)", out)
    return float(m.group(1)), float(m.group(2)), host_mono, host_wall


def samples(p):
    """The sampler's lines since it started: (boot-time clock, wall clock)."""
    out = need(p, f"cat {SAMPLES}", lambda o: True, "sampler log")
    rows = []
    for line in out.split("\n"):
        f = line.split()
        if len(f) == 2:
            try:
                rows.append((float(f[0]), float(f[1])))
            except ValueError:
                pass
    return rows


def main():
    d = linux_dir()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--image", default=os.path.join(d, "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(d, "u-boot.bin"))
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--seconds", default="30,120", help="pause lengths, comma separated")
    ap.add_argument("--slack", type=float, default=2.0, help="seconds the boot-time clock may be off")
    ap.add_argument("--max-cpu", type=float, default=1.0, help="percent of one core a paused tuxvm may use")
    ap.add_argument("--settle", type=float, default=15.0, help="seconds to watch the guest after a resume")
    ap.add_argument("--sync-wait", type=float, default=0, help="seconds to wait at the end for timesyncd's step")
    ap.add_argument("--no-pause", action="store_true", help="SIGSTOP and SIGCONT only (no hv_vm_pause)")
    ap.add_argument("--expect-stall", action="store_true", help="with --no-pause: pass only if the guest stalls")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()
    lengths = [float(x) for x in args.seconds.split(",") if x]

    tmp = tempfile.mkdtemp(prefix="suspend-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    p = None
    stalls = 0
    try:
        subprocess.run(["/bin/cp", "-c", args.image, disk], check=True)
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', disk + ".stderr", args.tuxvm, "--firmware", args.firmware, "--ram", "2048", "--cpus", str(args.cpus), "--disk", disk]
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
        p.expect(r"\(automatic login\)", timeout=180)
        p.expect(SHELL, timeout=60)
        p.sendline(f"stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
        p.expect(MARK + r"42\r*\n", timeout=60)
        need(p, "systemctl is-system-running --wait", lambda o: o in ("running", "degraded"), "system state", 180)
        need(p, "nproc", lambda o: o == str(args.cpus), "CPU count")
        # Synchronised first, so a later step is the one the pause caused.
        sync = need(p, "for i in $(seq 60); do timedatectl show -p NTPSynchronized --value | grep -qx yes && break; "
                    "sleep 1; done; timedatectl show -p NTPSynchronized --value", lambda o: True, "timesyncd", 90)
        print(f"  {args.cpus} CPUs, timesyncd synchronised: {sync}")
        need(p, "sudo dmesg -C", lambda o: True, "clear dmesg")
        need(p, f"(while :; do echo $(cut -d' ' -f1 /proc/uptime) $(date +%s.%N); sleep 0.5; done) > {SAMPLES} "
             "2>/dev/null & disown", lambda o: True, "sampler")
        for run, length in enumerate(lengths):
            time.sleep(3)
            b_up, b_wall, h0, h0_wall = clocks(p)
            skew0 = b_wall - h0_wall
            nrows = len(samples(p))
            cpu_pct = None
            if args.no_pause:
                t_stop = time.monotonic()
                os.kill(p.pid, signal.SIGSTOP)
                time.sleep(length)
                os.kill(p.pid, signal.SIGCONT)
                paused = time.monotonic() - t_stop
                how = "SIGSTOP"
            elif run % 2 == 0:
                t_stop = time.monotonic()
                p.send("\x01s")
                time.sleep(2)  # the pause is done long before this
                c0, w0 = cpu_seconds(p.pid), time.monotonic()
                time.sleep(min(10.0, max(0.0, length - 2)))
                c1, w1 = cpu_seconds(p.pid), time.monotonic()
                cpu_pct = 100 * (c1 - c0) / (w1 - w0)
                os.kill(p.pid, signal.SIGSTOP)
                time.sleep(max(0.0, length - (time.monotonic() - t_stop)))
                os.kill(p.pid, signal.SIGCONT)
                p.send("\x01s")
                paused = time.monotonic() - t_stop
                how = "Ctrl-A s + SIGSTOP"
            else:
                t_stop = time.monotonic()
                os.kill(p.pid, signal.SIGTSTP)
                time.sleep(length)
                os.kill(p.pid, signal.SIGCONT)
                paused = time.monotonic() - t_stop
                how = "SIGTSTP"
            time.sleep(args.settle)
            a_up, a_wall, h1, h1_wall = clocks(p)
            host = h1 - h0
            guest = a_up - b_up
            want = host if args.no_pause else host - paused
            rows = samples(p)[max(0, nrows - 1):]
            steps = [(b[0] - a[0], b[1] - a[1]) for a, b in zip(rows, rows[1:])]
            up_step = max((s[0] for s in steps), default=0)
            wall_steps = [s[1] - s[0] for s in steps if abs(s[1] - s[0]) > 0.5]
            skew1 = a_wall - h1_wall
            dmesg = need(p, "sudo dmesg -c", lambda o: True, "dmesg")
            bad = [l for l in dmesg.split("\n") if re.search(KERNEL_BAD, l)]
            stalled = any(re.search(r"rcu: INFO|detected stall", l) for l in bad)
            stalls += stalled
            print(f"  {how} {length:.0f} s: host {host:.1f} s, paused {paused:.1f} s, guest boot-time clock "
                  f"{guest:.1f} s (want {want:.1f}), largest step {up_step:.2f} s; wall clock off "
                  f"{skew0:+.2f} s before, {skew1:+.2f} s after, steps {[round(s, 2) for s in wall_steps]}"
                  + (f"; paused tuxvm {cpu_pct:.2f}% of a core" if cpu_pct is not None else ""))
            for l in bad[:12]:
                print(f"    dmesg: {l}")
            if args.no_pause:
                continue
            if bad:
                raise Fail(f"kernel warnings after the {length:.0f} s pause")
            if abs(guest - want) > args.slack:
                raise Fail(f"the guest's clock moved {guest:.1f} s, not {want:.1f} s")
            if up_step > 2:
                raise Fail(f"the guest's boot-time clock stepped {up_step:.2f} s")
            lag = paused - skew0  # what timesyncd has to put back, this pause and any before
            for s in wall_steps:  # only timesyncd's correction: forward, and to the host's time
                if s < 0 or abs(s - lag) > max(args.slack, 0.05 * lag):
                    raise Fail(f"the guest's wall clock stepped {s:+.2f} s with {lag:.2f} s to put back")
                lag -= s
            if cpu_pct is not None and cpu_pct > args.max_cpu:
                raise Fail(f"the paused tuxvm used {cpu_pct:.2f}% of a core")
        if args.no_pause and args.expect_stall and not stalls:
            raise Fail("no RCU stall without the pause: the reproduction failed")
        if args.sync_wait and not args.no_pause:  # how long the guest's wall clock stays behind
            t = time.monotonic()
            while True:
                _, wall, _, host_wall = clocks(p)
                if abs(wall - host_wall) < 1 or time.monotonic() - t > args.sync_wait:
                    break
                time.sleep(2)
            print(f"  wall clock off {wall - host_wall:+.2f} s after waiting {time.monotonic() - t:.0f} s for timesyncd")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60)
        p.close()
        if p.exitstatus != 0:
            raise Fail(f"tuxvm exit status {p.exitstatus} after poweroff")
        print("suspend-check: PASS" + (f" ({stalls} stalls without the pause, as expected)" if args.no_pause else ""))
        return 0
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"suspend-check: FAIL: {e}", file=sys.stderr)
        try:
            print("console tail:\n" + (p.before or "")[-3000:], file=sys.stderr)
            print("tuxvm stderr:\n" + open(disk + ".stderr", errors="replace").read()[-3000:], file=sys.stderr)
        except Exception:
            pass
        return 1
    finally:
        if p is not None and p.isalive():
            p.terminate(force=True)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
