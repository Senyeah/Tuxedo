#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect", "pillow"]
# ///
"""A8: the desktop image with and without `tuxvm --gpu-accel` (make test-linux-accel).

Boots a clone of debian-desktop.img twice by direct kernel boot, back to back: first with the virgl renderer behind the
virtio GPU (tux-session picks gles2), then without it (pixman, llvmpipe). Both sets of numbers come from the same run at
the same host load, so no saved score decides the result. Each boot checks, over the serial console: the session
log names the expected renderer, eglinfo names virgl and OpenGL ES >= 3.0 (accelerated boot), dmesg has no virtio_gpu or
DRM error, the --screenshot PNG shows the idle desktop before and after the load, and the guest powers off with status 0.
Each boot measures:
  - frame time: tools/linux/wlprobe.py, a Wayland client that redraws a full 1280x720 shm window on every frame callback
    and times the callback gaps (labwc's real per-frame time). Rule: virgl median <= 4 ms and p99 <= 16.7 ms (one 60 Hz
    frame). The pixman numbers and the virgl/pixman ratio are printed only: a shm client costs virgl one extra upload,
    while GL clients run 5 to 7 times faster.
  - glmark2: the virgl score is at least 3 x the llvmpipe score. The gate runs a short scene set; --full runs the whole
    default benchmark at 1280x720 and prints every scene's FPS and frame time.
  - the foot terminal time (seq 1 3000000), printed only: it measures pty throughput, not frame time.
  - tuxvm's CPU use (cputime over wall time, from ps) per phase, and the host load average.
The shared image never changes: each guest runs on an APFS clone.
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
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROBE = os.path.join(ROOT, "tools", "linux", "wlprobe.py")
MARK = "TUX_RC_"
WAYLAND = "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
SCENE = "build:duration=10.0"  # the gate's short scene set
SIZE = "1280x720"
PROBE_SECS = 10
TERM_CMD = "foot -e sh -c 'seq 1 3000000'"
TERM_RUNS = 3
DESKTOP_LIT = 0.2  # the foot window alone lights about 0.4; fbcon text only about 0.012


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
    out = "\n".join(l for l in out.splitlines() if not l.startswith("[virgl"))  # virglrenderer's own log lines
    return re.sub(gu.prompt_prefix(), "", out), int(p.match.group(1))


def lit_fraction(path):
    from PIL import Image
    im = Image.open(path).convert("L")
    return sum(im.histogram()[25:]) / (im.width * im.height)


def cpu_secs(pid):
    # ps cputime is [H:]M:SS.ss
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    secs = 0.0
    for part in out.split(":"):
        secs = secs * 60 + float(part)
    return secs


class Phase:
    """tuxvm's CPU use over one stretch of the run."""

    def __init__(self, pid, cpu_log, name):
        self.pid, self.cpu_log, self.name = pid, cpu_log, name

    def __enter__(self):
        self.c0, self.t0 = cpu_secs(self.pid), time.monotonic()

    def __exit__(self, *exc):
        c1, t1 = cpu_secs(self.pid), time.monotonic()
        if self.c0 is not None and c1 is not None and t1 > self.t0:
            self.cpu_log[self.name] = 100 * (c1 - self.c0) / (t1 - self.t0)


def load_note():
    return f"host load average {os.getloadavg()[0]:.1f} on {os.cpu_count()} CPUs"


def term_ms(p):
    runs = []
    for _ in range(TERM_RUNS):
        out, rc = sh(p, f"{WAYLAND}; s=$(date +%s%N); {TERM_CMD}; e=$(date +%s%N); echo T=$(( (e-s)/1000000 ))", 180)
        m = re.search(r"T=(\d+)", out)
        if rc or not m:
            raise Fail(f"the terminal run gave no time: {out.strip()}")
        runs.append(int(m.group(1)))
    return statistics.median(runs), runs


def desktop_shot(shot, keep, tag, what, wait=6.0):
    # the shot is rewritten every HV_SHOT_SECS: wait for a file newer than this call
    start = time.time()
    deadline = start + wait + 15
    while time.time() < deadline:
        if os.path.exists(shot) and os.path.getmtime(shot) >= start + wait:
            break
        time.sleep(0.5)
    else:
        raise Fail(f"no fresh screenshot ({tag}, {what})")
    lit = lit_fraction(shot)
    if keep:
        subprocess.run(["/bin/cp", shot, f"{keep}.{tag}.{what.replace(' ', '-')}.png"])
    if lit < DESKTOP_LIT:
        raise Fail(f"the screenshot {what} ({tag}) is not the desktop ({lit:.4f} of its pixels are lit, need {DESKTOP_LIT})")
    print(f"ok   [{tag}] screenshot {what} shows the desktop ({lit:.3f} of its pixels are lit)")


