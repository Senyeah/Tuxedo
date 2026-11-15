#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""A10: how long a GL program takes to start on `tuxvm --gpu-accel`, and what the shader cache does about it.

For each tuxvm process it boots the desktop image and starts glmark2 twice in the same boot, then restarts the guest
(same process) and starts it once more. A start is read from the Wayland trace (WAYLAND_DEBUG): ms from the first message
to the first buffer attached, and to the first and the tenth frame callback after that. The terrain scene has a big shader
whose compile holds the renderer's queue for about 0.8 s, so its tenth frame comes late; the build scene has none.
With --processes 2 the second process shows what the disk cache saves: its first start finds the first process's shaders.
--check (make test-linux-shader-cache) fails unless the cache is written, read by the second process, and that start is
--factor times faster. A gap sampler runs in the guest during the first start and reports the longest pause of a 5 ms
sleep loop: if the renderer's compile held the device lock, the guest's timer and its input and sound devices would
pause with it. The guest's own shader cache is off (MESA_SHADER_CACHE_DISABLE), so only the host's cache counts.
The harness keeps reading the console: tuxvm's log lines share the pty, and a full pty blocks the renderer thread.
The shared image never changes: each guest runs on an APFS clone.
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
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MARK = "TUX_RC_"
ENVSET = "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 MESA_SHADER_CACHE_DISABLE=true"
GAP = """import os, sys, time
mx = n = over = 0
t = time.monotonic()
while not os.path.exists('/tmp/gap.stop'):
    time.sleep(0.005)
    now = time.monotonic()
    d = (now - t) * 1000 - 5
    t = now
    n += 1
    mx = max(mx, d)
    over += d > 50
print('GAP max=%.0f over50=%d samples=%d' % (mx, over, n))
"""


class Fail(Exception):
    pass


def linux_dir():
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
    common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


def sh(p, cmd, limit=60):
    p.sendline(f"{cmd}; echo {MARK}$?")
    try:
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    except pexpect.TIMEOUT:
        raise Fail(f"{cmd[:80]!r}: no answer within {limit} s")
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    out = "\n".join(l for l in out.splitlines() if not l.startswith("[virgl"))
    return re.sub(gu.prompt_prefix(), "", out), int(p.match.group(1))


def settle(p, secs):
    # keeps reading: tuxvm's stderr shares this pty, and a full pty blocks the renderer thread in a log write
    p.expect(pexpect.TIMEOUT, timeout=secs)


def put_text(p, text, remote):
    data = base64.b64encode(text.encode()).decode()
    sh(p, f": > {remote}.b64")
    for i in range(0, len(data), 600):
        sh(p, f"printf %s '{data[i:i + 600]}' >> {remote}.b64")
    sh(p, f"base64 -d {remote}.b64 > {remote}")


def start_ms(p, scene, secs, gap):
    """One glmark2 start from the Wayland trace: ms from the first message to the first buffer attached, and to the
    first and the tenth frame callback after it (the compositor presented those frames, after the host's compile).
    Also the guest's longest pause while it ran."""
    if gap:
        sh(p, "rm -f /tmp/gap.stop; (python3 /tmp/gap.py > /tmp/gap.out 2>&1 &) ; sleep 0.3")
    out, rc = sh(p, f"{ENVSET}; WAYLAND_DEBUG=client glmark2-es2-wayland -s 1280x720 -b {scene}:duration={secs} 2>&1 | "
                    f"grep -E 'FPS|Error|wl_surface#[0-9]+[.](attach|commit)|wl_callback#[0-9]+[.]done|get_registry' | cut -c1-110", 300)
    if "FPS" not in out:
        raise Fail(f"glmark2 did not finish: {out[-400:].strip()}")
    t0 = attach = None
    dones = []
    for line in out.splitlines():
        m = re.match(r"\[\s*(\d+\.\d+)\]\s+(.*)", line)
        if not m:
            continue
        t, ev = float(m.group(1)), m.group(2)
        if t0 is None:
            t0 = t
        if attach is None and re.search(r"[.]attach\(wl_buffer#", ev):
            attach = t
        elif attach is not None and re.search(r"wl_callback#\d+[.]done", ev):
            dones.append(t)
    if attach is None or len(dones) < 10:
        raise Fail(f"no frames in the Wayland trace of {scene}: {out[-400:].strip()}")
    pause = None
    if gap:
        sh(p, "touch /tmp/gap.stop; sleep 0.5")
        g, _ = sh(p, "cat /tmp/gap.out")
        mm = re.search(r"GAP max=(\d+) over50=(\d+)", g)
        pause = (int(mm.group(1)), int(mm.group(2))) if mm else None
    return (round(attach - t0), round(dones[0] - t0), round(dones[9] - t0)), pause


