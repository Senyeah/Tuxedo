#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# ///
"""Compares Henge's virt device tree with QEMU's, node by node.

QEMU: -M virt,gic-version=3,highmem=off,dumpdtb. Henge: build/hengevm --dump-dtb.
Exit 1 on any difference that is not in the allow lists below.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU = os.environ.get("QEMU", "/opt/homebrew/bin/qemu-system-aarch64")
QEMU_MAX_MB = 3072  # highmem=off keeps RAM below 4 GB, so QEMU refuses -m 4096

# Top-level nodes only QEMU has (devices Henge leaves out by design).
QEMU_ONLY_NODES = {"platform-bus@c000000", "fw-cfg@9020000", "pmu", "flash@0"}
QEMU_ONLY_PREFIXES = ("virtio_mmio@",)
# Top-level nodes only Henge has: the device's battery, mains and backlight (LINUX-PLAN-13).
HENGE_ONLY_NODES = {"i2c@90c0000", "ac-power"}
# Subtrees only QEMU has: the ITS (no MSI) and the CPU topology.
QEMU_ONLY_PATHS = {"/intc@8000000/its@8080000", "/cpus/cpu-map"}
# Properties that differ by design: path -> names.
IGNORED_PROPS = {
    "/pcie@10000000": {"msi-map"},
    "/chosen": {"rng-seed", "kaslr-seed"},  # random per tree
    "/memory@40000000": {"reg"},  # checked against the RAM size instead
    "/intc@8000000": {"reg"},  # checked piecewise
}
# Henge says arm,armv8 and has no cache properties.
CPU_IGNORED = {"compatible", "next-level-cache", "i-cache-sets", "i-cache-size", "i-cache-block-size",
               "d-cache-sets", "d-cache-size", "d-cache-block-size"}

# Phandle cells by property: (stride, position), to compare references by node path.
PHANDLE_PROPS = {"interrupt-parent": (1, 0), "clocks": (1, 0), "gpios": (3, 0), "msi-map": (4, 1)}
INTERRUPT_MAP_STRIDE, INTERRUPT_MAP_PARENT = 10, 4


def parse_dts(text):
    """dtc text to {path: {prop: value}}. A value is True, a list of ints, or a list of strings."""
    nodes, stack = {}, []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("/dts-v1/", "//")):
            continue
        m = re.match(r"^([^\s=;{}]+)\s*\{$", line)
        if m:
            name = m.group(1)
            path = "/" if not stack else (stack[-1].rstrip("/") + "/" + name)
            stack.append(path)
            nodes[path] = {}
            continue
        if line == "};":
            stack.pop()
            continue
        m = re.match(r"^([^\s=;]+)(?:\s*=\s*(.*))?;$", line)
        if not m:
            raise ValueError("cannot parse: " + line)
        name, val = m.group(1), m.group(2)
        if val is None:
            nodes[stack[-1]][name] = True
        elif val.startswith("<"):
            nodes[stack[-1]][name] = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", val)]
        else:
            nodes[stack[-1]][name] = re.findall(r'"([^"]*)"', val)
    return nodes


def normalise(nodes):
    """Replaces phandle values by the path of the node that owns them; drops phandle properties."""
    owner = {p["phandle"][0]: path for path, p in nodes.items() if "phandle" in p}
    for props in nodes.values():
        props.pop("phandle", None)
        for name, (stride, pos) in PHANDLE_PROPS.items():
            cells = props.get(name)
            for i in range(pos, len(cells or []), stride):
                cells[i] = owner.get(cells[i], cells[i])
        cells = props.get("interrupt-map")
        for i in range(INTERRUPT_MAP_PARENT, len(cells or []), INTERRUPT_MAP_STRIDE):
            cells[i] = owner.get(cells[i], cells[i])
    return nodes


def dtb_to_nodes(dtb):
    out = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", dtb], capture_output=True, text=True, check=True).stdout
    return normalise(parse_dts(out))


def qemu_dtb(path, ncpus, ram_mb):
    cmd = [QEMU, "-M", f"virt,gic-version=3,highmem=off,dumpdtb={path}", "-cpu", "max", "-smp", str(ncpus),
           "-m", str(ram_mb), "-display", "none"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(path):
        raise RuntimeError("qemu failed: " + r.stderr.strip())


def henge_dtb(path, ncpus, ram_mb):
    tool = os.path.join(ROOT, "build", "hengevm")
    cmd = [tool, "--board", "virt", "--dump-dtb", path, "--cpus", str(ncpus), "--ram", str(ram_mb)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("hengevm --dump-dtb failed: " + r.stderr.strip())


def fmt(v):
    if v is None:
        return "(absent)"
    if isinstance(v, list) and v and all(isinstance(x, int) for x in v):
        return " ".join(hex(x) for x in v)
    return str(v)


def is_qemu_only(path):
    top = path.split("/")[1]
    return (top in QEMU_ONLY_NODES or top.startswith(QEMU_ONLY_PREFIXES)
            or any(path == p or path.startswith(p + "/") for p in QEMU_ONLY_PATHS))


def compare(q, h, ncpus, ram_mb):
    """Returns (errors, allowed): lists of messages."""
    errors, allowed = [], []
    for path in sorted(set(q) | set(h)):
        if path not in h:
            (allowed if is_qemu_only(path) else errors).append(f"{path}: only in QEMU")
            continue
        if path not in q:
            (allowed if path.split("/")[1] in HENGE_ONLY_NODES else errors).append(f"{path}: only in Henge")
            continue
        ignored = set(IGNORED_PROPS.get(path, ()))
        if re.fullmatch(r"/cpus/cpu@\d+", path):
            ignored |= CPU_IGNORED
            if ncpus == 1:
                ignored.add("enable-method")  # QEMU leaves it out for one CPU; Henge always names psci
        for name in sorted(set(q[path]) | set(h[path])):
            qv, hv = q[path].get(name), h[path].get(name)
            if qv != hv:
                msg = f"{path}: {name}: QEMU {fmt(qv)}, Henge {fmt(hv)}"
                (allowed if name in ignored else errors).append(msg)

    # Properties checked by rule rather than by value.
    ram = ram_mb << 20
    mem = h.get("/memory@40000000", {}).get("reg")
    if mem != [0, 0x40000000, ram >> 32, ram & 0xffffffff]:
        errors.append(f"/memory@40000000: reg {fmt(mem)}, expected base 0x40000000 and {ram_mb} MB")
    qmem = q.get("/memory@40000000", {}).get("reg")
    if ram_mb <= QEMU_MAX_MB and qmem != mem:
        errors.append(f"/memory@40000000: reg QEMU {fmt(qmem)}, Henge {fmt(mem)}")
    qg, hg = q.get("/intc@8000000", {}).get("reg"), h.get("/intc@8000000", {}).get("reg")
    if not qg or not hg or len(qg) != 8 or len(hg) != 8 or qg[:6] != hg[:6]:
        errors.append(f"/intc@8000000: reg QEMU {fmt(qg)}, Henge {fmt(hg)}")
    elif hg[6:] != [0, 0x20000 * ncpus]:
        errors.append(f"/intc@8000000: redistributor size {fmt(hg[6:])}, expected 0x20000 * {ncpus}")
    else:
        allowed.append(f"/intc@8000000: redistributor size QEMU {hex(qg[7])}, Henge {hex(hg[7])}")
    cpus = [p for p in h if re.fullmatch(r"/cpus/cpu@\d+", p)]
    if len(cpus) != ncpus:
        errors.append(f"Henge has {len(cpus)} cpu nodes, expected {ncpus}")
    return errors, allowed


def run_case(tmp, ncpus, ram_mb, verbose):
    qmb = min(ram_mb, QEMU_MAX_MB)
    qd = os.path.join(tmp, f"q{ncpus}-{qmb}.dtb")
    hd = os.path.join(tmp, f"h{ncpus}-{ram_mb}.dtb")
    if not os.path.exists(qd):
        qemu_dtb(qd, ncpus, qmb)
    henge_dtb(hd, ncpus, ram_mb)
    errors, allowed = compare(dtb_to_nodes(qd), dtb_to_nodes(hd), ncpus, ram_mb)
    note = f" (QEMU reference at {qmb} MB; memory size checked by rule)" if qmb != ram_mb else ""
    print(f"{ncpus} CPUs, {ram_mb} MB{note}: {'FAIL' if errors else 'ok'}, {len(allowed)} allowed differences")
    if verbose:
        for a in allowed:
            print("  allowed:", a)
    for e in errors:
        print("  DIFF:", e)
    return not errors


def check_options(tmp):
    """--dump-dtb keeps --append in /chosen and refuses --initrd, which it cannot place."""
    tool = os.path.join(ROOT, "build", "hengevm")
    path, append = os.path.join(tmp, "append.dtb"), "console=ttyAMA0 break=top"
    r = subprocess.run([tool, "--board", "virt", "--dump-dtb", path, "--append", append], capture_output=True, text=True)
    dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", path], capture_output=True, text=True).stdout if r.returncode == 0 else ""
    errors = []
    if f'bootargs = "{append}";' not in dts:
        errors.append(f"--dump-dtb --append: no bootargs line (exit {r.returncode}: {r.stderr.strip()})")
    r = subprocess.run([tool, "--board", "virt", "--dump-dtb", path, "--initrd", path], capture_output=True, text=True)
    if r.returncode != 2 or "--initrd" not in r.stderr:
        errors.append(f"--dump-dtb --initrd: exit {r.returncode}, expected a usage error")
    print(f"--dump-dtb options: {'FAIL' if errors else 'ok'}")
    for e in errors:
        print("  ", e)
    return not errors


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cpus", type=int, nargs="+", default=[1, 2, 4])
    ap.add_argument("--ram-mb", type=int, nargs="+", default=[1024, 4096])
    ap.add_argument("-v", "--verbose", action="store_true", help="list allowed differences")
    args = ap.parse_args()
    for tool in ("dtc", QEMU, os.path.join(ROOT, "build", "hengevm")):
        if not (shutil.which(tool) or os.path.exists(tool)):
            sys.exit(f"missing tool: {tool} (run make build/hengevm)")
    with tempfile.TemporaryDirectory() as tmp:
        results = [run_case(tmp, c, r, args.verbose) for c in args.cpus for r in args.ram_mb]
        results.append(check_options(tmp))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
