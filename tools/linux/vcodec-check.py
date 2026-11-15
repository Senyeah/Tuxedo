#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""hvcodec in the guest (docs/guest-video-encode-plan.md, VE0.4 and VE0.5).

Boots a clone of the desktop image with `tuxvm --vcodec --share DIR` and, over the serial console:
  1. installs the build tools and Debian's libavformat (apt; --image names an image that has them);
  2. builds tools/linux/hvcodec/tux-xcode.c and hvbench.c from the --share folder;
  3. `tux-xcode --query` must list an HEVC and an H.264 hardware encoder;
  4. transcodes each test clip (3840x2160 and 1920x1080, 60 fps: H.264, HEVC 8 bit, HEVC 10 bit, AV1, VP9) to HEVC with
     the frames on the host, and copies the output back through the share. On the Mac, ffprobe must count the
     clip's frames, ffmpeg must decode it with no error (the VE0.4 exit), and ffmpeg's psnr filter against the clip
     must reach MIN_PSNR on Y, U and V and MIN_FRAME_PSNR on the worst frame;
  5. measures (VE0.5): tux-xcode's fps, its CPU time and the whole guest's, the MB/s on the socket, tuxvm's CPU,
     Debian's software decode of the same clip to -f null, and the guest memcpy speed (hvbench).
With --ffmpeg DIR (VE2, the patched ffmpeg from tools/linux/build-ffmpeg.sh), it also copies DIR's ffmpeg, ffprobe and
tux-codec-info to the guest, checks `tux-codec-info --json`, and runs the plan's main command on each clip:
  ffmpeg -hwaccel tux -hwaccel_output_format tux -i CLIP -c:v hevc_tux -b:v 20M -c:a copy out.mp4
The output must have the clip's frames, decode with no error, reach MIN_PSNR, and keep the audio in sync: the same
video times as the clip, and the same audio start, duration and packet count. Its fps is set against tux-xcode's
on the same clip in the same run. Then a scale_tux, a software filter chain and an h264_tux output. Before the clips,
each input format goes to h264_tux and hevc_tux, and the profile must follow the rule in PROFILE_RULE.
With --apt TREE (VE3, the repository of publish-apt.sh, build/linux/apt), it serves TREE through --share and checks the
packages instead: tux-guest from TREE (its key and its apt source, Enabled: no, with which apt update gives no error),
then tux-ffmpeg. `ffmpeg` must be the Tuxedo build through /usr/local/bin and /usr/bin/ffmpeg Debian's, unchanged;
`man ffmpeg-tux` must open and list each encoder and option (hvcodec/manpage-check.py); tux-codec-info --json; the
main command with `ffmpeg` on each clip; a reinstall keeps the links; apt remove gives Debian's ffmpeg back; and an
admin's own file in /usr/local/bin stays through an install and a remove.
The shared image never changes: the guest runs on an APFS clone, deleted at the end. Exit 1 on a failed check.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import pexpect
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MARK = "TUX_RC_"
PACKAGES = ["ffmpeg", "gcc", "libc6-dev", "pkg-config", "libavformat-dev", "libavcodec-dev", "libavutil-dev"]
SIZES = {"4k": "3840x2160", "1080p": "1920x1080"}
CODECS = ["h264", "hevc8", "hevc10", "av1", "vp9"]
FPS = 60
# The clips carry noise, so the transcode loses more than test_vcodec's clean frames; black or swapped planes give 10 to 20 dB.
MIN_PSNR = 35.0
MIN_FRAME_PSNR = 30.0


# The encoders' profile when -profile is not set (tuxenc.c auto_profiles): input format to profile, and a fallback
# where the device does not list the first. The output's chroma must be the input's (bgra: 4:2:0).
PROFILE_RULE = {
    "hevc_tux": {"nv12": ["HEVC_Main_AutoLevel"], "p010le": ["HEVC_Main10_AutoLevel"], "nv16": ["HEVC_Main42210_AutoLevel"],
                   "p210le": ["HEVC_Main42210_AutoLevel"], "nv24": ["HEVC_Main444_AutoLevel"], "p410le": ["HEVC_Main44410_AutoLevel"],
                   "bgra": ["HEVC_Main_AutoLevel"]},
    "h264_tux": {"nv12": ["H264_High_AutoLevel"], "p010le": ["H264_High10_AutoLevel", "H264_High_AutoLevel"],
                   "nv16": ["H264_High422_AutoLevel"], "p210le": ["H264_High422_AutoLevel"],
                   "nv24": ["H264_High444Predictive_AutoLevel"], "p410le": ["H264_High444Predictive_AutoLevel"],
                   "bgra": ["H264_High_AutoLevel"]},
}


