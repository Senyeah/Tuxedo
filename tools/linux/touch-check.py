#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""TS3: the virtio touchscreen reaches labwc (make test-linux-touch).

Boots a clone of debian-desktop.img on `tuxvm` at --display 1920x1080 with --share and drives the
touchscreen with ts / tsframe / tscancel lines in HV_INPUT_FILE. In the guest it checks:
- dmesg names "TuxVM Touchscreen" in PCI slot 9, udev marks it ID_INPUT_TOUCHSCREEN=1, and
  libinput lists it with the capability touch;
- evtest shows the raw events of one contact in TS1's order (the kernel drops an ABS_MT_SLOT that
  does not change the slot);
- libinput debug-events shows a tap at the centre at 50%/50% (down and up 10 ms apart), a drag,
  two contacts that move apart, and a cancel that lifts both;
- a full-screen Wayland client (touchprobe.py) gets wl_touch down events within 2 logical pixels of
  each tap at 10% and 90% of each axis, then again after `mode 1200x2616 2` (600 x 1308 logical).
Then, unless --no-qemu, the same image on QEMU (hvf) with -device virtio-multitouch-pci, and
evcaps.py on both: the differences between the two devices are printed.

libinput-tools and evtest are installed in the clone if missing (apt through slirp); --image FILE
clones a disk that has them. The shared image never changes.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, send_file  # noqa: E402
from smoke import sh as _sh  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MAXV = 32767
ENV = "env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"


def sh(p, cmd, limit=30):
    return _sh(p, cmd, limit)


def feed(path, lines):
    with open(path, "a") as f:
        f.write("".join(l + "\n" for l in lines))


def at(f):
    return round(f * MAXV)


def tap(slot, fx, fy, hold=10):
    x, y = at(fx), at(fy)
    return [f"ts {slot} 0 {x} {y}", "tsframe", f"msleep {hold}", f"ts {slot} 2 {x} {y}", "tsframe"]


def drag(slot, pts, gap=12):
    out = []
    for i, (fx, fy) in enumerate(pts):
        out += [f"ts {slot} {0 if i == 0 else 1} {at(fx)} {at(fy)}", "tsframe", f"msleep {gap}"]
    return out + [f"ts {slot} 2 0 0", "tsframe"]


def apart(steps=15):
    out = []
    for i in range(steps):
        d = 0.02 + 0.015 * i
        ph = 0 if i == 0 else 1
        out += [f"ts 0 {ph} {at(0.5 - d)} {at(0.5)}", f"ts 1 {ph} {at(0.5 + d)} {at(0.5)}", "tsframe", "msleep 12"]
    return out + ["ts 0 2 0 0", "ts 1 2 0 0", "tsframe"]


TOUCH = re.compile(r"(TOUCH_DOWN|TOUCH_MOTION|TOUCH_UP|TOUCH_FRAME|TOUCH_CANCEL)\s+(?:\d+\s+)?\+([\d.]+)s\s*(.*)")  # "2": a repeat count


def parse_libinput(cap):
    evs = []
    for l in cap.splitlines():
        m = TOUCH.search(l)
        if not m:
            continue
        kind, rest = m.group(1)[6:], m.group(3)
        s = re.match(r"(\d+) \((\d+)\)", rest)
        pos = re.search(r"([\d.]+)/\s*([\d.]+)", rest[s.end():] if s else rest)
        evs.append((kind, int(s.group(1)) if s else None, (float(pos.group(1)), float(pos.group(2))) if pos and kind in ("DOWN", "MOTION") else None))
    return evs


def libinput_run(p, node, infile, lines, wait):
    sh(p, f"sudo sh -c 'libinput debug-events --device {node} > /tmp/li.txt 2>&1 &'; sleep 2")
    feed(infile, lines)
    time.sleep(wait)
    sh(p, "sudo pkill -INT -f 'libinput[ -]debug-events'; sleep 1")  # the wrapper execs libinput-debug-events; [ -] keeps sudo's own line out
    out, _ = sh(p, "cat /tmp/li.txt", 30)
    return out, parse_libinput(out)


def checks_print(checks, cap=""):
    for what, ok in checks:
        print(("ok   " if ok else "FAIL ") + what)
    if not all(ok for _, ok in checks):
        raise Fail("some touch input did not reach libinput as expected; the capture:\n" + cap[-4000:])


def probe_lines(p):
    out, _ = sh(p, "cat /tmp/tp.log")
    return [l.strip() for l in out.splitlines() if l.strip()]


