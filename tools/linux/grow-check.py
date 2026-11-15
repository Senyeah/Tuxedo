#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""G8 check: a clone of the image on a bigger sparse disk must grow into it, at first boot and later.

Boot 1: clone grown to --size-gb. Boot 2: nothing changed (the first-boot unit must not run again).
Boot 3: the disk grown by --extra-gb more (the grow unit runs on a later boot).
Runs on tuxvm (--firmware) or, with --qemu, on QEMU TCG. Exit 1 on a failed check.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU = os.environ.get("QEMU", "/opt/homebrew/bin/qemu-system-aarch64")
SHELL = r"henge@henge:\S*\$ "
MARK = "TUX_RC_"


class Fail(Exception):
    pass


def argv(args, disk):
    if args.qemu:
        return [QEMU, "-M", "virt,gic-version=3,highmem=off,its=off", "-accel", "tcg", "-cpu", "max",
                "-smp", str(args.cpus), "-m", "2048", "-nographic", "-bios", args.firmware,
                "-drive", f"if=none,file={disk},format=raw,id=d0", "-device", "virtio-blk-pci,drive=d0",
                "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0", "-device", "virtio-rng-pci",
                "-device", "qemu-xhci", "-device", "usb-kbd"]
    # tuxvm's stderr goes to a file so it cannot break the console parsing
    return ["/bin/sh", "-c", 'exec "$@" 2>"$0"', disk + ".stderr", args.tuxvm, "--firmware", args.firmware, "--ram", "2048", "--cpus", str(args.cpus), "--disk", disk]


def sh(p, cmd, limit=30):
    p.sendline(f"{cmd}; echo {MARK}$?")
    p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    out = re.sub(r"^henge@henge:[^\n$]*\$ ", "", out)
    return out.strip(), int(p.match.group(1))