def deb_key(v):
    """Sort key for a Debian version (epoch, then dpkg's order of upstream and revision, without ~)."""
    epoch, _, rest = v.rpartition(":") if ":" in v else ("0", "", v)
    def part(x):
        return [int(t) if t.isdigit() else [(ord(c) if c.isalpha() else ord(c) + 256) for c in t]
                for t in re.findall(r"\d+|\D+", x)]
    up, _, rev = rest.rpartition("-") if "-" in rest else (rest, "", "0")
    return (int(epoch or 0), part(up), part(rev))


def chroma_of(pix_fmt):
    return "4:4:4" if "444" in pix_fmt or pix_fmt.startswith(("nv24", "p410")) else \
           "4:2:2" if "422" in pix_fmt or pix_fmt.startswith(("nv16", "p210")) else "4:2:0"


def check_profiles(p, encs):
    """Each input format to h264_tux and hevc_tux: the profile in the verbose log must follow PROFILE_RULE for the
    device's list, and the output must keep the input's chroma."""
    ok = True
    for enc, codec in (("hevc_tux", "hvc1"), ("h264_tux", "avc1")):
        listed = {x["name"] for x in encs[codec].get("profiles", [])}
        for fmt, names in PROFILE_RULE[enc].items():
            want = next((n for n in names if n in listed), "default")
            out = need(p, f"./ffmpeg -hide_banner -nostats -v verbose -y -f lavfi -i testsrc2=size=640x360:rate=30 -frames:v 10 "
                          f"-pix_fmt {fmt} -c:v {enc} -b:v 2M /tmp/prof.mp4 2>&1 | grep -E 'Tuxedo .* encoder|no profile|has no'; "
                          "./ffprobe -v error -select_streams v -show_entries stream=profile,pix_fmt -of csv=p=0 /tmp/prof.mp4",
                       f"{enc} from {fmt}", 120)
            m = re.search(r"profile (\S+), ", out)
            got = m.group(1) if m else "?"
            pix = out.strip().splitlines()[-1].split(",")[-1] if out.strip() else "?"
            want_chroma = "4:2:0" if fmt == "bgra" else chroma_of(fmt)
            good = got == want and chroma_of(pix) == want_chroma
            ok &= good
            print(f"{'ok  ' if good else 'FAIL'} {enc} from {fmt}: profile {got} (rule: {want}), output {out.strip().splitlines()[-1]}")
    return ok


class Fail(Exception):
    pass


def linux_dir():
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
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
    return re.sub(gu.prompt_prefix(), "", out), int(p.match.group(1))


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
        "vp9": ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-row-mt", "1", "-pix_fmt", "yuv420p"],
    }[codec]
    rate = "40M" if size.startswith("3840") else "10M"
    # a beep each second: the audio that -c:a copy must keep in step
    audio = ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate=48000:beep_factor=4:duration={seconds}"]
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", src] + audio + enc
                       + ["-b:v", rate, "-c:a", "aac", "-b:a", "128k", "-shortest", path], capture_output=True, text=True)
    if r.returncode:
        raise Fail(f"cannot make {path} on the Mac: {r.stderr.strip()[-800:]}")


def probe(path):
    """codec,profile,width,height,pix_fmt,transfer,frames: the frame count last (stream side data would follow it in csv)."""
    r = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v", "-show_entries",
                        "stream=codec_name,profile,pix_fmt,width,height,nb_read_frames,color_transfer", "-of", "json", path],
                       capture_output=True, text=True)
    st = (json.loads(r.stdout or "{}").get("streams") or [{}])[0]
    keys = ("codec_name", "profile", "width", "height", "pix_fmt", "color_transfer", "nb_read_frames")
    return ",".join(str(st.get(k, "unknown")) for k in keys) if st else ""


def psnr(out, src):
    """ffmpeg's psnr filter, the output against the clip: the average of each plane and of the worst frame."""
    # frame by frame: the two files' time bases differ, and a scaled output is compared at the clip's size
    size = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=width,height", "-of", "csv=s=x:p=0", src],
                          capture_output=True, text=True).stdout.strip()
    graph = f"[0:v]settb=1/60,setpts=N,scale={size}:flags=bicubic[a];[1:v]settb=1/60,setpts=N[b];[a][b]psnr"
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "info", "-i", out, "-i", src, "-lavfi", graph, "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.search(r"PSNR y:([\d.inf]+) u:([\d.inf]+) v:([\d.inf]+) average:([\d.inf]+) min:([\d.inf]+)", r.stderr)
    if r.returncode or not m:
        return None
    return dict(zip(("y", "u", "v", "average", "min"), (float(x) for x in m.groups())))


def streams(path):
    """Each stream's type, start, duration and packet count, and the video packets' times in seconds."""
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=index,codec_type,start_time,duration,time_base", "-of", "json", path],
                       capture_output=True, text=True)
    info = {}
    for st in json.loads(r.stdout or "{}").get("streams", []):
        pk = subprocess.run(["ffprobe", "-v", "error", "-select_streams", str(st["index"]), "-show_entries", "packet=pts_time",
                             "-of", "default=nw=1:nk=1", path], capture_output=True, text=True).stdout.split()
        times = sorted(float(t) for t in pk if t not in ("", "N/A"))
        info[st["codec_type"]] = dict(start=float(st.get("start_time", "nan")), duration=float(st.get("duration", "nan")), packets=len(pk), times=times)
    return info


