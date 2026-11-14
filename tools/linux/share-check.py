#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""P6 check: the shared folder at ~/Henge in the guest is the --share directory on the Mac.

Boot 1 has --share. It checks the automount and the mount, create, rename, delete, names with
spaces and non-ASCII characters, a 100 MB copy each way, the lock traffic, and that a file written
just before poweroff reaches the Mac. Boot 2 has no --share: the machine must reach "running", and
a visit to ~/Henge must fail in time and not hang.
The image needs davfs2 and henge-guest 1.1 (--image FILE names a rebuilt copy). The shared image never
changes: the guest writes to a clone. Exit 1 on a failed check.
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHELL = r"henge@henge:\S*\$ "
MARK = "TUX_RC_"
MB = 1 << 20


class Fail(Exception):
    pass


def argv(args, disk, share):
    # tuxvm's stderr goes to a file so it cannot break the console parsing
    cmd = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', disk + ".stderr", args.tuxvm, "--firmware", args.firmware, "--ram", "2048", "--cpus", str(args.cpus), "--disk", disk]
    return cmd + (["--share", share] if share else [])


def sh(p, cmd, limit=30):
    p.sendline(f"{cmd}; echo {MARK}$?")
    p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
    out = re.sub(r"^henge@henge:[^\n$]*\$ ", "", out)
    return out.strip(), int(p.match.group(1))


def need(p, cmd, ok=lambda o: True, what="", limit=30):
    out, rc = sh(p, cmd, limit)
    if rc != 0 or not ok(out):
        raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
    return out


def boot(args, disk, share):
    a = argv(args, disk, share)
    p = pexpect.spawn(a[0], a[1:], encoding="utf-8", timeout=60)
    p.expect(r"\(automatic login\)", timeout=120)
    p.expect(SHELL, timeout=30)
    p.sendline(f"stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
    p.expect(MARK + r"42\r*\n", timeout=30)
    need(p, "systemctl is-system-running --wait", lambda o: o == "running", "system state", 120)
    return p


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(MB), b""):
            h.update(block)
    return h.hexdigest()


def wait_host(what, test, limit=60):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if test():
            return
        time.sleep(0.2)
    raise Fail(f"{what}: not seen on the Mac within {limit} s")