def output(p, size, scale, limit=60):
    """Waits for labwc's output to have this mode and scale (henge-display follows the host); its size in logical pixels."""
    end, raw = time.monotonic() + limit, ""
    while time.monotonic() < end:
        raw, rc = sh(p, f"{ENV} wlr-randr 2>&1", 15)
        m = re.search(r"^\s+(\d+x\d+) px(?:, [\d.]+ Hz)? \(.*current\)", raw, re.M)
        s = re.search(r"Scale: ([\d.]+)", raw)
        if rc == 0 and m and s and (m.group(1), s.group(1)) == (size, scale):
            w, h = map(int, size.split("x"))
            return round(w / float(scale)), round(h / float(scale))
        time.sleep(1)
    raise Fail(f"labwc's output is not {size} at scale {scale} within {limit} s; wlr-randr says:\n{raw[-800:]}")


def wait_configure(p, size, limit=30):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        conf = [l for l in probe_lines(p) if l.startswith("configure ")]
        if conf and conf[-1] == f"configure {size[0]} {size[1]}":
            return
        time.sleep(0.5)
    raise Fail(f"the probe has no full-screen configure of {size} within {limit} s; it printed:\n" +
               "\n".join(probe_lines(p)[-20:]))


def positions(p, infile, size, label):
    """Taps at 10% and 90% of each axis; each wl_touch down must be within 2 logical pixels."""
    W, H = size
    taps = ((0.1, 0.5), (0.9, 0.5), (0.5, 0.1), (0.5, 0.9), (0.5, 0.5))
    before = len(probe_lines(p))
    lines = []
    for fx, fy in taps:
        lines += tap(0, fx, fy, 30) + ["msleep 200"]
    feed(infile, lines)
    time.sleep(0.25 * len(taps) + 3)
    got = [l for l in probe_lines(p)[before:] if l.startswith(("down ", "button "))]
    downs = [tuple(map(float, l.split()[2:4])) for l in got if l.startswith("down ")]
    if len(downs) != len(taps):
        raise Fail(f"{label}: {len(downs)} wl_touch downs for {len(taps)} taps; the probe printed:\n" + "\n".join(got))
    worst = 0.0
    for (fx, fy), (x, y) in zip(taps, downs):
        ex, ey = at(fx) * W / (MAXV + 1), at(fy) * H / (MAXV + 1)  # libinput maps 0..max over max + 1 steps
        err = max(abs(x - ex), abs(y - ey))
        worst = max(worst, err)
        print(f"     tap at {fx:.0%}, {fy:.0%}: wl_touch {x:.2f}, {y:.2f}; expected {ex:.2f}, {ey:.2f}")
        if err > 2:
            raise Fail(f"{label}: tap at {fx:.0%},{fy:.0%} landed at {x:.2f},{y:.2f}, expected {ex:.2f},{ey:.2f}")
    print(f"ok   {label}: 5 taps on {W}x{H} logical pixels, largest error {worst:.2f} px")
    return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--image", help="desktop disk to clone (default debian-desktop.img in the linux dir)")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--save", help="write the libinput captures and the probe log to this file")
    ap.add_argument("--no-qemu", action="store_true", help="skip the QEMU virtio-multitouch-pci comparison")
    ap.add_argument("--cpus", type=int, default=2)
    args = ap.parse_args()
    d = args.linux_dir or smoke.linux_dir()
    image = args.image or os.path.join(d, "debian-desktop.img")
    kernel, initrd = (os.path.join(d, f) for f in ("Image", "initrd.img"))
    pu = image[:-4] + ".partuuid"
    if not os.path.exists(pu):
        pu = os.path.join(d, "debian-desktop.partuuid")
    for f in (args.tuxvm, kernel, initrd, image, pu):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    partuuid = open(pu).read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    with tempfile.TemporaryDirectory(prefix="touch-", dir=args.work_dir) as tmp:
        clone, infile, err, share = (os.path.join(tmp, n) for n in ("disk.img", "input", "stderr", "share"))
        open(infile, "w").close()
        os.mkdir(share)  # henge-display reads the scale from the share (as in the app)
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
            tux_caps = run(p, args, infile, err)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:])
        finally:
            if p.isalive():
                p.terminate(force=True)
        if not args.no_qemu:
            qemu_compare(args, image, kernel, initrd, partuuid, tux_caps)
    print("PASS")


