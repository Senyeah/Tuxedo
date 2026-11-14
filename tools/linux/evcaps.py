#!/usr/bin/env python3
# TS3, run in the guest as root: what each touchscreen evdev node offers (names, ids, bits, axis ranges).
# The same text on Tuxedo and on QEMU's virtio-multitouch-pci shows how the two devices differ.
import fcntl, glob, os, struct
def ioc(nr, size): return (2 << 30) | (size << 16) | (ord("E") << 8) | nr
def bits(fd, nr, n):
    b = bytearray((n + 7) // 8)
    try: fcntl.ioctl(fd, ioc(nr, len(b)), b)
    except OSError: return []
    return [i for i in range(n) if b[i // 8] >> (i % 8) & 1]
for node in sorted(glob.glob("/dev/input/event*"), key=lambda p: int(p[16:])):
    fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
    absb = bits(fd, 0x20 + 3, 0x40)
    if 0x2f not in absb or 1 not in bits(fd, 0x09, 32):  # touchscreens only: INPUT_PROP_DIRECT
        os.close(fd); continue
    name = bytearray(256); fcntl.ioctl(fd, ioc(0x06, 256), name)
    ids = bytearray(8); fcntl.ioctl(fd, ioc(0x02, 8), ids)
    print("device " + name.split(b"\0")[0].decode())
    print("ids bus %#x vendor %#x product %#x version %#x" % struct.unpack("<4H", ids))
    print("props", bits(fd, 0x09, 32))
    print("ev", bits(fd, 0x20, 32))
    print("key", [hex(k) for k in bits(fd, 0x20 + 1, 0x300)])
    for a in absb:
        info = bytearray(24); fcntl.ioctl(fd, ioc(0x40 + a, 24), info)
        v, lo, hi, fuzz, flat, res = struct.unpack("<6i", info)
        print(f"abs {a:#x} min {lo} max {hi} fuzz {fuzz} flat {flat} res {res}")
    os.close(fd)
