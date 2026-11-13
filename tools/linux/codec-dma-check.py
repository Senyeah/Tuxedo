#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""The hvcodec DMA channel in the guest (docs/guest-video-encode-plan.md, VE4.2 to VE4.5).

Boots a clone of the desktop image through U-Boot with `hengevm --vcodec-dma --share DIR` and, over the serial console:
  1. the device is on the bus, and no driver has it before henge-codec-dkms;
  2. installs henge-codec-dkms (--out codec/) with apt, which brings dkms, gcc and the headers: DKMS must build the
     module, and /dev/hvcodec must be there at once, root:video 0660, with no restart;
  3. builds hvcodec/hvxfer.c with libhvcodec, and measures 4K NV12 and P010 upload and download in fps on
     /dev/hvcodec and on TCP (VE4.4), with the frames in RAM already; the first frame must come back unchanged;
  4. with the patched ffmpeg (--out ffmpeg/bin): the plan's main command and a hwdownload, software filter, hwupload
     chain, on /dev/hvcodec and on TCP (HENGE_VCODEC=10.0.2.4:8470), each output checked on the Mac (frames, decode,
     PSNR, audio in sync), and ffmpeg must say which channel it has;
  5. the fallback: with the module unloaded the chain works on TCP and ffmpeg warns; a ninth open is refused; a
     process killed during transfers leaves the device working;
  6. with --kernel-update (VE4.5): apt installs the newest 16 KB kernel and its headers, DKMS builds the module for it,
     the machine powers off and boots again into it, and /dev/hvcodec works there.
The shared image never changes: the guest runs on an APFS clone, deleted at the end. Exit 1 on a failed check.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
_spec = importlib.util.spec_from_file_location("vcodec_check", os.path.join(HERE, "vcodec-check.py"))
vc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vc)
Fail, sh, need, put, fetch, probe, ffmpeg_case = vc.Fail, vc.sh, vc.need, vc.put, vc.fetch, vc.probe, vc.ffmpeg_case
SHELL = vc.SHELL
TCP = "HENGE_VCODEC=10.0.2.4:8470"


def boot(args, disk, share, err_log):
    argv = ["/bin/sh", "-c", 'exec "$@" 2>>"$0"', err_log, args.hengevm, "--board", "virt", "--firmware", args.firmware,
            "--disk", disk, "--ram", str(args.ram), "--cpus", str(args.cpus), "--display", "1280x800", "--share", share,
            "--vcodec-dma"]
    print(f"--   booting {os.path.basename(disk)} through U-Boot (host load average {os.getloadavg()[0]:.1f})")
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 250))
    p.expect(r"\(automatic login\)", timeout=600)
    p.expect(SHELL, timeout=60)
    sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
    sh(p, "systemctl is-system-running --wait", 300)
    return p


def poweroff(p):
    p.sendline("sudo poweroff")
    try:
        p.expect(pexpect.EOF, timeout=180)
    except pexpect.TIMEOUT:
        p.terminate(force=True)
    p.close()