def run(p, args, infile, err):
    out, _ = sh(p, "sudo dmesg | grep -E 'TuxVM Touchscreen'")
    print("--- dmesg ---\n" + out.strip())
    if not re.search(r"input: TuxVM Touchscreen as /devices/.*/0000:00:09\.0/", out):
        raise Fail("dmesg has no TuxVM Touchscreen in PCI slot 9")
    node, _ = sh(p, "for e in /sys/class/input/event*; do grep -qx 'TuxVM Touchscreen' $e/device/name && echo /dev/input/${e##*/}; done; true")
    node = node.strip()
    if not re.fullmatch(r"/dev/input/event\d+", node):
        raise Fail(f"no event node for the touchscreen: {node!r}")
    out, _ = sh(p, f"udevadm info --query=property --name={node} | grep -E '^ID_INPUT'")
    print(f"--- udev {node} ---\n" + out.strip())
    if "ID_INPUT_TOUCHSCREEN=1" not in out:
        raise Fail("udev does not mark the device ID_INPUT_TOUCHSCREEN=1")
    _, rc1 = sh(p, "command -v libinput")
    _, rc2 = sh(p, "command -v evtest")
    if rc1 or rc2:
        _, rc = sh(p, "sudo apt-get update >/dev/null 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "
                      "--no-install-recommends libinput-tools evtest >/dev/null 2>&1", 900)
        if rc:
            raise Fail("apt-get install libinput-tools evtest failed")
    out, _ = sh(p, "sudo libinput list-devices 2>&1")
    block = re.search(r"Device:\s+TuxVM Touchscreen\n(?:.+\n)+", out + "\n")
    print("--- libinput list-devices ---\n" + (block.group(0).strip() if block else out[-1500:]))
    if not block or not re.search(r"Capabilities:\s+touch", block.group(0)):
        raise Fail("libinput does not list TuxVM Touchscreen with the capability touch")
    warn = [l for l in out.splitlines() if re.search(r"Touchscreen.*(bug|error|ignor)", l, re.I)]
    print("libinput warnings for the device: " + ("; ".join(warn) if warn else "none"))
    send_file(p, os.path.join(HERE, "evcaps.py"), "/tmp/evcaps.py")
    caps, _ = sh(p, "sudo python3 /tmp/evcaps.py")
    print("--- evcaps (Henge) ---\n" + caps.strip())

    # Raw order: TS1's list for one contact; the kernel drops ABS_MT_SLOT 0 (no change from its start).
    sh(p, f"sudo sh -c 'timeout 6 evtest {node} > /tmp/evtest.txt 2>&1 &'; sleep 1.5")
    feed(infile, ["ts 0 0 16384 16384", "tsframe", "msleep 60", "ts 0 1 16484 16384", "tsframe", "msleep 60",
                  "ts 0 2 0 0", "tsframe"])
    time.sleep(6)
    ev, _ = sh(p, "cat /tmp/evtest.txt", 30)
    toks = []
    for l in ev.splitlines():
        if "SYN_REPORT" in l:
            toks.append("|")
        else:
            m = re.search(r"type \d+ \((EV_\w+)\), code \d+ \((\w+)\), value (-?\d+)", l)
            if m and l.startswith("Event:"):
                toks.append(f"{m.group(2)}={m.group(3)}")
    got = " ".join(toks)
    want = re.compile(r"^ABS_MT_TRACKING_ID=\d+ ABS_MT_POSITION_X=16384 ABS_MT_POSITION_Y=16384 BTN_TOUCH=1 \| "
                      r"ABS_MT_POSITION_X=16484 \| ABS_MT_TRACKING_ID=-1 BTN_TOUCH=0 \|$")
    print("--- evtest, one contact ---\n" + got)
    if not want.match(got):
        raise Fail("evtest events are not TS1's order for one contact:\n" + ev[-2000:])
    print("ok   evtest: one contact down, move, up in TS1's order")

    saved = []
    cap, evs = libinput_run(p, node, infile, tap(0, 0.5, 0.5, 10), 2)
    saved.append(cap)
    downs = [e for e in evs if e[0] == "DOWN"]
    c = [("centre tap: one down, one up, frames",
          len(downs) == 1 and sum(e[0] == "UP" for e in evs) == 1 and sum(e[0] == "FRAME" for e in evs) >= 2),
         ("centre tap at 50%/50%", len(downs) == 1 and all(abs(v - 50) < 0.1 for v in downs[0][2]))]
    print("--- libinput: centre tap ---\n" + "\n".join(l for l in cap.splitlines() if "TOUCH" in l))
    checks_print(c, cap)

    cap, evs = libinput_run(p, node, infile, drag(0, [(0.25 + 0.025 * i, 0.5) for i in range(21)]), 3)
    saved.append(cap)
    xs = [e[2][0] for e in evs if e[0] in ("DOWN", "MOTION")]
    checks_print([("drag: one down, 20 motions, one up", sum(e[0] == "DOWN" for e in evs) == 1
                   and sum(e[0] == "MOTION" for e in evs) == 20 and sum(e[0] == "UP" for e in evs) == 1),
                  ("drag: x goes from 25% to 75%", len(xs) == 21 and abs(xs[0] - 25) < 0.1 and abs(xs[-1] - 75) < 0.1
                   and all(b > a for a, b in zip(xs, xs[1:])))], cap)

    cap, evs = libinput_run(p, node, infile, apart(), 3)
    saved.append(cap)
    slots = sorted({e[1] for e in evs if e[0] == "DOWN"})
    last = {}
    for e in evs:
        if e[0] in ("DOWN", "MOTION"):
            last.setdefault(e[1], []).append(e[2][0])
    spread = [abs(last[1][i] - last[0][i]) for i in range(min(len(last.get(0, [])), len(last.get(1, []))))] if len(last) == 2 else []
    checks_print([("two contacts: slots 0 and 1 down and up", slots == [0, 1] and sum(e[0] == "UP" for e in evs) == 2),
                  ("two contacts move apart", len(spread) >= 10 and spread[-1] > spread[0] + 30)], cap)

    cap, evs = libinput_run(p, node, infile, ["ts 0 0 10000 10000", "ts 1 0 20000 20000", "tsframe", "msleep 100",
                                              "tscancel"], 2)
    saved.append(cap)
    checks_print([("tscancel lifts both contacts", sum(e[0] == "DOWN" for e in evs) == 2
                   and sum(e[0] in ("UP", "CANCEL") for e in evs) == 2)], cap)

    send_file(p, os.path.join(HERE, "touchprobe.py"), "/tmp/touchprobe.py")
    first = output(p, "1920x1080", "1.000000")
    sh(p, f"({ENV} nohup python3 -u /tmp/touchprobe.py > /tmp/tp.log 2>&1 &)")
    wait_configure(p, first)
    print(f"ok   probe: full screen at {first[0]}x{first[1]} logical (1920x1080, scale 1)")
    e1 = positions(p, infile, first, "position at 1920x1080 scale 1")
    feed(infile, ["mode 1200x2616 2"])
    turned = output(p, "1200x2616", "2.000000")
    wait_configure(p, turned)
    time.sleep(1)
    print(f"ok   probe: full screen at {turned[0]}x{turned[1]} logical after mode 1200x2616 2")
    e2 = positions(p, infile, turned, "position at 1200x2616 scale 2")
    buttons = [l for l in probe_lines(p) if l.startswith("button ")]
    print(f"     pointer buttons the probe saw (labwc mouse emulation): {len(buttons)}")
    if args.save:
        open(args.save, "w").write("\n\n".join(saved) + "\n\n--- probe ---\n" + "\n".join(probe_lines(p)) + "\n")
    print(f"     measured position error: {e1:.2f} px at {first[0]}x{first[1]}, {e2:.2f} px at {turned[0]}x{turned[1]} logical")

    log = open(err, errors="replace").read()
    bad = [l for l in log.splitlines() if re.search(r"out of memory|ERR_|fail", l, re.I)]
    if bad:
        raise Fail("host errors on stderr:\n" + "\n".join(bad[:10]))
    p.sendline("sudo poweroff")
    p.expect(pexpect.EOF, timeout=60)
    p.close()
    if p.exitstatus != 0:
        raise Fail(f"power off gave exit status {p.exitstatus}")
    return caps