def boot_process(args, d, tmp, cache, n):
    image = os.path.join(d, "debian-desktop.img")
    gu.use(image)
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    clone = os.path.join(tmp, f"disk-{n}.img")
    r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
    if r.returncode:
        raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
    argv = [args.tuxvm, "--kernel", os.path.join(d, "Image"), "--initrd", os.path.join(d, "initrd.img"),
            "--append", f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", clone, "--ram", "3072",
            "--cpus", str(args.cpus), "--display", "1280x720", "--gpu-accel"]
    env = dict(os.environ, HV_VIRGL_STATS="1", HV_GL_CACHE=cache)
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200), env=env)
    logf = open(os.path.join(tmp, f"console-{n}.log"), "w")
    p.logfile_read = logf
    res = {"start 1": {}, "start 2": {}, "after restart": {}}
    try:
        gu.login(p, 300, 60)
        sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
        put_text(p, GAP, "/tmp/gap.py")
        settle(p, 10)
        for scene in args.scenes:
            res["start 1"][scene] = start_ms(p, scene, args.duration, True)
        for scene in args.scenes:
            res["start 2"][scene] = start_ms(p, scene, args.duration, False)
        p.sendline("sudo reboot")
        gu.login(p, 300, 60)
        settle(p, 10)
        for scene in args.scenes:
            res["after restart"][scene] = start_ms(p, scene, args.duration, False)
    except pexpect.TIMEOUT:
        raise Fail("timeout waiting for the guest; tail:\n" + (p.before or "")[-1500:])
    except pexpect.EOF:
        raise Fail("tuxvm ended early; tail:\n" + (p.before or "")[-1500:])
    finally:
        if p.isalive():
            p.sendline("sudo poweroff")
            try:
                p.expect(pexpect.EOF, timeout=60)
            except pexpect.TIMEOUT:
                p.terminate(force=True)
        p.close()
        logf.close()
    return res, re.findall(r"virgl: (?:\d+ requests|request 0x)[^\n\r]*", open(logf.name).read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "accel", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--cache", default="tmp", help="'off', 'tmp' (a fresh directory), or a directory to keep")
    ap.add_argument("--processes", type=int, default=2)
    ap.add_argument("--scenes", default="build,terrain")
    ap.add_argument("--duration", type=float, default=4.0)
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--check", action="store_true", help="fail unless the cache is written, read by the next process, and that start is --factor times faster")
    ap.add_argument("--factor", type=float, default=2.0)
    args = ap.parse_args()
    args.scenes = args.scenes.split(",")
    if args.check and (args.cache == "off" or args.processes < 2 or "terrain" not in args.scenes):
        raise Fail("--check needs the cache on, two processes and the terrain scene")
    d = args.linux_dir or linux_dir()
    for f in (args.tuxvm, os.path.join(d, "debian-desktop.img"), os.path.join(d, "debian-desktop.partuuid"),
              os.path.join(d, "Image"), os.path.join(d, "initrd.img")):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    runs, cache_stats = [], []
    with tempfile.TemporaryDirectory(prefix="stall-") as tmp:
        cache = "off" if args.cache == "off" else (os.path.join(tmp, "cache") if args.cache == "tmp" else args.cache)
        print(f"cache: {cache}; load {os.getloadavg()[0]:.1f} on {os.cpu_count()} CPUs")
        for n in range(1, args.processes + 1):
            res, stats = boot_process(args, d, tmp, cache, n)
            runs.append(res)
            for label in ("start 1", "start 2", "after restart"):
                for scene, (ms, pause) in res[label].items():
                    extra = f", guest pause max {pause[0]} ms ({pause[1]} over 50 ms)" if pause else ""
                    print(f"process {n} {label:14s} {scene:8s} attach {ms[0]:5d} ms, first frame {ms[1]:5d} ms, tenth {ms[2]:5d} ms{extra}")
            for line in stats:
                print(f"process {n} {line}")
            m = next((re.search(r"cache (\d+) hits, (\d+) misses, (\d+) stored", l) for l in stats if "shader cache" in l), None)
            cache_stats.append(tuple(int(x) for x in m.groups()) if m else None)
        files = 0
        if args.cache != "off" and os.path.isdir(cache):
            for sub in os.listdir(cache):
                files += len([f for f in os.listdir(os.path.join(cache, sub)) if not f.endswith(".tmp")])
            sizes = [os.path.getsize(os.path.join(cache, sub, f)) for sub in os.listdir(cache) for f in os.listdir(os.path.join(cache, sub))]
            print(f"cache files: {files}, {sum(sizes) // 1024} KB")
    if not args.check:
        return
    bad = []
    if not cache_stats[0] or cache_stats[0][2] < 1 or not files:
        bad.append(f"the first process stored nothing in the shader cache ({cache_stats[0]}, {files} files)")
    if not cache_stats[1] or cache_stats[1][0] < 1:
        bad.append(f"the second process read nothing from the shader cache ({cache_stats[1]})")
    cold, warm = runs[0]["start 1"]["terrain"][0][2], runs[1]["start 1"]["terrain"][0][2]
    print(f"terrain tenth frame, first start of a process: {cold} ms with an empty cache, {warm} ms with the cache of the first process ({cold / max(warm, 1):.1f} times)")
    if cold < args.factor * warm:
        bad.append(f"the cached start is {cold / max(warm, 1):.1f} times faster, need {args.factor:g} (host load {os.getloadavg()[0]:.1f})")
    if bad:
        raise Fail("; ".join(bad))
    print("ok   shader cache written, read back, and the cached start is at least %g times faster" % args.factor)


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
