#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""hvcodec in the guest (docs/guest-video-encode-plan.md, VE0.4 and VE0.5).

Boots a clone of the desktop image with `hengevm --vcodec --share DIR` and, over the serial console:
  1. installs the build tools and Debian's libavformat (apt; --image names an image that has them);
  2. builds tools/linux/hvcodec/henge-xcode.c and hvbench.c from the --share folder;
  3. `henge-xcode --query` must list an HEVC and an H.264 hardware encoder;
  4. transcodes each test clip (3840x2160 and 1920x1080, 60 fps: H.264, HEVC 8 bit, HEVC 10 bit, AV1) to HEVC with
     the frames on the host, and copies the output back through the share. On the Mac, ffprobe must count the
     clip's frames, ffmpeg must decode it with no error (the VE0.4 exit), and ffmpeg's psnr filter against the clip
     must reach MIN_PSNR on Y, U and V and MIN_FRAME_PSNR on the worst frame;
  5. measures (VE0.5): henge-xcode's fps, its CPU time and the whole guest's, the MB/s on the socket, hengevm's CPU,
     Debian's software decode of the same clip to -f null, and the guest memcpy speed (hvbench).
The shared image never changes: the guest runs on an APFS clone, deleted at the end. Exit 1 on a failed check.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MARK = "HENGE_RC_"
SHELL = r"henge@henge:[^\n]*\$ "
PACKAGES = ["ffmpeg", "gcc", "libc6-dev", "pkg-config", "libavformat-dev", "libavcodec-dev", "libavutil-dev"]
SIZES = {"4k": "3840x2160", "1080p": "1920x1080"}
CODECS = ["h264", "hevc8", "hevc10", "av1"]
FPS = 60
# The clips carry noise, so the transcode loses more than test_vcodec's clean frames; black or swapped planes give 10 to 20 dB.
MIN_PSNR = 35.0
MIN_FRAME_PSNR = 30.0


class Fail(Exception):
    pass


def linux_dir():
    common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


def sh(p, cmd, limit=60):
    p.sendline(f"{cmd}; echo {MARK}$?")
    try:
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
    except pexpect.TIMEOUT:
        raise Fail(f"{cmd[:100]!r}: no answer within {limit} s")
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "\n")
    return re.sub(r"^henge@henge:[^\n$]*\$ ", "", out), int(p.match.group(1))


def need(p, cmd, what, limit=60):
    out, rc = sh(p, cmd, limit)
    if rc:
        raise Fail(f"{what}: {cmd[:100]!r} gave status {rc}:\n{out.strip()[-2000:]}")
    return out


def cpu_secs(pid):
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    secs = 0.0
    for part in out.split(":"):
        secs = secs * 60 + float(part)
    return secs


def make_clip(path, codec, size, seconds):
    if os.path.exists(path):
        return
    src = f"testsrc2=size={size}:rate={FPS}:duration={seconds},noise=alls=6:allf=t+u"
    enc = {
        "h264": ["-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-bf", "3", "-pix_fmt", "yuv420p"],
        "hevc8": ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-x265-params", "log-level=error:bframes=4"],
        "hevc10": ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-x265-params",
                   "log-level=error:bframes=4:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:"
                   "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"],
        "av1": ["-c:v", "libsvtav1", "-preset", "10", "-pix_fmt", "yuv420p", "-svtav1-params", "tune=0"],
    }[codec]
    rate = "40M" if size.startswith("3840") else "10M"
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", src] + enc + ["-b:v", rate, path],
                       capture_output=True, text=True)
    if r.returncode:
        raise Fail(f"cannot make {path} on the Mac: {r.stderr.strip()[-800:]}")


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v", "-show_entries",
                        "stream=codec_name,profile,pix_fmt,width,height,nb_read_frames,color_transfer", "-of", "csv=p=0", path],
                       capture_output=True, text=True)
    return r.stdout.strip()


def psnr(out, src):
    """ffmpeg's psnr filter, the output against the clip: the average of each plane and of the worst frame."""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info", "-i", out, "-i", src, "-lavfi", "[0:v][1:v]psnr", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.search(r"PSNR y:([\d.inf]+) u:([\d.inf]+) v:([\d.inf]+) average:([\d.inf]+) min:([\d.inf]+)", r.stderr)
    if r.returncode or not m:
        return None
    return dict(zip(("y", "u", "v", "average", "min"), (float(x) for x in m.groups())))