def in_sync(out, src):
    """The output's video has the clip's times, and its copied audio the clip's start, duration and packets."""
    a, b = streams(out), streams(src)
    if "video" not in a or "audio" not in a or "audio" not in b:
        return False, "no video or audio stream"
    v, sv = a["video"], b["video"]
    worst = max((abs(x - y) for x, y in zip(v["times"], sv["times"])), default=1e9) if len(v["times"]) == len(sv["times"]) else 1e9
    au, sa = a["audio"], b["audio"]
    ok = worst <= 0.5 / FPS and abs(au["start"] - sa["start"]) < 1e-3 and abs(au["duration"] - sa["duration"]) < 0.03 and au["packets"] == sa["packets"]
    return ok, (f"video times within {worst * 1000:.2f} ms of the clip's, audio start {au['start']:.3f} s (clip {sa['start']:.3f}), "
                f"{au['packets']} of {sa['packets']} audio packets, video start {v['start']:.3f} s against audio {au['start']:.3f} s")


def ffmpeg_case(p, share, tag, src, want, args, cmd_out="/tmp/ff-out.mp4", check_sync=True, min_psnr=None, startup=False, exe="./ffmpeg"):
    """One patched-ffmpeg command in the guest, its output checked on the Mac. With startup, a 1-frame run first gives the
    fixed cost (connect, QUERY, sessions, the global header's blank frame), and steady is the rate without it."""
    rt1 = None
    if startup:
        one = need(p, f"{exe} -hide_banner -nostats -benchmark -y {args.replace(' -c:v ', ' -frames:v 1 -c:v ', 1)} {cmd_out} 2>&1 | grep bench:",
                   f"ffmpeg {tag} one frame", 300)
        m1 = re.search(r"rtime=([\d.]+)s", one)
        rt1 = float(m1.group(1)) if m1 else None
    text = need(p, f"TIMEFORMAT='GUEST_TIME %R %U %S'; time {exe} -hide_banner -nostats -benchmark -y {args} {cmd_out} 2>&1 "
                   "| grep -E 'bench:|rror|refused|frame=' | tail -4", f"ffmpeg {tag}", 900)
    gt = re.search(r"GUEST_TIME ([\d.]+) ([\d.]+) ([\d.]+)", text)
    rt = re.search(r"rtime=([\d.]+)s", text)
    if not gt or not rt:
        raise Fail(f"ffmpeg {tag}: no timing:\n{text.strip()[-1200:]}")
    oname = f"ff-{tag}{os.path.splitext(cmd_out)[1]}"
    put(p, cmd_out, oname)
    path = os.path.join(share, oname)
    got = probe(path)
    frames = int(got.split(",")[-1]) if got and got.split(",")[-1].isdigit() else -1
    dec = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "null", "-"], capture_output=True, text=True)
    q = psnr(path, os.path.join(share, src))
    floor = MIN_PSNR if min_psnr is None else min_psnr
    sharp = q is not None and min(q["y"], q["u"], q["v"]) >= floor and q["min"] >= floor - 5
    sync, why = in_sync(path, os.path.join(share, src)) if check_sync else (True, "")
    good = frames == want and not dec.stderr.strip() and dec.returncode == 0 and sharp and sync
    secs = float(rt.group(1))
    r = dict(frames=frames, secs=secs, fps=want / secs if secs else 0.0, wall=float(gt.group(1)), cpu=float(gt.group(2)) + float(gt.group(3)))
    if rt1 is not None and secs > rt1:
        r.update(startup=rt1, steady_fps=(want - 1) / (secs - rt1))
    if q:
        r.update(psnr_y=q["y"], psnr_u=q["u"], psnr_v=q["v"], psnr_min=q["min"])
    pq = f"PSNR y {q['y']:.1f} u {q['u']:.1f} v {q['v']:.1f} dB, worst frame {q['min']:.1f} dB" if q else "no PSNR"
    steady = f", {r['steady_fps']:.1f} fps without the {r['startup'] * 1000:.0f} ms start" if "steady_fps" in r else ""
    print(f"{'ok  ' if good else 'FAIL'} ffmpeg {tag}: {r['fps']:.1f} fps{steady} ({secs:.2f} s, guest CPU {r['cpu']:.2f} s), output {got} "
          f"({frames} of {want} frames, {len(dec.stderr.strip().splitlines())} decode errors), {pq}")
    if check_sync:
        print(f"     {'in sync' if sync else 'NOT IN SYNC'}: {why}")
    os.remove(path)
    return good, r