def upload(p, local, remote):
    import base64
    data = base64.b64encode(open(local, "rb").read()).decode()
    sh(p, f": > {remote}.b64")
    for i in range(0, len(data), 600):
        sh(p, f"printf %s '{data[i:i + 600]}' >> {remote}.b64")
    out, rc = sh(p, f"base64 -d {remote}.b64 > {remote}")
    if rc:
        raise Fail(f"upload of {local} failed: {out.strip()}")


def parse_glmark(out):
    sc = re.search(r"glmark2 Score: (\d+)", out)
    if not sc:
        raise Fail(f"glmark2 gave no score: {out.strip()}")
    scenes = []
    for m in re.finditer(r"^\[(\w+)\] ([^\n]*?): FPS: (\d+)(?: FrameTime: ([\d.]+) ms)?", out, re.M):
        scenes.append((f"{m.group(1)} {m.group(2)}".strip(), int(m.group(3)), float(m.group(4)) if m.group(4) else None))
    return int(sc.group(1)), scenes


def boot(args, accel, d, tmp):
    """One boot and every measurement. Returns the numbers."""
    tag = "virgl" if accel else "pixman"
    image = os.path.join(d, "debian-desktop.img")
    gu.use(image)
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    clone, shot = os.path.join(tmp, f"disk-{tag}.img"), os.path.join(tmp, f"shot-{tag}.png")
    r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
    if r.returncode:
        raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
    argv = [args.tuxvm, "--kernel", os.path.join(d, "Image"), "--initrd", os.path.join(d, "initrd.img"),
            "--append", f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", clone, "--ram", "3072",
            "--cpus", str(args.cpus), "--display", SIZE, "--screenshot", shot]
    if accel:
        argv.append("--gpu-accel")
    res = {"tag": tag, "cpu": {}, "load_start": os.getloadavg()[0]}
    print(f"--   [{tag}] booting ({load_note()})")
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                      env=dict(os.environ, HV_SHOT_SECS="1"))
    try:
        gu.login(p, 300, 60)
        sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
        time.sleep(10)  # labwc and foot settle
        measure(p, args, accel, tag, shot, res)
    except pexpect.TIMEOUT:
        raise Fail(f"[{tag}] timeout waiting for the guest; tail:\n" + (p.before or "")[-1500:])
    except pexpect.EOF:
        raise Fail(f"[{tag}] tuxvm ended early; tail:\n" + (p.before or "")[-1500:])
    finally:
        if p.isalive():
            p.sendline("sudo poweroff")
            try:
                p.expect(pexpect.EOF, timeout=60)
            except pexpect.TIMEOUT:
                p.terminate(force=True)
        p.close()
    if p.exitstatus != 0:
        raise Fail(f"[{tag}] tuxvm exit status {p.exitstatus}, expected 0 after poweroff")
    print(f"ok   [{tag}] power off: exit status 0")
    res["load_end"] = os.getloadavg()[0]
    return res


