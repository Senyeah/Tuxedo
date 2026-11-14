#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""P10 check: the Linux virtio_balloon driver binds to Henge's balloon and inflating returns host memory.

Boots a clone of the image on the virt board with HV_BALLOON=0 and drives the target through HV_INPUT_FILE
("balloon MB", "balloonstat"). It checks that:
  1. the guest driver binds, and the guest's MemTotal falls by the inflated amount (each 16 KB guest page is
     four 4 KB protocol units, the device counts a host page once all four quarters are in);
  2. the device's counters show about the inflated amount given back, with no partial pages or failures,
     and the host process's physical footprint falls after the guest dirtied and freed that memory;
  3. deflating hands the pages back to the guest;
  4. with --load: the guest survives an inflate by half of its free memory during a package build (apt
     install of build-essential, then make -j of cproject.sh) and a memory stress, and nothing is killed.
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
OUT = os.environ.get("HENGE_LINUX_OUT", "$HOME/Repos/Henge/build/linux")
SHELL = r"henge@henge:\S*\$ "
MARK = "HENGE_RC_"
CPROJECT = os.path.join(ROOT, "tools", "linux", "cproject.sh")
BAD_LOG = r"Out of memory|oom-kill|oom_reaper|Killed process|invoked oom|page allocation failure|Call trace|BUG:|WARNING:"


class Fail(Exception):
    pass


