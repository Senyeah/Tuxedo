#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""K2: what the initrd costs at boot (LINUX-PLAN-04, K2 item 3).

Boots Debian's 16 KB kernel from an APFS clone of debian-console.img on QEMU (TCG, no hvf) and on
tuxvm, by direct kernel boot or through U-Boot, with and without the initrd. Kernel
messages carry timestamps (printk.time=1, no quiet), so the tool reads these marks from the console:

  unpack     "Freeing initrd memory": the initramfs is unpacked
  run_init   "Run /init as init process": the kernel is ready for user space
  mounted    "EXT4-fs (vda1): mounted": the root file system is mounted (initramfs user space is over)
  systemd    the first "systemd[1]:" line: the real init runs
  login      host seconds from the start of the kernel to the autologin prompt, and /proc/uptime there

Debian's kernel has virtio_blk and ext4 as modules, so it cannot mount the root without the initrd. A
run without the initrd stops at "VFS: Cannot open root device"; that kernel time (root_fail) is what a
kernel with the drivers built in would spend before it could mount the root.

U-Boot runs load the kernel (and initrd) with ext4load and start it with booti, with the same bootargs
as the direct run, so the two paths differ only in who loads the files. The wall time of each ext4load
is reported (the plan's "Starting kernel" line is the start of the kernel marks).

Files come from TUX_LINUX_OUT or build/linux in the main checkout (read only; the disk is cloned).
Usage: kernel-boot-time.py [--machine tux|qemu ...] [--boot direct|uboot ...] [--initrd on|off ...]
       [--runs N] [--cpus N] [--json FILE]. With no selection it runs the whole matrix.
"""
import argparse
import itertools
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

import pexpect
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU = os.environ.get("QEMU", "/opt/homebrew/bin/qemu-system-aarch64")
KVER = "6.12.107+deb13-arm64-16k"
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
MARKS = [
    ("unpack", r"Freeing initrd memory"),
    ("run_init", r"Run /init as init process"),
    ("mounted", r"EXT4-fs \(vda1\): (mounted|recovery)"),
    ("systemd", r"systemd\[1\]: "),
    ("root_fail", r"VFS: Cannot open root device|Kernel panic - not syncing: VFS"),
]


def linux_dir():
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
    common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


class Stamp:
    """Console log that keeps each finished line with the host time it arrived."""

    def __init__(self):
        self.lines, self.part = [], ""

    def write(self, s):
        s = ANSI.sub("", self.part + s.replace("\r", ""))
        *done, self.part = s.split("\n")
        now = time.monotonic()
        self.lines += [(now, ln) for ln in done]

    def flush(self):
        pass


def argv_for(a, machine, boot, initrd_on, disk, files, append):
    kernel, initrd, firmware = files
    if machine == "qemu":
        argv = [QEMU, "-M", "virt,gic-version=3,highmem=off,its=off", "-accel", "tcg", "-cpu", "max",
                "-smp", str(a.cpus), "-m", str(a.ram), "-nographic",
                "-drive", f"if=none,file={disk},format=raw,id=d0", "-device", "virtio-blk-pci,drive=d0",
                "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0", "-device", "virtio-rng-pci"]
        if boot == "uboot":
            return argv + ["-bios", firmware]
        argv += ["-kernel", kernel, "-append", append]
        return argv + (["-initrd", initrd] if initrd_on else [])
    argv = [a.tuxvm, "--ram", str(a.ram), "--cpus", str(a.cpus), "--disk", disk]
    if boot == "uboot":
        return argv + ["--firmware", firmware]
    argv += ["--kernel", kernel, "--append", append]
    return argv + (["--initrd", initrd] if initrd_on else [])


def expect(p, pat, limit, what):
    try:
        p.expect(pat, timeout=limit)
    except pexpect.TIMEOUT:
        raise RuntimeError(f"{what}: no {pat!r} in {limit} s; buffer {p.buffer[-200:]!r}")
    except pexpect.EOF:
        raise RuntimeError(f"{what}: the machine stopped before {pat!r}")


def uboot_cmd(p, cmd, limit):
    """Runs a U-Boot command; returns (output, wall seconds)."""
    t = time.monotonic()
    p.sendline(cmd)
    expect(p, re.escape(cmd) + r"\r*\n", limit, cmd)
    expect(p, r"=> ", limit, cmd)
    out = p.before.replace("\r", "")
    if re.search(r"Failed|ERROR|Unknown command", out):
        raise RuntimeError(f"{cmd}: {out.strip()}")
    return out, time.monotonic() - t


def one(a, machine, boot, initrd_on, files, tmp):
    kernel, initrd, firmware = files
    disk = os.path.join(tmp, "disk.img")
    subprocess.run(["/bin/cp", "-c", os.path.join(a.dir, "debian-console.img"), disk], check=True)
    uuid = open(os.path.join(a.dir, "debian-console.partuuid")).read().strip()
    append = f"root=PARTUUID={uuid} rw console=ttyAMA0 printk.time=1 panic=0"
    argv = argv_for(a, machine, boot, initrd_on, disk, files, append)
    st, res = Stamp(), {}
    t0 = time.monotonic()
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
    p.logfile_read = st
    lim = a.limit
    try:
        if boot == "uboot":
            expect(p, r"U-Boot 20\d\d\.\d\d", lim, "banner")
            res["banner"] = time.monotonic() - t0
            expect(p, r"Hit any key to stop autoboot", lim, "countdown")
            p.send(" ")
            expect(p, r"=> ", lim, "prompt")
            res["uboot_prompt"] = time.monotonic() - t0
            _, res["load_kernel"] = uboot_cmd(p, f"ext4load virtio 0:1 ${{kernel_addr_r}} /boot/vmlinuz-{KVER}", lim)
            if initrd_on:
                _, res["load_initrd"] = uboot_cmd(
                    p, f"ext4load virtio 0:1 ${{ramdisk_addr_r}} /boot/initrd.img-{KVER}", lim)
                rd = "${ramdisk_addr_r}:${filesize}"
            else:
                rd = "-"
            uboot_cmd(p, f'setenv bootargs "{append}"', lim)
            p.sendline(f"booti ${{kernel_addr_r}} {rd} ${{fdt_addr}}")
            expect(p, r"Starting kernel \.\.\.", lim, "booti")
        t_kernel = time.monotonic()
        res["uboot_total"] = t_kernel - t0
        if initrd_on:
            expect(p, gu.shell(), lim, "login")
            res["login"] = time.monotonic() - t_kernel
            p.sendline("cat /proc/uptime")
            expect(p, r"(\d+\.\d+) \d+\.\d+\r*\n", 10, "uptime")
            res["uptime_at_login"] = float(p.match.group(1))
        else:
            expect(p, r"Kernel panic - not syncing", lim, "root fail")
            time.sleep(0.3)
    finally:
        p.terminate(force=True)
        p.close()
        if a.console_dir:
            with open(os.path.join(a.console_dir, f"{machine}-{boot}-{'on' if initrd_on else 'off'}-{time.time():.0f}.log"), "w") as f:
                f.write("\n".join(f"{w - t0:8.3f} {ln}" for w, ln in st.lines))
    for ts_wall, ln in st.lines:
        m = re.match(r"\[\s*(\d+\.\d+)\] (.*)", ln)
        if not m:
            continue
        for name, pat in MARKS:
            if name not in res and re.search(pat, m.group(2)):
                if name == "systemd" and "mounted" not in res:
                    continue
                res[name] = float(m.group(1))
    return res


def summarize(rows):
    keys = []
    for r in rows:
        keys += [k for k in r if k not in keys]
    return {k: {"min": min(v), "median": statistics.median(v), "max": max(v), "n": len(v)}
            for k in keys for v in [[r[k] for r in rows if k in r]]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--machine", nargs="+", choices=["tux", "qemu"], default=["qemu", "tux"])
    ap.add_argument("--boot", nargs="+", choices=["direct", "uboot"], default=["uboot", "direct"])
    ap.add_argument("--initrd", nargs="+", choices=["on", "off"], default=["on", "off"])
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--cpus", type=int, default=1)
    ap.add_argument("--ram", type=int, default=2048)
    ap.add_argument("--limit", type=int, default=300, help="seconds for each wait")
    ap.add_argument("--dir", default=None, help="artefact directory")
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--work-dir", default=None, help="for the disk clone; on the image's volume")
    ap.add_argument("--console-dir", default=None, help="keep each console log here, with host seconds")
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    a.dir = a.dir or linux_dir()
    gu.use(os.path.join(a.dir, "debian-console.img"))
    # The countdown is stopped to type commands, so use the stock build when there is one (P2)
    fw = next((f for f in (os.path.join(a.dir, "u-boot-stock.bin"), os.path.join(a.dir, "u-boot.bin")) if os.path.exists(f)),
              os.path.join(a.dir, "u-boot.bin"))
    files = (os.path.join(a.dir, "Image"), os.path.join(a.dir, "initrd.img"), fw)
    for f in files + (a.tuxvm,):
        if not os.path.exists(f):
            sys.exit(f"missing {f}")
    out = {"load": os.getloadavg(), "cpus": a.cpus, "ram": a.ram, "kernel": KVER, "runs": {}}
    for machine, boot, onoff in itertools.product(a.machine, a.boot, a.initrd):
        name = f"{machine}-{boot}-initrd-{onoff}"
        rows = []
        for i in range(a.runs):
            tmp = tempfile.mkdtemp(prefix="kbt-", dir=a.work_dir)
            try:
                rows.append(one(a, machine, boot, onoff == "on", files, tmp))
                print(f"{name} run {i + 1}: " + " ".join(f"{k}={v:.2f}" for k, v in rows[-1].items()), flush=True)
            except RuntimeError as e:
                print(f"{name} run {i + 1}: FAILED {e}", flush=True)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        out["runs"][name] = {"rows": rows, "summary": summarize(rows) if rows else {}}
    out["load_end"] = os.getloadavg()
    print("\nmedian (min-max) seconds")
    for name, r in out["runs"].items():
        print(name + ": " + ", ".join(f"{k} {v['median']:.2f} ({v['min']:.2f}-{v['max']:.2f})"
                                       for k, v in r["summary"].items()))
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
