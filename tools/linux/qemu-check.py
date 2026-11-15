#!/usr/bin/env -S uv run --with pexpect python3
"""Drive tools/linux/qemu-ref.sh through U-Boot and Linux, check the guest and save reference output."""
import argparse
import os
import re
import subprocess
import sys
import time

import pexpect
import guest_user as gu

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("TUX_LINUX_OUT") or os.path.join(os.path.dirname(subprocess.run(
    ["git", "-C", HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True, check=True).stdout.strip()), "build", "linux")
PROMPT = r"[$#] $"  # tux@host:~$ or root@host:~# (tux-guest 1.11.0, no account marker)
MARK = "TUX_DONE_"
# No userspace knob gives the VA size: the modules segment in /proc/kcore starts at PAGE_END = -(1 << (VA - 1))
GUEST_VA = (
    'import struct as s;f=open("/proc/kcore","rb");h=f.read(64);o=s.unpack_from("<Q",h,32)[0];'
    'e,n=s.unpack_from("<HH",h,54);f.seek(o);v=[s.unpack_from("<QQ",f.read(e),16) for _ in range(n)];'
    "pe=min(a for a,p in v if p==2**64-1 and a>>56==255);print((2**64-pe).bit_length())"
)


def run(child, cmd, timeout=120):
    # Marker tells our command output apart from the echo
    child.sendline(f"{cmd}; echo {MARK}$?")
    child.expect(rf"{MARK}(\d+)\r*\n", timeout=timeout)
    text = child.before.decode(errors="replace")
    text = re.sub(rf"^(\x1b\[[0-9;?]*[a-zA-Z])*{gu.user()}@{gu.host()}:[^$]*\$ ", "", text)
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text).replace("\r", "")
    return text.strip("\n"), int(child.match.group(1))


def save(path, text):
    with open(path, "w") as f:
        f.write(text.rstrip("\n") + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--direct", action="store_true", help="direct kernel boot (use with --accel hvf)")
    ap.add_argument("--accel", default="tcg")
    ap.add_argument("--ref", default=os.path.join(OUT, "ref"), help="reference output directory")
    ap.add_argument("--tag", default="", help="suffix for saved files")
    ap.add_argument("--boot-timeout", type=int, default=900)
    ap.add_argument("--no-save", action="store_true")
    ap.add_argument("--its-off", action="store_true", help="no ITS: MSI-X absent, INTx used")
    args = ap.parse_args()
    gu.use(os.path.join(OUT, "debian-console.img"))

    os.makedirs(args.ref, exist_ok=True)
    cmd = [os.path.join(HERE, "qemu-ref.sh"), "--accel", args.accel]
    if args.direct:
        cmd.append("--direct")
    if args.its_off:
        cmd.append("--its-off")
    log = open(os.path.join(args.ref, f"console{args.tag}.log"), "wb")
    t0 = time.time()
    child = pexpect.spawn(cmd[0], cmd[1:], timeout=args.boot_timeout)
    child.logfile_read = log
    results = {}
    ok = True

    def check(name, cond, detail):
        nonlocal ok
        results[name] = (cond, detail)
        ok &= cond
        print(f"{'PASS' if cond else 'FAIL'} {name}: {detail}", flush=True)

    if not args.direct:
        child.expect("Hit any key to stop autoboot")
        child.send(" ")
        child.expect(r"=> ")
        for name, uboot_cmd in [("pci", "pci"), ("virtio-info", "virtio info"), ("bootflow-scan", "bootflow scan -l")]:
            child.sendline(uboot_cmd)
            child.expect(r"=> ", timeout=120)
            text = child.before.decode(errors="replace").replace("\r", "")
            text = text.split("\n", 1)[1] if "\n" in text else text
            if not args.no_save:
                save(os.path.join(args.ref, f"uboot-{name}{args.tag}.txt"), text)
        child.sendline("boot")

    # Autologin shell or a login prompt, whichever comes first
    i = child.expect([PROMPT, r"login: $"], timeout=args.boot_timeout)
    boot_s = time.time() - t0
    check("login", True, f"{'shell' if i == 0 else 'login prompt'} after {boot_s:.1f}s")
    if i == 1:
        child.sendline(gu.user())
        child.expect(PROMPT)
    gu.to_user(child, timeout=60)
    child.sendline("bind 'set enable-bracketed-paste off'; stty -echo")
    child.expect(PROMPT)

    def get(cmd, **kw):
        return run(child, cmd, **kw)

    page, _ = get("getconf PAGESIZE")
    check("pagesize", page.strip() == "16384", page.strip())
    nproc, _ = get("nproc")
    check("nproc", nproc.strip() == "4", nproc.strip())
    addr, _ = get("ip -4 -o addr show scope global 2>/dev/null || ifconfig 2>/dev/null")
    check("network", bool(re.search(r"\d+\.\d+\.\d+\.\d+", addr)), addr.replace("\n", " | "))
    va, _ = get(f"sudo -n python3 -c '{GUEST_VA}'")
    va_bits = int(va) if va.isnumeric() else 0
    check("va-size", 39 <= va_bits <= 52, f"run-time kernel VA bits {va_bits}")

    dmesg, _ = get("sudo -n dmesg")
    cpuinfo, _ = get("cat /proc/cpuinfo")
    lspci, rc = get("lspci -nn 2>&1")
    irq, _ = get("cat /proc/interrupts")
    sysfs_pci, _ = get("for d in /sys/bus/pci/devices/*; do echo \"$(basename $d) $(cat $d/vendor) $(cat $d/device) $(cat $d/class)\"; done")
    uname, _ = get("uname -a; cat /proc/cmdline; grep -E 'MemTotal' /proc/meminfo")
    if not args.no_save:
        t = args.tag
        save(os.path.join(args.ref, f"dmesg{t}.txt"), dmesg)
        save(os.path.join(args.ref, f"cpuinfo{t}.txt"), cpuinfo)
        save(os.path.join(args.ref, f"lspci{t}.txt"), lspci if rc == 0 else "lspci missing\n" + sysfs_pci)
        save(os.path.join(args.ref, f"pci-sysfs{t}.txt"), sysfs_pci)
        save(os.path.join(args.ref, f"interrupts{t}.txt"), irq)
        save(os.path.join(args.ref, f"uname{t}.txt"), uname)
        save(os.path.join(args.ref, f"boot-time{t}.txt"), f"login after {boot_s:.1f}s\n")

    t1 = time.time()
    child.sendline("sudo -n poweroff || poweroff")
    try:
        child.expect(pexpect.EOF, timeout=120)
        child.close()
        check("poweroff", True, f"QEMU exited in {time.time() - t1:.1f}s")
    except pexpect.TIMEOUT:
        check("poweroff", False, "QEMU still running after 120s")
        child.terminate(force=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
