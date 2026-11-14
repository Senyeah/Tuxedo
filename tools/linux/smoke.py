#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Guest smoke test over the serial console.

--direct: direct kernel boot (Image and initrd.img) to the (initramfs) prompt,
then cat /proc/cpuinfo, uname -m, reboot -f to the prompt again, and poweroff -f,
which must end tuxvm with status 0. With --no-reboot, reboot -f must end it
with status 3 instead. --fatal sends tuxvm SIGILL at the prompt instead: its
crash report must still reach stderr with the terminal in raw mode. --qemu runs
the same checks on QEMU's virt machine (hvf), and --qemu --tux-dtb gives QEMU
Henge's device tree (E8 step 1).
--direct --disk: the same kernel with an APFS clone of debian-console.img as the
root disk (E9). After autologin it checks systemd, the disk, the page size, the
CPU count, the network (10.0.2.15, ping 10.0.2.2, DNS), the virtio entropy
device, the RTC and dmesg errors, writes 256 MB and syncs, powers off, boots the
clone again and compares the checksum.
--uboot: the same checks on the same clone, booted by U-Boot (u-boot.bin in flash) through
extlinux.conf instead of a direct kernel boot (E10). The first boot is unattended and times
U-Boot's steps; the second stops the countdown, checks pci, virtio info and bootflow scan -l
at the U-Boot prompt, then boots and compares the checksum. --qemu runs it on QEMU with TCG.
--stress, with --uboot or --direct --disk: the several-CPU checks (E11). One boot of a clone of --image
(default debian-console.img), then the CPU count, no CPU that failed to come online, stress-ng --cpu N
--vm 2 --vm-bytes 256M for 60 s, and make -jN of cproject.sh's project, whose program must print the
checksum that the same project gives on the Mac. No kernel warning may appear. stress-ng, gcc and make
are installed with apt (network through slirp) when the image has none.
--power, with --uboot or --direct --disk (E12): after the --disk checks, four boots of a fresh clone. Each writes 64 MB
without sync and then ends the machine a different way, and the next boot must find the file whole and the root filesystem
clean (no journal recovery): sudo reboot (tuxvm builds the machine again; the guest comes back), the power key as SIGTERM
(Debian shuts down by itself, exit status 0), the power key as Ctrl-A p, and two SIGTERMs (the second stops the machine at
once). --qemu has no power key (see power_key), no Ctrl-A p and no second SIGTERM: sudo poweroff takes their place.
Exit 1 on any failed check; the last 200 lines of console output go to stderr.
"""
import argparse
import base64
import collections
import gzip
import os
import re
import signal
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CPROJECT = os.path.join(ROOT, "tools", "linux", "cproject.sh")
CPROJECT_UNITS = 48
QEMU = os.environ.get("QEMU", "/opt/homebrew/bin/qemu-system-aarch64")
APPEND = "console=ttyAMA0 earlycon=pl011,0x9000000 break=top"
PROMPT = r"\(initramfs\) "

# Seconds: three times the slowest of five runs (prompt 2.8 s). Commands (0.1 s) and poweroff (0.2 s)
# get a 5 s floor instead, as three times those is inside scheduling noise (E8 findings).
LIMITS = {"prompt": 9, "command": 5, "poweroff": 5}

SHELL = r"henge@henge:\S*\$ "  # not anchored: a kernel line can follow it in the same read
MARK = "TUX_RC_"  # ends each --disk command; its echo shows "$?", never digits
# Add a pattern only with a note in the findings log.
DMESG_ALLOW = [
    # E9: port 2 says speed ID 2 (low speed in xHCI), and a low-speed ep0 must be 8 bytes; the trackpad is D5's.
    r"usb 1-2: Invalid ep0 maxpacket: 64",
    r"usb usb1-port2: unable to enumerate USB device",
]
# --disk, seconds: three times the slowest of five runs at 1 CPU (login 10.6 s, the 256 MB write 1.6 s,
# poweroff 1.7 s), with the same 5 s floor (E9 findings). 4 CPUs are faster. Login is 60 s: at load 60+
# (other jobs on the Mac) it took 29 s or more (E12 review).
DISK_LIMITS = {"login": 60, "running": 5, "command": 5, "network": 5, "write": 5, "poweroff": 6}
# --uboot, seconds: three times the slowest of five runs at 1 CPU (kernel to login 9.5 s; the longest
# U-Boot step is its 2 s countdown) (E10 findings). Banner, step and login limits are wider for a busy Mac:
# the banner took 4.7 s and the login 28 s at load 15 to 60 (E12 review).
UBOOT_LIMITS = {"banner": 15, "uboot step": 15, "uboot command": 10, "login": 60}
# QEMU runs U-Boot under TCG only (hvf aborts on it), which is several times slower.
QEMU_TCG_SCALE = 4
UBOOT_PROMPT = r"=> "
# --power, seconds: three times the slowest of five runs at 1 CPU (sudo reboot to the banner 1.5 s, the power key to the
# exit 1.4 s, the second SIGTERM to the exit 0.4 s). Wider for a busy Mac (E12 review).
POWER_LIMITS = {"restart": 15, "power key": 10, "stop": 10}
# --stress, seconds. The install depends on snapshot.debian.org (105 s at 4 CPUs); stress-ng runs for 60 s.
STRESS_LIMITS = {"install": 900, "stress": 180, "build": 600}
STRESS_PACKAGES = "stress-ng build-essential"
KERNEL_BAD = (r"WARNING:|BUG:|Oops|Call trace:|soft lockup|hard LOCKUP|rcu: INFO|detected stall|"
              r"blocked for more than|failed to come online|Unable to handle|Internal error|segfault|"
              r"unhandled|Out of memory")
# Warning-level lines that --stress allows: sudo's audit records hit printk's rate limit (E11).
STRESS_ALLOW = DMESG_ALLOW + [r"kauditd_printk_skb: \d+ callbacks suppressed"]


def linux_dir():
    """TUX_LINUX_OUT, else build/linux in the main checkout (worktrees share it)."""
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
    try:
        common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
        return os.path.join(os.path.dirname(common), "build", "linux")
    except (OSError, subprocess.CalledProcessError):
        return os.path.join(ROOT, "build", "linux")


class Tail:
    """Keeps the last lines of the console for a failure report."""

    def __init__(self, n=200):
        self.lines, self.part = collections.deque(maxlen=n), ""

    def write(self, s):
        s = self.part + s.replace("\r", "")
        *done, self.part = s.split("\n")
        self.lines.extend(done)

    def flush(self):
        pass

    def text(self):
        return "\n".join(list(self.lines) + [self.part])


class Fail(Exception):
    pass


def command(args, kernel, initrd, tmp, append=APPEND, disk=None, firmware=None):
    """argv for the machine under test. tuxvm's stderr goes to a file so the console stays clean."""
    if args.qemu and firmware:
        return [QEMU, "-M", "virt,gic-version=3,highmem=off,its=off", "-accel", "tcg", "-cpu", "max",
                "-smp", str(args.cpus), "-m", str(args.ram), "-nographic", "-bios", firmware,
                "-drive", f"if=none,file={disk},format=raw,id=d0", "-device", "virtio-blk-pci,drive=d0",
                "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0", "-device", "virtio-rng-pci",
                "-device", "qemu-xhci", "-device", "usb-kbd"]
    if args.qemu:
        argv = [QEMU, "-M", "virt,gic-version=3,highmem=off", "-accel", "hvf", "-cpu", "host",
                "-smp", str(args.cpus), "-m", str(args.ram), "-nographic",
                "-kernel", kernel, "-initrd", initrd] + (["-no-reboot"] if args.no_reboot else [])
        if disk:
            argv += ["-drive", f"if=none,file={disk},format=raw,id=d0", "-device", "virtio-blk-pci,drive=d0",
                     "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0", "-device", "virtio-rng-pci"]
        if not args.tux_dtb:
            return argv + ["-append", append]
        # Tuxedo's tree carries the command line; QEMU adds only the initrd range.
        dtb = os.path.join(tmp, "henge.dtb")
        r = subprocess.run([args.tuxvm, "--dump-dtb", dtb, "--append", append,
                            "--ram", str(args.ram), "--cpus", str(args.cpus)], capture_output=True, text=True)
        if r.returncode != 0:
            raise Fail(f"tuxvm --dump-dtb failed: {r.stderr.strip()}")
        return argv + ["-dtb", dtb]
    boot = ["--firmware", firmware] if firmware else ["--kernel", kernel, "--initrd", initrd, "--append", append]
    argv = [args.tuxvm] + boot + ["--ram", str(args.ram), "--cpus", str(args.cpus),
                                                        "--log", str(args.log)]
    if disk:
        argv += ["--disk", disk]
    if args.no_reboot:
        argv.append("--no-reboot")
    if args.phone:
        argv.append("--phone")
    return ["/bin/sh", "-c", 'exec "$@" 2>"$0"', os.path.join(tmp, "stderr")] + argv


