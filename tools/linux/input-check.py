#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""D5: keys, pointer, buttons, wheel and trackpad reach a Linux guest (make test-linux-input).

Boots a clone of debian-desktop.img on `tuxvm` and drives the machine through
HV_INPUT_FILE. In the guest, `libinput debug-events` records what arrives. The test checks the
xHCI probe in dmesg, then each device: the USB keyboard, the virtio mouse (move, left, right,
wheel) and the USB Magic Trackpad 2 (one finger, two-finger scroll, click).

The image needs libinput-tools. If it is missing the test installs it in the clone (apt through
slirp). --image FILE clones a disk that has it already. The shared image never changes.
"""
import argparse
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
        raise Fail(f"{cmd!r}: no answer within {limit} s")
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    return re.sub(gu.prompt_prefix(), "", out), int(p.match.group(1))


def feed(path, lines):
    with open(path, "a") as f:
        f.write("".join(l + "\n" for l in lines))


def finger_path(tag, pts):
    """One finger: down, moves 12 ms apart, up. pts are (x, y) sensor units."""
    out = []
    for i, (x, y) in enumerate(pts):
        out.append(f"tp {tag} {0 if i == 0 else 1} {x} {y}")
        out.append("tpframe")
        out.append("msleep 12")
    out.append(f"tp {tag} 2 {pts[-1][0]} {pts[-1][1]}")
    return out


def two_fingers(pts_a, pts_b):
    out = []
    for i, ((ax, ay), (bx, by)) in enumerate(zip(pts_a, pts_b)):
        ph = 0 if i == 0 else 1
        out.append(f"tp 1 {ph} {ax} {ay}")
        out.append(f"tp 2 {ph} {bx} {by}")
        out.append("tpframe")
        out.append("msleep 12")
    out.append(f"tp 1 2 {pts_a[-1][0]} {pts_a[-1][1]}")
    out.append(f"tp 2 2 {pts_b[-1][0]} {pts_b[-1][1]}")
    return out


def uboot_keyboard(args, fw, tmp):
    """The xHCI keyboard stops the autoboot countdown and types a command at the U-Boot prompt."""
    infile = os.path.join(tmp, "uboot-input")
    open(infile, "w").close()
    p = pexpect.spawn("/bin/sh", ["-c", 'exec "$@" 2>"$0"', os.path.join(tmp, "uboot-stderr"), args.tuxvm, "--firmware", fw, "--ram", "1024"],
                      encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                      env=dict(os.environ, HV_INPUT_FILE=infile))
    try:
        p.expect(r"USB XHCI.*\r*\n.*Bus xhci_pci: (\d+) USB Device\(s\) found", timeout=60)
        n = int(p.match.group(1))
        p.expect("Hit any key to stop autoboot", timeout=30)
        feed(infile, ["key 57"])  # space
        p.expect(r"autoboot: 0\r*\n=> ", timeout=20)
        time.sleep(0.5)
        feed(infile, ["type version", "key 28"])  # Enter
        p.expect(r"version\r*\nU-Boot \d+\.\d+", timeout=20)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        raise Fail(f"U-Boot keyboard: {type(e).__name__}; the keyboard did not stop autoboot or type; tail:\n"
                   + (p.before or "")[-800:] + "\n" + (p.buffer or "")[-800:])
    finally:
        p.terminate(force=True)
    if n < 3:
        raise Fail(f"U-Boot found {n} USB devices, expected 3 (hub, keyboard, trackpad)")
    print(f"ok   U-Boot: {n} USB devices; the xHCI keyboard stopped autoboot and typed 'version'")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--linux-dir")
    ap.add_argument("--image", help="disk to clone (default debian-desktop.img)")
    ap.add_argument("--uboot", action="store_true", help="boot through U-Boot instead of the direct kernel")
    ap.add_argument("--no-uboot-keys", action="store_true", help="skip the U-Boot keyboard check")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--save", help="write the libinput capture to this file")
    ap.add_argument("--cpus", type=int, default=2)
    args = ap.parse_args()
    d = args.linux_dir or linux_dir()
    image = args.image or os.path.join(d, "debian-desktop.img")
    gu.use(image)
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    kernel, initrd = (os.path.join(d, f) for f in ("Image", "initrd.img"))
    # u-boot.bin has no countdown for the keyboard to stop (P2)
    fw = next(f for f in (os.path.join(d, "u-boot-stock.bin"), os.path.join(d, "u-boot.bin")) if os.path.exists(f))
    for f in (args.tuxvm, image):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    with tempfile.TemporaryDirectory(prefix="input-", dir=args.work_dir) as tmp:
        clone, infile = os.path.join(tmp, "disk.img"), os.path.join(tmp, "input")
        open(infile, "w").close()
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        if not args.no_uboot_keys:
            uboot_keyboard(args, fw, tmp)
        boot = (["--firmware", fw] if args.uboot else
                ["--kernel", kernel, "--initrd", initrd, "--append",
                 f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"])
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', os.path.join(tmp, "stderr"), args.tuxvm] + \
            boot + ["--disk", clone, "--ram", "2048", "--cpus", str(args.cpus), "--display", "1280x720"]
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200),
                          env=dict(os.environ, HV_INPUT_FILE=infile))
        try:
            gu.login(p, 150, 60)
            sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
            time.sleep(4)  # labwc and logind settle
            run(p, args, infile)
        except pexpect.TIMEOUT:
            raise Fail("timeout waiting for the guest; tail:\n" + (p.before or "")[-1500:])
        finally:
            if p.isalive():
                p.sendline("sudo poweroff")
                try:
                    p.expect(pexpect.EOF, timeout=60)
                except pexpect.TIMEOUT:
                    p.terminate(force=True)


def run(p, args, infile):
    out, _ = sh(p, "sudo dmesg | grep -E 'xhci|usb [0-9]|usb[0-9]|magicmouse|apple 0003|hid-generic|TuxVM'")
    print("--- dmesg (usb and input) ---\n" + out.strip())
    bad = [l for l in out.splitlines() if re.search(r"can't setup|Invalid ep0|unable to enumerate|error|fail", l, re.I)]
    if bad:
        raise Fail("xHCI or USB errors in dmesg:\n" + "\n".join(bad))
    for what, pat in (("xHCI probe", r"xhci_hcd 0000:00:04\.0: xHCI Host Controller"),
                      ("keyboard", r"usb 1-1: Product: TuxVM USB Keyboard"),
                      ("trackpad", r"usb 1-2: Product: Magic Trackpad 2"),
                      ("hid-magicmouse bound", r"magicmouse 0003:05AC:0265\.\d+: input.*Magic Trackpad 2")):
        if not re.search(pat, out):
            raise Fail(f"dmesg has no line for {what}: {pat}")
    _, rc = sh(p, "command -v libinput")
    if rc:
        out, rc = sh(p, "sudo apt-get update >/dev/null 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "
                        "--no-install-recommends libinput-tools evtest >/dev/null 2>&1", 900)
        if rc:
            raise Fail("apt-get install libinput-tools evtest failed")
    out, _ = sh(p, "sudo libinput list-devices | grep -E '^(Device|Capabilities|Kernel)'")
    print("--- libinput list-devices ---\n" + out.strip())
    for dev, cap in (("TuxVM TuxVM USB Keyboard", "keyboard"), ("Apple Inc. Magic Trackpad 2", "pointer gesture"),
                     ("TuxVM Mouse", "pointer")):
        if not re.search(re.escape(dev) + r"\n.*\n.*" + cap, out):
            raise Fail(f"libinput does not list {dev} with {cap}")

    sh(p, "sudo sh -c 'libinput debug-events --show-keycodes > /tmp/li.txt 2>&1 &'; sleep 2")
    sensor_x, sensor_y = 8134, 5206
    cx, cy = sensor_x // 2, sensor_y // 2
    lines = ["type hello", "msleep 300",
             "rel 40 0", "msleep 50", "rel 0 30", "msleep 100",
             "click 0 0", "msleep 200", "rclick", "msleep 200",
             "btn 0x113 1", "msleep 100", "btn 0x113 0", "msleep 100", "btn 0x114 1", "msleep 100", "btn 0x114 0", "msleep 200",
             "scroll 0 1", "msleep 100", "scroll 0 -1", "msleep 100", "scroll 1 0", "msleep 200",
             "msleep 300"]
    lines += finger_path(1, [(cx - 1000 + 100 * i, cy) for i in range(21)]) + ["msleep 300"]
    lines += finger_path(1, [(cx, cy - 1000 + 100 * i) for i in range(21)]) + ["msleep 300"]
    lines += two_fingers([(cx - 400, cy - 800 + 80 * i) for i in range(21)],
                         [(cx + 400, cy - 800 + 80 * i) for i in range(21)]) + ["msleep 300"]
    lines += two_fingers([(cx - 400, cy + 800 - 80 * i) for i in range(21)],
                         [(cx + 400, cy + 800 - 80 * i) for i in range(21)]) + ["msleep 300"]
    lines += ["tpclick 1", "msleep 150", "tpclick 0", "msleep 500", "wait 1"]
    feed(infile, lines)
    time.sleep(12)
    sh(p, "sudo pkill -INT -x libinput; sleep 1")
    out, _ = sh(p, "cat /tmp/li.txt", 30)
    if args.save:
        open(args.save, "w").write(out)
    check_capture(out)
    p.sendline("sudo poweroff")
    p.expect(pexpect.EOF, timeout=60)
    p.close()
    if p.exitstatus != 0:
        raise Fail(f"power off gave exit status {p.exitstatus}")
    print("PASS")


def check_capture(cap):
    print("--- libinput debug-events (first 80 lines of the capture) ---")
    print("\n".join(cap.splitlines()[:80]))
    ids = {}
    for m in re.finditer(r"^-?(event\d+)\s+DEVICE_ADDED\s+(.+?)\s+seat", cap, re.M):
        ids[m.group(2).strip()] = m.group(1)
    kbd, mouse, tp = (ids.get(n) for n in ("TuxVM TuxVM USB Keyboard", "TuxVM Mouse", "Apple Inc. Magic Trackpad 2"))
    if not (kbd and mouse and tp):
        raise Fail(f"libinput added no device for one of the three: {ids}")
    lines = {k: [l for l in cap.splitlines() if re.match(rf"^\s*-?{v}\s", l)] for k, v in
             (("kbd", kbd), ("mouse", mouse), ("tp", tp))}

    def count(dev, kind, extra=""):
        return sum(1 for l in lines[dev] if re.search(rf"\s{kind}\s.*{extra}", l))
    keys = [re.search(r"(KEY_\w+) \(\d+\) pressed", l).group(1) for l in lines["kbd"] if "KEYBOARD_KEY" in l and "pressed" in l]
    if keys != ["KEY_H", "KEY_E", "KEY_L", "KEY_L", "KEY_O"]:
        raise Fail(f"keyboard: expected H E L L O, got {keys}")
    def nums(dev, kind):
        res = []
        for l in lines[dev]:
            if re.search(r"\s" + kind + r"\s", l):
                m = re.search(r"vert (-?[\d.]+)/\s*-?[\d.]+\*? horiz (-?[\d.]+)/", l) or \
                    re.search(r"\s(-?[\d.]+)/\s*(-?[\d.]+) \(", l)
                if m:
                    res.append((float(m.group(1)), float(m.group(2))))
        return res
    wheel = nums("mouse", "POINTER_SCROLL_WHEEL")
    # the second number of each axis is libinput's v120: 120 is one notch, as the hi-res event gives it
    v120 = []
    for l in lines["mouse"]:
        m = re.search(r"POINTER_SCROLL_WHEEL.*vert -?[\d.]+/\s*(-?[\d.]+)\*? horiz -?[\d.]+/\s*(-?[\d.]+)", l)
        if m:
            v120.append((float(m.group(1)), float(m.group(2))))
    mmotion = nums("mouse", "POINTER_MOTION")
    motion = nums("tp", "POINTER_MOTION")
    fscroll = nums("tp", "POINTER_SCROLL_FINGER")
    nz = [v for v, _ in fscroll if v]
    half = len(nz) // 2
    checks = [
        ("virtio mouse: +x moves right, +y moves down", len(mmotion) == 2 and mmotion[0][0] > 0 and mmotion[1][1] > 0),
        ("virtio mouse BTN_LEFT press and release", count("mouse", "POINTER_BUTTON", r"BTN_LEFT.*pressed") == 1
         and count("mouse", "POINTER_BUTTON", r"BTN_LEFT.*released") == 1),
        ("virtio mouse BTN_RIGHT press and release", count("mouse", "POINTER_BUTTON", r"BTN_RIGHT.*pressed") == 1
         and count("mouse", "POINTER_BUTTON", r"BTN_RIGHT.*released") == 1),
        ("virtio mouse BTN_SIDE and BTN_EXTRA press and release",
         all(count("mouse", "POINTER_BUTTON", rf"{b}.*{w}") == 1 for b in ("BTN_SIDE", "BTN_EXTRA") for w in ("pressed", "released"))),
        ("a notch is 120 in libinput's v120: up, down, right",
         v120 == [(-120.0, 0.0), (120.0, 0.0), (0.0, 120.0)]),
        ("wheel +1 scrolls up, -1 scrolls down, hwheel +1 scrolls right",
         len(wheel) == 3 and wheel[0][0] < 0 and wheel[1][0] > 0 and wheel[2][1] > 0),
        ("trackpad one finger: +x moves right, +y moves down",
         sum(1 for x, _ in motion if x > 0) >= 10 and sum(1 for _, y in motion if y > 0) >= 10
         and not any(x < 0 or y < 0 for x, y in motion)),
        ("trackpad two-finger scroll in both directions (opposite signs)",
         len(nz) >= 20 and all(v < 0 for v in nz[:half - 2]) and all(v > 0 for v in nz[-(half - 2):])
         or len(nz) >= 20 and all(v > 0 for v in nz[:half - 2]) and all(v < 0 for v in nz[-(half - 2):])),
        ("trackpad click", count("tp", "POINTER_BUTTON", r"BTN_LEFT.*pressed") == 1
         and count("tp", "POINTER_BUTTON", r"BTN_LEFT.*released") == 1),
    ]
    print("--- wheel events ---\n" + "\n".join(l for l in lines["mouse"] if "POINTER_SCROLL_WHEEL" in l))
    for what, ok in checks:
        print(("ok   " if ok else "FAIL ") + what)
    if not all(ok for _, ok in checks):
        raise Fail("some input did not reach libinput; see the capture above")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print("FAIL: " + str(e), file=sys.stderr)
        sys.exit(1)