def boot(args, disk, share, err_log):
    d = args.linux_dir
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err_log, args.hengevm, "--board", "virt",
            "--kernel", os.path.join(d, "Image"), "--initrd", os.path.join(d, "initrd.img"),
            "--append", f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", disk, "--ram", str(args.ram),
            "--cpus", str(args.cpus), "--display", "1280x800", "--share", share, "--vcodec"]
    print(f"--   booting {os.path.basename(disk)} (host load average {os.getloadavg()[0]:.1f})")
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 250))
    p.expect(r"\(automatic login\)", timeout=300)
    p.expect(SHELL, timeout=60)
    sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
    sh(p, "systemctl is-system-running --wait", 180)
    return p


def install(p):
    out, _ = sh(p, "dpkg-query -W -f '${Package} ${Status}\\n' " + " ".join(PACKAGES) + " 2>/dev/null")
    have = {l.split()[0] for l in out.splitlines() if l.strip().endswith("install ok installed")}
    missing = [x for x in PACKAGES if x not in have]
    if missing:
        print(f"--   apt install {' '.join(missing)}")
        need(p, "sudo apt-get update -q >/dev/null", "apt-get update", 600)
        need(p, "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "
             + " ".join(missing) + " >/tmp/apt.log 2>&1 || { tail -20 /tmp/apt.log; false; }", "apt-get install", 1800)
    out = need(p, "dpkg-query -W -f '${Package} ${Version}\\n' ffmpeg libavformat-dev gcc", "package versions")
    print("ok   packages: " + ", ".join(l.strip() for l in out.splitlines() if l.strip()))


def fetch(p, name, dest):
    # the desktop image has no curl
    need(p, f"python3 -c 'import shutil,urllib.request as u; shutil.copyfileobj(u.urlopen(\"http://10.0.2.4/{name}\"), "
         f"open(\"{dest}\", \"wb\"))'", f"copy {name} from --share", 300)


def put(p, src, name):
    need(p, f"python3 -c 'import urllib.request as u; u.urlopen(u.Request(\"http://10.0.2.4/{name}\", "
         f"data=open(\"{src}\",\"rb\").read(), method=\"PUT\"))'", f"copy {src} to --share", 300)


def proc_stat(text):
    m = re.search(r"cpu\s+([\d ]+)", text)
    v = [int(x) for x in m.group(1).split()] if m else []
    return (sum(v) - v[3] - (v[4] if len(v) > 4 else 0), sum(v)) if v else (0, 0)


def transcode(p, pid, clip, out_codec, speed):
    out = f"/tmp/out-{out_codec}.mp4"
    c0, t0 = cpu_secs(pid), time.monotonic()
    text = need(p, f"head -1 /proc/stat; ./henge-xcode -c {out_codec} {'--speed ' if speed else ''}/tmp/{clip} {out} 2>&1 | tail -5; "
                   "head -1 /proc/stat", f"henge-xcode {clip}", 900)
    c1, t1 = cpu_secs(pid), time.monotonic()
    stats = re.findall(r"cpu\s+[\d ]+", text)
    m = re.search(r"(\d+) frames in, (\d+) with no picture, (\d+) packets out, ([\d.]+) s, ([\d.]+) fps; socket ([\d.]+) MB sent, "
                  r"([\d.]+) MB received, ([\d.]+) MB/s, (\d+) calls; cpu user ([\d.]+) s sys ([\d.]+) s", text)
    if not m or len(stats) < 2:
        raise Fail(f"henge-xcode {clip}: no summary:\n{text.strip()[-1500:]}")
    b0, a0 = proc_stat(stats[0])
    b1, a1 = proc_stat(stats[-1])
    r = dict(frames=int(m.group(1)), none=int(m.group(2)), packets=int(m.group(3)), secs=float(m.group(4)), fps=float(m.group(5)),
             sent=float(m.group(6)), recv=float(m.group(7)), mbs=float(m.group(8)), calls=int(m.group(9)),
             cpu=float(m.group(10)) + float(m.group(11)),
             guest_busy=(b1 - b0) / max(a1 - a0, 1) * 100, host_cpu=(c1 - c0) / max(t1 - t0, 1e-9) * 100 if c0 is not None and c1 is not None else float("nan"))
    return out, r