def expect(p, pattern, limit, what):
    try:
        p.expect(pattern, timeout=limit)
    except pexpect.TIMEOUT:
        raise Fail(f"{what}: no match for {pattern!r} within {limit} s")
    except pexpect.EOF:
        raise Fail(f"{what}: the machine stopped before {pattern!r}")


def run_cmd(p, cmd, limit):
    """Sends cmd at the prompt and returns its output."""
    p.sendline(cmd)
    expect(p, re.escape(cmd) + r"\r*\n", limit, cmd)
    expect(p, PROMPT, limit, cmd)
    return p.before.replace("\r", "")


def stopped(p, status_want, line, stderr, args):
    """The machine has ended: check its exit status and tuxvm's stop line."""
    p.close()
    status = p.exitstatus if p.exitstatus is not None else 128 + (p.signalstatus or 0)
    if status != status_want:
        raise Fail(f"exit status {status}, expected {status_want}")
    if not args.qemu and f"tuxvm: stopped: {line}" not in stderr():
        raise Fail(f"no 'tuxvm: stopped: {line}' line on stderr")


def boot(p):
    expect(p, "Kernel command line: " + re.escape(APPEND) + r"\r*\n", LIMITS["prompt"], "boot")
    expect(p, PROMPT, LIMITS["prompt"], "boot")


