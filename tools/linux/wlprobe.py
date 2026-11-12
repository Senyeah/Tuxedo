#!/usr/bin/env python3
# Compositor frame-time probe: a shm client that redraws a W x H window every frame callback.
import array, mmap, os, socket, struct, sys, time
W, H, SECS = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
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
buf = b""
def events():
    global buf
    d = s.recv(65536)
    if not d: raise SystemExit("compositor closed")
    buf += d
    out = []
    while len(buf) >= 8:
        o, sz_op = struct.unpack_from("<II", buf)
        sz, op = sz_op >> 16, sz_op & 0xffff
        if len(buf) < sz: break
        out.append((o, op, buf[8:sz])); buf = buf[sz:]
    return out
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
comp, shm, wm = bind("wl_compositor", 4), bind("wl_shm", 1), bind("xdg_wm_base", 1)
surf = new(); send(comp, 0, struct.pack("<I", surf))
xs = new(); send(wm, 2, struct.pack("<II", xs, surf))
top = new(); send(xs, 1, struct.pack("<I", top))
send(top, 2, string("probe"))
send(surf, 6)
size = W * H * 4
fd = os.memfd_create("p"); os.ftruncate(fd, size * 2); mm = mmap.mmap(fd, size * 2)
pool = new(); send(shm, 0, struct.pack("<II", pool, size * 2), fd)
bufs = []
for i in range(2):
    b = new(); send(pool, 0, struct.pack("<IIIIII", b, i * size, W, H, W * 4, 1)); bufs.append(b)
pat = [bytes([40, 80, 160, 255]) * (size // 4), bytes([200, 120, 20, 255]) * (size // 4)]
busy = [False, False]
configured = False
while not configured:
    for o, op, a in events():
        if o == wm and op == 0: send(wm, 3, a[:4])
        if o == xs and op == 0: send(xs, 4, a[:4]); configured = True
times = []
n = 0; frame_cb = None; t_end = None
def draw():
    global frame_cb, n
    i = 0 if not busy[0] else 1
    mm[i * size:(i + 1) * size] = pat[n & 1]; n += 1
    busy[i] = True
    send(surf, 1, struct.pack("<Iii", bufs[i], 0, 0))
    send(surf, 2, struct.pack("<iiii", 0, 0, W, H))
    frame_cb = new(); send(surf, 3, struct.pack("<I", frame_cb))
    send(surf, 6)
draw()
t0 = time.monotonic(); last = None
while True:
    for o, op, a in events():
        if o == wm and op == 0: send(wm, 3, a[:4])
        elif o == xs and op == 0: send(xs, 4, a[:4])
        elif o in bufs and op == 0: busy[bufs.index(o)] = False
        elif o == frame_cb and op == 0:
            t = time.monotonic()
            if last is not None: times.append((t - last) * 1000)
            last = t
            if t - t0 >= SECS: times.sort(); break
            draw()
    else:
        continue
    break
times = times[:] ; times.sort()
k = len(times)
def pc(p): return times[min(k - 1, int(k * p))]
print(f"probe {W}x{H}: frames={k} mean={sum(times)/k:.2f}ms p50={pc(.5):.2f} p95={pc(.95):.2f} p99={pc(.99):.2f} max={times[-1]:.2f} fps={1000*k/sum(times):.1f}")
