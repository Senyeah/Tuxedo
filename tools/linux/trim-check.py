#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""P4 check: fstrim in the guest gives disk space back on the host.

Boot a clone of the image on a sparse disk, write --mb MB, delete it, run fstrim and compare the
clone's allocated size (st_blocks, what du shows) before and after. A file written before the trim
must still match its checksum after a power off and a second boot.
Runs on tuxvm (--firmware) or, with --qemu, on QEMU TCG (QEMU is the reference: it also discards).
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
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU = os.environ.get("QEMU", "/opt/homebrew/bin/qemu-system-aarch64")
MARK = "TUX_RC_"


class Fail(Exception):
    pass


def argv(args, disk):
    if args.qemu:
        return [QEMU, "-M", "virt,gic-version=3,highmem=off,its=off", "-accel", "tcg", "-cpu", "max",
                "-smp", str(args.cpus), "-m", "2048", "-nographic", "-bios", args.firmware,
                "-drive", f"if=none,file={disk},format=raw,id=d0,discard=unmap,detect-zeroes=unmap",
                "-device", "virtio-blk-pci,drive=d0",
                "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0", "-device", "virtio-rng-pci",
                "-device", "qemu-xhci", "-device", "usb-kbd"]
    # tuxvm's stderr goes to a file so it cannot break the console parsing
    return ["/bin/sh", "-c", 'exec "$@" 2>"$0"', disk + ".stderr", args.tuxvm, "--firmware", args.firmware, "--ram", "2048", "--cpus", str(args.cpus), "--disk", disk]


def sh(p, cmd, limit=30):
    p.sendline(f"{cmd}; echo {MARK}$?")
    p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    out = re.sub(gu.prompt_prefix(), "", out)
    return out.strip(), int(p.match.group(1))


def need(p, cmd, ok, what, limit=30):
    out, rc = sh(p, cmd, limit)
    if rc != 0 or not ok(out):
        raise Fail(f"{what}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
    return out


def boot(args, disk, scale):
    p = pexpect.spawn(argv(args, disk)[0], argv(args, disk)[1:], encoding="utf-8", timeout=60 * scale)
    p.expect(r"\(automatic login\)", timeout=120 * scale)
    p.expect(gu.shell(), timeout=30 * scale)
    p.sendline(f"stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
    p.expect(MARK + r"42\r*\n", timeout=30)
    need(p, "systemctl is-system-running --wait", lambda o: o == "running", "system state", 120)
    return p


def host_mb(disk):
    return os.stat(disk).st_blocks * 512 / (1 << 20)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", action="store_true")
    ap.add_argument("--image", default=os.path.join(gu.linux_dir(), "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(gu.linux_dir(), "u-boot.bin"))
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--size-gb", type=int, default=4)
    ap.add_argument("--mb", type=int, default=512)
    ap.add_argument("--cpus", type=int, default=1)
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()
    gu.use(args.image)
    scale = 4 if args.qemu else 1

    tmp = tempfile.mkdtemp(prefix="trim-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    try:
        subprocess.run(["/bin/cp", "-c", args.image, disk], check=True)
        os.truncate(disk, args.size_gb << 30)
        p = boot(args, disk, scale)
        gran = int(need(p, "cat /sys/block/vda/queue/discard_granularity", str.isdigit, "discard granularity"))
        maxb = int(need(p, "cat /sys/block/vda/queue/discard_max_bytes", str.isdigit, "discard max bytes"))
        if not gran or not maxb:
            raise Fail(f"the guest sees no discard: granularity {gran}, max bytes {maxb}")
        print(f"  guest discard: granularity {gran} B, max {maxb >> 20} MiB per request")
        timer, _ = sh(p, "systemctl is-enabled fstrim.timer")
        print(f"  fstrim.timer: {timer}" + ("" if timer == "enabled" else " (images built before P4 lack it)"))
        need(p, "dd if=/dev/urandom of=$HOME/keep bs=1M count=64 status=none && sync && "
             "sha256sum ~/keep > ~/keep.sum && sync", lambda o: True, "keep file", 60)
        need(p, "sudo fstrim /", lambda o: True, "first trim", 120)  # drop what the image's own deletes left
        base = host_mb(disk)
        need(p, f"dd if=/dev/urandom of=$HOME/big bs=1M count={args.mb} status=none && sync",
             lambda o: True, "write", 180 * scale)
        full = host_mb(disk)
        need(p, "rm ~/big && sync", lambda o: True, "delete")
        t = time.monotonic()
        out = need(p, "sudo fstrim -v /", lambda o: "trimmed" in o, "fstrim", 180 * scale)
        took = time.monotonic() - t
        need(p, "sync", lambda o: True, "sync after trim")
        done = host_mb(disk)
        print(f"  host file: {base:.0f} MB before, {full:.0f} MB after the write, {done:.0f} MB after the trim")
        print(f"  guest: {out} ({took:.1f} s)")
        freed = full - done
        if freed < args.mb * 0.9:
            raise Fail(f"the trim gave back {freed:.0f} MB of the {args.mb} MB written")
        need(p, "sudo dmesg --level=err,crit,alert,emerg | grep -vE 'usb 1-2|usb1-port2' | wc -l",
             lambda o: o == "0", "dmesg errors")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60 * scale)

        p = boot(args, disk, scale)
        need(p, "cd ~ && sha256sum -c keep.sum", lambda o: o.endswith("OK"), "file written before the trim")
        need(p, "sudo dmesg --level=err,crit,alert,emerg | grep -vE 'usb 1-2|usb1-port2' | wc -l",
             lambda o: o == "0", "dmesg errors, second boot")
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=60 * scale)
        print("trim-check: PASS")
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"trim-check: FAIL: {e}", file=sys.stderr)
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