def direct(args, times):
    d = args.linux_dir or linux_dir()
    kernel, initrd = os.path.join(d, "Image"), os.path.join(d, "initrd.img")
    for f in (kernel, initrd):
        if not os.path.exists(f):
            raise Fail(f"missing {f} (set TUX_LINUX_OUT or --linux-dir)")
    tail = Tail()
    with tempfile.TemporaryDirectory(prefix="smoke-") as tmp:
        argv = command(args, kernel, initrd, tmp)
        stderr = lambda: open(os.path.join(tmp, "stderr"), errors="replace").read() if not args.qemu else ""
        t0 = time.monotonic()
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
        p.logfile_read = tail
        try:
            boot(p)
            times["prompt"] = time.monotonic() - t0
            if args.fatal:
                os.kill(p.pid, signal.SIGILL)
                expect(p, pexpect.EOF, LIMITS["poweroff"], "SIGILL")
                p.close()
                if p.signalstatus != signal.SIGILL:
                    raise Fail(f"exit status {p.exitstatus}, signal {p.signalstatus}; expected death by SIGILL")
                if "tuxvm: signal 4 in translated code" not in stderr():
                    raise Fail("no crash report from vm.c's handler on stderr")
                return
            t = time.monotonic()
            info = run_cmd(p, "cat /proc/cpuinfo", LIMITS["command"])
            n = len(re.findall(r"^processor\s*:", info, re.M))
            if n != args.cpus:
                raise Fail(f"/proc/cpuinfo lists {n} processors, expected {args.cpus}")
            if not re.search(r"^Features\s*:.*\bfp\b", info, re.M):
                raise Fail("/proc/cpuinfo has no Features line")
            arch = run_cmd(p, "uname -m", LIMITS["command"]).strip()
            if arch != "aarch64":
                raise Fail(f"uname -m printed {arch!r}")
            times["commands"] = time.monotonic() - t
            t = time.monotonic()
            p.sendline("reboot -f")
            if args.no_reboot:
                expect(p, pexpect.EOF, LIMITS["poweroff"], "reboot")
                times["reboot"] = time.monotonic() - t
                stopped(p, 0 if args.qemu else 3, "guest restart", stderr, args)
                return
            # The second boot must keep the console: the prompt has no newline to flush it.
            boot(p)
            times["restart"] = time.monotonic() - t
            if run_cmd(p, "uname -m", LIMITS["command"]).strip() != "aarch64":
                raise Fail("uname -m after the restart")
            t = time.monotonic()
            p.sendline("poweroff -f")
            expect(p, pexpect.EOF, LIMITS["poweroff"], "poweroff")
            times["poweroff"] = time.monotonic() - t
            stopped(p, 0, "guest shutdown", stderr, args)
        except Fail:
            report(p, tail, stderr)
            raise


def report(p, tail, stderr):
    if p.isalive():
        p.terminate(force=True)
        p.close()
    tail.write("\n")
    print(f"--- last console lines ---\n{tail.text()}\n--- tuxvm stderr (end) ---\n{stderr()[-4000:]}",
          file=sys.stderr)


def sh(p, cmd, limit):
    """Runs cmd in the guest's shell: its output and exit status."""
    p.sendline(f"{cmd}; echo {MARK}$?")
    expect(p, MARK + r"(\d+)\r*\n", limit, cmd)
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    return re.sub(r"^henge@henge:[^\n$]*\$ ", "", out), int(p.match.group(1))


def check(p, cmd, limit, ok, what):
    out, rc = sh(p, cmd, limit)
    if rc != 0 or not ok(out.strip()):
        raise Fail(f"{what}: {cmd!r} gave status {rc} and {out.strip()[-2000:]!r}")
    return out.strip()