def measure(p, args, accel, tag, shot, res):
    pid, cpu = p.pid, res["cpu"]
    out, _ = sh(p, "cat /run/user/1000/tux-session.log")
    m = re.search(r"renderer=(\w+)", out)
    want = "gles2" if accel else "pixman"
    if not m or m.group(1) != want:
        raise Fail(f"[{tag}] session log says {m.group(1) if m else 'nothing'}, expected renderer={want}; log: {out.strip()}")
    print(f"ok   [{tag}] tux-session: renderer={want}")
    out, _ = sh(p, "eglinfo -B -p gbm 2>/dev/null | grep -E 'OpenGL ES profile (renderer|version)'")
    rend = re.search(r"ES profile renderer: (.*)", out)
    ver = re.search(r"OpenGL ES (\d+)\.(\d+)", out)
    if not rend or not ver:
        raise Fail(f"[{tag}] eglinfo gave no ES profile: {out.strip()}")
    res["gl_renderer"] = rend.group(1).strip()
    print(f"     [{tag}] GL_RENDERER: {res['gl_renderer']}; OpenGL ES {ver.group(1)}.{ver.group(2)}")
    if accel:
        if "virgl" not in rend.group(1).lower():
            raise Fail(f"eglinfo's renderer does not name virgl: {rend.group(1)}")
        if (int(ver.group(1)), int(ver.group(2))) < (3, 0):
            raise Fail(f"the guest gets OpenGL ES {ver.group(1)}.{ver.group(2)}, expected at least 3.0")
        print("ok   [virgl] eglinfo names virgl with OpenGL ES >= 3.0")
    desktop_shot(shot, args.keep_shot, tag, "before the load")

    upload(p, PROBE, "/tmp/wlprobe.py")
    with Phase(pid, cpu, "frame probe"):
        out, rc = sh(p, f"{WAYLAND}; python3 /tmp/wlprobe.py 1280 720 {PROBE_SECS} 2>&1 | tail -3", PROBE_SECS + 120)
    m = re.search(r"frames=(\d+) mean=([\d.]+)ms p50=([\d.]+) p95=[\d.]+ p99=([\d.]+)", out)
    if not m:
        raise Fail(f"[{tag}] the frame probe gave no result: {out.strip()}")
    res["frames"], res["frame_mean"], res["frame_p50"], res["frame_p99"] = int(m.group(1)), float(m.group(2)), float(m.group(3)), float(m.group(4))
    print(f"     [{tag}] frame time {SIZE}: median {res['frame_p50']:.2f} ms, p99 {res['frame_p99']:.2f} ms, mean {res['frame_mean']:.2f} ms over {res['frames']} frames ({load_note()})")

    cmd = f"-s {SIZE}" if args.full else f"-s {SIZE} -b {SCENE}"
    with Phase(pid, cpu, "glmark2"):
        out, rc = sh(p, f"{WAYLAND}; glmark2-es2-wayland {cmd} 2>&1 | grep -E 'FPS|Score|Error|error'", 1500 if args.full else 180)
    res["score"], res["scenes"] = parse_glmark(out)
    print(f"     [{tag}] glmark2 {'(full default run)' if args.full else SCENE} at {SIZE}: score {res['score']} ({load_note()})")
    if args.full:
        for name, fps, ft in res["scenes"]:
            print(f"       {name}: {fps} FPS" + (f", {ft:.3f} ms" if ft else ""))

    with Phase(pid, cpu, "terminal"):
        res["term_ms"], runs = term_ms(p)
    print(f"     [{tag}] terminal ({TERM_CMD}): median {res['term_ms']:g} ms of {runs} (printed only)")
    for name, pct in cpu.items():
        print(f"     [{tag}] tuxvm CPU during {name}: {pct:.0f}% of one core")

    out, _ = sh(p, "sudo dmesg | grep -i -E 'virtio_gpu.*(error|fail|timed? ?out)|\\[drm.*(error|fail)|\\*ERROR\\*'")
    if out.strip():
        raise Fail(f"[{tag}] the guest logged virtio_gpu or DRM errors:\n" + out.strip())
    print(f"ok   [{tag}] dmesg has no virtio_gpu or DRM error")
    desktop_shot(shot, args.keep_shot, tag, "after the load")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--work-dir", help="where the clones go (the image's APFS volume)")
    ap.add_argument("--factor", type=float, default=3.0, help="the least virgl glmark2 score over the llvmpipe score")
    ap.add_argument("--frame-median", type=float, default=4.0, help="the most virgl median frame time in ms")
    ap.add_argument("--frame-p99", type=float, default=16.7, help="the most virgl p99 frame time in ms")
    ap.add_argument("--full", action="store_true", help="glmark2's whole default benchmark instead of the short scene set")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--keep-shot", help="copy the screenshots here (suffixed)")
    args = ap.parse_args()
    d = args.linux_dir or linux_dir()
    for f in (args.tuxvm, os.path.join(d, "debian-desktop.img"), os.path.join(d, "debian-desktop.partuuid"),
              os.path.join(d, "Image"), os.path.join(d, "initrd.img"), PROBE):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    with tempfile.TemporaryDirectory(prefix="accel-", dir=args.work_dir) as tmp:
        v = boot(args, True, d, tmp)
        s = boot(args, False, d, tmp)
    print(f"     host load average at the start of each boot: virgl {v['load_start']:.1f}, pixman {s['load_start']:.1f}; at the end {v['load_end']:.1f}, {s['load_end']:.1f}")
    ratio = v["frame_p50"] / s["frame_p50"]
    need = args.factor * s["score"]
    print(f"     frame time median (information only): virgl {v['frame_p50']:.2f} ms, pixman {s['frame_p50']:.2f} ms, ratio {ratio:.2f}")
    print(f"     frame time p99: virgl {v['frame_p99']:.2f} ms, pixman {s['frame_p99']:.2f} ms")
    print(f"     glmark2 score: virgl {v['score']}, llvmpipe {s['score']} (ratio {v['score'] / max(1, s['score']):.1f}, need {args.factor:g})")
    bad = []
    if v["frame_p50"] > args.frame_median:
        bad.append(f"virgl median frame time {v['frame_p50']:.2f} ms is over {args.frame_median:g} ms")
    else:
        print(f"ok   virgl median frame time {v['frame_p50']:.2f} ms <= {args.frame_median:g} ms")
    if v["frame_p99"] > args.frame_p99:
        bad.append(f"virgl p99 frame time {v['frame_p99']:.2f} ms is over {args.frame_p99:g} ms")
    else:
        print(f"ok   virgl p99 frame time {v['frame_p99']:.2f} ms <= {args.frame_p99:g} ms")
    if v["score"] < need:
        bad.append(f"virgl glmark2 scored {v['score']}, under {args.factor:g} times the llvmpipe score {s['score']} ({need:g})")
    else:
        print(f"ok   glmark2 {v['score']} >= {args.factor:g} x {s['score']} (llvmpipe, same run)")
    if bad:
        raise Fail("; ".join(bad) + f"; {load_note()}")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
