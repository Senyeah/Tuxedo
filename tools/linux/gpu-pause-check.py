#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""A9c check: a paused accelerated machine sends no work to the renderer (make test-linux-gpu-pause).

The iOS app may not send Metal work from the background, so an accelerated machine always pauses whole there, even
while its guest plays sound. hv_vm_pause stops the CPUs, waits for the renderer to finish what it holds, then stops the
presenter. This check boots a clone of debian-desktop.img with --gpu-accel and runs glmark2 scenes in a loop. It then:
  1. pauses with Ctrl-A s, with SIGTSTP (tuxvm pauses and stops itself) and with Ctrl-A s again;
  2. starts aplay, so the guest plays sound, and enters the app's background with Ctrl-A b (hv_vm_set_background): the
     machine must pause although it plays sound;
  3. restarts the guest (sudo reboot): the machine is built again after those pauses, and glmark2 runs on it;
  4. pauses the new machine and powers it off while paused (SIGTERM twice): it must end at once, without the renderer
     missing its time limit (which would leave guest RAM behind).
tuxvm prints how many requests the renderer has run when the pause is done and just before the resume. The two
numbers must be equal and the state must be "held" in between; afterwards glmark2 must go on and dmesg must show no
virtio_gpu or DRM error and no stall. On the Mac tuxvm has no layer, so frames stay 0 and only the renderer half is
checked here; test_vgpu_metal covers the presenter. The shared image never changes: the guest runs on an APFS clone.
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
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MARK = "TUX_RC_"
WAYLAND = "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
BAD = r"virtio_gpu|drm.*error|\[drm|WARNING:|BUG:|Oops|rcu: INFO|detected stall|soft lockup"
LOG = "/tmp/gl.log"
LATE = r"did not finish|abandoned|still busy"


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
    return re.sub(gu.prompt_prefix(), "", out).strip(), int(p.match.group(1))


def scenes(p):
    out, _ = sh(p, f"grep -c 'FPS:' {LOG}")
    return int(out.split()[-1]) if out.split() else 0


def counts(errfile, when):
    """The last '(held|running) <when>: N frames, M renderer requests' line of tuxvm's stderr."""
    text = open(errfile, errors="replace").read()
    rows = re.findall(r"gpu (held|running) " + when + r": (\d+) frames, (\d+) renderer requests", text)
    if not rows:
        raise Fail(f"tuxvm printed no GPU counts {when}:\n{text[-1500:]}")
    state, frames, requests = rows[-1]
    return state, int(frames), int(requests)


def stderr_has(errfile, pattern):
    return re.search(pattern, open(errfile, errors="replace").read()) is not None


def wait_stderr(errfile, pattern, limit):
    end = time.time() + limit
    while time.time() < end:
        if stderr_has(errfile, pattern):
            return
        time.sleep(0.2)
    raise Fail(f"tuxvm did not print {pattern!r} in {limit} s")


def desktop_up(p, label):
    gu.login(p, 300, 60)
    sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
    time.sleep(10)  # labwc settles
    out, _ = sh(p, f"{WAYLAND}; eglinfo 2>/dev/null | grep -m1 'OpenGL ES profile renderer'")
    print(f"  {label}: guest renderer: {out}")
    if "virgl" not in out.lower():
        raise Fail("the desktop does not run on virgl: " + out)
    sh(p, "sudo dmesg -C")
    sh(p, f"{WAYLAND}; (while :; do glmark2-es2-wayland -b build:duration=2.0 -s 800x600; done) > {LOG} 2>&1 & disown")
    for _ in range(60):
        time.sleep(2)
        if scenes(p) >= 2:
            return
    raise Fail("glmark2 finished no scene in 2 minutes")


def progress(p, before, what):
    time.sleep(8)
    after = scenes(p)
    print(f"  glmark2 scenes: {before} before, {after} after the resume ({what})")
    if after <= before:
        raise Fail(f"glmark2 made no progress after the resume ({what})")


def held_between(errfile, at, bt, what):
    state, f0, r0 = counts(errfile, at)
    state1, f1, r1 = counts(errfile, bt)
    print(f"  {what}: gpu {state} at {f0} frames and {r0} requests after the pause; {state1} at {f1} and {r1} before the resume")
    if state != "held" or r1 != r0 or f1 != f0:
        raise Fail(f"the renderer or presenter worked while paused ({what}): {r0} -> {r1} requests, {f0} -> {f1} frames")