def login(p, append, limit=DISK_LIMITS["login"]):
    end = time.monotonic() + limit
    left = lambda: max(0.1, end - time.monotonic())
    if append:  # extlinux.conf says quiet, which hides this line
        expect(p, "Kernel command line: " + re.escape(append) + r"\r*\n", left(), "boot")
    expect(p, r"\(automatic login\)", left(), "autologin")
    expect(p, SHELL, left(), "autologin")
    # Quiet the console first: kernel lines in the middle of output break the parsing. The marker
    # is printed after that, and its echo has no "42" (sudo drops typed-ahead lines).
    p.sendline(f"stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
    expect(p, MARK + r"42\r*\n", DISK_LIMITS["command"], "quiet the console")


def poweroff(p, stderr, args, times, key, scale=1):
    t = time.monotonic()
    p.sendline("sudo poweroff")
    expect(p, pexpect.EOF, DISK_LIMITS["poweroff"] * scale, "poweroff")
    times[key] = time.monotonic() - t
    stopped(p, 0, "guest shutdown", stderr, args)


def stock_firmware(d):
    """The build that keeps the autoboot countdown, for checks that stop at the prompt (u-boot.bin has none since P2)."""
    f = os.path.join(d, "u-boot-stock.bin")
    return f if os.path.exists(f) else os.path.join(d, "u-boot.bin")


def uboot_boot(p, times, scale):
    """U-Boot from the banner to the kernel, unattended; times each step (the P2 baseline)."""
    t0 = time.monotonic()
    expect(p, r"U-Boot 20\d\d\.\d\d", UBOOT_LIMITS["banner"] * scale, "U-Boot banner")
    times["banner"] = time.monotonic() - t0
    # Read-only flash 1 holds no saved environment (risk row 1).
    expect(p, r"bad CRC, using default environment", UBOOT_LIMITS["uboot step"] * scale, "U-Boot environment")
    t = time.monotonic()
    # The stock build counts down 2 s here; the build with the P2 fragment prints "autoboot: 0" and goes on.
    expect(p, r"Hit any key to stop autoboot", UBOOT_LIMITS["uboot step"] * scale, "U-Boot devices")
    times["devices"] = time.monotonic() - t
    for name, pattern in [("countdown", r"Scanning for bootflows"), ("extlinux", r"Starting kernel \.\.\.")]:
        t = time.monotonic()
        expect(p, pattern, UBOOT_LIMITS["uboot step"] * scale, f"U-Boot {name}")
        times[name] = time.monotonic() - t


def uboot_cmd(p, cmd, scale):
    p.sendline(cmd)
    expect(p, re.escape(cmd) + r"\r*\n", UBOOT_LIMITS["uboot command"] * scale, cmd)
    expect(p, UBOOT_PROMPT, UBOOT_LIMITS["uboot command"] * scale, cmd)
    return p.before.replace("\r", "")


def uboot_checks(p, image, times, scale):
    """Stops the countdown and checks U-Boot's view of the board against QEMU's (build/linux/ref)."""
    t = time.monotonic()
    expect(p, r"Hit any key to stop autoboot", UBOOT_LIMITS["banner"] * scale, "U-Boot countdown")
    p.send(" ")
    expect(p, UBOOT_PROMPT, UBOOT_LIMITS["uboot step"] * scale, "U-Boot prompt")
    times["uboot prompt"] = time.monotonic() - t
    t = time.monotonic()
    pci = uboot_cmd(p, "pci", scale)
    # Tuxedo's virtio is modern only (0x104x); QEMU's is transitional (0x100x).
    for what, pattern in [("host bridge", r"00\.00\.00\s+0x1b36\s+0x0008\s+Bridge"),
                          ("virtio block", r"0x1af4\s+0x10(42|01)\s+Mass storage"),
                          ("virtio network", r"0x1af4\s+0x10(41|00)\s+Network"),
                          ("virtio entropy", r"0x1af4\s+0x10(44|05)\s"),
                          ("xHCI", r"0x1b36\s+0x000d\s+Serial bus")]:
        if not re.search(pattern, pci):
            raise Fail(f"U-Boot pci: no {what}:\n{pci}")
    info = uboot_cmd(p, "virtio info", scale)
    mb = f"{os.path.getsize(image) / (1 << 20):.1f} MB"
    if "VirtIO Block Device" not in info or f"Capacity: {mb}" not in info:
        raise Fail(f"U-Boot virtio info: no {mb} block device:\n{info}")
    scan = uboot_cmd(p, "bootflow scan -l", scale)
    for what, pattern in [("extlinux on the disk",
                           r"extlinux\s+ready\s+virtio\s+1\s+\S+\s+/boot/extlinux/extlinux\.conf"),
                          ("DHCP", r"DHCP client bound to address 10\.0\.2\.15"),
                          ("every bootflow valid", r"\((\d+) bootflows, \1 valid\)")]:
        if not re.search(pattern, scan):
            raise Fail(f"U-Boot bootflow scan -l: no {what}:\n{scan}")
    times["uboot commands"] = time.monotonic() - t
    p.sendline("boot")
    expect(p, r"Starting kernel \.\.\.", UBOOT_LIMITS["uboot step"] * scale, "U-Boot boot")


def disk(args, times):
    d = args.linux_dir or linux_dir()
    kernel, initrd, image = (os.path.join(d, f) for f in ("Image", "initrd.img", "debian-console.img"))
    firmware = os.path.join(d, "u-boot.bin") if args.uboot else None
    for f in [image, image[:-4] + ".partuuid"] + ([firmware] if args.uboot else [kernel, initrd]):
        if not os.path.exists(f):
            raise Fail(f"missing {f} (set TUX_LINUX_OUT or --linux-dir)")
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    scale = QEMU_TCG_SCALE if args.uboot and args.qemu else 1
    limit = lambda k: DISK_LIMITS[k] * scale
    with tempfile.TemporaryDirectory(prefix="smoke-", dir=args.work_dir) as tmp:
        clone = os.path.join(tmp, "disk.img")
        # The shared image never changes: the guest writes to a clone that costs no space until then.
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode != 0:
            raise Fail(f"cannot clone {image} into {tmp} (it needs the same APFS volume; see --work-dir): "
                       f"{r.stderr.strip()}")
        stderr = lambda: open(os.path.join(tmp, "stderr"), errors="replace").read() if not args.qemu else ""
        for boot_no in (1, 2):
            # Boot 2 stops the countdown, so it needs the stock build.
            fw = stock_firmware(d) if args.uboot and boot_no == 2 else firmware
            argv = command(args, kernel, initrd, tmp, append, clone, fw)
            tail = Tail()
            t0 = time.monotonic()
            p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
            p.logfile_read = tail
            try:
                if args.uboot:
                    if boot_no == 1:
                        uboot_boot(p, times, scale)
                    else:
                        uboot_checks(p, image, times, scale)
                    t = time.monotonic()
                    login(p, None, UBOOT_LIMITS["login"] * scale)
                    times["kernel to login" + (" again" if boot_no == 2 else "")] = time.monotonic() - t
                else:
                    login(p, append)
                times["login" if boot_no == 1 else "login again"] = time.monotonic() - t0
                if boot_no == 2:
                    t = time.monotonic()
                    check(p, "sha256sum /var/tmp/t", limit("write"),
                          lambda o: o.split()[:1] == [digest], "checksum after a power off")
                    times["checksum"] = time.monotonic() - t
                    poweroff(p, stderr, args, times, "poweroff again", scale)
                    return
                if args.uboot:  # extlinux.conf, not --append, gave the command line
                    check(p, "cat /proc/cmdline", limit("command"),
                          lambda o: f"root=PARTUUID={partuuid}" in o.split(), "extlinux command line")
                t = time.monotonic()
                check(p, "systemctl is-system-running --wait || systemctl --failed --no-pager",
                      limit("running"), lambda o: o == "running", "systemd")
                times["running"] = time.monotonic() - t
                t = time.monotonic()
                check(p, "dpkg-query -W -f='${db:Status-Abbrev} ${Package}\\n' henge-guest", limit("command"),
                      lambda o: o == "ii  henge-guest", "henge-guest package")
                check(p, "systemctl is-enabled henge-firstboot.service henge-grow.service "
                      "home-henge-Henge.automount", limit("command"),
                      lambda o: o.split() == ["enabled", "enabled", "enabled"], "henge-guest units enabled")
                check(p, "lsblk -rno NAME,TYPE,MOUNTPOINTS /dev/vda", limit("command"),
                      lambda o: "vda1 part /" in o.split("\n"), "root on virtio-blk")
                check(p, "getconf PAGESIZE", limit("command"), lambda o: o == "16384", "page size")
                check(p, "nproc", limit("command"), lambda o: o == str(args.cpus), "CPU count")
                check(p, "uname -m", limit("command"), lambda o: o == "aarch64", "machine")
                year = str(time.gmtime().tm_year)
                check(p, "date -u +%Y", limit("command"), lambda o: o == year, "RTC")
                check(p, "cat /sys/class/misc/hw_random/rng_current", limit("command"),
                      lambda o: o.startswith("virtio_rng"), "entropy device")
                check(p, "sudo dd if=/dev/hwrng bs=64 count=1 status=none | od -An -v -tx1 | tr -d ' \\n'",
                      limit("command"), lambda o: len(o) == 128 and o.strip("0") != "", "bytes from /dev/hwrng")
                times["commands"] = time.monotonic() - t
                t = time.monotonic()
                # DHCP can finish after systemd says running.
                check(p, "for i in $(seq 40); do ip -4 -o addr show scope global | grep -q 'inet 10\\.0\\.2\\.15/' "
                      "&& break; sleep 0.1; done; ip -4 -o addr show scope global", limit("network"),
                      lambda o: "inet 10.0.2.15/24" in o, "address")
                check(p, "sudo ping -c1 -W5 10.0.2.2", limit("network"), lambda o: " 0% packet loss" in o,
                      "ping the host")
                check(p, "getent hosts deb.debian.org", limit("network"),
                      lambda o: re.search(r"^[0-9a-f.:]+\s.*\bdeb\.debian\.org$", o, re.M), "name resolution")
                times["network"] = time.monotonic() - t
                errors = check(p, "sudo dmesg --level=err,crit,alert,emerg", limit("command"),
                               lambda o: True, "dmesg")
                bad = [l for l in errors.split("\n") if l and not any(re.search(a, l) for a in DMESG_ALLOW)]
                if bad:
                    raise Fail("kernel errors not on the allow list:\n" + "\n".join(bad))
                t = time.monotonic()
                out = check(p, "dd if=/dev/urandom of=/var/tmp/t bs=1M count=256 status=none && sync && "
                            "sha256sum /var/tmp/t", limit("write"),
                            lambda o: re.match(r"[0-9a-f]{64}\s", o), "write 256 MB")
                digest = out.split()[0]
                times["write"] = time.monotonic() - t
                poweroff(p, stderr, args, times, "poweroff", scale)
            except Fail:
                report(p, tail, stderr)
                raise


def power_key(p, args, how):
    """Presses the guest's power key: SIGTERM or Ctrl-A p for tuxvm. On the -bios path QEMU has no gpio-keys
    (it builds an ACPI GED), so there the guest powers itself off."""
    if args.qemu:
        p.sendline("sudo poweroff")
    elif how == "sigterm":
        os.kill(p.pid, signal.SIGTERM)
    else:
        p.send("\x01p")


def wait_for_logind_keys(p):
    """logind must watch gpio-keys before the key; an earlier press is lost (E12 review)."""
    check(p, "( for i in $(seq 150); do sudo journalctl -b -u systemd-logind --no-pager | "
          "grep -q 'Watching system buttons.*gpio-keys' && exit 0; sleep 0.2; done; exit 1 )",
          DISK_LIMITS["command"] + 30, lambda o: True, "logind watching gpio-keys")
    time.sleep(1)


def power(args, times):
    d = args.linux_dir or linux_dir()
    kernel, initrd, image = (os.path.join(d, f) for f in ("Image", "initrd.img", "debian-console.img"))
    firmware = os.path.join(d, "u-boot.bin") if args.uboot else None
    for f in [image, image[:-4] + ".partuuid"] + ([firmware] if args.uboot else [kernel, initrd]):
        if not os.path.exists(f):
            raise Fail(f"missing {f} (set TUX_LINUX_OUT or --linux-dir)")
    partuuid = open(image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    scale = QEMU_TCG_SCALE if args.uboot and args.qemu else 1
    lim = lambda k: POWER_LIMITS[k] * scale
    cmd = DISK_LIMITS["command"]
    with tempfile.TemporaryDirectory(prefix="smoke-", dir=args.work_dir) as tmp:
        clone = os.path.join(tmp, "disk.img")
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode != 0:
            raise Fail(f"cannot clone {image} into {tmp} (it needs the same APFS volume; see --work-dir): "
                       f"{r.stderr.strip()}")
        stderr = lambda: open(os.path.join(tmp, "stderr"), errors="replace").read() if not args.qemu else ""
        st = {}

        def start():
            argv = command(args, kernel, initrd, tmp, append, clone, firmware)
            st["tail"] = Tail()
            st["p"] = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
            st["p"].logfile_read = st["tail"]

        def up(what):
            """From a start or a restart to the shell; returns the seconds it took."""
            t = time.monotonic()
            if args.uboot:
                uboot_boot(st["p"], {}, scale)
                login(st["p"], None, UBOOT_LIMITS["login"] * scale)
            else:
                login(st["p"], append)
            return time.monotonic() - t

        def clean(p, name, digest):
            check(p, f"sha256sum /var/tmp/{name}", cmd, lambda o: o.split()[:1] == [digest], "file after " + what)
            check(p, "sudo dmesg | grep -E 'EXT4-fs \\(vda1\\): (recovery|orphan)' || echo clean", cmd,
                  lambda o: o == "clean", "root filesystem after " + what)

        def write(p, name):
            out = check(p, f"dd if=/dev/urandom of=/var/tmp/{name} bs=1M count=64 status=none && sha256sum "
                        f"/var/tmp/{name}", DISK_LIMITS["write"], lambda o: re.match(r"[0-9a-f]{64}\s", o),
                        "write 64 MB without sync")
            return out.split()[0]

        def ends(how, key, want_line, what_t):
            """Ends the running machine; it must exit 0 with tuxvm's stop line."""
            p = st["p"]
            if not args.qemu:
                wait_for_logind_keys(p)
            t = time.monotonic()
            power_key(p, args, how)
            expect(p, pexpect.EOF, lim(key), what_t)
            times[what_t] = time.monotonic() - t
            stopped(p, 0, want_line, stderr, args)

        try:
            start()
            up("first boot")
            p = st["p"]
            what, digest = "sudo reboot", write(p, "r1")
            t = time.monotonic()
            p.sendline("sudo reboot")
            if args.uboot:
                expect(p, r"U-Boot 20\d\d\.\d\d", lim("restart"), "restart")
                times["reboot to banner"] = time.monotonic() - t
                # the banner has gone; take the rest of U-Boot's steps as uboot_boot does
                expect(p, r"Starting kernel \.\.\.", UBOOT_LIMITS["uboot step"] * 3 * scale, "U-Boot after the restart")
                login(p, None, UBOOT_LIMITS["login"] * scale)
            else:
                expect(p, "Kernel command line: ", lim("restart"), "restart")
                times["reboot to kernel"] = time.monotonic() - t
                login(p, None)
            times["reboot to login"] = time.monotonic() - t
            if not args.qemu and "tuxvm: guest restart" not in stderr():
                raise Fail("no 'tuxvm: guest restart' line on stderr")
            clean(p, "r1", digest)

            what, digest = "the power key (SIGTERM)", write(p, "r2")
            ends("sigterm", "power key", "guest shutdown", "power key")
            start()
            up(what)
            p = st["p"]
            clean(p, "r2", digest)

            if not args.qemu:
                what, digest = "the power key (Ctrl-A p)", write(p, "r3")
                ends("ctrl-a", "power key", "guest shutdown", "ctrl-a p")
                start()
                up(what)
                p = st["p"]
                clean(p, "r3", digest)
                # the second SIGTERM stops the machine without the guest; no gap (the source merges them)
                wait_for_logind_keys(p)
                t = time.monotonic()
                os.kill(p.pid, signal.SIGTERM)
                os.kill(p.pid, signal.SIGTERM)
                expect(p, pexpect.EOF, lim("stop"), "second SIGTERM")
                times["second SIGTERM"] = time.monotonic() - t
                stopped(p, 0, "interrupted", stderr, args)
            else:
                ends("sigterm", "power key", "guest shutdown", "power key again")
        except Fail:
            report(st["p"], st["tail"], stderr)
            raise


def send_file(p, path, dest):
    """Copies a host file into the guest over the console, in lines the tty accepts."""
    data = base64.b64encode(gzip.compress(open(path, "rb").read())).decode()
    lines = [f": > {dest}.b64"] + [f"echo {data[i:i + 1024]} >> {dest}.b64" for i in range(0, len(data), 1024)]
    for line in lines + [f"base64 -d {dest}.b64 | gunzip > {dest} && rm {dest}.b64"]:
        check(p, line, DISK_LIMITS["command"], lambda o: True, "send " + dest)


def cproject_sum(tmp, units):
    """What the guest's ./prog must print: the same project built on the Mac."""
    d = os.path.join(tmp, "cproject")
    r = subprocess.run(f"sh '{CPROJECT}' '{d}' {units} && make -s -C '{d}' -j4 >/dev/null && '{d}/prog'",
                       shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise Fail(f"cproject.sh on the Mac failed: {r.stderr.strip()[-2000:]}")
    return r.stdout.strip()


def kernel_bad(p, what):
    out = check(p, "sudo dmesg", DISK_LIMITS["command"], lambda o: True, "dmesg")
    bad = [l for l in out.split("\n") if re.search(KERNEL_BAD, l)]
    if bad:
        raise Fail(f"kernel warnings {what}:\n" + "\n".join(bad[:40]))


def stress(args, times):
    d = args.linux_dir or linux_dir()
    kernel, initrd = os.path.join(d, "Image"), os.path.join(d, "initrd.img")
    image = args.image or os.path.join(d, "debian-console.img")
    partuuid = os.path.join(d, "debian-console.partuuid")
    firmware = os.path.join(d, "u-boot.bin") if args.uboot else None
    for f in [image, partuuid] + ([firmware] if args.uboot else [kernel, initrd]):
        if not os.path.exists(f):
            raise Fail(f"missing {f} (set TUX_LINUX_OUT or --linux-dir)")
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={open(partuuid).read().strip()} rw"
    n, scale = args.cpus, QEMU_TCG_SCALE if args.uboot and args.qemu else 1
    cmd = DISK_LIMITS["command"]
    with tempfile.TemporaryDirectory(prefix="smoke-", dir=args.work_dir) as tmp:
        want = cproject_sum(tmp, CPROJECT_UNITS)
        clone = os.path.join(tmp, "disk.img")
        r = subprocess.run(["/bin/cp", "-c", image, clone], capture_output=True, text=True)
        if r.returncode != 0:
            raise Fail(f"cannot clone {image} into {tmp} (it needs the same APFS volume; see --work-dir): "
                       f"{r.stderr.strip()}")
        stderr = lambda: open(os.path.join(tmp, "stderr"), errors="replace").read() if not args.qemu else ""
        argv = command(args, kernel, initrd, tmp, append, clone, firmware)
        tail = Tail()
        t0 = time.monotonic()
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200))
        p.logfile_read = tail
        try:
            if args.uboot:
                uboot_boot(p, {}, scale)
                login(p, None, UBOOT_LIMITS["login"] * scale)
            else:
                login(p, append)
            times["login"] = time.monotonic() - t0
            check(p, "nproc", cmd, lambda o: o == str(n), "CPU count")
            up = f"smp: Brought up 1 node, {n} CPU" + ("s" if n > 1 else "")
            check(p, "sudo dmesg | grep -E 'smp: Brought up|failed to come online'", cmd,
                  lambda o: o.endswith(up) and o.count("\n") == 0, "CPUs online")
            kernel_bad(p, "at boot")
            _, rc = sh(p, "command -v stress-ng gcc make >/dev/null", cmd)
            if rc != 0:
                t = time.monotonic()
                apt = "sudo DEBIAN_FRONTEND=noninteractive apt-get -q -o Acquire::Check-Valid-Until=false"
                check(p, f"{{ {apt} update && {apt} install -y --no-install-recommends {STRESS_PACKAGES}; }} "
                      ">/var/tmp/apt.log 2>&1 || { tail -n 20 /var/tmp/apt.log; false; }",
                      STRESS_LIMITS["install"] * scale, lambda o: True, "install " + STRESS_PACKAGES)
                times["install"] = time.monotonic() - t
            # From here only the workloads' kernel lines count.
            check(p, "sudo dmesg -C", cmd, lambda o: True, "dmesg -C")
            t = time.monotonic()
            out = check(p, f"stress-ng --cpu {n} --vm 2 --vm-bytes 256M --timeout 60s --metrics-brief 2>&1",
                        STRESS_LIMITS["stress"] * scale, lambda o: "successful run completed" in o, "stress-ng")
            times["stress-ng"] = time.monotonic() - t
            # bogo ops/s (real time) per stressor, to compare runs
            for m in re.finditer(r"metrc: \[\d+\]\s+(cpu|vm)\s+\d+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+([\d.]+)", out):
                print(f"smoke: stress-ng {m.group(1)}: {m.group(2)} bogo ops/s")
            kernel_bad(p, "after stress-ng")
            send_file(p, CPROJECT, "/var/tmp/cproject.sh")
            t = time.monotonic()
            check(p, f"sh /var/tmp/cproject.sh /var/tmp/proj {CPROJECT_UNITS} && make -s -C /var/tmp/proj -j{n} "
                  f"2>&1 && /var/tmp/proj/prog", STRESS_LIMITS["build"] * scale,
                  lambda o: o.split("\n")[-1] == want, f"make -j{n} (./prog must print {want})")
            times["make"] = time.monotonic() - t
            kernel_bad(p, "after make")
            errors = check(p, "sudo dmesg --level=warn,err,crit,alert,emerg", cmd, lambda o: True, "dmesg")
            bad = [l for l in errors.split("\n") if l and not any(re.search(a, l) for a in STRESS_ALLOW)]
            if bad:
                raise Fail("kernel warnings during the workloads:\n" + "\n".join(bad[:40]))
            poweroff(p, stderr, args, times, "poweroff", scale)
        except Fail:
            report(p, tail, stderr)
            raise


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--direct", action="store_true", help="direct kernel boot to the initramfs")
    ap.add_argument("--disk", action="store_true", help="with --direct: boot a clone of debian-console.img")
    ap.add_argument("--uboot", action="store_true", help="boot a clone of debian-console.img through U-Boot")
    ap.add_argument("--stress", action="store_true", help="with --uboot or --direct --disk: the E11 checks")
    ap.add_argument("--image", help="--stress: the disk to clone (default debian-console.img)")
    ap.add_argument("--work-dir", help="--disk, --uboot: where the clone goes (the image's APFS volume; default TMPDIR)")
    ap.add_argument("--power", action="store_true", help="with --uboot or --direct --disk: the E12 checks")
    ap.add_argument("--qemu", action="store_true", help="run the checks on QEMU instead of tuxvm")
    ap.add_argument("--tux-dtb", action="store_true", help="with --qemu: boot QEMU with tuxvm --dump-dtb's tree")
    ap.add_argument("--cpus", type=int, default=1)
    ap.add_argument("--ram", type=int, default=2048, help="MB")
    ap.add_argument("--phone", action="store_true", help="pass --phone to tuxvm")
    ap.add_argument("--no-reboot", action="store_true", help="reboot -f must stop the machine (tuxvm: status 3)")
    ap.add_argument("--fatal", action="store_true", help="SIGILL at the prompt must give vm.c's crash report")
    ap.add_argument("--log", type=int, default=1, help="tuxvm --log level")
    ap.add_argument("--runs", type=int, default=1, help="boot this many times; all must pass")
    ap.add_argument("--linux-dir", help="directory with Image, initrd.img, u-boot.bin and debian-console.img")
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    args = ap.parse_args()
    if args.direct == args.uboot:
        ap.error("give one of --direct and --uboot")
    if args.uboot and (args.disk or args.tux_dtb):
        ap.error("--uboot boots the disk already, and --tux-dtb is for --qemu --direct")
    if args.tux_dtb and not args.qemu:
        ap.error("--tux-dtb needs --qemu")
    if args.fatal and args.qemu:
        ap.error("--fatal is for tuxvm")
    if args.stress and not (args.disk or args.uboot):
        ap.error("--stress needs --uboot or --direct --disk")
    if args.power and not (args.disk or args.uboot):
        ap.error("--power needs --uboot or --direct --disk")
    if args.power and args.stress:
        ap.error("--power and --stress are separate runs")
    if args.image and not args.stress:
        ap.error("--image is for --stress")
    if (args.disk or args.uboot) and (args.no_reboot or args.fatal):
        ap.error("--disk and --uboot do not take --no-reboot or --fatal")
    worst = {}
    for i in range(args.runs):
        times = {}
        try:
            (stress if args.stress else disk if args.disk or args.uboot else direct)(args, times)
            if args.power:
                power(args, times)
        except Fail as e:
            print(f"smoke: run {i + 1}: FAIL: {e}", file=sys.stderr)
            sys.exit(1)
        print("smoke: run %d: pass (%s)" % (i + 1, ", ".join(f"{k} {v:.1f} s" for k, v in times.items())))
        for k, v in times.items():
            worst[k] = max(worst.get(k, 0), v)
    if args.runs > 1:
        print("smoke: slowest: " + ", ".join(f"{k} {v:.1f} s" for k, v in worst.items()))


if __name__ == "__main__":
    main()