def boot(args, disk, share, err_log):
    d = args.linux_dir
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err_log, args.tuxvm, "--kernel", os.path.join(d, "Image"), "--initrd", os.path.join(d, "initrd.img"),
            "--append", f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", disk, "--ram", str(args.ram),
            "--cpus", str(args.cpus), "--display", "1280x800", "--share", share, "--vcodec"]
    print(f"--   booting {os.path.basename(disk)} (host load average {os.getloadavg()[0]:.1f})")
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 250))
    p.expect(r"\(automatic login\)", timeout=300)
    p.expect(gu.shell_wide(), timeout=60)
    sh(p, "stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1")
    sh(p, "systemctl is-system-running --wait", 180)
    return p


def install(p, extra=(), base=PACKAGES, show=("ffmpeg", "libavformat-dev", "gcc")):
    want = list(base) + [x for x in extra if x not in base]
    out, _ = sh(p, "dpkg-query -W -f '${Package} ${Status}\\n' " + " ".join(want) + " 2>/dev/null")
    have = {l.split()[0] for l in out.splitlines() if l.strip().endswith("install ok installed")}
    missing = [x for x in want if x not in have]
    if missing:
        print(f"--   apt install {' '.join(missing)}")
        need(p, "sudo apt-get update -q >/dev/null", "apt-get update", 600)
        need(p, "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "
             + " ".join(missing) + " >/tmp/apt.log 2>&1 || { tail -20 /tmp/apt.log; false; }", "apt-get install", 1800)
    out = need(p, "dpkg-query -W -f '${Package} ${Version}\\n' " + " ".join(show), "package versions")
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
    text = need(p, f"head -1 /proc/stat; ./tux-xcode -c {out_codec} {'--speed ' if speed else ''}/tmp/{clip} {out} 2>&1 | tail -5; "
                   "head -1 /proc/stat", f"tux-xcode {clip}", 900)
    c1, t1 = cpu_secs(pid), time.monotonic()
    stats = re.findall(r"cpu\s+[\d ]+", text)
    m = re.search(r"(\d+) frames in, (\d+) with no picture, (\d+) packets out, ([\d.]+) s, ([\d.]+) fps; socket ([\d.]+) MB sent, "
                  r"([\d.]+) MB received, ([\d.]+) MB/s, (\d+) calls; cpu user ([\d.]+) s sys ([\d.]+) s", text)
    if not m or len(stats) < 2:
        raise Fail(f"tux-xcode {clip}: no summary:\n{text.strip()[-1500:]}")
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


def apt_update(p):
    """sudo apt-get update: its status, its W:, E: and Err: lines, and the whole log."""
    out = need(p, "sudo apt-get update >/tmp/aptu.log 2>&1; echo APT_RC=$?; cat /tmp/aptu.log", "apt-get update", 600)
    m = re.search(r"APT_RC=(\d+)", out)
    return (int(m.group(1)) if m else -1), [l.strip() for l in out.splitlines() if re.match(r"\s*(W|E|Err):", l)], out


def apt_install(p, what, args=""):
    return need(p, f"sudo DEBIAN_FRONTEND=noninteractive apt-get {args or 'install -y -q'} {what} >/tmp/apt.log 2>&1; rc=$?; "
                   "grep -E 'tux-ffmpeg:|^(W|E):' /tmp/apt.log; test $rc -eq 0 || { tail -20 /tmp/apt.log; false; }",
                f"apt-get {args or 'install'} {what}", 1800)


def nonblank(text):
    return [l.strip() for l in text.splitlines() if l.strip()]