def main():
    d = linux_dir()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "accel", "tuxvm"), help="a GFX=1 build")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--seconds", type=float, default=10, help="length of each pause (the plan's step 5 says 60)")
    ap.add_argument("--slow-us", type=int, default=400,
                    help="HV_VIRGL_SLOW_US: each renderer request takes this much longer, so a queue is always waiting")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()

    image = os.path.join(d, "debian-desktop.img")

    gu.use(image)
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    tmp = tempfile.mkdtemp(prefix="gpu-pause-check-", dir=args.work_dir)
    disk, errfile = os.path.join(tmp, "disk.img"), os.path.join(tmp, "stderr")
    p = None
    try:
        subprocess.run(["/bin/cp", "-c", image, disk], check=True)
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', errfile, args.tuxvm, "--kernel",
                os.path.join(d, "Image"), "--initrd", os.path.join(d, "initrd.img"), "--append",
                f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", disk, "--ram", "3072", "--cpus", str(args.cpus),
                "--display", "1280x720", "--gpu-accel", "--screenshot", os.path.join(tmp, "shot.png")]
        env = dict(os.environ, HV_SND_CAPTURE=os.path.join(tmp, "snd.raw"),  # the host plays nothing aloud
               HV_VIRGL_SLOW_US=str(args.slow_us))
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200), env=env)
        desktop_up(p, "boot 1")

        for how in ["Ctrl-A s", "SIGTSTP", "Ctrl-A s again"]:
            before = scenes(p)
            if how == "SIGTSTP":
                os.kill(p.pid, signal.SIGTSTP)
            else:
                p.send("\x01s")
            time.sleep(args.seconds)
            if how == "SIGTSTP":
                os.kill(p.pid, signal.SIGCONT)
            else:
                p.send("\x01s")
            time.sleep(1)
            held_between(errfile, "after the pause", "before the resume", how)
            progress(p, before, how)

        # The guest plays sound, which alone would keep an app running in the background.
        sh(p, "aplay -q -D default -t raw -f S16_LE -r 48000 -c 2 /dev/zero >/tmp/aplay.log 2>&1 & disown")
        time.sleep(3)
        out, rc = sh(p, "pgrep -x aplay; cat /tmp/aplay.log")
        if not re.match(r"\d+", out):
            raise Fail("aplay does not run: " + out)
        before = scenes(p)
        p.send("\x01b")
        wait_stderr(errfile, r"tuxvm: background with the guest's sound \w+: ", 60)
        time.sleep(args.seconds)
        p.send("\x01b")
        wait_stderr(errfile, r"tuxvm: foreground with ", 30)
        time.sleep(1)
        text = open(errfile, errors="replace").read()
        bg = re.findall(r"tuxvm: background with the guest's sound (\w+): (\w+)", text)[-1]
        print(f"  Ctrl-A b: sound {bg[0]}, the machine was {bg[1]}")
        if bg[0] != "playing":
            raise Fail("the host did not play the guest's sound, so the policy was not tested: " + str(bg))
        if bg[1] != "paused":
            raise Fail("an accelerated machine did not pause in the background while its guest played sound")
        held_between(errfile, "after the background", "before the foreground", "Ctrl-A b with sound")
        progress(p, before, "Ctrl-A b with sound")
        out, _ = sh(p, "pgrep -x aplay; pkill -x aplay; true")
        if not out.strip():
            raise Fail("aplay ended during the background")

        out, _ = sh(p, "sudo dmesg")
        bad = [l for l in out.split("\n") if re.search(BAD, l)]
        for l in bad[:12]:
            print(f"    dmesg: {l}")
        if bad:
            raise Fail("kernel warnings after the pauses")

        # The machine is built again after pauses, and the new one pauses too.
        p.sendline("sync; sudo reboot -f")
        wait_stderr(errfile, r"guest restart: building the machine again", 120)
        desktop_up(p, "boot 2")
        before = scenes(p)
        p.send("\x01s")
        end = time.time() + 30
        while True:
            n = len(re.findall(r"gpu held after the pause", open(errfile, errors="replace").read()))
            if n >= 4:
                break
            if time.time() > end:
                raise Fail("the rebuilt machine did not hold the GPU in its pause")
            time.sleep(0.2)
        # Power off while paused: the first SIGTERM is the power key (the paused guest cannot answer), the second stops.
        t0 = time.time()
        os.kill(p.pid, signal.SIGTERM)
        time.sleep(0.5)
        os.kill(p.pid, signal.SIGTERM)
        p.expect(pexpect.EOF, timeout=60)
        p.close()
        took = time.time() - t0
        print(f"  power off while paused: ended in {took:.1f} s, exit status {p.exitstatus}")
        if took > 15:
            raise Fail(f"a power off while paused took {took:.0f} s")
        if stderr_has(errfile, LATE):
            raise Fail("the renderer missed a time limit during the power off:\n" + open(errfile, errors="replace").read()[-1500:])
        print("gpu-pause-check: PASS")
        return 0
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"gpu-pause-check: FAIL: {e}", file=sys.stderr)
        try:
            print("console tail:\n" + (p.before or "")[-2500:], file=sys.stderr)
            print("tuxvm stderr:\n" + open(errfile, errors="replace").read()[-2500:], file=sys.stderr)
        except Exception:
            pass
        return 1
    finally:
        if p is not None and p.isalive():
            p.terminate(force=True)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