def boot(args, disk, scale):
    p = pexpect.spawn(argv(args, disk)[0], argv(args, disk)[1:], encoding="utf-8", timeout=60 * scale)
    p.expect(r"\(automatic login\)", timeout=120 * scale)
    p.expect(SHELL, timeout=30 * scale)
    p.sendline(f"stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
    p.expect(MARK + r"42\r*\n", timeout=30)
    # The grow unit can still run when the autologin shell appears
    need(p, "systemctl is-system-running --wait", lambda o: o == "running", "system state", 120)
    return p


def need(p, cmd, ok, what, limit=30):
    out, rc = sh(p, cmd, limit)
    if rc != 0 or not ok(out):
        raise Fail(f"{what}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
    return out


def grown(p, gb, what):
    """Partition, filesystem and GPT all fill a gb GiB disk."""
    disk_b = int(need(p, "cat /sys/class/block/vda/size", str.isdigit, what)) * 512
    part_b = int(need(p, "cat /sys/class/block/vda1/size", str.isdigit, what)) * 512
    if disk_b != gb << 30:
        raise Fail(f"{what}: disk is {disk_b} bytes, want {gb} GiB")
    # 1 MiB before the partition, 33 sectors for the backup table; sgdisk aligns the end to 2048
    if disk_b - part_b > (2 << 20) + 16896:
        raise Fail(f"{what}: partition {part_b} of disk {disk_b}")
    fs_mb = int(need(p, "df -BM --output=size / | tail -n 1 | tr -dc 0-9", str.isdigit, what))
    if fs_mb < gb * 1024 * 0.93:
        raise Fail(f"{what}: df says {fs_mb} MB for a {gb} GiB disk")
    need(p, "sudo sgdisk -v /dev/vda", lambda o: "No problems found" in o, what + " GPT")
    print(f"  {what}: disk {gb} GiB, partition {part_b >> 20} MiB, df {fs_mb} MB, GPT clean")
    return fs_mb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", action="store_true")
    ap.add_argument("--image", default=os.path.join(ROOT, "build", "linux", "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(ROOT, "build", "linux", "u-boot.bin"))
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--size-gb", type=int, default=16)
    ap.add_argument("--extra-gb", type=int, default=4)
    ap.add_argument("--cpus", type=int, default=1)
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()
    scale = 4 if args.qemu else 1

    tmp = tempfile.mkdtemp(prefix="grow-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    try:
        subprocess.run(["/bin/cp", "-c", args.image, disk], check=True)
        os.truncate(disk, args.size_gb << 30)
        t0 = time.monotonic()
        p = boot(args, disk, scale)
        print(f"boot 1 (first boot, {args.size_gb} GiB): login after {time.monotonic() - t0:.1f} s")
        grown(p, args.size_gb, "first boot")
        need(p, "test -s /etc/machine-id && test -e /var/lib/tux/firstboot-done", lambda o: True, "first-boot work")
        need(p, "systemctl is-active tux-firstboot.service tux-grow.service",
             lambda o: o.split() == ["active", "active"], "units ran")
        need(p, "systemctl is-system-running", lambda o: o == "running", "system state")
        need(p, "systemctl show -p Result -p ExecMainStatus tux-grow.service",
             lambda o: "Result=success" in o, "grow unit result")
        need(p, "sudo dmesg --level=err,crit,alert,emerg | grep -vE 'usb 1-2|usb1-port2' | wc -l",
             lambda o: o == "0", "dmesg errors")
        need(p, "sudo journalctl -b -u tux-grow.service -o cat --no-pager",
             lambda o: "disk unchanged" not in o, "first boot ran the grow tools")
        need(p, "cat /var/lib/tux/grow-size", lambda o: o == str(args.size_gb << 21), "grow stamp after first boot")
        mid = need(p, "cat /etc/machine-id", lambda o: re.fullmatch(r"[0-9a-f]{32}", o), "machine id")
        need(p, "echo growcheck > /home/henge/keep; sync", lambda o: True, "write a file")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60 * scale)

        t0 = time.monotonic()
        p = boot(args, disk, scale)
        print(f"boot 2 (unchanged): login after {time.monotonic() - t0:.1f} s")
        grown(p, args.size_gb, "second boot")
        need(p, "sudo journalctl -b -u tux-grow.service -o cat --no-pager",
             lambda o: "disk unchanged" in o, "unchanged disk skips the grow tools")
        need(p, "systemctl show -p ConditionResult tux-firstboot.service",
             lambda o: o == "ConditionResult=no", "first-boot unit skipped")
        need(p, "cat /etc/machine-id", lambda o: o == mid, "machine id kept")
        need(p, "cat /home/henge/keep", lambda o: o == "growcheck", "file kept")
        need(p, "systemctl is-system-running", lambda o: o == "running", "system state")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60 * scale)

        bigger = args.size_gb + args.extra_gb
        os.truncate(disk, bigger << 30)
        t0 = time.monotonic()
        p = boot(args, disk, scale)
        print(f"boot 3 (disk grown to {bigger} GiB): login after {time.monotonic() - t0:.1f} s")
        grown(p, bigger, "later boot")
        need(p, "sudo journalctl -b -u tux-grow.service -o cat --no-pager",
             lambda o: "disk unchanged" not in o and "resize2fs" in o, "a bigger disk runs the grow tools")
        need(p, "cat /var/lib/tux/grow-size", lambda o: o == str(bigger << 21), "grow stamp after growing")
        need(p, "cat /etc/machine-id", lambda o: o == mid, "machine id kept")
        need(p, "cat /home/henge/keep", lambda o: o == "growcheck", "file kept")
        need(p, "systemctl is-system-running", lambda o: o == "running", "system state")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60 * scale)
        print("grow-check: PASS")
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"grow-check: FAIL: {e}", file=sys.stderr)
        try:
            print("console tail:\n" + (p.before or "")[-3000:], file=sys.stderr)
        except Exception:
            pass
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