def hvxfer(p, chan, fmt, frames, pad=0):
    cmd = f"./hvxfer --format {fmt} --frames {frames} --pad {pad}" + (f" --channel {chan}" if chan else "")
    out = need(p, cmd, f"hvxfer {chan or 'default'} {fmt}", 900)
    return [json.loads(l) for l in out.splitlines() if l.startswith("{")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hengevm", default=os.path.join(ROOT, "build", "hengevm"))
    ap.add_argument("--linux-dir", help="u-boot.bin and the images (default: build/linux of the main checkout)")
    ap.add_argument("--image", help="default: KW-out/debian-desktop.img in --linux-dir")
    ap.add_argument("--firmware", help="default: u-boot.bin in --linux-dir")
    ap.add_argument("--out", required=True, help="the build output: codec/henge-codec-dkms_*.deb and ffmpeg/bin")
    ap.add_argument("--clips", help="a folder with hevc8_4k.mp4 and hevc8_1080p.mp4 (made if missing)")
    ap.add_argument("--work-dir")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--ram", type=int, default=3072)
    ap.add_argument("--grow", type=int, default=8, help="the clone's size in GB (the guest grows its root to it)")
    ap.add_argument("--frames", type=int, default=240, help="hvxfer frames on /dev/hvcodec (a quarter of that on TCP)")
    ap.add_argument("--no-ffmpeg", action="store_true")
    ap.add_argument("--kernel-update", action="store_true", help="VE4.5")
    ap.add_argument("--results", help="write the measurements here as JSON")
    ap.add_argument("--keep-log", help="copy hengevm's stderr here")
    args = ap.parse_args()
    args.linux_dir = args.linux_dir or vc.linux_dir()
    image = args.image or os.path.join(args.linux_dir, "KW-out", "debian-desktop.img")
    args.firmware = args.firmware or os.path.join(args.linux_dir, "u-boot.bin")
    debs = sorted(f for f in os.listdir(os.path.join(args.out, "codec")) if f.startswith("henge-codec-dkms_") and f.endswith(".deb"))
    for f in (args.hengevm, image, args.firmware):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    if not debs:
        raise Fail(f"no henge-codec-dkms in {args.out}/codec: run tools/linux/build-codec-dkms-pkg.sh")
    ok = True
    res = {"xfer": [], "ffmpeg": {}, "checks": {}}

    def check(name, good, text=""):
        nonlocal ok
        ok &= bool(good)
        res["checks"][name] = bool(good)
        print(f"{'ok  ' if good else 'FAIL'} {name}{': ' + text if text else ''}")

    with tempfile.TemporaryDirectory(prefix="codecdma-", dir=args.work_dir) as tmp:
        share = os.path.join(tmp, "share")
        os.mkdir(share)
        for f in ("tools/linux/hvcodec/hvxfer.c", "tools/linux/hvcodec/libhvcodec/hvcodec.c", "tools/linux/hvcodec/libhvcodec/hvcodec.h",
                  "host/vcodec_proto.h", "host/vcodec_dev.h"):
            shutil.copy(os.path.join(ROOT, f), share)
        shutil.copy(os.path.join(args.out, "codec", debs[-1]), share)
        runtime = []
        if not args.no_ffmpeg:
            for f in ("ffmpeg", "ffprobe"):
                shutil.copy(os.path.join(args.out, "ffmpeg", "bin", f), share)
            for line in open(os.path.join(args.out, "ffmpeg", "ffmpeg.manifest")):
                if line.startswith("runtime="):
                    runtime = line.split("=", 1)[1].split()
            for size in ("4k", "1080p"):
                name = f"hevc8_{size}.mp4"
                if args.clips and os.path.exists(os.path.join(args.clips, name)):
                    shutil.copy(os.path.join(args.clips, name), share)
                vc.make_clip(os.path.join(share, name), "hevc8", vc.SIZES[size], 3)
        disk, err_log = os.path.join(tmp, "disk.img"), os.path.join(tmp, "hengevm.stderr")
        r = subprocess.run(["/bin/cp", "-c", image, disk], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        os.truncate(disk, max(os.path.getsize(disk), args.grow << 30))
        p = boot(args, disk, share, err_log)
        try:
            kver = need(p, "uname -r", "kernel").strip().splitlines()[-1]
            print(f"     kernel {kver}; {need(p, 'df -h / | tail -1', 'df').strip()}")
            out = need(p, "for d in /sys/bus/pci/devices/*; do [ \"$(cat $d/device)\" = 0x107f ] && echo $d $(cat $d/class) "
                          "$(readlink $d/virtio*/driver 2>/dev/null | xargs -r basename); done", "the device")
            check("the device is on the bus (1af4:107f), with no driver before the package", "0x048000" in out and "henge_codec" not in out, out.strip())
            src = need(p, "grep -rhE '^(URIs|Suites|deb |Enabled)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u", "apt sources")
            print("     apt sources: " + "; ".join(l.strip() for l in src.splitlines() if l.strip()))
            # the install: dkms, the compiler and the headers come with the package (decision 11)
            t0 = time.time()
            need(p, "sudo apt-get update -q >/dev/null 2>&1", "apt-get update", 900)
            deb = debs[-1]
            fetch(p, deb, f"/tmp/{deb}")
            text = need(p, f"sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q linux-headers-$(uname -r) /tmp/{deb} >/tmp/apt.log 2>&1; "
                           "echo APT_RC=$?; grep -E 'henge-codec|dkms|Building|Installing|newly installed|Need to get|After this operation' /tmp/apt.log | tail -18", "install", 3600)
            res["install_secs"] = time.time() - t0
            check("apt install henge-codec-dkms", "APT_RC=0" in text, f"{res['install_secs']:.0f} s\n" + text.strip())
            st = need(p, "sudo dkms status henge-codec; ls -l /dev/hvcodec; id henge | tr ' ' '\\n' | grep -c video; lsmod | grep -c henge_codec; "
                         "sudo dmesg | grep -iE 'henge|hvcodec' | tail -3", "after the install")
            print(st)
            check("DKMS built and installed the module for the running kernel", re.search(rf"{re.escape(kver)}.*installed", st))
            check("/dev/hvcodec at once, root:video 0660", re.search(r"crw-rw---- 1 root video .* /dev/hvcodec", st))
            need(p, "cp /tmp/" + deb + " ~/ 2>/dev/null; true", "keep")
            # hvxfer
            for f in ("hvxfer.c", "hvcodec.c", "hvcodec.h", "vcodec_proto.h", "vcodec_dev.h"):
                fetch(p, f, f)
            need(p, "gcc -O2 -Wall -Wextra -I. hvxfer.c hvcodec.c -lpthread -o hvxfer 2>&1", "build hvxfer", 300)
            for fmt in ("nv12", "p010"):
                for chan, frames in (("/dev/hvcodec", args.frames), ("10.0.2.4:8470", max(8, args.frames // 8))):
                    rows = hvxfer(p, chan, fmt, frames)
                    res["xfer"] += rows
                    for x in rows:
                        print(f"     {fmt} {x['dir']:8} on {chan:13}: {x['fps']:7.1f} fps, {x['MBps']:6.0f} MB/s, guest CPU {x['cpu_s'] / x['secs'] * 100:4.0f}% "
                              f"of a core ({x['sys_s'] / x['secs'] * 100:.0f}% in the kernel), {x['frames']} frames")
            got = {(x["format"], x["dir"], x["dma"]): x["fps"] for x in res["xfer"]}
            check("4K NV12 upload and download each above 60 fps on /dev/hvcodec",
                  got.get(("nv12", "upload", 1), 0) >= 60 and got.get(("nv12", "download", 1), 0) >= 60)
            rows = hvxfer(p, "", "nv12", 16, pad=4096)
            check("the default channel is /dev/hvcodec, with rows padded past a page", rows and rows[0]["dma"] == 1)

            # the ninth context, and a process killed in the middle
            out = need(p, "( for i in 3 4 5 6 7 8 9 10 11; do eval \"exec $i<>/dev/hvcodec\" 2>/tmp/open.err || "
                          "{ echo refused at $((i - 2)): $(cat /tmp/open.err); break; }; done )", "nine opens")
            check("a ninth context is refused", "refused at 9" in out and "busy" in out, out.strip())
            need(p, f"./hvxfer --format p010 --frames 100000 >/dev/null 2>&1 & sleep 3; kill -9 $!; wait $! 2>/dev/null; true", "kill", 120)
            rows = hvxfer(p, "/dev/hvcodec", "nv12", 16)
            check("after a process killed during transfers, the device works", rows and rows[0]["dma"] == 1)

            if not args.no_ffmpeg:
                vc.install(p, runtime, base=[], show=("dkms",))
                for f in ("ffmpeg", "ffprobe", "hevc8_4k.mp4", "hevc8_1080p.mp4"):
                    fetch(p, f, f)
                need(p, "chmod +x ffmpeg ffprobe", "chmod")
                out = need(p, "./ffmpeg -hide_banner -v verbose -init_hw_device henge -f lavfi -i nullsrc -frames:v 1 -f null - 2>&1 | grep 'Henge codec'", "channel")
                check("ffmpeg names /dev/hvcodec", "at /dev/hvcodec" in out, out.strip())
                main_cmd = "-hwaccel henge -hwaccel_output_format henge -i {c} -c:v hevc_henge -b:v 20M -c:a copy"
                chain = "-init_hw_device henge -hwaccel henge -hwaccel_output_format henge -i {c} -vf hwdownload,format=nv12,hflip,hflip,hwupload -c:v hevc_henge -b:v 20M -c:a copy"
                for size in ("4k", "1080p"):
                    clip = f"hevc8_{size}.mp4"
                    for name, cmd in (("main", main_cmd), ("chain", chain)):
                        for chan, exe in (("dev", "./ffmpeg"), ("tcp", f"{TCP} ./ffmpeg")):
                            good, r = ffmpeg_case(p, share, f"{name}-{size}-{chan}", clip, 180, cmd.format(c=clip), exe=exe)
                            ok &= good
                            res["ffmpeg"][f"{name}-{size}-{chan}"] = dict(r, good=good)
                # the fallback: no module
                need(p, "sudo modprobe -r henge_codec; ! ls /dev/hvcodec 2>/dev/null", "unload the module")
                out = need(p, f"./ffmpeg -hide_banner -nostats -y {chain.format(c='hevc8_1080p.mp4')} /tmp/fb.mp4 2>&1 | grep -iE 'TCP|rror' | head -3",
                           "fallback", 600)
                check("with no module, ffmpeg warns and uses TCP", "over TCP" in out, out.strip())
                good, r = ffmpeg_case(p, share, "chain-1080p-nomodule", "hevc8_1080p.mp4", 180, chain.format(c="hevc8_1080p.mp4"))
                ok &= good
                res["ffmpeg"]["chain-1080p-nomodule"] = dict(r, good=good)
                need(p, "sudo modprobe henge_codec && sleep 1 && ls -l /dev/hvcodec", "load the module again")

            if args.kernel_update:
                # A kernel update needs a newer kernel in the guest's sources. The image's sources are the pinned snapshot,
                # which has none: then the same snapshot's trixie-security stands in for Debian publishing one.
                sim = need(p, "apt-get -s install linux-image-arm64-16k 2>/dev/null | grep -c '^Inst linux-image'; true", "a newer kernel?").strip()
                if sim.splitlines()[-1] == "0":
                    snap = open(os.path.join(ROOT, "tools/linux/versions.env")).read()
                    stamp = re.search(r"DEBIAN_SNAPSHOT=(\S+)", snap).group(1)
                    need(p, "printf 'Types: deb\\nURIs: http://snapshot.debian.org/archive/debian-security/%s/\\nSuites: trixie-security\\n"
                            "Components: main\\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\\nCheck-Valid-Until: no\\n' "
                            f"{stamp} | sudo tee /etc/apt/sources.list.d/ve4-security.sources >/dev/null && sudo apt-get update -q >/dev/null 2>&1",
                         "the security snapshot", 900)
                    res["kernel_source"] = f"snapshot.debian.org debian-security {stamp}, trixie-security (the image's own sources have no newer kernel)"
                    print(f"     no newer kernel in the image's sources: added trixie-security from the snapshot {stamp}")
                else:
                    res["kernel_source"] = "the image's own sources"
                t0 = time.time()
                text = need(p, "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q linux-image-arm64-16k linux-headers-arm64-16k "
                               ">/tmp/k.log 2>&1; echo APT_RC=$?; grep -iE 'linux-image|linux-headers|dkms|henge|Building|Installing|u-boot' /tmp/k.log | tail -25; "
                               "ls /boot; sudo dkms status henge-codec; grep -m3 -E '^\\s*(linux|label|default)' /boot/extlinux/extlinux.conf", "kernel update", 3600)
                print(text)
                res["kernel_update_secs"] = time.time() - t0
                vers = sorted(set(re.findall(r"vmlinuz-(\S+)", text)))
                newest = sorted(vers, key=lambda v: [int(x) if x.isdigit() else x for x in re.split(r"[.+-]", v)])[-1] if vers else kver
                res["kernel_before"], res["kernel_after"] = kver, newest
                check("apt installed a newer kernel", "APT_RC=0" in text and newest != kver, f"{kver} -> {newest}")
                check("DKMS built the module for it", re.search(rf"{re.escape(newest)}.*installed", text))
                poweroff(p)
                p = boot(args, disk, share, err_log)
                now = need(p, "uname -r", "kernel").strip().splitlines()[-1]
                check("the machine came back on the new kernel", now == newest, now)
                st = need(p, "ls -l /dev/hvcodec; sudo dkms status henge-codec; sudo dmesg | grep -i hvcodec | tail -2", "after the restart")
                print(st)
                check("/dev/hvcodec after the restart", "crw-rw---- 1 root video" in st)
                rows = hvxfer(p, "/dev/hvcodec", "nv12", 60)
                check("transfers on the new kernel", rows and rows[0]["dma"] == 1, ", ".join(f"{x['dir']} {x['fps']:.1f} fps" for x in rows))
                res["xfer_after_update"] = rows
        except (Fail, pexpect.EOF, pexpect.TIMEOUT) as e:
            ok = False
            print(f"FAIL {e}")
            print("stderr:\n" + open(err_log, errors="replace").read()[-2000:])
        finally:
            if p.isalive():
                poweroff(p)
            log = open(err_log, errors="replace").read()
            for line in re.findall(r"hengevm: vcodec: [^\n]+|virtio-hvcodec[^\n]+", log)[-12:]:
                print("     " + line)
            if args.keep_log:
                shutil.copy(err_log, args.keep_log)
        if args.results:
            with open(args.results, "w") as f:
                json.dump(res, f, indent=1)
    print("all checks passed" if ok else "SOME CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Fail as e:
        print(f"FAIL {e}")
        sys.exit(1)