def apt_checks(p, share, tree, clips):
    """VE3: tux-guest and tux-ffmpeg from the repository that publish-apt.sh built, served at http://10.0.2.4/apt."""
    ok = True
    LOCAL = "/etc/apt/sources.list.d/tux-local.sources"

    def check(good, text):
        nonlocal ok
        ok &= bool(good)
        print(f"{'ok  ' if good else 'FAIL'} {text}")

    def local_source(keyring):
        need(p, f"printf 'Types: deb\\nURIs: http://10.0.2.4/apt\\nSuites: trixie\\nComponents: main\\nSigned-By: {keyring}\\n' "
                f"| sudo tee {LOCAL} >/dev/null", "local apt source")

    pool = {}
    for block in open(os.path.join(tree, "dists", "trixie", "main", "binary-arm64", "Packages")).read().split("\n\n"):
        f = dict(l.split(": ", 1) for l in block.splitlines() if ": " in l and not l.startswith(" "))
        if f:
            # The pool keeps old versions: apt's candidate is the highest
            if f["Package"] not in pool or deb_key(f["Version"]) > deb_key(pool[f["Package"]]):
                pool[f["Package"]] = f["Version"]
    print(f"     repository {tree}: " + ", ".join(f"{k} {v}" for k, v in sorted(pool.items())))
    keyring_sha = subprocess.run(["shasum", "-a", "256", os.path.join(ROOT, "tools/linux/tux-guest/usr/share/keyrings/tux-archive.gpg")],
                                 capture_output=True, text=True, check=True).stdout.split()[0]
    need(p, "mkdir -p ~/hv && cd ~/hv", "work folder")
    fetch(p, "manpage-check.py", "manpage-check.py")
    fetch(p, "apt/tux-archive.asc", "/tmp/tux-test.asc")
    old = need(p, "dpkg-query -W -f '${Version}' tux-guest", "tux-guest version").strip()
    deb_sums = need(p, "sha256sum /usr/bin/ffmpeg /usr/bin/ffprobe", "Debian's ffmpeg")
    rc, base, _ = apt_update(p)
    print(f"     before: tux-guest {old}; apt update with Debian's sources only: status {rc}, {len(base)} W/E lines")

    local_source("/tmp/tux-test.asc")
    rc, lines, log = apt_update(p)
    check(rc == 0 and not set(lines) - set(base) and "10.0.2.4" in log,
          f"apt update with the local repository, InRelease signed by the new key: status {rc}, new W/E lines {sorted(set(lines) - set(base))}")
    pol = need(p, "apt-cache policy tux-guest tux-ffmpeg | grep -E '^[a-z]|Candidate'", "apt-cache policy")
    print("     " + "\n     ".join(nonblank(pol)))
    apt_install(p, "tux-guest")
    got = need(p, "dpkg-query -W -f '${Version}' tux-guest", "tux-guest version").strip()
    src = need(p, "cat /etc/apt/sources.list.d/tux.sources; sha256sum /usr/share/keyrings/tux-archive.gpg", "tux.sources")
    check(got == pool.get("tux-guest"), f"tux-guest {old} to {got} from the repository")
    check(re.search(r"^Enabled: no$", src, re.M) and "URIs: https://walkies.site/tux-linux-catalogue/apt" in src and keyring_sha in src,
          "tux-guest ships tux.sources (walkies.site, Enabled: no) and the repository's key")

    need(p, f"sudo rm -f {LOCAL}", "remove the local source")
    rc, lines, log = apt_update(p)
    check(rc == 0 and not set(lines) - set(base) and "walkies" not in log,
          f"apt update with tux-guest {got} and its source off: status {rc}, new W/E lines {sorted(set(lines) - set(base))}, "
          f"walkies.site {'named' if 'walkies' in log else 'not contacted'}")
    # The README's way to turn it on, with the URI pointed at the local copy: the shipped key and fields must work.
    need(p, "sed -e 's#^URIs: .*#URIs: http://10.0.2.4/apt#' -e 's/^Enabled: no/Enabled: yes/' /etc/apt/sources.list.d/tux.sources "
            f"| sudo tee {LOCAL} >/dev/null", "enabled copy of tux.sources")
    rc, lines, log = apt_update(p)
    check(rc == 0 and not set(lines) - set(base) and "10.0.2.4" in log,
          f"tux.sources with Enabled: yes (URIs set to the local copy) and the shipped key: status {rc}, "
          f"new W/E lines {sorted(set(lines) - set(base))}")
    # The admin's file, not a conffile: the README's edit in place stays over an upgrade with another default, with no prompt.
    SRC = "/etc/apt/sources.list.d/tux.sources"
    own = nonblank(need(p, f"dpkg-query -W -f '${{Conffiles}}\\n' tux-guest | grep -c tux.sources || true; "
                           f"dpkg -S {SRC} >/dev/null 2>&1 && echo owned || echo unowned", "tux.sources owner"))
    check(own == ["0", "unowned"], f"tux.sources is not a conffile and no package owns it: {own}")
    nxt = f"{got}+test1"
    fetch(p, f"apt/pool/main/t/tux-guest/tux-guest_{got}_all.deb", "/tmp/hg.deb")
    need(p, "rm -rf /tmp/hgn && dpkg-deb -R /tmp/hg.deb /tmp/hgn && "
            f"sed -i 's/^Version: .*/Version: {nxt}/' /tmp/hgn/DEBIAN/control && "
            "sed -i 's#^URIs: .*#URIs: https://example.invalid/next#' /tmp/hgn/usr/share/tux/tux.sources && "
            "dpkg-deb --root-owner-group -b /tmp/hgn /tmp/hg-next.deb >/dev/null", "tux-guest with another default")
    need(p, f"sudo sed -i 's/^Enabled: no/Enabled: yes/' {SRC}", "the README's edit")
    out, rc = sh(p, "sudo dpkg -i /tmp/hg-next.deb </dev/null >/tmp/dpkg.log 2>&1; echo rc=$?; grep -c 'Configuration file' /tmp/dpkg.log; "
                    f"grep -E '^(Enabled|URIs):' {SRC}", 300)
    got_next = need(p, "dpkg-query -W -f '${Version}' tux-guest", "tux-guest version").strip()
    out = nonblank(out)
    check(out[:2] == ["rc=0", "0"] and got_next == nxt and "Enabled: yes" in out
          and "URIs: https://walkies.site/tux-linux-catalogue/apt" in out,
          f"tux-guest {got} to {nxt} (another default): no prompt, the edit stays: {out}")
    need(p, f"sudo sed -i 's/^Enabled: yes/Enabled: no/' {SRC}; rm -rf /tmp/hgn /tmp/hg.deb /tmp/hg-next.deb", "turn the source off again")

    def resolve():
        out = need(p, "hash -r; for c in ffmpeg ffprobe; do echo \"$c $(command -v $c) $(readlink /usr/local/bin/$c)\"; done", "which ffmpeg")
        return {l.split()[0]: l.split()[1:] for l in out.splitlines() if l.strip()}

    log = apt_install(p, "tux-ffmpeg")
    if log.strip():
        print("     " + "\n     ".join(nonblank(log)))
    r = resolve()
    tux_bin = "/usr/lib/tux/ffmpeg/bin"
    check(all(r.get(c) == [f"/usr/local/bin/{c}", f"{tux_bin}/{c}"] for c in ("ffmpeg", "ffprobe")),
          f"tux-ffmpeg {pool.get('tux-ffmpeg')}: ffmpeg and ffprobe are links into {tux_bin}: {r}")
    ver = nonblank(need(p, "ffmpeg -hide_banner -version | head -1; ffmpeg -hide_banner -hwaccels | tail -n +2 | tr '\\n' ' '; echo; "
                  "/usr/bin/ffmpeg -hide_banner -version | head -1; dpkg -S /usr/bin/ffmpeg /usr/bin/ffprobe; "
                  "sha256sum /usr/bin/ffmpeg /usr/bin/ffprobe; command -v tux-codec-info", "versions"))
    print("     " + "\n     ".join(ver))
    check("tux" in ver[0] and "tux" in ver[1].split(), f"`ffmpeg` is the Tuxedo build: {ver[0]}")
    check(ver[2].startswith("ffmpeg version ") and "tux" not in ver[2] and "ffmpeg: /usr/bin/ffmpeg" in ver and "ffmpeg: /usr/bin/ffprobe" in ver
          and all(l in ver for l in nonblank(deb_sums)),
          f"/usr/bin/ffmpeg is Debian's and unchanged: {ver[2]}")
    js = need(p, "tux-codec-info --json", "tux-codec-info --json")
    try:
        table = json.loads(js[js.index("{"):js.rindex("}") + 1])
        encs = {e["codec"]: e for e in table["encoders"]}
    except ValueError:
        encs = {}
    listed = ", ".join(f"{k} ({e.get('ffmpeg')})" for k, e in encs.items())
    check(ver[-1] == "/usr/bin/tux-codec-info" and encs.get("hvc1", {}).get("hardware") and encs.get("avc1", {}).get("hardware"),
          f"tux-codec-info on the PATH: encoders {listed}")
    man = need(p, "man -w ffmpeg-tux; man -w ffmpeg; dpkg -S $(man -w ffmpeg); MANWIDTH=100 man -P cat ffmpeg-tux | head -4",
               "man ffmpeg-tux")
    print("     " + "\n     ".join(nonblank(man)))
    check("/usr/share/man/man7/ffmpeg-tux.7.gz" in man and "ffmpeg-tux - " in man and re.search(r"^ffmpeg[^:]*: /usr/share/man/man1/ffmpeg\.1", man, re.M),
          "man ffmpeg-tux opens; man ffmpeg is still Debian's page")
    out, rc = sh(p, "python3 manpage-check.py ffmpeg-tux", 120)
    print("     " + "\n     ".join(nonblank(out)))
    check(rc == 0, "the installed man page lists each encoder, option and value of the installed ffmpeg")

    for name, info in clips:
        fetch(p, name, f"/tmp/{name}")
        want = int(info.split(",")[-1]) if info.split(",")[-1].isdigit() else -1
        good, _ = ffmpeg_case(p, share, f"pkg-{name[:-4]}", name, want,
                              f"-hwaccel tux -hwaccel_output_format tux -i /tmp/{name} -c:v hevc_tux -b:v 20M -c:a copy", exe="ffmpeg")
        ok &= good
        sh(p, f"rm -f /tmp/{name}")

    apt_install(p, "tux-ffmpeg", "install -y -q --reinstall")
    r = resolve()
    check(all(r.get(c) == [f"/usr/local/bin/{c}", f"{tux_bin}/{c}"] for c in ("ffmpeg", "ffprobe")), f"a reinstall keeps the links: {r}")

    apt_install(p, "tux-ffmpeg", "remove -y -q")
    r = resolve()
    ver = nonblank(need(p, "ffmpeg -hide_banner -version | head -1; ls /usr/local/bin", "after remove"))
    check(all(r.get(c) == [f"/usr/bin/{c}"] for c in ("ffmpeg", "ffprobe")) and ver[0].startswith("ffmpeg version ") and "tux" not in ver[0],
          f"apt remove tux-ffmpeg gives Debian's ffmpeg back: {r}, {ver[0]}")

    # An admin's own /usr/local/bin/ffprobe: not replaced by the install, not removed by the remove.
    need(p, "printf '#!/bin/sh\\necho admin-ffprobe\\n' | sudo tee /usr/local/bin/ffprobe >/dev/null && sudo chmod 755 /usr/local/bin/ffprobe",
         "admin ffprobe")
    log = apt_install(p, "tux-ffmpeg")
    r = resolve()
    mine = need(p, "/usr/local/bin/ffprobe", "admin ffprobe").strip()
    check(r.get("ffmpeg") == ["/usr/local/bin/ffmpeg", f"{tux_bin}/ffmpeg"] and mine == "admin-ffprobe" and "is not ours" in log,
          f"an admin's /usr/local/bin/ffprobe stays at install, with a notice: {' '.join(nonblank(log))}")
    apt_install(p, "tux-ffmpeg", "purge -y -q")
    mine = need(p, "/usr/local/bin/ffprobe; test ! -e /usr/local/bin/ffmpeg && echo no-link", "admin ffprobe").strip()
    check(mine.split() == ["admin-ffprobe", "no-link"], "and stays at remove, while the ffmpeg link goes")
    need(p, f"sudo rm -f /usr/local/bin/ffprobe {LOCAL}", "clean up")
    rc, lines, log = apt_update(p)
    check(rc == 0 and not set(lines) - set(base) and "walkies" not in log,
          f"at the end, apt update with tux.sources off: status {rc}, new W/E lines {sorted(set(lines) - set(base))}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
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
    ap.add_argument("--keep-log", help="copy tuxvm's stderr here")
    ap.add_argument("--ffmpeg", help="VE2: a folder with the patched ffmpeg, ffprobe and tux-codec-info (build/linux/ffmpeg/bin)")
    ap.add_argument("--keep-disk", help="keep the guest's disk (with the packages installed) at this path, for --image next time")
    ap.add_argument("--no-xcode", action="store_true", help="with --ffmpeg: skip tux-xcode's transcodes")
    ap.add_argument("--apt", help="VE3: the repository from publish-apt.sh (build/linux/apt): check the packages instead")
    args = ap.parse_args()
    args.linux_dir = args.linux_dir or linux_dir()
    image = args.image or os.path.join(args.linux_dir, "debian-desktop.img")
    gu.use(image)
    for f in (args.tuxvm, image, os.path.join(args.linux_dir, "Image"), os.path.join(args.linux_dir, "initrd.img")):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    sizes = [s for s in args.sizes.split(",") if s]
    codecs = [c for c in args.codecs.split(",") if c]
    ok = True
    rows = []
    with tempfile.TemporaryDirectory(prefix="vcodec-", dir=args.work_dir) as tmp:
        share = os.path.join(tmp, "share")
        os.mkdir(share)
        for f in ("tools/linux/hvcodec/tux-xcode.c", "tools/linux/hvcodec/hvbench.c", "host/vcodec_proto.h",
                  "tools/linux/hvcodec/manpage-check.py"):
            shutil.copy(os.path.join(ROOT, f), share)
        if args.apt:
            r = subprocess.run(["/bin/cp", "-cR", os.path.abspath(args.apt), os.path.join(share, "apt")], capture_output=True, text=True)
            if r.returncode:
                raise Fail(f"cannot copy {args.apt}: {r.stderr.strip()}")
        runtime = []
        if args.ffmpeg:
            for f in ("ffmpeg", "ffprobe", "tux-codec-info"):
                shutil.copy(os.path.join(args.ffmpeg, f), share)
            manifest = os.path.join(os.path.dirname(os.path.abspath(args.ffmpeg)), "ffmpeg.manifest")
            for line in open(manifest):
                if line.startswith("runtime="):
                    runtime = line.split("=", 1)[1].split()
            print(f"     patched ffmpeg from {args.ffmpeg}: {open(manifest).readline().strip()}, runtime {' '.join(runtime)}")
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
        disk, err_log = os.path.join(tmp, "disk.img"), os.path.join(tmp, "tuxvm.stderr")
        r = subprocess.run(["/bin/cp", "-c", image, disk], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        p = boot(args, disk, share, err_log)
        try:
            if args.apt:
                install(p, base=["ffmpeg"], show=("ffmpeg", "tux-guest"))  # man-db comes as tux-ffmpeg's Recommends
                ok &= apt_checks(p, share, args.apt, clips)
            else:
                install(p, runtime)
                need(p, "mkdir -p ~/hv && cd ~/hv", "work folder")
                for f in ("tux-xcode.c", "hvbench.c", "vcodec_proto.h"):
                    fetch(p, f, f)
                need(p, "gcc -O2 -Wall -Wextra -I. tux-xcode.c $(pkg-config --cflags --libs libavformat libavcodec libavutil) -o tux-xcode 2>&1",
                     "build tux-xcode", 300)
                need(p, "gcc -O2 hvbench.c -o hvbench", "build hvbench", 120)
                print("ok   tux-xcode and hvbench built in the guest against Debian's libavformat")
                q = need(p, "./tux-xcode --query 2>&1 | grep -E '^(encoder|decoder)'", "tux-xcode --query")
                print("     " + q.strip().replace("\n", "\n     "))
                if "encoder hvc1" not in q or "encoder avc1" not in q:
                    raise Fail("QUERY lists no HEVC or no H.264 encoder")
                print("ok   QUERY from the guest lists the H.264 and HEVC encoders")
                if args.ffmpeg:
                    for f in ("ffmpeg", "ffprobe", "tux-codec-info"):
                        fetch(p, f, f)
                    need(p, "chmod +x ffmpeg ffprobe tux-codec-info", "chmod")
                    ver = need(p, "./ffmpeg -hide_banner -version | head -1; ./ffmpeg -hide_banner -hwaccels | tail -n +2; "
                                  "./ffmpeg -hide_banner -encoders | grep _tux", "patched ffmpeg")
                    print("     " + ver.strip().replace("\n", "\n     "))
                    if "hevc_tux" not in ver or not re.search(r"^tux$", ver, re.M):
                        raise Fail("the patched ffmpeg has no tux hwaccel or no hevc_tux")
                    js = need(p, "./tux-codec-info --json", "tux-codec-info --json")
                    try:
                        table = json.loads(js[js.index("{"):js.rindex("}") + 1])
                    except ValueError:
                        raise Fail(f"tux-codec-info --json is not JSON:\n{js[-800:]}")
                    encs = {e["codec"]: e for e in table["encoders"]}
                    if not (encs.get("hvc1", {}).get("hardware") and encs.get("avc1", {}).get("hardware")):
                        raise Fail("tux-codec-info lists no H.264 or no HEVC hardware encoder")
                    listed = ", ".join(f"{k} ({e['ffmpeg']})" for k, e in encs.items())
                    print(f"ok   tux-codec-info --json: encoders {listed}; decoders {', '.join(d['codec'] for d in table['decoders'])}")
                    ok &= check_profiles(p, encs)
                mem = need(p, "./hvbench", "hvbench")
                for line in re.findall(r"hvbench: [^\n]+", mem):
                    print(f"     {line}")
                for name, info in clips:
                    fetch(p, name, f"/tmp/{name}")
                    want = int(info.split(",")[-1]) if info.split(",")[-1].isdigit() else -1
                    if args.ffmpeg:
                        good, r = ffmpeg_case(p, share, name[:-4], name, want,
                                              f"-hwaccel tux -hwaccel_output_format tux -i /tmp/{name} -c:v hevc_tux -b:v 20M -c:a copy",
                                              startup=True)
                        ok &= good
                        rows.append((f"{name} ffmpeg main", r))
                        if name == "hevc8_4k.mp4":
                            good, r = ffmpeg_case(p, share, "scale", name, want, f"-hwaccel tux -hwaccel_output_format tux -i /tmp/{name} "
                                                  "-vf scale_tux=1920:1080 -c:v hevc_tux -b:v 10M -c:a copy", min_psnr=30.0)
                            ok &= good
                            rows.append((f"{name} ffmpeg scale_tux", r))
                        if name == "hevc8_1080p.mp4":
                            for tag, a in [("swfilter", f"-init_hw_device tux -hwaccel tux -hwaccel_output_format tux -i /tmp/{name} "
                                                        "-vf hwdownload,format=nv12,hflip,hflip,hwupload -c:v hevc_tux -b:v 20M -c:a copy"),
                                           ("h264", f"-hwaccel tux -hwaccel_output_format tux -i /tmp/{name} -c:v h264_tux -b:v 20M -c:a copy"),
                                           ("swdec", f"-i /tmp/{name} -c:v hevc_tux -b:v 20M -c:a copy")]:
                                good, r = ffmpeg_case(p, share, tag, name, want, a)
                                ok &= good
                                rows.append((f"{name} ffmpeg {tag}", r))
                    for out_codec, speed in ([] if args.no_xcode else [("hevc", False)]) + ([("hevc", True)] if args.speed else []):
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
                              f"tux-xcode CPU {r['cpu']:.2f} s ({r['cpu'] / r['secs'] * 100:.0f}% of one core), guest busy {r['guest_busy']:.0f}% "
                              f"of {args.cpus} CPUs, tuxvm {r['host_cpu']:.0f}% of one host core")
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
            raise Fail("tuxvm ended early; tail:\n" + (p.before or "")[-1500:] + "\nstderr:\n" + open(err_log, errors="replace").read()[-2000:])
        finally:
            if p.isalive():
                p.sendline("sudo poweroff")
                try:
                    p.expect(pexpect.EOF, timeout=90)
                except pexpect.TIMEOUT:
                    p.terminate(force=True)
            p.close()
            if args.keep_disk:
                os.replace(disk, args.keep_disk)
            log = open(err_log, errors="replace").read() if os.path.exists(err_log) else ""
            for line in re.findall(r"tuxvm: vcodec: [^\n]+", log)[-12:]:
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
