#!/usr/bin/python3
"""The guest's half of files-check.py: runs in the guest, prints one JSON line per command.

  ro DIR              every change, expected to fail with EROFS
  change DIR          the same changes in a Copy-on-write or Read-write folder (see FIXTURE in files-check.py)
  view DIR            names, kinds, modes, contents and links of the tree, for comparison
  wait PATH TEXT S    prints WAITING, then SEEN with the seconds when PATH holds TEXT
  mmap PATH           writes through a shared map and msync
  build DIR           builds a program in DIR and runs it from there, three times with new code
  bench DIR NAME ...  times tar x, git clone and status, dd write and read, and rm -r in DIR
"""
import errno
import hashlib
import json
import mmap
import os
import shutil
import subprocess
import sys
import time


def out(**kw):
    print(json.dumps(kw), flush=True)


def err(fn):
    try:
        fn()
        return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))


def ro(d):
    j = lambda *p: os.path.join(d, *p)  # noqa: E731
    tests = {
        "create": lambda: open(j("new.txt"), "x").close(),
        "write": lambda: open(j("f.txt"), "r+").close(),
        "append": lambda: open(j("f.txt"), "a").close(),
        "truncate": lambda: os.truncate(j("f.txt"), 0),
        "unlink": lambda: os.unlink(j("del.txt")),
        "mkdir": lambda: os.mkdir(j("newdir")),
        "rmdir": lambda: os.rmdir(j("emptydir")),
        "rename": lambda: os.rename(j("ren.txt"), j("renamed.txt")),
        "rename-dir": lambda: os.rename(j("rendir"), j("rendir2")),
        "symlink": lambda: os.symlink("f.txt", j("link")),
        "link": lambda: os.link(j("hl.txt"), j("hl2.txt")),
        "chmod": lambda: os.chmod(j("f.txt"), 0o600),
        "utime": lambda: os.utime(j("f.txt"), (1, 1)),
        "mkfifo": lambda: os.mkfifo(j("fifo")),
        "setxattr": lambda: os.setxattr(j("f.txt"), "user.tux", b"1"),
    }
    out(**{k: err(v) for k, v in tests.items()})


def change(d):
    j = lambda *p: os.path.join(d, *p)  # noqa: E731
    r = {}
    with open(j("new.txt"), "w") as f:
        f.write("new\n")
    with open(j("f.txt"), "w") as f:
        f.write("changed\n")
    with open(j("dir", "inner.txt"), "a") as f:
        f.write("appended\n")
    os.unlink(j("del.txt"))
    os.rename(j("ren.txt"), j("renamed.txt"))
    r["rename-dir"] = err(lambda: os.rename(j("rendir"), j("rendir2")))  # EXDEV on an overlay over the original
    if r["rename-dir"] != "ok":
        r["mv-dir"] = subprocess.run(["mv", j("rendir"), j("rendir2")], capture_output=True, text=True).returncode
    os.mkdir(j("newdir"))
    with open(j("newdir", "a.txt"), "w") as f:
        f.write("a\n")
    os.mkdir(j("gone"))
    os.rmdir(j("gone"))
    shutil.rmtree(j("dir", "sub"))
    os.symlink("f.txt", j("link"))
    os.link(j("hl.txt"), j("hl2.txt"))
    a, b = os.stat(j("hl.txt")), os.stat(j("hl2.txt"))
    with open(j("hl2.txt"), "r+") as f:
        f.write("HARD")
    with open(j("hl.txt")) as f:
        shared = f.read() == "HARD\n"
    with open(j("hl2.txt"), "r+") as f:
        f.write("hard")
    r["hard-link"] = {"same-inode": a.st_ino == b.st_ino, "nlink": [a.st_nlink, b.st_nlink], "shared": shared}
    os.chmod(j("f.txt"), 0o600)
    r["readlink"] = os.readlink(j("link"))
    with open(j("big.bin"), "ab") as f:
        f.write(b"tail")
    out(**r)


def view(d):
    tree = {}
    for top, dirs, files in os.walk(d):
        dirs.sort()
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
                    tree[rel] = ["file", oct(st.st_mode & 0o7777), hashlib.sha256(f.read()).hexdigest()[:16]]
    out(tree=tree)


def wait(path, text, limit):
    print("WAITING", flush=True)
    t = time.monotonic()
    while time.monotonic() - t < limit:
        try:
            with open(path) as f:
                if f.read() == text:
                    print(f"SEEN {time.monotonic() - t:.2f}", flush=True)
                    return
        except OSError:
            pass
        time.sleep(0.05)
    print("NOT SEEN", flush=True)


def do_mmap(path):
    with open(path, "w+b") as f:
        f.truncate(65536)
        m = mmap.mmap(f.fileno(), 65536)
        for i in range(16):
            m[i * 4096:i * 4096 + 6] = b"tux%03d" % i
        m.flush()
        m.close()
    out(mmap="ok")


PROG = '#include <stdio.h>\nint main(void) { volatile int n = %d; printf("tux %%d\\n", n * 3); return 0; }\n'


def build(d):
    """Each round writes new code over the old program: a stale JIT translation of the old page would print the
    old number."""
    got = []
    for n in (11, 22, 33):
        with open(os.path.join(d, "prog.c"), "w") as f:
            f.write(PROG % n)
        subprocess.run(["gcc", "-O1", "-o", os.path.join(d, "prog"), os.path.join(d, "prog.c")], check=True)
        for _ in range(2):
            got.append(subprocess.run([os.path.join(d, "prog")], capture_output=True, text=True).stdout.strip())
    out(build=got)


def drop_caches():
    subprocess.run(["sudo", "sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"], check=True)


def timed(fn):
    t = time.monotonic()
    fn()
    return round(time.monotonic() - t, 2)


def bench(d, name, tarball, bundle, mb):
    w = os.path.join(d, "bench")
    os.makedirs(w, exist_ok=True)
    r = {"where": name}
    run = lambda *c: subprocess.run(c, check=True, capture_output=True)  # noqa: E731
    r["tar_x"] = timed(lambda: run("tar", "xf", tarball, "-C", w))
    r["rm_r"] = timed(lambda: run("rm", "-rf", os.path.join(w, "small")))
    r["git_clone"] = timed(lambda: run("git", "clone", "-q", bundle, os.path.join(w, "repo")))
    drop_caches()
    r["git_status"] = timed(lambda: run("git", "-C", os.path.join(w, "repo"), "status", "--porcelain"))
    r["git_status_warm"] = timed(lambda: run("git", "-C", os.path.join(w, "repo"), "status", "--porcelain"))
    big = os.path.join(w, "big")
    r["dd_mb"] = mb
    r["dd_write"] = timed(lambda: run("dd", "if=/dev/zero", f"of={big}", "bs=1M", f"count={mb}", "conv=fsync"))
    drop_caches()
    r["dd_read"] = timed(lambda: run("dd", f"if={big}", "of=/dev/null", "bs=1M"))
    os.remove(big)
    run("rm", "-rf", w)
    out(**r)


def main():
    os.umask(0o022)  # Debian gives the user 002; the expected trees in files-check.py have 022's modes
    a = sys.argv[1:]
    {"ro": lambda: ro(a[1]), "change": lambda: change(a[1]), "view": lambda: view(a[1]),
     "wait": lambda: wait(a[1], a[2], float(a[3])), "mmap": lambda: do_mmap(a[1]), "build": lambda: build(a[1]),
     "bench": lambda: bench(a[1], a[2], a[3], a[4], int(a[5]))}[a[0]]()


if __name__ == "__main__":
    main()
