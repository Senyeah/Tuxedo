#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""FM6 check: the folders from the Files app at /media/henge/<name> (virtio-fs and henge-files).

Boot 0 installs henge-guest (built from tools/linux/henge-guest, or --deb) and the tools the checks use (gcc, git,
make; fsx from LTP; pjdfstest with --pjdfstest) in a clone of --image. Boot 1 has --folder a=DIR:ro, b=DIR:cow,
c=DIR (Read-write, the default) and --share, and checks the mounts and owners, that a Read-only folder refuses
every change (also after root remounts it rw), the same changes in Copy-on-write (the Mac's folder stays as it
was; export and reset) and in Read-write (the Mac sees them), a new original under a Copy-on-write folder (the
guest's changes stay on top), host changes within 2 s, a new mode, offline and online, a folder added and
removed while running, a program built and run on the folder, a shared mmap, links from the Mac that point out
of the folder, fsx, and times for tar, git, dd and rm on each folder, on ~/Henge (davfs2) and on the root disk.
Boot 2 has no --folder: the system is running and /media/henge is empty.
--pjdfstest runs FM7 instead: pjdfstest's groups on the Read-write folder, with the failures by cause.
The shared image never changes: the guest writes to a clone. Exit 1 on a failed check.
"""
import argparse
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
SHELL = r"henge@henge:\S*\$ "
MARK = "HENGE_RC_"
MEDIA = "/media/henge"
FSX_URL = "https://raw.githubusercontent.com/linux-test-project/ltp/20230127/testcases/kernel/fs/fsx-linux/fsx-linux.c"
FSX_SHA = "cafcbd6a6afcf3486908a601f355c4824f99a2f4a9dbd5153ba5bfeddd738575"
PJD_URL = "https://github.com/pjd/pjdfstest.git"
PJD_COMMIT = "85a8aea9e685999ef0540392fd80535f873d7ff7"
PJD_GROUPS = ["rename", "unlink", "link", "symlink", "chmod", "open", "mkdir"]

# Each folder starts as this; "/" ends a directory. big.bin is 1 MB of seeded random bytes.
FIXTURE = {"f.txt": "original\n", "del.txt": "delete me\n", "ren.txt": "rename me\n", "hl.txt": "hard\n",
           "dir/inner.txt": "inner\n", "dir/sub/deep.txt": "deep\n", "rendir/x.txt": "x\n", "emptydir/": None}


class Fail(Exception):
    pass


def linux_dir():
    if os.environ.get("HENGE_LINUX_OUT"):
        return os.environ["HENGE_LINUX_OUT"]
    common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


def big_bytes():
    return random.Random(7).randbytes(1 << 20)


def make_fixture(d):
    for rel, text in FIXTURE.items():
        p = os.path.join(d, rel)
        if rel.endswith("/"):
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    with open(os.path.join(d, "big.bin"), "wb") as f:
        f.write(big_bytes())


def h16(data):
    return hashlib.sha256(data).hexdigest()[:16]


def tree_of(d):
    """What files-probe.py view prints, for a folder on the Mac."""
    tree = {}
    for top, dirs, files in os.walk(d):
        for n in sorted(dirs + files):
            p = os.path.join(top, n)
            rel = os.path.relpath(p, d)
            st = os.lstat(p)
            if os.path.islink(p):
                tree[rel] = ["link", os.readlink(p)]
            elif os.path.isdir(p):
                tree[rel] = ["dir", oct(st.st_mode & 0o7777)]
            else:
                with open(p, "rb") as f:
                    tree[rel] = ["file", oct(st.st_mode & 0o7777), h16(f.read())]
    return tree


def fixture_tree():
    t = {}
    for rel, text in FIXTURE.items():
        if rel.endswith("/"):
            t[rel[:-1]] = ["dir", "0o755"]
        else:
            parts = rel.split("/")
            for i in range(1, len(parts)):
                t["/".join(parts[:i])] = ["dir", "0o755"]
            t[rel] = ["file", "0o644", h16(text.encode())]
    t["big.bin"] = ["file", "0o644", h16(big_bytes())]
    return t


def changed_tree():
    """The fixture after files-probe.py change."""
    t = fixture_tree()
    f = lambda text, mode="0o644": ["file", mode, h16(text.encode())]  # noqa: E731
    t["new.txt"] = f("new\n")
    t["f.txt"] = f("changed\n", "0o600")
    t["dir/inner.txt"] = f("inner\nappended\n")
    for gone in ("del.txt", "ren.txt", "rendir", "rendir/x.txt", "dir/sub", "dir/sub/deep.txt"):
        del t[gone]
    t["renamed.txt"] = f("rename me\n")
    t["rendir2"] = ["dir", "0o755"]
    t["rendir2/x.txt"] = f("x\n")
    t["newdir"] = ["dir", "0o755"]
    t["newdir/a.txt"] = f("a\n")
    t["link"] = ["link", "f.txt"]
    t["hl2.txt"] = f("hard\n")
    t["big.bin"] = ["file", "0o644", h16(big_bytes() + b"tail")]
    return t


def diff(a, b):
    keys = sorted(set(a) | set(b))
    return [f"{k}: {a.get(k)} != {b.get(k)}" for k in keys if a.get(k) != b.get(k)]


class Vm:
    def __init__(self, args, disk, share, tmp):
        self.args, self.disk, self.share = args, disk, share
        self.input = os.path.join(tmp, "input.txt")
        self.err = disk + ".stderr"
        open(self.input, "w").close()

    def boot(self, folders=()):
        a = self.args
        cmd = ["/bin/sh", "-c", 'exec "$@" 2>>"$0"', self.err, a.hengevm, "--board", "virt", "--firmware", a.firmware,
               "--ram", str(a.ram), "--cpus", str(a.cpus), "--disk", self.disk, "--share", self.share]
        for f in folders:
            cmd += ["--folder", f]
        env = dict(os.environ, HV_INPUT_FILE=self.input)
        self.p = p = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", timeout=60, env=env, maxread=65536)
        p.logfile_read = open(self.disk + ".console", "a")  # for a failure: the guest's side
        p.expect(r"\(automatic login\)", timeout=300)
        p.expect(SHELL, timeout=60)
        p.sendline(f"set +m +H; stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
        p.expect(MARK + r"42\r*\n", timeout=30)
        self.need("systemctl is-system-running --wait", lambda o: o == "running", "system state", 180)

    def sh(self, cmd, limit=60):
        p = self.p
        p.sendline(f"{cmd}; echo {MARK}$?")
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
        out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
        out = re.sub(r"^henge@henge:[^\n$]*\$ ", "", out)
        return out.strip(), int(p.match.group(1))

    def need(self, cmd, ok=lambda o: True, what="", limit=60):
        out, rc = self.sh(cmd, limit)
        if rc != 0 or not ok(out):
            raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
        return out

    def probe(self, *a, limit=120):
        q = " ".join("'" + str(x).replace("'", "'\\''") + "'" for x in a)
        out = self.need(f"python3 /tmp/files-probe.py {q}", what=f"probe {a[0]}", limit=limit)
        return json.loads([line for line in out.splitlines() if line.startswith("{")][-1])

    def input_line(self, line):
        with open(self.input, "a") as f:
            f.write(line + "\n")

    def wait_guest(self, cmd, what, limit=20):
        """Runs cmd until it succeeds; the seconds it took."""
        t = time.monotonic()
        out, rc = self.sh(f"for i in $(seq {limit * 5}); do {cmd} && break; sleep 0.2; done >/dev/null 2>&1; {cmd}", limit + 30)
        if rc != 0:
            raise Fail(f"{what}: not within {limit} s ({out[-500:]!r})")
        return round(time.monotonic() - t, 2)

    def poweroff(self):
        self.p.sendline("sudo poweroff")
        self.p.expect(pexpect.EOF, timeout=180)
        self.p.close()


def ok(msg):
    print(f"ok: {msg}", flush=True)


def build_deb(tmp):
    out = os.path.join(tmp, "deb")
    os.makedirs(out)
    r = subprocess.run(["sh", os.path.join(HERE, "build-guest-pkg.sh")], env=dict(os.environ, HENGE_LINUX_OUT=out),
                       capture_output=True, text=True)
    debs = [f for f in os.listdir(out) if f.endswith(".deb")]
    if r.returncode != 0 or not debs:
        raise Fail(f"build-guest-pkg.sh: {r.stderr[-800:]}")
    return os.path.join(out, debs[0])


def prepare(vm, args, deb):
    """Boot 0: henge-guest and the tools, in the clone."""
    vm.boot()
    pkgs = "gcc libc6-dev make git perl" + (" autoconf automake" if args.pjdfstest else "")
    t = time.monotonic()
    if deb:
        vm.need(f"cp ~/Henge/{os.path.basename(deb)} /tmp/")
    vm.need("sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/var/tmp/apt.log 2>&1 && sudo DEBIAN_FRONTEND="
            f"noninteractive apt-get install -y -qq --reinstall --no-install-recommends {pkgs} "
            f"{'/tmp/' + os.path.basename(deb) if deb else ''} >>/var/tmp/apt.log 2>&1; tail -2 /var/tmp/apt.log",
            what="apt-get install", limit=1200)
    vm.need("dpkg --compare-versions $(dpkg-query -W -f='${Version}' henge-guest) ge 1.7.0", what="henge-guest 1.7.0")
    vm.need(f"python3 -c \"import urllib.request; open('/tmp/fsx.c','wb').write(urllib.request.urlopen('{FSX_URL}').read())\" "
            f"&& echo '{FSX_SHA}  /tmp/fsx.c' | sha256sum -c --quiet && gcc -O2 -w -include libgen.h -o /tmp/fsx /tmp/fsx.c "
            "&& sudo install -m 0755 /tmp/fsx /usr/local/bin/fsx", what="fsx", limit=300)
    if args.pjdfstest:
        vm.need(f"(sudo rm -rf /opt/pjdfstest && sudo git clone -q {PJD_URL} /opt/pjdfstest && cd /opt/pjdfstest && "
                f"sudo git checkout -q {PJD_COMMIT} && sudo autoreconf -ifs >/dev/null 2>&1 && sudo ./configure -q "
                ">/dev/null && sudo make -s pjdfstest >/dev/null 2>&1)", what="pjdfstest", limit=900)
    ok(f"boot 0 installed henge-guest and the tools in {time.monotonic() - t:.0f} s")
    vm.poweroff()


def host_unchanged(d, before, what):
    now = tree_of(d)
    if now != before:
        raise Fail(f"{what}: the Mac's folder changed: {diff(before, now)[:8]}")


def check_mounts(vm):
    vm.need("systemctl is-active henge-files.service run-henge-files.mount", what="units active")
    out = vm.need(f"findmnt -rn -o TARGET,FSTYPE,OPTIONS | grep '^{MEDIA}/'", what="mounts")
    mounts = {line.split()[0]: line.split()[1:] for line in out.splitlines()}
    want = {"a": ("virtiofs", "ro"), "b": ("overlay", "rw"), "c": ("virtiofs", "rw")}
    for name, (fstype, mode) in want.items():
        m = mounts.get(f"{MEDIA}/{name}")
        if not m or m[0] != fstype or mode not in m[1].split(","):
            raise Fail(f"{MEDIA}/{name}: want {fstype} {mode}, got {m}")
    vm.need(f"stat -c %U:%G {MEDIA}/a {MEDIA}/b {MEDIA}/c {MEDIA}/c/f.txt {MEDIA}/b/dir",
            lambda o: set(o.split()) == {"henge:henge"}, "owners")
    vm.need(f"touch {MEDIA}/c/owned && stat -c %U:%G {MEDIA}/c/owned && rm {MEDIA}/c/owned", lambda o: o == "henge:henge",
            "owner of a new file")
    ok("a, b and c are mounted at /media/henge as ro virtiofs, overlay and rw virtiofs, owned by henge")


def check_ro(vm, dirs, before):
    for who, prefix in (("henge", ""), ("root after a rw remount", "sudo ")):
        if prefix:
            vm.need(f"sudo mount -o remount,bind,rw {MEDIA}/a", what="remount rw")
        r = vm.probe("ro", f"{MEDIA}/a") if not prefix else json.loads(
            vm.need(f"sudo python3 /tmp/files-probe.py ro {MEDIA}/a").splitlines()[-1])
        bad = {k: v for k, v in r.items() if v != "EROFS" and not (k == "setxattr" and v in ("EOPNOTSUPP", "ENOTSUP"))}
        if bad:
            raise Fail(f"Read-only as {who}: not EROFS: {bad}")
    vm.need(f"sudo mount -o remount,bind,ro {MEDIA}/a")
    host_unchanged(dirs["a"], before["a"], "Read-only")
    ok("Read-only: 15 kinds of change give EROFS, also for root after a rw remount (the host refuses); the Mac's folder is unchanged")


def check_changes(vm, dirs, before, share):
    want, links = changed_tree(), {}
    for name in ("b", "c"):
        r = vm.probe("change", f"{MEDIA}/{name}")
        hl = r["hard-link"]
        # An overlay reports the original's inode for a file it copied up, so only Read-write has one inode number
        if hl["nlink"] != [2, 2] or not hl["shared"] or (name == "c" and not hl["same-inode"]) or r["readlink"] != "f.txt":
            raise Fail(f"{name}: links: {r}")
        links[name] = hl["same-inode"]
        if name == "b" and (r["rename-dir"] != "EXDEV" or r.get("mv-dir") != 0):
            raise Fail(f"Copy-on-write: renaming a directory from the original: want EXDEV and mv to work, got {r}")
        if name == "c" and r["rename-dir"] != "ok":
            raise Fail(f"Read-write: renaming a directory: {r}")
        got = vm.probe("view", f"{MEDIA}/{name}")["tree"]
        if got != want:
            raise Fail(f"{name}: the guest's view after the changes: {diff(want, got)[:8]}")
    host_unchanged(dirs["b"], before["b"], "Copy-on-write")
    ok("Copy-on-write: create, write, append, delete, rename, mkdir, rmdir, rm -r, symlink, hard link and chmod; "
       "a directory from the original gives EXDEV and mv copies it; the Mac's folder is unchanged"
       + ("" if links["b"] else " (the hard link has two inode numbers in the overlay, one file)"))
    host = tree_of(dirs["c"])
    if host != want:
        raise Fail(f"Read-write: the Mac's folder: {diff(want, host)[:8]}")
    a, b = os.stat(os.path.join(dirs["c"], "hl.txt")), os.stat(os.path.join(dirs["c"], "hl2.txt"))
    if a.st_ino != b.st_ino:
        raise Fail("Read-write: the hard link is not one inode on the Mac")
    ok("Read-write: the same changes, the directory rename too, are on the Mac (the hard link is one inode there)")

    out = vm.need("henge-files export b", what="export")
    dest = out.splitlines()[-1].rsplit(": ", 1)[-1]
    rel = os.path.relpath(dest, "/home/henge/Henge")
    host_dest = os.path.join(share, rel)
    want_files = {"new.txt", "f.txt", "dir/inner.txt", "renamed.txt", "rendir2/x.txt", "newdir/a.txt", "hl.txt",
                  "hl2.txt", "big.bin"}

    def exported():
        if not os.path.isdir(host_dest):
            return None
        got = {k for k, v in tree_of(host_dest).items() if v[0] == "file"}
        read = lambda n: open(os.path.join(host_dest, n)).read() if n in got else ""  # noqa: E731
        return got, set(read("deletions.txt").split("\n")) - {""}, read("links.txt").strip(), read("f.txt")

    want_all = (want_files | {"deletions.txt", "links.txt"}, {"del.txt", "ren.txt", "rendir", "dir/sub"}, "link -> f.txt",
                "changed\n")
    end = time.monotonic() + 60  # davfs2 uploads a second after close
    while time.monotonic() < end and exported() != want_all:
        time.sleep(0.5)
    if exported() != want_all:
        raise Fail(f"export: {exported()}")
    ok(f"export: ~/Henge/{rel} has the 9 changed files, deletions.txt and links.txt (davfs2 has no links)")

    vm.need("henge-files reset b", what="reset")
    if vm.probe("view", f"{MEDIA}/b")["tree"] != fixture_tree():
        raise Fail("reset: b is not the original again")
    vm.need("sudo find /var/lib/henge/files/b/upper -mindepth 1 | wc -l", lambda o: o == "0", "reset: the upper layer is empty")
    ok("reset: b is the original again and its upper layer is empty")


def check_new_original(vm, dirs, tmp):
    """Decision 5: another folder picked for b keeps the guest's Copy-on-write changes on top of it."""
    vm.need(f"echo kept > {MEDIA}/b/kept.txt")
    b2 = os.path.join(tmp, "b2")
    make_fixture(b2)
    with open(os.path.join(b2, "only-in-b2.txt"), "w") as f:
        f.write("b2\n")
    vm.input_line(f"folder add b {b2} cow")
    took = vm.wait_guest(f"[ -e {MEDIA}/b/only-in-b2.txt ]", "a new original under b", 30)
    vm.need(f"cat {MEDIA}/b/kept.txt", lambda o: o == "kept", "the guest's change on the new original")
    vm.input_line(f"folder add b {dirs['b']} cow")
    vm.wait_guest(f"! [ -e {MEDIA}/b/only-in-b2.txt ]", "the first original under b again", 30)
    vm.need(f"rm {MEDIA}/b/kept.txt")
    vm.need("henge-files reset b", what="reset")
    if tree_of(b2) != dict(fixture_tree(), **{"only-in-b2.txt": ["file", "0o644", h16(b"b2\n")]}):
        raise Fail("the new original changed")
    ok(f"a new original for b: the overlay moved onto it in {took} s and kept the guest's file")


def seen_after(vm, path, text, write):
    """Seconds from write() on the Mac until the guest reads text at path (the console's round trip is in it)."""
    vm.p.sendline(f"python3 /tmp/files-probe.py wait {path} '{text}' 10; echo {MARK}$?")
    vm.p.expect("WAITING", timeout=30)
    time.sleep(0.3)
    t = time.monotonic()
    write()
    i = vm.p.expect([r"SEEN ([0-9.]+)", "NOT SEEN"], timeout=30)
    took = time.monotonic() - t
    vm.p.expect(MARK + r"(\d+)\r*\n", timeout=30)
    return round(took, 2) if i == 0 else None


def mac_write(path, text):
    def w():
        with open(path, "w") as f:
            f.write(text)
    return w


def check_host_change(vm, dirs, times):
    want = {}
    want["host new file seen (c)"] = seen_after(vm, f"{MEDIA}/c/from-mac.txt", "from the mac",
                                                mac_write(os.path.join(dirs["c"], "from-mac.txt"), "from the mac"))
    there = {"c": ("f.txt", "changed\n"), "b": ("ren.txt", FIXTURE["ren.txt"])}  # c has had the changes, b was reset
    for name, (n, _) in there.items():
        want[f"host changed file seen ({name})"] = seen_after(
            vm, f"{MEDIA}/{name}/{n}", "changed on the mac", mac_write(os.path.join(dirs[name], n), "changed on the mac"))
    late = {k: v for k, v in want.items() if v is None or v > 2.0}
    if late:
        raise Fail(f"changes made on the Mac: not within 2 s: {late}")
    times.update(want)
    # An overlay keeps its own "no such file" for a name it looked up, so a file new in the original shows after a remount
    with open(os.path.join(dirs["b"], "from-mac.txt"), "w") as f:
        f.write("from the mac")
    vm.need(f"cat {MEDIA}/b/from-mac.txt 2>/dev/null; henge-files remount b >/dev/null && cat {MEDIA}/b/from-mac.txt",
            lambda o: o.endswith("from the mac"), "a file new in b's original, after henge-files remount b")
    for name, (n, text) in there.items():
        os.remove(os.path.join(dirs[name], "from-mac.txt"))
        with open(os.path.join(dirs[name], n), "w") as f:
            f.write(text)
    ok(f"a file made on the Mac shows in c in {want['host new file seen (c)']} s; a changed file in c in "
       f"{want['host changed file seen (c)']} s and in b in {want['host changed file seen (b)']} s; a file new in b's "
       "original after henge-files remount b")


def check_mode(vm, dirs):
    vm.input_line(f"folder add a {dirs['a']} rw")
    vm.wait_guest(f"findmnt -rn -o OPTIONS {MEDIA}/a | grep -q '^rw,'", "a new mode", 20)
    vm.need(f"touch {MEDIA}/a/mode-test && rm {MEDIA}/a/mode-test", what="a write after the mode changed to rw")
    vm.input_line(f"folder add a {dirs['a']} ro")
    vm.wait_guest(f"findmnt -rn -o OPTIONS {MEDIA}/a | grep -q '^ro,'", "back to ro", 20)
    ok("a new mode: a remounts as rw and takes a write, then ro again")


def check_offline(vm, dirs, tmp, times):
    mid = f"awk '$5==\"{MEDIA}/c\"{{print $1}}' /proc/self/mountinfo"
    before = vm.need(mid)
    vm.input_line("folder offline c")
    vm.wait_guest(f"! ls {MEDIA}/c", "offline", 10)
    vm.need(f"ls {MEDIA}/c 2>&1; cat {MEDIA}/c/f.txt 2>&1; true", lambda o: o.count("Input/output error") == 2, "offline gives EIO")
    vm.input_line("folder online c")
    vm.wait_guest(f"cat {MEDIA}/c/f.txt", "online", 10)
    if vm.need(mid) != before:
        raise Fail("online: c was mounted again")
    ok("offline: ls and cat give EIO; online: c works again with the same mount")
    d = os.path.join(tmp, "d")
    os.makedirs(d)
    with open(os.path.join(d, "hello.txt"), "w") as f:
        f.write("added\n")
    vm.input_line(f"folder add d {d} rw")
    times["folder add seen"] = vm.wait_guest(f"grep -qx added {MEDIA}/d/hello.txt", "folder add", 20)
    vm.need(f"echo back > {MEDIA}/d/back.txt")
    if open(os.path.join(d, "back.txt")).read() != "back\n":
        raise Fail("folder add: a write did not reach the Mac")
    vm.input_line("folder remove d")
    times["folder remove done"] = vm.wait_guest(f"! [ -e {MEDIA}/d ]", "folder remove", 20)
    ok(f"folder add while running: d mounted in {times['folder add seen']} s; remove: gone in {times['folder remove done']} s")


def check_programs(vm, dirs):
    r = vm.probe("build", f"{MEDIA}/c", limit=300)
    if r["build"] != ["henge 33", "henge 33", "henge 66", "henge 66", "henge 99", "henge 99"]:
        raise Fail(f"a program built on c and run from there: {r['build']}")
    vm.probe("mmap", f"{MEDIA}/c/mapped")
    with open(os.path.join(dirs["c"], "mapped"), "rb") as f:
        data = f.read()
    if len(data) != 65536 or any(data[i * 4096:i * 4096 + 8] != b"henge%03d" % i for i in range(16)):
        raise Fail("mmap: the Mac's file does not have the mapped writes")
    vm.need(f"rm {MEDIA}/c/prog {MEDIA}/c/prog.c {MEDIA}/c/mapped")
    ok("a program built on c three times with new code runs the new code each time; a shared mmap write with msync reaches the Mac")


def check_escape(vm, dirs):
    os.symlink("/", os.path.join(dirs["c"], "escape"))
    os.symlink("../../..", os.path.join(dirs["c"], "up"))
    os.makedirs(os.path.join(dirs["c"], "deep"))
    os.symlink("/private/etc", os.path.join(dirs["c"], "deep", "etc-link"))
    vm.need(f"readlink {MEDIA}/c/escape", lambda o: o == "/", "readlink")
    listing = vm.need(f"ls {MEDIA}/c/escape/ /run/henge/files/c/escape/").split()
    mac = {"Users", "Applications", "System", "Library", "private"}
    if mac & set(listing) or "etc" not in listing:
        raise Fail(f"escape: the link to / lists {listing}")
    vm.need(f"cat {MEDIA}/c/up/etc/hostname", lambda o: o == "henge", "escape: ../../.. is the guest's /")
    vm.need(f"ls {MEDIA}/c/deep/etc-link/ 2>&1; true", lambda o: "No such file" in o, "escape: a link to /private/etc")
    for n in ("escape", "up", "deep/etc-link"):
        os.remove(os.path.join(dirs["c"], n))
    os.rmdir(os.path.join(dirs["c"], "deep"))
    ok("links made on the Mac to /, ../../.. and /private/etc resolve in the guest, never to the Mac's files")


def check_fsx(vm, seconds, times):
    out, rc = vm.sh(f"(cd {MEDIA}/c && timeout -s INT {seconds} fsx -q fsx.data > /tmp/fsx.log 2>&1; R=$?; "
                    f"tail -3 /tmp/fsx.log; exit $R)", seconds + 120)
    m = re.search(r"testcalls = (\d+)", out)
    if rc != 124 or not m:
        raise Fail(f"fsx on c: status {rc}: {out[-1500:]!r}")
    vm.need(f"rm -f {MEDIA}/c/fsx.data {MEDIA}/c/fsx.data.fsxlog {MEDIA}/c/fsx.data.fsxgood")
    times["fsx operations"] = int(m.group(1))
    times["fsx seconds"] = seconds
    ok(f"fsx on c: {m.group(1)} operations in {seconds} s with no error (mapped reads and writes on)")


def check_bench(vm, args, share, times):
    bundle = os.path.join(share, "henge.bundle")
    subprocess.run(["git", "-C", ROOT, "bundle", "create", bundle, "HEAD"], check=True, capture_output=True)
    vm.need("cp ~/Henge/henge.bundle /var/tmp/ && rm -rf /var/tmp/small && python3 -c \"import os,sys\n"
            "for n, tar in ((int(sys.argv[1]), 'small'), (int(sys.argv[2]), 'small-dav')):\n"
            "    for i in range(n):\n"
            "        d = f'/var/tmp/{tar}/small/d{i // 100:03d}'\n"
            "        os.makedirs(d, exist_ok=True)\n"
            "        open(f'{d}/f{i:05d}.txt', 'w').write('x' * (100 + i % 900))\n"
            f"\" {args.files} {args.davfs_files} && tar cf /var/tmp/small.tar -C /var/tmp/small small && "
            "tar cf /var/tmp/small-dav.tar -C /var/tmp/small-dav small && rm -rf /var/tmp/small /var/tmp/small-dav",
            what="bench data", limit=600)
    rows = []
    for where, d, tar, mb in (("c: Read-write (virtio-fs)", f"{MEDIA}/c", "/var/tmp/small.tar", args.dd_mb),
                              ("b: Copy-on-write (overlay)", f"{MEDIA}/b", "/var/tmp/small.tar", args.dd_mb),
                              ("root disk (ext4)", "/var/tmp/rootbench", "/var/tmp/small.tar", args.dd_mb),
                              ("~/Henge (davfs2)", "/home/henge/Henge", "/var/tmp/small-dav.tar", args.davfs_mb)):
        n = args.davfs_files if "davfs" in where else args.files
        r = vm.probe("bench", d, where, tar, "/var/tmp/henge.bundle", mb, limit=7200)
        r["files"] = n
        rows.append(r)
        print(f"  {where}: tar x of {n} files {r['tar_x']} s, rm -r {r['rm_r']} s, git clone {r['git_clone']} s, "
              f"git status {r['git_status']} s cold and {r['git_status_warm']} s warm, dd {mb} MB write "
              f"{r['dd_write']} s ({mb / max(r['dd_write'], 0.01):.0f} MB/s), read {r['dd_read']} s "
              f"({mb / max(r['dd_read'], 0.01):.0f} MB/s)", flush=True)
    vm.need("rm -f /var/tmp/small.tar /var/tmp/small-dav.tar /var/tmp/henge.bundle")
    os.remove(bundle)
    vm.need("henge-files reset b", what="reset after the bench")
    times["bench"] = rows
    ok("times for tar, git, dd and rm on c, b, the root disk and ~/Henge")


def check_no_folders(vm):
    vm.boot()
    vm.need("systemctl is-active henge-files.service run-henge-files.mount; true",
            lambda o: o.split() == ["inactive", "inactive"], "units without the device")
    vm.need(f"ls -A {MEDIA} | wc -l", lambda o: o == "0", f"{MEDIA} is empty")
    vm.need("systemctl --failed --no-legend | wc -l", lambda o: o == "0", "no failed unit")
    vm.poweroff()
    ok("boot 2 without --folder: the system is running, no unit failed, /media/henge is empty")


# The causes the README lists: everything is henge's (no chown), no devices or sockets on the host, PATH_MAX 1024
PJD_EXPECTED = re.compile(r"^((l?chown|-u \S+ -g \S+ chown)\b.*got EPERM|mknod [bc]: .*got EPERM|bind: .*got EPERM|.*got ENAMETOOLONG)")


def pjd_cause(line):
    """A "not ok" line as its operation, what pjdfstest wanted and what it got, names and numbers left out."""
    m = re.search(r"tried '([^']*)', expected (\S+), got (\S+)", line)
    if not m:
        return "a check with no message (ctime, mtime or a size compared)"
    words = m.group(1).split()
    op = " ".join(words[:5]) if words[0] in ("-u", "-g", "--") else words[0]
    if words[0] == "mknod" and len(words) > 2:
        op += " " + words[2]  # b, c or f
    op = re.sub(r"pjdfstest_[0-9a-f]+|[0-9a-f]{40,}\S*", "N", op)
    norm = lambda v: re.sub(r"\b\d{6,}\b", "INODE", v)  # noqa: E731
    return f"{op}: expected {norm(m.group(2))}, got {norm(m.group(3))}"


def run_pjdfstest(vm, times):
    """FM7: pjdfstest's groups on c as root. A test file's first failure is its cause (the ones after it are mostly
    that one again, further on), so the causes are counted by test file."""
    vm.need(f"mkdir -p {MEDIA}/c/pj")
    totals = {}
    for g in PJD_GROUPS:
        t = time.monotonic()
        vm.sh(f"cd {MEDIA}/c/pj && sudo prove -v -r /opt/pjdfstest/tests/{g} > /tmp/pj-{g}.log 2>&1; cd", 3600)
        out = vm.need(f"grep -E '^/opt/pjdfstest/tests/.*\\.t \\.\\.|^ok |^not ok ' /tmp/pj-{g}.log", limit=120)
        passed = failed = 0
        first, files, now = {}, set(), None
        for line in out.splitlines():
            if line.startswith("/opt/pjdfstest/tests/"):
                now = line.split()[0].split("/tests/")[1]
                files.add(now)
            elif line.startswith("ok "):
                passed += 1
            elif line.startswith("not ok "):
                failed += 1
                if now and now not in first and "# TODO" not in line:
                    first[now] = pjd_cause(line)
        causes = {}
        for f, c in first.items():
            causes.setdefault(c, []).append(f.split("/")[-1])
        secs = round(time.monotonic() - t)
        totals[g] = {"ok": passed, "not ok": failed, "files": len(files), "files failed": len(first), "seconds": secs,
                     "causes": causes}
        print(f"  {g}: {passed} ok, {failed} not ok; {len(files) - len(first)} of {len(files)} test files pass; {secs} s", flush=True)
        for c, fs in sorted(causes.items(), key=lambda kv: -len(kv[1])):
            print(f"    {len(fs):3d} files  {c}  ({' '.join(sorted(fs))})", flush=True)
    vm.need(f"sudo rm -rf {MEDIA}/c/pj")
    times["pjdfstest"] = totals
    odd = {c: fs for t in totals.values() for c, fs in t["causes"].items() if not PJD_EXPECTED.match(c)}
    if odd:
        raise Fail(f"pjdfstest: causes the README does not list: {odd}")
    ok("pjdfstest: every failing test file fails first on chown, a device node, a socket or a path over 1023 bytes")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", help="disk to clone (default debian-console.img)")
    ap.add_argument("--firmware", help="default u-boot.bin next to the image")
    ap.add_argument("--hengevm", default=os.path.join(ROOT, "build", "hengevm"))
    ap.add_argument("--deb", help="henge-guest package to install (default: built from tools/linux/henge-guest)")
    ap.add_argument("--no-install", action="store_true", help="the image has henge-guest 1.7.0, the tools and fsx")
    ap.add_argument("--save-image", help="keep the disk after boot 0 here, for --image and --no-install")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--ram", type=int, default=2048)
    ap.add_argument("--files", type=int, default=10000, help="small files for tar x")
    ap.add_argument("--davfs-files", type=int, default=1000, help="small files for tar x on ~/Henge")
    ap.add_argument("--dd-mb", type=int, default=1024)
    ap.add_argument("--davfs-mb", type=int, default=100)
    ap.add_argument("--fsx-seconds", type=int, default=600)
    ap.add_argument("--pjdfstest", action="store_true", help="FM7: pjdfstest on the Read-write folder, no FM6 checks")
    ap.add_argument("--json", help="write the times here")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    args = ap.parse_args()
    d = linux_dir()
    image = args.image or os.path.join(d, "debian-console.img")
    args.firmware = args.firmware or os.path.join(d, "u-boot.bin")

    tmp = tempfile.mkdtemp(prefix="files-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    # hengevm listens on "<share>.sock", and a unix socket path is limited to 103 characters
    share = tempfile.mkdtemp(prefix="fcs-", dir="/tmp")
    folders = tempfile.mkdtemp(prefix="fcf-", dir="/tmp")
    dirs = {n: os.path.join(folders, n) for n in "abc"}
    times, vm = {}, None
    try:
        subprocess.run(["/bin/cp", "-c", image, disk], check=True)
        os.truncate(disk, max(os.path.getsize(disk), 8 << 30))  # henge-grow takes it: room for 1 GB on the root disk twice
        shutil.copy(os.path.join(HERE, "files-probe.py"), share)
        vm = Vm(args, disk, share, tmp)
        if not args.no_install:
            deb = args.deb or build_deb(tmp)
            shutil.copy(deb, share)
            prepare(vm, args, deb)
            if args.save_image:
                subprocess.run(["/bin/cp", "-c", disk, args.save_image], check=True)
        for n, p in dirs.items():
            make_fixture(p)
        before = {n: tree_of(p) for n, p in dirs.items()}
        vm.boot([f"a={dirs['a']}:ro", f"b={dirs['b']}:cow", f"c={dirs['c']}"])
        vm.need("cp ~/Henge/files-probe.py /tmp/")
        if args.pjdfstest:
            run_pjdfstest(vm, times)
        else:
            check_mounts(vm)
            check_ro(vm, dirs, before)
            check_changes(vm, dirs, before, share)
            check_new_original(vm, dirs, folders)
            check_host_change(vm, dirs, times)
            check_mode(vm, dirs)
            check_offline(vm, dirs, folders, times)
            check_programs(vm, dirs)
            check_escape(vm, dirs)
            check_fsx(vm, args.fsx_seconds, times)
            check_bench(vm, args, share, times)
            host_unchanged(dirs["a"], before["a"], "Read-only at the end")
        vm.poweroff()
        if not args.pjdfstest:
            check_no_folders(vm)
        if args.json:
            with open(args.json, "w") as f:
                json.dump(times, f, indent=1)
        print("files-check: ok")
    except (Fail, pexpect.TIMEOUT, pexpect.EOF, subprocess.CalledProcessError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        for log in (vm.err, vm.disk + ".console") if vm else ():
            if os.path.exists(log):
                print(f"--- {os.path.basename(log)}:", open(log, errors="replace").read()[-2500:], file=sys.stderr)
        sys.exit(1)
    finally:
        if vm and getattr(vm, "p", None) and vm.p.isalive():
            vm.p.terminate(force=True)
        for p in (tmp, share, folders):
            shutil.rmtree(p, ignore_errors=True)


if __name__ == "__main__":
    main()