def qemu_compare(args, image, kernel, initrd, partuuid, tux_caps):
    """QEMU's virtio-multitouch-pci in the same guest: evcaps.py on both, and the differences."""
    if not os.path.exists(smoke.QEMU):
        print(f"skip QEMU comparison: no {smoke.QEMU}")
        return
    argv = [smoke.QEMU, "-M", "virt,gic-version=3,highmem=off,its=off", "-accel", "hvf", "-cpu", "max", "-smp", "2",
            "-m", "2048", "-drive", f"if=none,file={image},format=raw,id=d0,snapshot=on", "-device", "virtio-blk-pci,drive=d0",
            "-device", "virtio-multitouch-pci", "-nographic", "-kernel", kernel, "-initrd", initrd,
            "-append", f"console=ttyAMA0 root=PARTUUID={partuuid} rw"]
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
    try:
        login(p, None, 200)
        send_file(p, os.path.join(HERE, "evcaps.py"), "/tmp/evcaps.py")
        qcaps, _ = sh(p, "sudo python3 /tmp/evcaps.py")
        udev, _ = sh(p, "for e in /sys/class/input/event*; do grep -q MultiTouch $e/device/name && "
                        "udevadm info --query=property --name=/dev/input/${e##*/} | grep -E '^ID_INPUT'; done")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60)
    except (pexpect.TIMEOUT, pexpect.EOF, Fail) as e:
        print(f"QEMU comparison not done: {e}"[:1500])
        return
    finally:
        if p.isalive():
            p.terminate(force=True)
    print("--- evcaps (QEMU virtio-multitouch-pci) ---\n" + qcaps.strip())
    print("--- udev (QEMU) ---\n" + udev.strip())
    h = [l for l in tux_caps.strip().splitlines() if not l.startswith("device ")]
    q = [l for l in qcaps.strip().splitlines() if not l.startswith("device ")]
    diff = [f"Henge only: {l}" for l in h if l not in q] + [f"QEMU only:  {l}" for l in q if l not in h]
    print("--- differences (names aside) ---\n" + ("\n".join(diff) if diff else "none"))


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