def soft_decode(p, clip):
    text = need(p, f"TIMEFORMAT='GUEST_TIME %R %U %S'; time ffmpeg -hide_banner -nostats -benchmark -i /tmp/{clip} -f null - 2>&1 "
                   "| grep -E 'frame=|bench:' | tail -3", f"software decode {clip}", 1800)
    frames = re.findall(r"frame=\s*(\d+)", text)
    gt = re.search(r"GUEST_TIME ([\d.]+) ([\d.]+) ([\d.]+)", text)
    if not frames or not gt:
        raise Fail(f"software decode {clip}: {text.strip()[-800:]}")
    n, real = int(frames[-1]), float(gt.group(1))
    return dict(frames=n, secs=real, fps=n / real, cpu=float(gt.group(2)) + float(gt.group(3)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hengevm", default=os.path.join(ROOT, "build", "hengevm"))
    ap.add_argument("--linux-dir", help="Image, initrd.img and the desktop partuuid (default: build/linux of the main checkout)")
    ap.add_argument("--image", help="a desktop image that has the packages (default: debian-desktop.img, then apt install)")
    ap.add_argument("--work-dir", help="where the disk clone and the clips go (the image's APFS volume)")
    ap.add_argument("--clips", help="a folder with the clips already made (NAME_SIZE.mp4)")
    ap.add_argument("--sizes", default="4k,1080p")
    ap.add_argument("--codecs", default=",".join(CODECS))
    ap.add_argument("--seconds", type=int, default=3)
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--ram", type=int, default=3072)
    ap.add_argument("--speed", action="store_true", help="also transcode with speed over quality")
    ap.add_argument("--no-software", action="store_true", help="skip Debian's software decode")
    ap.add_argument("--keep-log", help="copy hengevm's stderr here")
    args = ap.parse_args()
    args.linux_dir = args.linux_dir or linux_dir()
    image = args.image or os.path.join(args.linux_dir, "debian-desktop.img")
    for f in (args.hengevm, image, os.path.join(args.linux_dir, "Image"), os.path.join(args.linux_dir, "initrd.img")):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    sizes = [s for s in args.sizes.split(",") if s]
    codecs = [c for c in args.codecs.split(",") if c]
    ok = True
    rows = []
    with tempfile.TemporaryDirectory(prefix="vcodec-", dir=args.work_dir) as tmp:
        share = os.path.join(tmp, "share")
        os.mkdir(share)
        for f in ("tools/linux/hvcodec/henge-xcode.c", "tools/linux/hvcodec/hvbench.c", "host/vcodec_proto.h"):
            shutil.copy(os.path.join(ROOT, f), share)
        clips = []
        for size in sizes:
            for codec in codecs:
                name = f"{codec}_{size}.mp4"
                path = os.path.join(share, name)
                if args.clips and os.path.exists(os.path.join(args.clips, name)):
                    os.link(os.path.join(args.clips, name), path) if os.stat(args.clips).st_dev == os.stat(share).st_dev else shutil.copy(os.path.join(args.clips, name), path)
                make_clip(path, codec, SIZES[size], args.seconds)
                clips.append((name, probe(path)))
                print(f"     clip {name}: {clips[-1][1]}")
        disk, err_log = os.path.join(tmp, "disk.img"), os.path.join(tmp, "hengevm.stderr")
        r = subprocess.run(["/bin/cp", "-c", image, disk], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        p = boot(args, disk, share, err_log)
        try:
            install(p)
            need(p, "mkdir -p ~/hv && cd ~/hv", "work folder")
            for f in ("henge-xcode.c", "hvbench.c", "vcodec_proto.h"):
                fetch(p, f, f)
            need(p, "gcc -O2 -Wall -Wextra -I. henge-xcode.c $(pkg-config --cflags --libs libavformat libavcodec libavutil) -o henge-xcode 2>&1",
                 "build henge-xcode", 300)
            need(p, "gcc -O2 hvbench.c -o hvbench", "build hvbench", 120)
            print("ok   henge-xcode and hvbench built in the guest against Debian's libavformat")
            q = need(p, "./henge-xcode --query 2>&1 | grep -E '^(encoder|decoder)'", "henge-xcode --query")
            print("     " + q.strip().replace("\n", "\n     "))
            if "encoder hvc1" not in q or "encoder avc1" not in q:
                raise Fail("QUERY lists no HEVC or no H.264 encoder")
            print("ok   QUERY from the guest lists the H.264 and HEVC encoders")
            mem = need(p, "./hvbench", "hvbench")
            for line in re.findall(r"hvbench: [^\n]+", mem):
                print(f"     {line}")
            for name, info in clips:
                fetch(p, name, f"/tmp/{name}")
                want = int(info.split(",")[-1]) if info.split(",")[-1].isdigit() else -1
                for out_codec, speed in [("hevc", False)] + ([("hevc", True)] if args.speed else []):
                    out, r = transcode(p, p.pid, name, out_codec, speed)
                    tag = f"{name} to {out_codec}{' speed' if speed else ''}"
                    oname = f"out-{name[:-4]}-{out_codec}{'-speed' if speed else ''}.mp4"
                    put(p, out, oname)
                    got = probe(os.path.join(share, oname))
                    dec = subprocess.run(["ffmpeg", "-v", "error", "-i", os.path.join(share, oname), "-f", "null", "-"], capture_output=True, text=True)
                    frames = int(got.split(",")[-1]) if got and got.split(",")[-1].isdigit() else -1
                    q = psnr(os.path.join(share, oname), os.path.join(share, name))
                    sharp = q is not None and min(q["y"], q["u"], q["v"]) >= MIN_PSNR and q["min"] >= MIN_FRAME_PSNR
                    good = frames == want and not dec.stderr.strip() and dec.returncode == 0 and r["packets"] == want and sharp
                    ok &= good
                    pq = f"PSNR y {q['y']:.1f} u {q['u']:.1f} v {q['v']:.1f} dB, worst frame {q['min']:.1f} dB" if q else "no PSNR"
                    print(f"{'ok  ' if good else 'FAIL'} {tag}: {r['fps']:.1f} fps, {r['packets']} packets, output {got} "
                          f"({frames} of {want} frames, {len(dec.stderr.strip().splitlines())} decode errors), {pq}")
                    if q:
                        r.update(psnr_y=q["y"], psnr_u=q["u"], psnr_v=q["v"], psnr_min=q["min"])
                    print(f"     socket {r['sent']:.1f} MB up, {r['recv']:.1f} MB down, {r['mbs']:.1f} MB/s, {r['calls']} calls; "
                          f"henge-xcode CPU {r['cpu']:.2f} s ({r['cpu'] / r['secs'] * 100:.0f}% of one core), guest busy {r['guest_busy']:.0f}% "
                          f"of {args.cpus} CPUs, hengevm {r['host_cpu']:.0f}% of one host core")
                    rows.append((tag, r))
                    os.remove(os.path.join(share, oname))
                if not args.no_software:
                    s = soft_decode(p, name)
                    print(f"     Debian software decode {name} -f null: {s['fps']:.1f} fps ({s['frames']} frames in {s['secs']:.2f} s, "
                          f"guest CPU {s['cpu']:.2f} s)")
                    rows.append((f"{name} software decode", s))
                sh(p, f"rm -f /tmp/{name} /tmp/out-*.mp4")
        except pexpect.TIMEOUT:
            raise Fail("timeout waiting for the guest; tail:\n" + (p.before or "")[-1500:])
        except pexpect.EOF:
            raise Fail("hengevm ended early; tail:\n" + (p.before or "")[-1500:] + "\nstderr:\n" + open(err_log, errors="replace").read()[-2000:])
        finally:
            if p.isalive():
                p.sendline("sudo poweroff")
                try:
                    p.expect(pexpect.EOF, timeout=90)
                except pexpect.TIMEOUT:
                    p.terminate(force=True)
            p.close()
            log = open(err_log, errors="replace").read() if os.path.exists(err_log) else ""
            for line in re.findall(r"hengevm: vcodec: [^\n]+", log)[-12:]:
                print(f"     {line}")
            if args.keep_log and os.path.exists(err_log):
                shutil.copy(err_log, args.keep_log)
    for tag, r in rows:
        print(f"RESULT {tag}: " + ", ".join(f"{k}={v:.2f}" if isinstance(v, float) else f"{k}={v}" for k, v in r.items()))
    if not ok:
        raise Fail("see the FAIL lines above")


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
