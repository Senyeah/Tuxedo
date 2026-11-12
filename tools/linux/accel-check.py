#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect", "pillow"]
# ///
"""A8: the desktop image with `hengevm --gpu-accel` (make test-linux-accel).

Boots a clone of debian-desktop.img by direct kernel boot, with the virgl renderer behind the virtio GPU. Checks, over the
serial console: the session log says renderer=gles2, eglinfo names virgl and an OpenGL ES version of at least 3.0, a ten
second glmark2 scene scores at least three times the saved software score, and dmesg has no virtio_gpu or DRM error. The
--screenshot PNG must show the idle desktop (a large lit area: the foot window), both before glmark2 and a few seconds
after it ends. The desktop path is timed too: foot printing 3000000 lines under labwc (median of three runs, window startup
included) must take no more than 1.25 times the saved pixman time, as the plan's rule that virgl is no slower than pixman.
The guest then powers off with status 0. glmark2's frame time is 1000/score for one scene, so it is not a second check.

--save-baseline boots without --gpu-accel (labwc on pixman, glmark2 on llvmpipe), runs the same scene and writes the score
to tools/linux/accel-baseline.json. The shared image never changes: the guest runs on an APFS clone.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = os.path.join(ROOT, "tools", "linux", "accel-baseline.json")
MARK = "HENGE_RC_"
SHELL = r"henge@henge:[^\n]*\$ "
WAYLAND = "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
SCENE = "build:duration=10.0"
SIZE = "1280x720"
TERM_CMD = "foot -e sh -c 'seq 1 3000000'"
TERM_RUNS = 3


class Fail(Exception):
    pass


def linux_dir():
    if os.environ.get("HENGE_LINUX_OUT"):
        return os.environ["HENGE_LINUX_OUT"]
    common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


def sh(p, cmd, limit=60):
    p.sendline(f"{cmd}; echo {MARK}$?")
    try:
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    except pexpect.TIMEOUT:
        raise Fail(f"{cmd!r}: no answer within {limit} s")
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    out = "\n".join(l for l in out.splitlines() if not l.startswith("[virgl"))  # virglrenderer's own log lines
    return re.sub(r"^henge@henge:[^\n$]*\$ ", "", out), int(p.match.group(1))


DESKTOP_LIT = 0.2  # the foot window alone lights about 0.4; fbcon text only about 0.012


def lit_fraction(path):
    from PIL import Image
    im = Image.open(path).convert("L")
    return sum(im.histogram()[25:]) / (im.width * im.height)


def term_ms(p):
    runs = []
    for _ in range(TERM_RUNS):
        out, rc = sh(p, f"{WAYLAND}; s=$(date +%s%N); {TERM_CMD}; e=$(date +%s%N); echo T=$(( (e-s)/1000000 ))", 180)
        m = re.search(r"T=(\d+)", out)
        if rc or not m:
            raise Fail(f"the terminal run gave no time: {out.strip()}")
        runs.append(int(m.group(1)))
    return statistics.median(runs), runs


def load_note():
    return f"host load average {os.getloadavg()[0]:.1f} on {os.cpu_count()} CPUs"


def desktop_shot(shot, keep, what, wait=6.0):
    # the shot is rewritten every HV_SHOT_SECS: wait for a file newer than this call
    start = time.time()
    deadline = start + wait + 15
    while time.time() < deadline:
        if os.path.exists(shot) and os.path.getmtime(shot) >= start + wait:
            break
        time.sleep(0.5)
    else:
        raise Fail(f"no fresh screenshot ({what})")
    lit = lit_fraction(shot)
    if keep:
        subprocess.run(["/bin/cp", shot, keep + "." + what.replace(" ", "-") + ".png"])
    if lit < DESKTOP_LIT:
        raise Fail(f"the screenshot {what} is not the desktop ({lit:.4f} of its pixels are lit, need {DESKTOP_LIT})")
    print(f"ok   screenshot {what} shows the desktop ({lit:.3f} of its pixels are lit)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hengevm", default=os.path.join(ROOT, "build", "hengevm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--save-baseline", action="store_true", help="measure the software path and save its score")
    ap.add_argument("--factor", type=float, default=3.0, help="the least accelerated score over the saved one")
    ap.add_argument("--term-slack", type=float, default=1.25, help="the most accelerated terminal time over the saved one")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--keep-shot", help="copy the screenshots here (suffixed)")
    args = ap.parse_args()
    d = args.linux_dir or linux_dir()
    image = os.path.join(d, "debian-desktop.img")
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    kernel, initrd = os.path.join(d, "Image"), os.path.join(d, "initrd.img")
    for f in (args.hengevm, image, kernel, initrd):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    accel = not args.save_baseline
    if accel:
        if not os.path.exists(BASELINE):
            raise Fail(f"no {BASELINE}: run with --save-baseline first")
        base = json.load(open(BASELINE))
    with tempfile.TemporaryDirectory(prefix="accel-", dir=args.work_dir) as tmp:
        clone, shot = os.path.join(tmp, "disk.img"), os.path.join(tmp, "shot.png")
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        argv = [args.hengevm, "--board", "virt", "--kernel", kernel, "--initrd", initrd, "--append",
                f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", clone, "--ram", "3072", "--cpus", str(args.cpus),
                "--display", SIZE, "--screenshot", shot]
        if accel:
            argv.append("--gpu-accel")
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                          env=dict(os.environ, HV_SHOT_SECS="1"))
        try:
            p.expect(r"\(automatic login\)", timeout=300)
            p.expect(SHELL, timeout=60)
            sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
            time.sleep(10)  # labwc and foot settle
            run(p, args, accel, shot, tmp, base if accel else None)
        except pexpect.TIMEOUT:
            raise Fail("timeout waiting for the guest; tail:\n" + (p.before or "")[-1500:])
        except pexpect.EOF:
            raise Fail("hengevm ended early; tail:\n" + (p.before or "")[-1500:])
        finally:
            if p.isalive():
                p.sendline("sudo poweroff")
                try:
                    p.expect(pexpect.EOF, timeout=60)
                except pexpect.TIMEOUT:
                    p.terminate(force=True)
            p.close()
        if p.exitstatus != 0:
            raise Fail(f"hengevm exit status {p.exitstatus}, expected 0 after poweroff")
        print("ok   power off: exit status 0")


def run(p, args, accel, shot, tmp, base):
    out, _ = sh(p, "cat /run/user/1000/henge-session.log")
    m = re.search(r"renderer=(\w+)", out)
    want = "gles2" if accel else "pixman"
    if not m or m.group(1) != want:
        raise Fail(f"session log says {m.group(1) if m else 'nothing'}, expected renderer={want}; log: {out.strip()}")
    print(f"ok   henge-session: renderer={want}")
    out, _ = sh(p, "eglinfo -B -p gbm 2>/dev/null | grep -E 'OpenGL ES profile (renderer|version)'")
    rend = re.search(r"ES profile renderer: (.*)", out)
    ver = re.search(r"OpenGL ES (\d+)\.(\d+)", out)
    if not rend or not ver:
        raise Fail(f"eglinfo gave no ES profile: {out.strip()}")
    print(f"     GL_RENDERER: {rend.group(1).strip()}; OpenGL ES {ver.group(1)}.{ver.group(2)}")
    if accel:
        if "virgl" not in rend.group(1).lower():
            raise Fail(f"eglinfo's renderer does not name virgl: {rend.group(1)}")
        if (int(ver.group(1)), int(ver.group(2))) < (3, 0):
            raise Fail(f"the guest gets OpenGL ES {ver.group(1)}.{ver.group(2)}, expected at least 3.0")
        print("ok   eglinfo names virgl with OpenGL ES >= 3.0")
    desktop_shot(shot, args.keep_shot, "before glmark2")
    out, rc = sh(p, f"{WAYLAND}; glmark2-es2-wayland -s {SIZE} -b {SCENE} 2>&1 | grep -E 'FPS|Score|Error|error'", 180)
    sc = re.search(r"glmark2 Score: (\d+)", out)
    if not sc:
        raise Fail(f"glmark2 gave no score: {out.strip()}")
    score = int(sc.group(1))
    ft = re.search(r"FrameTime: ([\d.]+) ms", out)
    print(f"     glmark2 {SCENE} at {SIZE}: score {score}" + (f", frame time {ft.group(1)} ms" if ft else "") + f" ({load_note()})")
    tms, truns = term_ms(p)
    print(f"     terminal ({TERM_CMD}): median {tms:g} ms of {truns}")
    if not accel:
        json.dump({"scene": SCENE, "size": SIZE, "software_score": score, "frame_time_ms": float(ft.group(1)) if ft else None,
                   "terminal_cmd": TERM_CMD, "terminal_ms": tms,
                   "measured": time.strftime("%d/%m/%Y"), "renderer": rend.group(1).strip()}, open(BASELINE, "w"), indent=2)
        open(BASELINE, "a").write("\n")
        print(f"ok   saved the software score {score} to {BASELINE}")
    else:
        need = args.factor * base["software_score"]
        if score < need:
            raise Fail(f"glmark2 scored {score}, under {args.factor:g} times the saved software score {base['software_score']} ({need:g}); {load_note()}")
        print(f"ok   glmark2 {score} >= {args.factor:g} x {base['software_score']} (software)")
        if not base.get("terminal_ms"):
            raise Fail("the baseline has no terminal time: run with --save-baseline")
        limit = base["terminal_ms"] * args.term_slack
        if tms > limit:
            raise Fail(f"terminal run took {tms:g} ms, over {limit:g} ms ({args.term_slack:g} x the software {base['terminal_ms']} ms); {load_note()}")
        print(f"ok   terminal {tms:g} ms <= {limit:g} ms (software {base['terminal_ms']} ms x {args.term_slack:g})")
    out, _ = sh(p, "sudo dmesg | grep -i -E 'virtio_gpu.*(error|fail|timed? ?out)|\\[drm.*(error|fail)|\\*ERROR\\*'")
    if out.strip():
        raise Fail("the guest logged virtio_gpu or DRM errors:\n" + out.strip())
    print("ok   dmesg has no virtio_gpu or DRM error")
    desktop_shot(shot, args.keep_shot, "after glmark2")

if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
