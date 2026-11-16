#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# TS3 probe, run in the guest: a full-screen Wayland window that prints what wl_touch and wl_pointer give it.
# Lines: "configure W H", "down ID X Y", "motion ID X Y", "up ID", "frame", "cancel", "button X Y STATE".
import array, mmap, os, socket, struct, sys
path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "wayland-0"))
s = socket.socket(socket.AF_UNIX); s.connect(path)
nid = [1]
def new(): nid[0] += 1; return nid[0]
def pad(b): return b + b"\0" * (-len(b) % 4)
def string(t): b = t.encode() + b"\0"; return struct.pack("<I", len(b)) + pad(b)
def send(obj, op, args=b"", fd=None):
    msg = struct.pack("<II", obj, ((8 + len(args)) << 16) | op) + args
    if fd is None: s.sendall(msg)
    else: s.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
def out(line): print(line, flush=True)
buf = b""
def events():
    global buf
    d = s.recv(65536)
    if not d: raise SystemExit("compositor closed")
    buf += d
    res = []
    while len(buf) >= 8:
        o, sz_op = struct.unpack_from("<II", buf)
        sz, op = sz_op >> 16, sz_op & 0xffff
        if len(buf) < sz: break
        res.append((o, op, buf[8:sz])); buf = buf[sz:]
    return res
def fixed(v): return v / 256.0
reg = new(); send(1, 1, struct.pack("<I", reg))
cb = new(); send(1, 0, struct.pack("<I", cb))
glob = {}
done = False
while not done:
    for o, op, a in events():
        if o == reg and op == 0:
            name, ln = struct.unpack_from("<II", a); iface = a[8:8 + ln - 1].decode()
            ver = struct.unpack_from("<I", a, 8 + ((ln + 3) & ~3))[0]; glob[iface] = (name, ver)
        elif o == cb: done = True
def bind(iface, ver):
    n, v = glob[iface]; i = new()
    send(reg, 0, struct.pack("<I", n) + string(iface) + struct.pack("<II", min(v, ver), i)); return i
comp, shm, wm, seat = bind("wl_compositor", 4), bind("wl_shm", 1), bind("xdg_wm_base", 1), bind("wl_seat", 5)
surf = new(); send(comp, 0, struct.pack("<I", surf))
xs = new(); send(wm, 2, struct.pack("<II", xs, surf))
top = new(); send(xs, 1, struct.pack("<I", top))
send(top, 2, string("touchprobe"))
send(top, 11, struct.pack("<I", 0))  # set_fullscreen on the compositor's choice of output
send(surf, 6)
touch = pointer = None
size = (0, 0)
want = (0, 0)
bufobj = None
px = py = 0.0
def attach(w, h):
    global bufobj, size
    w, h = w or 640, h or 480
    fd = os.memfd_create("p"); os.ftruncate(fd, w * h * 4)
    mm = mmap.mmap(fd, w * h * 4); mm[:] = bytes([30, 30, 30, 255]) * (w * h)
    pool = new(); send(shm, 0, struct.pack("<II", pool, w * h * 4), fd)
    b = new(); send(pool, 0, struct.pack("<IIIIII", b, 0, w, h, w * 4, 1))
    send(pool, 1); os.close(fd)
    send(surf, 1, struct.pack("<Iii", b, 0, 0))
    send(surf, 2, struct.pack("<iiii", 0, 0, w, h))
    send(surf, 6)
    bufobj, size = b, (w, h)
    out(f"configure {w} {h}")
while True:
    for o, op, a in events():
        if o == 1 and op == 0:
            out("error " + repr(a)); sys.exit(1)
        elif o == wm and op == 0: send(wm, 3, a[:4])
        elif o == top and op == 0: want = struct.unpack_from("<ii", a)
        elif o == xs and op == 0:
            send(xs, 4, a[:4])
            if want != size: attach(*want)
            else: send(surf, 6)
        elif o == seat and op == 0:
            caps = struct.unpack_from("<I", a)[0]
            if caps & 4 and touch is None: touch = new(); send(seat, 2, struct.pack("<I", touch))
            if caps & 1 and pointer is None: pointer = new(); send(seat, 0, struct.pack("<I", pointer))
        elif o == touch and op == 0:
            _, _, _, tid, x, y = struct.unpack_from("<IIIiii", a); out(f"down {tid} {fixed(x):.2f} {fixed(y):.2f}")
        elif o == touch and op == 1: out(f"up {struct.unpack_from('<IIi', a)[2]}")
        elif o == touch and op == 2:
            _, tid, x, y = struct.unpack_from("<Iiii", a); out(f"motion {tid} {fixed(x):.2f} {fixed(y):.2f}")
        elif o == touch and op == 3: out("frame")
        elif o == touch and op == 4: out("cancel")
        elif o == pointer and op == 0: px, py = (fixed(v) for v in struct.unpack_from("<ii", a, 8))
        elif o == pointer and op == 2: px, py = (fixed(v) for v in struct.unpack_from("<ii", a, 4))
        elif o == pointer and op == 3: out(f"button {px:.2f} {py:.2f} {struct.unpack_from('<IIII', a)[3]}")