def nfc(names):
    return {unicodedata.normalize("NFC", n) for n in names}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(ROOT, "build", "linux", "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(ROOT, "build", "linux", "u-boot.bin"))
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--cpus", type=int, default=2)
    ap.add_argument("--size-mb", type=int, default=100, help="size of the copy test in each direction")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="share-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    # tuxvm listens on "<share>.sock", and a unix socket path is limited to 103 characters
    share = tempfile.mkdtemp(prefix="shc-", dir="/tmp")
    p = None
    try:
        subprocess.run(["/bin/cp", "-c", args.image, disk], check=True)
        p = boot(args, disk, share)
        home = "/home/henge/Henge"

        need(p, "systemctl is-enabled home-henge-Henge.automount", lambda o: o == "enabled", "automount enabled")
        need(p, "systemctl is-active home-henge-Henge.automount", lambda o: o == "active", "automount active")
        need(p, "systemctl is-active home-henge-Henge.mount; true", lambda o: o == "inactive", "not mounted before use")
        t = time.monotonic()
        need(p, f"ls -la {home}", what="first visit", limit=60)
        print(f"  first visit mounts the share: {time.monotonic() - t:.2f} s")
        need(p, f"findmnt -n -t fuse -o FSTYPE,SOURCE {home}", lambda o: o.split() == ["fuse", "http://10.0.2.4/"],
             "mount type and source")
        need(p, f"stat -c %U:%G {home}", lambda o: o == "henge:henge", "owner of the folder")
        need(p, f"touch {home}/owned && stat -c %U {home}/owned", lambda o: o == "henge", "owner of a new file")
        need(p, f"rm {home}/owned")

        # Create, rename, delete
        need(p, f"echo hello > {home}/a.txt", what="create")
        wait_host("create", lambda: os.path.exists(f"{share}/a.txt") and open(f"{share}/a.txt").read() == "hello\n")
        need(p, f"mv {home}/a.txt {home}/b.txt", what="rename")
        wait_host("rename", lambda: os.path.exists(f"{share}/b.txt") and not os.path.exists(f"{share}/a.txt"))
        need(p, f"mkdir {home}/dir && echo deep > {home}/dir/c.txt && mv {home}/b.txt {home}/dir/b.txt", what="folder")
        wait_host("folder", lambda: os.path.exists(f"{share}/dir/b.txt") and os.path.exists(f"{share}/dir/c.txt"))
        need(p, f"rm {home}/dir/b.txt && rm -r {home}/dir", what="delete")
        wait_host("delete", lambda: not os.path.exists(f"{share}/dir"))
        print("  create, rename, move into a folder and delete reach the Mac")

        # A file made on the Mac shows in the guest (dir_refresh is 5 s)
        with open(f"{share}/from-mac.txt", "w") as f:
            f.write("from the mac\n")
        need(p, f"for i in $(seq 60); do [ -e {home}/from-mac.txt ] && break; sleep 0.5; done; cat {home}/from-mac.txt",
             lambda o: o == "from the mac", "a file made on the Mac")
        os.remove(f"{share}/from-mac.txt")
        need(p, f"for i in $(seq 60); do [ -e {home}/from-mac.txt ] || break; sleep 0.5; done; ! [ -e {home}/from-mac.txt ]",
             what="a file removed on the Mac")
        print("  Mac-side create and delete show in the guest")

        # Names
        names = ["with space.txt", "café.txt", "日本語.txt", "emoji \U0001f600.txt",
                 "it's a \"quote\" & more #1 %20.txt", "  lead and trail  .txt"]
        for i, n in enumerate(names):
            # printf with the name in single quotes via python-made octal escapes keeps the console ASCII
            esc = "".join(f"\\{b:03o}" for b in n.encode())
            need(p, f"printf '{esc}' > /tmp/name{i}; printf 'x{i}' > \"$(cat /tmp/name{i})\"; mv \"$(cat /tmp/name{i})\" {home}/\"$(cat /tmp/name{i})\"",
                 what=f"create name {i}")
        def names_whole():
            have = {unicodedata.normalize("NFC", x): x for x in os.listdir(share)}
            for i, n in enumerate(names):
                real = have.get(unicodedata.normalize("NFC", n))
                if real is None or open(f"{share}/{real}").read() != f"x{i}":
                    return False
            return True
        wait_host("names", names_whole)
        # Mac-made names, read in the guest
        mac_names = ["müsli bar.txt", "été 2026.txt"]
        for n in mac_names:
            with open(f"{share}/{n}", "w") as f:
                f.write(n)
        need(p, f"for i in $(seq 60); do [ $(ls {home} | grep -c 'sli bar\\|t.. 2026') -ge 2 ] && break; sleep 0.5; done; "
                f"cat {home}/m*sli*bar.txt; echo; cat {home}/*2026.txt",
             lambda o: all(n in o for n in mac_names), "names made on the Mac")
        need(p, f"rm -f {home}/*.txt")
        wait_host("names removed", lambda: not [x for x in os.listdir(share) if x.endswith(".txt")])
        print(f"  {len(names)} names with spaces, quotes and non-ASCII characters go guest to Mac, "
              f"{len(mac_names)} Mac to guest")

        # Big copies
        size = args.size_mb
        need(p, f"dd if=/dev/urandom of=/tmp/big bs=1M count={size} status=none", limit=120)
        want = need(p, "sha256sum /tmp/big", lambda o: re.match(r"[0-9a-f]{64}", o), "hash", 60).split()[0]
        t = time.monotonic()
        need(p, f"cp /tmp/big {home}/big.bin", what="copy in", limit=600)
        wait_host("copy in", lambda: os.path.exists(f"{share}/big.bin") and os.path.getsize(f"{share}/big.bin") == size * MB, 600)
        wait_host("copy in", lambda: sha(f"{share}/big.bin") == want, 600)
        up = size / (time.monotonic() - t)
        print(f"  {size} MB guest to Mac arrived whole ({up:.1f} MB/s)")
        # The Mac to the guest: a temp name and a rename, so that the guest never lists half a file
        with open(f"{share}/.part", "wb") as f:
            for _ in range(size):
                f.write(os.urandom(MB))
        os.rename(f"{share}/.part", f"{share}/mac.bin")
        mac_sha = sha(f"{share}/mac.bin")
        t = time.monotonic()
        need(p, f"for i in $(seq 60); do [ -e {home}/mac.bin ] && break; sleep 0.5; done; cp {home}/mac.bin /tmp/back && "
                f"sha256sum /tmp/back", lambda o: o.split()[0] == mac_sha, "copy out", 600)
        print(f"  {size} MB Mac to guest arrived whole ({size / (time.monotonic() - t):.1f} MB/s)")
        need(p, f"rm {home}/big.bin {home}/mac.bin /tmp/big /tmp/back", what="clean up", limit=60)
        wait_host("clean up", lambda: not os.path.exists(f"{share}/big.bin") and not os.path.exists(f"{share}/mac.bin"))

        # Locks: the server accepts them and does not enforce them. davfs2 asks for one on a write.
        need(p, f"exec 7>{home}/locked.txt; echo one >&7; flock -n 7 echo flock-ok; exec 7>&-",
             lambda o: "flock-ok" in o, "a file held open for writing")
        need(p, "sudo journalctl -b --no-pager -t mount.davfs -t davfs2 | grep -ci 'lock\\|error\\|fail\\|warn' || true",
             lambda o: o == "0", "davfs2 messages about locks or errors")
        need(p, f"rm {home}/locked.txt")
        need(p, "sudo dmesg --level=err,crit,alert | grep -vE 'usb 1-2|usb1-port2' | wc -l", lambda o: o == "0",
             "dmesg errors")

        # A write right before poweroff must reach the Mac: the unmount uploads it
        need(p, f"head -c 3000000 /dev/urandom > {home}/last.bin; sha256sum {home}/last.bin > /tmp/last.sha")
        last = need(p, "cat /tmp/last.sha").split()[0]
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=90)
        wait_host("the file written before poweroff", lambda: os.path.exists(f"{share}/last.bin") and sha(f"{share}/last.bin") == last, 10)
        print("  a file written just before poweroff reached the Mac")
        p = None

        # No share: boot must reach running, and the folder must give up in time and not hang
        p = boot(args, disk, None)
        need(p, "systemctl is-active home-henge-Henge.automount", lambda o: o == "active", "automount active")
        t = time.monotonic()
        out, rc = sh(p, f"ls {home}", 90)
        waited = time.monotonic() - t
        if waited > 60:
            raise Fail(f"a visit to {home} without the share took {waited:.0f} s")
        # davfs2 mounts offline after its connect timeouts: an empty folder, and writes fail
        out2, rc2 = sh(p, f"touch {home}/x", 60)
        if rc2 == 0:
            raise Fail("a write succeeded with no share")
        print(f"  without --share the visit ends after {waited:.1f} s (ls status {rc}, shows {out!r}); "
              f"a write fails: {out2.split(': ')[-1]}")
        print("  system state: " + need(p, "systemctl is-system-running; systemctl list-units --failed --no-legend | cat"
                                        ).replace("\n", " | "))
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=90)
        print("share-check: PASS")
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"share-check: FAIL: {e}", file=sys.stderr)
        try:
            print("console tail:\n" + (p.before or "")[-3000:], file=sys.stderr)
            err = open(disk + ".stderr").read()
            print("tuxvm stderr tail:\n" + err[-2000:], file=sys.stderr)
        except Exception:
            pass
        return 1
    finally:
        if p is not None and p.isalive():
            p.terminate(force=True)
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(share, ignore_errors=True)
        if os.path.exists(share + ".sock"):
            os.remove(share + ".sock")
    return 0


if __name__ == "__main__":
    sys.exit(main())