class Vm:
    def __init__(self, args, disk, tmp):
        self.args, self.disk = args, disk
        self.input = os.path.join(tmp, "input.txt")
        self.err = os.path.join(tmp, "hengevm.stderr")
        open(self.input, "w").close()

    def boot(self):
        a = self.args
        env = dict(os.environ, HV_BALLOON="0", HV_INPUT_FILE=self.input)
        if a.ram_file:
            env["HV_RAM_FILE"] = os.path.join(os.path.dirname(self.input), "ram")
            env["HV_RAM_NO_LEDGER"] = "1"
        cmd = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', self.err, a.hengevm, "--firmware", a.firmware, "--ram", str(a.ram), "--cpus", str(a.cpus), "--disk", self.disk]
        self.p = p = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", timeout=60, env=env)
        p.expect(r"\(automatic login\)", timeout=120)
        p.expect(SHELL, timeout=30)
        p.sendline(f"set +m; stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
        p.expect(MARK + r"42\r*\n", timeout=30)
        self.need("systemctl is-system-running --wait", lambda o: o == "running", "system state", 120)
        return p

    def sh(self, cmd, limit=30):
        p = self.p
        p.sendline(f"{cmd}; echo {MARK}$?")
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
        out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
        out = re.sub(r"^henge@henge:[^\n$]*\$ ", "", out)
        return out.strip(), int(p.match.group(1))

    def need(self, cmd, ok, what, limit=30):
        out, rc = self.sh(cmd, limit)
        if rc != 0 or not ok(out):
            raise Fail(f"{what}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
        return out

    def meminfo(self, key):
        return int(self.need(f"awk '/^{key}:/ {{print $2}}' /proc/meminfo", str.isdigit, key)) // 1024  # MB

    def stat(self):
        """Ask hengevm for the balloon counters (HV_INPUT_FILE is polled every 200 ms)."""
        pat = re.compile(r"balloon: actual (\d+) MB, given back (\d+) MB, taken back (\d+) MB, partial (\d+), "
                         r"out of ram (\d+), failed (\d+)")
        seen = len(pat.findall(open(self.err).read()))
        with open(self.input, "a") as f:
            f.write("balloonstat\n")
        for _ in range(100):
            time.sleep(0.1)
            found = pat.findall(open(self.err).read())
            if len(found) > seen:
                return dict(zip(("actual", "given", "taken", "partial", "oor", "failed"), map(int, found[-1])))
        raise Fail("hengevm did not answer balloonstat: " + open(self.err).read()[-800:])

    def target(self, mb):
        with open(self.input, "a") as f:
            f.write(f"balloon {mb}\n")

    def wait_actual(self, mb, limit, slack=8):
        t = time.monotonic()
        while time.monotonic() - t < limit:
            s = self.stat()
            if abs(s["actual"] - mb) <= slack:
                return s, time.monotonic() - t
            time.sleep(1)
        raise Fail(f"the guest never reached {mb} MB in the balloon; the host sees {self.stat()}")

    def footprint(self):
        """The host process's physical footprint in MB (what iOS's memory limit counts)."""
        pid = self.p.pid  # sh execs hengevm
        fp = self.err + ".fp.json"
        subprocess.run(["footprint", "-j", fp, "-p", str(pid)], capture_output=True)
        try:
            m = re.search(r'"footprint"\s*:\s*(\d+)', open(fp).read())
        except OSError:
            return None
        if not m:
            return None
        if self.args.ram_file:  # the unlinked RAM file is not in the footprint, and its holes cannot be seen from outside
            return None
        return int(m.group(1)) / (1 << 20)

    def kernel_ok(self, what):
        out, _ = self.sh(f"sudo dmesg | grep -E '{BAD_LOG}' | head -5")
        if out:
            raise Fail(f"{what}: kernel messages: {out}")

    def poweroff(self):
        self.p.sendline("sudo poweroff")
        self.p.expect(pexpect.EOF, timeout=60)


def basic(vm, args):
    drv = vm.sh("ls /sys/bus/virtio/drivers/virtio_balloon/ 2>/dev/null | grep -c '^virtio'")[0]
    if drv != "1":
        mod, _ = vm.sh("lsmod | grep -c virtio_balloon; modinfo virtio_balloon 2>&1 | head -2")
        raise Fail(f"the guest driver is not bound to the balloon ({mod!r})")
    print("  driver: virtio_balloon is bound")
    vm.need("sudo dmesg | grep -iE 'balloon' | grep -iE 'fail|error|unsupported' | wc -l", lambda o: o == "0", "driver messages")
    total0 = vm.meminfo("MemTotal")  # with DEFLATE_ON_OOM the kernel keeps MemTotal and takes the pages from MemFree
    # dirty memory the guest then frees: its host pages stay resident until the balloon takes them
    dirty = min(args.mb + 256, total0 // 2 - 64)
    vm.need(f"dd if=/dev/urandom of=/dev/shm/dirty bs=1M count={dirty} status=none && rm /dev/shm/dirty",
            lambda o: True, "dirty the guest's memory", 180)
    free0 = vm.meminfo("MemFree")
    fp0 = vm.footprint()
    print(f"  guest MemTotal {total0} MB; host footprint {fp0 or 0:.0f} MB after dirtying {dirty} MB and freeing it")
    t0 = vm.stat()
    vm.target(args.mb)
    s, took = vm.wait_actual(args.mb, 120)
    time.sleep(4)  # the guest's free lists settle
    total1 = vm.meminfo("MemTotal")
    free1 = vm.meminfo("MemFree")
    fp1 = vm.footprint()
    got = s["given"] - t0["given"]
    print(f"  inflate {args.mb} MB: {took:.1f} s, guest MemFree {free0} -> {free1} MB, device gave back {got} MB, "
          f"partial {s['partial']}, out of RAM {s['oor']}, failed {s['failed']}; host footprint {fp1 or 0:.0f} MB")
    if abs((total0 - total1) + (free0 - free1) - args.mb) > args.mb // 4:  # MemFree is noisy: other guest activity moves it
        raise Fail(f"the guest's MemTotal fell by {total0 - total1} MB and MemFree by {free0 - free1} MB, not {args.mb} MB")
    if got < args.mb * 0.97 or got > args.mb * 1.03:
        raise Fail(f"the device returned {got} MB of the {args.mb} MB asked")
    if s["partial"] or s["oor"] or s["failed"]:
        raise Fail(f"the device counted partial pages, pages outside RAM or failures: {s}")
    if fp0 is not None and fp1 is not None:
        fell = fp0 - fp1
        print(f"  host footprint fell by {fell:.0f} MB")
        if fell < args.mb * 0.5:
            raise Fail(f"the host footprint fell by only {fell:.0f} MB after a {args.mb} MB inflate")
    vm.target(0)
    s, took = vm.wait_actual(0, 60)
    free2 = vm.meminfo("MemFree")
    print(f"  deflate: {took:.1f} s, guest MemFree {free2} MB, taken back {s['taken'] - t0['taken']} MB")
    if free2 < free0 - 32:
        raise Fail(f"deflate left MemFree at {free2} MB of {free0} MB")
    vm.kernel_ok("after inflate and deflate")


def load(vm, args):
    _, rc = vm.sh("command -v gcc make stress-ng >/dev/null")
    if rc != 0:
        vm.need("sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive "
                "apt-get -y -qq install build-essential stress-ng >/var/tmp/apt.log 2>&1; tail -3 /var/tmp/apt.log",
                lambda o: True, "install build-essential and stress-ng", 900)
        vm.need("command -v gcc make stress-ng", lambda o: o.count("/") >= 3, "tools installed")
    vm.need("mkdir -p /var/tmp/proj", lambda o: True, "dir")
    src = subprocess.check_output(["/bin/cat", CPROJECT]).decode()
    vm.p.sendline("cat > /var/tmp/cproject.sh <<'HENGE_EOF'\n" + src + "HENGE_EOF")
    vm.need("sh /var/tmp/cproject.sh /var/tmp/proj 48 && echo ok", lambda o: o.endswith("ok"), "project", 60)
    want = subprocess.check_output(["/bin/sh", "-c", f"d=$(mktemp -d) && sh {CPROJECT} $d 48 && make -s -C $d -j4 "
                                    f">/dev/null 2>&1 && $d/prog"], text=True).strip()
    free0 = vm.meminfo("MemAvailable")
    ask = free0 // 2
    print(f"  load: guest MemAvailable {free0} MB, will inflate by {ask} MB during the build")
    # stress holds 512 MB x 2 and the build runs on all CPUs; both end by themselves
    vm.sh("(stress-ng --vm 2 --vm-bytes 384M --timeout 150s >/var/tmp/stress.log 2>&1; echo $? >/var/tmp/stress.rc) & true")
    vm.sh("(for i in 1 2 3; do make -s -C /var/tmp/proj clean >/dev/null 2>&1; make -s -C /var/tmp/proj -j4 "
          ">/var/tmp/make.log 2>&1 || echo fail >>/var/tmp/make.log; done; /var/tmp/proj/prog >/var/tmp/prog.out; "
          "echo done >/var/tmp/make.done) & true")
    time.sleep(10)
    free1 = vm.meminfo("MemAvailable")
    ask = free1 // 2
    t0 = vm.stat()
    vm.target(ask)
    s, took = vm.wait_actual(ask, 180, slack=16)
    print(f"  inflated {ask} MB under load in {took:.1f} s (host gave back {s['given'] - t0['given']} MB)")
    for _ in range(100):
        out, _ = vm.sh("cat /var/tmp/make.done 2>/dev/null")
        if out == "done":
            break
        time.sleep(3)
    else:
        raise Fail("the build under load did not finish")
    prog, _ = vm.sh("cat /var/tmp/prog.out; grep -c fail /var/tmp/make.log")
    if prog.split("\n")[0] != want or prog.split("\n")[-1] != "0":
        raise Fail(f"the build under load gave {prog!r}, wanted {want!r} and no failure")
    print(f"  build under load: ./prog printed {want}, no make failure")
    vm.need("while [ ! -f /var/tmp/stress.rc ]; do sleep 2; done; cat /var/tmp/stress.rc", lambda o: o.split()[-1] == "0",
            "stress-ng ended cleanly", 200)
    killed, _ = vm.sh("pgrep -c systemd-journal; sudo dmesg | grep -cE 'Out of memory|oom-kill|Killed process'")
    vm.kernel_ok("under load")
    vm.target(0)
    vm.wait_actual(0, 90)
    print("  load: nothing killed, balloon deflated again")


def overshoot(vm, args):
    """Ask for nearly all of RAM while stress-ng holds memory: the driver must give pages back instead of the kernel killing."""
    total = vm.meminfo("MemTotal")
    vm.sh("rm -f /var/tmp/stress.rc; (stress-ng --vm 2 --vm-bytes 512M --timeout 60s >/var/tmp/stress.log 2>&1; "
          "echo $? >/var/tmp/stress.rc) & true")
    time.sleep(8)
    ask = total - 256
    t0 = vm.stat()
    vm.target(ask)
    time.sleep(40)
    s = vm.stat()
    vm.need("while [ ! -f /var/tmp/stress.rc ]; do sleep 2; done; cat /var/tmp/stress.rc", lambda o: True, "stress end", 120)
    bad, _ = vm.sh(f"sudo dmesg | grep -E '{BAD_LOG}' | head -3")
    left = vm.meminfo("MemTotal")
    print(f"  overshoot: asked {ask} MB of {total} MB; the guest holds {s['actual']} MB, MemTotal {left} MB, "
          f"taken back {s['taken'] - t0['taken']} MB; kernel messages: {bad or 'none'}")
    if bad:
        raise Fail(f"overshoot: {bad}")
    vm.target(0)
    vm.wait_actual(0, 90)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(OUT, "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(OUT, "u-boot.bin"))
    ap.add_argument("--hengevm", default=os.path.join(ROOT, "build", "hengevm"))
    ap.add_argument("--size-gb", type=int, default=6)
    ap.add_argument("--mb", type=int, default=512, help="size of the first inflate")
    ap.add_argument("--ram", type=int, default=2048)
    ap.add_argument("--cpus", type=int, default=2)
    ap.add_argument("--ram-file", action="store_true", help="guest RAM in a file (holes), as on iOS, instead of anonymous")
    ap.add_argument("--load", action="store_true", help="also inflate during a package build and a stress run")
    ap.add_argument("--overshoot", action="store_true", help="with --load: also ask for almost all RAM during a stress run")
    ap.add_argument("--save-image", help="keep the used disk here (with the packages --load installed) for later --image runs")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="balloon-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    vm = None
    try:
        subprocess.run(["/bin/cp", "-c", args.image, disk], check=True)
        os.truncate(disk, args.size_gb << 30)
        vm = Vm(args, disk, tmp)
        vm.boot()
        basic(vm, args)
        if args.load:
            load(vm, args)
            if args.overshoot:
                overshoot(vm, args)
        vm.need("sudo dmesg --level=err,crit,alert,emerg | grep -vE 'usb 1-2|usb1-port2' | wc -l",
                lambda o: o == "0", "dmesg errors")
        vm.poweroff()
        if args.save_image:
            subprocess.run(["/bin/cp", "-c", disk, args.save_image], check=True)
        print("balloon-check: PASS")
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"balloon-check: FAIL: {e}", file=sys.stderr)
        if vm:
            print("console tail:\n" + (vm.p.before or "")[-3000:], file=sys.stderr)
            try:
                print("hengevm stderr tail:\n" + open(vm.err).read()[-1500:], file=sys.stderr)
            except OSError:
                pass
        return 1
    finally:
        if vm and vm.p.isalive():
            vm.p.terminate(force=True)
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
