#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A test window for keyboard-panel-check.sh: window.py LOG [--text] [--float WxH].
An xdg_toplevel, maximized unless --float, that draws at each size the compositor gives it and writes
"W H" to LOG. --text: it has a text field (text-input-v3, enabled while it has the focus)."""
import array
import os
import socket
import struct
import sys

LOG = sys.argv[1]
TEXT = "--text" in sys.argv
FLOAT = tuple(int(v) for v in sys.argv[sys.argv.index("--float") + 1].split("x")) if "--float" in sys.argv else None

s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "wayland-0")))
last_id = 1
buf = b""


def new():
    global last_id
    last_id += 1
    return last_id


def send(obj, op, args=b"", fd=None):
    msg = struct.pack("<II", obj, ((8 + len(args)) << 16) | op) + args
    if fd is None:
        s.sendall(msg)
    else:
        s.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])


def string(text):
    b = text.encode() + b"\0"
    return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)


def events():
    global buf
    d = s.recv(65536)
    if not d:
        raise SystemExit("the compositor closed the connection")
    buf += d
    out = []
    while len(buf) >= 8:
        obj, word = struct.unpack_from("<II", buf)
        size = word >> 16
        if len(buf) < size:
            break
        out.append((obj, word & 0xFFFF, buf[8:size]))
        buf = buf[size:]
    return out


reg, cb = new(), new()
send(1, 1, struct.pack("<I", reg))
send(1, 0, struct.pack("<I", cb))
found = {}
done = False
while not done:
    for obj, op, a in events():
        if obj == reg and op == 0:
            name, n = struct.unpack_from("<II", a)
            found.setdefault(a[8:8 + n - 1].decode(), name)
        elif obj == cb:
            done = True


def bind(iface, version=1):
    i = new()
    send(reg, 0, struct.pack("<I", found[iface]) + string(iface) + struct.pack("<II", version, i))
    return i


comp, shm, wm = bind("wl_compositor", 4), bind("wl_shm"), bind("xdg_wm_base")
surface = new()
send(comp, 0, struct.pack("<I", surface))
xs = new()
send(wm, 2, struct.pack("<II", xs, surface))  # get_xdg_surface
top = new()
send(xs, 1, struct.pack("<I", top))  # get_toplevel
send(top, 2, string("tux keyboard test"))
if not FLOAT:
    send(top, 9)  # set_maximized
text = None
if TEXT:
    seat, manager = bind("wl_seat"), bind("zwp_text_input_manager_v3")
    text = new()
    send(manager, 1, struct.pack("<II", text, seat))  # get_text_input
send(surface, 6)

size = FLOAT or (640, 480)
drawn = None


def draw():
    global drawn
    if size == drawn:
        return
    w, h = size
    fd = os.memfd_create("window")
    os.ftruncate(fd, w * h * 4)
    os.pwrite(fd, b"\xff\x60\x60\x60" * (w * h), 0)
    pool, buffer = new(), new()
    send(shm, 0, struct.pack("<II", pool, w * h * 4), fd)
    os.close(fd)
    send(pool, 0, struct.pack("<IiiiiI", buffer, 0, w, h, w * 4, 1))  # XRGB8888
    send(pool, 1)  # destroy: the buffer keeps the memory
    send(surface, 1, struct.pack("<Iii", buffer, 0, 0))
    send(surface, 2, struct.pack("<iiii", 0, 0, w, h))
    send(surface, 6)
    drawn = size
    with open(LOG, "a") as f:
        f.write(f"{w} {h}\n")


while True:
    for obj, op, a in events():
        if obj == wm and op == 0:
            send(wm, 3, a[:4])  # pong
        elif obj == top and op == 0:  # configure: 0 0 leaves the size to the client
            w, h = struct.unpack_from("<ii", a)
            if w > 0 and h > 0:
                size = (w, h)
        elif obj == top and op == 1:
            raise SystemExit(0)
        elif obj == xs and op == 0:
            send(xs, 4, a[:4])  # ack_configure
            draw()
        elif obj == text and op == 0:  # enter: the text field has the focus
            send(text, 1)  # enable
            send(text, 7)  # commit
        elif obj == text and op == 1:  # leave
            send(text, 2)
            send(text, 7)
