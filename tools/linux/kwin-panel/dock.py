#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A stand-in for Plasma's panel, for keyboard-panel-check.sh: dock.py top|bottom HEIGHT.
A layer-shell surface over the whole edge that keeps HEIGHT for itself (an exclusive zone)."""
import array
import os
import socket
import struct
import sys

EDGE, HEIGHT = sys.argv[1], int(sys.argv[2])
ANCHOR = (1 if EDGE == "top" else 2) | 4 | 8  # the edge, left and right

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


comp, shm, shell = bind("wl_compositor", 4), bind("wl_shm"), bind("zwlr_layer_shell_v1")
surface = new()
send(comp, 0, struct.pack("<I", surface))
layer = new()
send(shell, 0, struct.pack("<IIII", layer, surface, 0, 2) + string("dock"))  # get_layer_surface, no output, layer top
send(layer, 0, struct.pack("<II", 0, HEIGHT))  # set_size: the whole width
send(layer, 1, struct.pack("<I", ANCHOR))
send(layer, 2, struct.pack("<i", HEIGHT))  # set_exclusive_zone
send(surface, 6)

while True:
    for obj, op, a in events():
        if obj == layer and op == 0:  # configure
            serial, w, h = struct.unpack_from("<III", a)
            send(layer, 6, struct.pack("<I", serial))  # ack_configure
            fd = os.memfd_create("dock")
            os.ftruncate(fd, w * h * 4)
            pool, buffer = new(), new()
            send(shm, 0, struct.pack("<II", pool, w * h * 4), fd)
            os.close(fd)
            send(pool, 0, struct.pack("<IiiiiI", buffer, 0, w, h, w * 4, 1))
            send(pool, 1)
            send(surface, 1, struct.pack("<Iii", buffer, 0, 0))
            send(surface, 2, struct.pack("<iiii", 0, 0, w, h))
            send(surface, 6)
        elif obj == layer and op == 1:
            raise SystemExit(0)
