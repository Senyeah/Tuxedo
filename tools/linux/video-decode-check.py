#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Guest video decode (docs/guest-video-decode-research.md): VA-API in the guest on VideoToolbox, for H.264, VP9 and AV1.

Boots a clone of the desktop image with `tuxvm --gpu-accel --gpu-video` (built with GFX=1 against a virglrenderer that has
tools/gfx/virglrenderer-videotoolbox.patch) and checks, over the serial console:
  1. packages: mesa-va-drivers, vainfo, ffmpeg and mpv (apt install when missing; --image names an image that has them).
  2. vainfo lists each codec's profiles (PROFILES) with VAEntrypointVLD.
  3. correctness, the frame checksum test: each test clip (CLIPS) decoded by `ffmpeg -hwaccel vaapi -f framemd5` and by
     `-hwaccel none`. Every frame must match. The clips are made on the Mac with FFmpeg (libx264, libvpx-vp9, libsvtav1;
     1080p30, 8 and 10 bits) and reach the guest through tuxvm's --share folder.
  4. speed, for each codec's first clip: `ffmpeg -benchmark -hwaccel vaapi -hwaccel_output_format vaapi -f null -`
     against `-hwaccel none`: frames per second and the guest CPU time. The hardware path must beat the clip's frame rate.
  5. mpv --hwdec=vaapi --vo=gpu on the desktop, with the first clip: dropped frames (printed; not a gate).
  6. tuxvm's log: VideoToolbox sessions on the hardware decoder, no decode error, and one codec per VA-API run that
     decoded every frame of the clip on VideoToolbox (the back end logs its totals when the guest destroys it).
  7. tuxvm's log: every frame's planes went to the guest's textures on the GPU (IOSurface pbuffers). With
     VREND_VIDEO_CPU_COPY=1 in the environment tuxvm copies them on the CPU instead, to measure against.
--codecs picks the codecs (default all), --bench N repeats step 4's VA-API run N times and reports the median, and
--clips DIR keeps the clips between runs.
With --no-video, tuxvm runs without --gpu-video: vainfo must list no decode profile and the back end must not start.
The shared image never changes: the guest runs on an APFS clone. Exit 1 on a failed check.
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
import guest_user as gu

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MARK = "TUX_RC_"
WAYLAND = "export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0"
PACKAGES = ["mesa-va-drivers", "vainfo", "ffmpeg", "mpv"]
# Debian's ffmpeg has VA-API; tux-ffmpeg, first in PATH when installed, does not (it decodes with -hwaccel tux).
FFMPEG = "/usr/bin/ffmpeg"
RENDER = "/dev/dri/renderD128"
# VREND_VIDEO_CPU_COPY=1 in the environment: tuxvm copies the planes on the CPU (the spike's path), to measure against
CPU_COPY = os.environ.get("VREND_VIDEO_CPU_COPY") == "1"
FPS = 30
# codec: the VA profiles vainfo must list with VAEntrypointVLD
PROFILES = {
    "h264": ["VAProfileH264Main", "VAProfileH264High"],
    "vp9": ["VAProfileVP9Profile0", "VAProfileVP9Profile2"],
    "av1": ["VAProfileAV1Profile0"],
}
# name: codec, the guest's pixel format for framemd5, the encoder arguments on the Mac
CLIPS = {
    "high-bframes": ("h264", "yuv420p", ["-c:v", "libx264", "-profile:v", "high", "-preset", "medium", "-g", "60",
                                         "-x264-params", "bframes=3:b-pyramid=normal:ref=4"]),
    "high-4slices": ("h264", "yuv420p", ["-c:v", "libx264", "-profile:v", "high", "-preset", "medium", "-g", "60",
                                         "-x264-params", "bframes=3:b-pyramid=normal:ref=4:slices=4"]),
    # two passes: libvpx makes hidden alt-ref frames (show_frame 0) only then
    "vp9-profile0": ("vp9", "yuv420p", ["-c:v", "libvpx-vp9", "-b:v", "6M", "-g", "60", "-deadline", "good",
                                        "-cpu-used", "4", "-row-mt", "1", "-tile-columns", "2", "-auto-alt-ref", "1",
                                        "-lag-in-frames", "25", "PASSES"]),
    "vp9-profile2": ("vp9", "yuv420p10le", ["-c:v", "libvpx-vp9", "-profile:v", "2", "-b:v", "6M", "-g", "60",
                                            "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-auto-alt-ref", "1",
                                            "-lag-in-frames", "25", "PASSES"]),
    # SVT-AV1's random access structure: hidden frames shown later with show_existing_frame, all 8 slots in use
    "av1-main": ("av1", "yuv420p", ["-c:v", "libsvtav1", "-preset", "8", "-b:v", "6M", "-g", "60"]),
    "av1-10bit-tiles": ("av1", "yuv420p10le", ["-c:v", "libsvtav1", "-preset", "8", "-b:v", "6M", "-g", "60",
                                               "-svtav1-params", "tile-columns=1:tile-rows=1"]),
    # superres, quantizer matrices and loop restoration
    "av1-tools": ("av1", "yuv420p", ["-c:v", "libsvtav1", "-preset", "4", "-b:v", "6M", "-g", "60", "-svtav1-params",
                                     "enable-qm=1:enable-restoration=1:superres-mode=1:superres-denom=12"]),
}
EXT = {"h264": "mp4", "vp9": "webm", "av1": "mp4"}


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


def clip_file(name):
    return f"{name}.{EXT[CLIPS[name][0]]}"


def make_clips(share, seconds, names):
    for name in names:
        codec, pix, enc = CLIPS[name]
        out = os.path.join(share, clip_file(name))
        if os.path.exists(out):
            continue
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
               f"testsrc2=size=1920x1080:rate={FPS}", "-f", "lavfi", "-i", f"cellauto=s=1920x1080:rate={FPS}:rule=110",
               "-filter_complex", f"[0][1]blend=all_mode=average,format={pix}", "-t", str(seconds)]
        enc = [a for a in enc if a != "PASSES"]
        log = os.path.join(share, f"{name}.pass")
        runs = [cmd + enc + ["-pass", "1", "-passlogfile", log, "-f", "null", "-"],
                cmd + enc + ["-pass", "2", "-passlogfile", log, out]] if "PASSES" in CLIPS[name][2] else [cmd + enc + [out]]
        if EXT[codec] == "mp4":
            runs[-1][-1:-1] = ["-movflags", "+faststart"]
        for c in runs:
            r = subprocess.run(c, capture_output=True, text=True)
            if r.returncode:
                raise Fail(f"cannot make {clip_file(name)} on the Mac: {r.stderr.strip()[-800:]}")
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-count_frames", "-show_entries",
                                "stream=codec_name,profile,width,height,pix_fmt,nb_read_frames", "-of", "csv=p=0", out],
                               capture_output=True, text=True).stdout.strip()
        coded = subprocess.run(["ffmpeg", "-v", "error", "-i", out, "-c", "copy", "-bsf:v",
                                "vp9_superframe_split" if codec == "vp9" else "null", "-f", "framecrc", "-"],
                               capture_output=True, text=True).stdout.count("\n0,")
        print(f"     clip {clip_file(name)}: {probe} (codec,profile,width,height,pix_fmt,frames), {coded} coded frames, "
              f"{os.path.getsize(out) / 1e6:.1f} MB")


def boot(args, disk, share, err_log):
    d = args.linux_dir
    partuuid = open(os.path.join(d, "debian-desktop.partuuid")).read().strip()
    argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err_log, args.tuxvm, "--kernel", os.path.join(d, "Image"), "--initrd", os.path.join(d, "initrd.img"),
            "--append", f"console=ttyAMA0 root=PARTUUID={partuuid} rw", "--disk", disk, "--ram", str(args.ram),
            "--cpus", str(args.cpus), "--display", "1920x1080", "--gpu-accel", "--share", share]
    if not args.no_video:
        argv.append("--gpu-video")
    env = dict(os.environ, HV_VIRGL_VERBOSE="1")  # the VideoToolbox session lines are info level
    print(f"--   booting {os.path.basename(disk)} (host load average {os.getloadavg()[0]:.1f})")
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 250), env=env)
    gu.login(p, 300, 60)
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
    out = need(p, "dpkg-query -W -f '${Package} ${Version}\\n' " + " ".join(PACKAGES), "package versions")
    print("ok   packages: " + ", ".join(l.strip() for l in out.splitlines() if l.strip()))


def check_vainfo(p, codecs):
    out, rc = sh(p, f"vainfo --display drm --device {RENDER} 2>&1", 120)
    lines = [l.strip() for l in out.splitlines()]
    driver = next((l for l in lines if "Driver version" in l), "no driver line")
    profiles = sorted({l.split(":")[0].strip() for l in lines if "VAEntrypointVLD" in l})
    print(f"     vainfo: {driver}")
    print(f"     vainfo decode profiles (VAEntrypointVLD): {', '.join(profiles) or 'none'}")
    want = [w for c in codecs for w in PROFILES[c]]
    if rc or any(w not in profiles for w in want):
        raise Fail(f"vainfo (status {rc}) does not list {', '.join(want)} with VAEntrypointVLD:\n{out.strip()[-2000:]}")
    print(f"ok   vainfo lists {', '.join(want)} with VAEntrypointVLD")
    return ", ".join(profiles)


def fetch_clips(p, names):
    for name in names:
        f = clip_file(name)
        # the desktop image has no curl
        need(p, f"python3 -c 'import shutil,urllib.request as u; shutil.copyfileobj(u.urlopen(\"http://10.0.2.4/{f}\"), "
             f"open(\"/tmp/{f}\", \"wb\"))'", f"copy {f} from --share", 300)


def framemd5(p, name):
    clip = f"/tmp/{clip_file(name)}"
    pix = CLIPS[name][1]
    # both sides in the clip's format: nv12 to yuv420p (p010 to yuv420p10le) only moves the bytes
    hw = (f"{FFMPEG} -hide_banner -v warning -hwaccel vaapi -hwaccel_device {RENDER} -i {clip} "
          f"-vf format={pix} -f framemd5 /tmp/{name}.hw.md5 2>/tmp/{name}.hw.log")
    sw = f"{FFMPEG} -hide_banner -v warning -hwaccel none -i {clip} -vf format={pix} -f framemd5 /tmp/{name}.sw.md5 2>/tmp/{name}.sw.log"
    out, rc = sh(p, hw, 1800)
    log, _ = sh(p, f"cat /tmp/{name}.hw.log")
    if rc:
        raise Fail(f"[{name}] ffmpeg -hwaccel vaapi gave status {rc}:\n{log.strip()[-2000:]}")
    if re.search(r"Failed setup|hwaccel initialisation returned error|Failed to create|vaapi.*[Ff]ail", log):
        raise Fail(f"[{name}] ffmpeg did not use VA-API:\n{log.strip()[-2000:]}")
    need(p, sw, f"[{name}] ffmpeg -hwaccel none", 3600)
    out = need(p, f"for s in hw sw; do grep -v '^#' /tmp/{name}.$s.md5 | awk -F, '{{gsub(/ /,\"\",$NF); print $NF}}' > /tmp/{name}.$s.h; done; "
               f"echo N=$(wc -l < /tmp/{name}.sw.h) M=$(wc -l < /tmp/{name}.hw.h) "
               f"D=$(paste -d' ' /tmp/{name}.hw.h /tmp/{name}.sw.h | awk '$1!=$2{{n++}} END{{print n+0}}') "
               f"F=$(paste -d' ' /tmp/{name}.hw.h /tmp/{name}.sw.h | awk '$1!=$2{{print NR-1; exit}}')", f"[{name}] compare")
    m = re.search(r"N=(\d+) M=(\d+) D=(\d+) F=(\d*)", out)
    if not m:
        raise Fail(f"[{name}] no comparison: {out.strip()}")
    n, mm, diff, first = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
    res = f"{name} ({CLIPS[name][0]}): {n} frames compared, {diff} differ" + (f" (first at frame {first})" if diff else "")
    if mm != n:
        res += f"; the hardware path gave {mm} frames"
    if diff or mm != n or n == 0:
        print(f"FAIL framemd5 {res}")
        return False, res
    print(f"ok   framemd5 {res}")
    return True, res


def bench(p, pid, name, hw):
    clip = f"/tmp/{clip_file(name)}"
    acc = f"-hwaccel vaapi -hwaccel_device {RENDER} -hwaccel_output_format vaapi" if hw else "-hwaccel none"
    tag = "vaapi" if hw else "software"
    c0, t0 = cpu_secs(pid), time.monotonic()
    out, rc = sh(p, f"TIMEFORMAT='GUEST_TIME %R %U %S'; time {FFMPEG} -hide_banner -nostats -benchmark {acc} -i {clip} -f null - 2>&1 "
                    "| grep -E 'bench:|frame=|rror|Fail' | tail -5", 3600)
    c1, t1 = cpu_secs(pid), time.monotonic()
    frames = re.findall(r"frame=\s*(\d+)", out)
    gt = re.search(r"GUEST_TIME ([\d.]+) ([\d.]+) ([\d.]+)", out)
    if rc or not frames or not gt:
        raise Fail(f"[{name}] ffmpeg {tag} benchmark gave status {rc}: {out.strip()[-1500:]}")
    n, real, user, syst = int(frames[-1]), float(gt.group(1)), float(gt.group(2)), float(gt.group(3))
    host = c1 - c0 if c0 is not None and c1 is not None else float("nan")
    fps = n / real
    line = (f"{tag}: {n} frames in {real:.2f} s = {fps:.1f} fps, guest CPU {user + syst:.2f} s "
            f"(user {user:.2f}, sys {syst:.2f}), tuxvm CPU {host:.2f} s ({100 * host / (t1 - t0):.0f}% of one core)")
    print(f"     [{name}] {line}")
    return fps, line


MPV_LUA = r"""local s = {}
local function grab()
  for _, k in ipairs({"hwdec-current", "frame-drop-count", "decoder-frame-drop-count", "mistimed-frame-count",
                      "estimated-frame-number", "time-pos"}) do
    local v = mp.get_property(k)
    if v then s[k] = v end
  end
end
mp.add_periodic_timer(0.25, grab)
mp.register_event("shutdown", function()
  mp.msg.warn(string.format("MPVSTAT hw=%s vo_drop=%s dec_drop=%s mistimed=%s frames=%s pos=%s", s["hwdec-current"] or "",
    s["frame-drop-count"] or "?", s["decoder-frame-drop-count"] or "?", s["mistimed-frame-count"] or "?",
    s["estimated-frame-number"] or "?", s["time-pos"] or "?"))
end)
"""


def mpv(p, name, seconds):
    # the status line needs a terminal, so a script reports the counters
    import base64
    need(p, f"echo {base64.b64encode(MPV_LUA.encode()).decode()} | base64 -d > /tmp/mpvstat.lua", "write the mpv script")
    out, rc = sh(p, f"{WAYLAND}; mpv --no-config --hwdec=vaapi --vo=gpu --gpu-context=wayland --no-audio --fs "
                    f"--msg-level=all=warn,vd=info --script=/tmp/mpvstat.lua /tmp/{clip_file(name)} 2>&1 | tail -c 3000",
                 seconds + 120)
    m = re.search(r"MPVSTAT hw=(\S*) vo_drop=(\S+) dec_drop=(\S+) mistimed=(\S+) frames=(\S+) pos=(\S+)", out)
    if not m:
        return f"mpv gave no counters (status {rc}): {out.strip()[-600:]}"
    hw, vo, dec, mis, frames, pos = m.groups()
    return (f"mpv --hwdec=vaapi --vo=gpu ({name}): hwdec-current={hw or 'none'}, {vo} frames dropped by the VO, "
            f"{dec} by the decoder, {mis} mistimed, last frame {frames}, played to {pos} s")


def host_log(err_log):
    text = open(err_log, errors="replace").read() if os.path.exists(err_log) else ""
    sessions = re.findall(r"vt: (\S+) session (\d+x\d+), (\w+) decoder", text)
    # (codec, decoded, failed, skipped, sessions, parameter set updates, slices per call) per codec
    codecs = [(m[0], *map(int, m[1:])) for m in re.findall(
        r"vt: (\S+) codec \d+x\d+ done: (\d+) frames decoded, (\d+) failed, (\d+) skipped, (\d+) sessions, "
        r"(\d+) parameter set updates, at most (\d+) slices", text)]
    bad = [l for l in re.findall(r"[^\n]*(?:vt: |video)[^\n]*", text, re.I)
           if " done: " not in l and re.search(r"not decoded|refused|failed|does not parse|does not fit|no sample buffer|"
                                               r"more than|not supported|invalid|not found", l)]
    started = "vt: video decode on VideoToolbox" in text
    copies = [tuple(map(float, m)) for m in re.findall(
        r"vrend video: codec done: (\d+) frames copied on the GPU, (\d+) on the CPU, (\d+) output surfaces, "
        r"([\d.]+) ms CPU", text)]
    return sessions, codecs, bad, started, copies


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "accel", "tuxvm"))
    ap.add_argument("--linux-dir", help="Image, initrd.img and the desktop partuuid (default: build/linux of the main checkout)")
    ap.add_argument("--image", help="a desktop image that has the packages (default: debian-desktop.img, then apt install)")
    ap.add_argument("--work-dir", help="where the disk clone and the clips go (the image's APFS volume)")
    ap.add_argument("--keep-image", help="save the guest disk here after the run (has the packages)")
    ap.add_argument("--keep-log", help="copy tuxvm's stderr (HV_VIRGL_VERBOSE=1) here")
    ap.add_argument("--seconds", type=int, default=15, help="clip length")
    ap.add_argument("--clips", help="keep the clips in this directory and use the ones already there")
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--ram", type=int, default=3072)
    ap.add_argument("--no-mpv", action="store_true")
    ap.add_argument("--bench", type=int, default=1, help="runs of the VA-API benchmark (the median is the result)")
    ap.add_argument("--no-video", action="store_true", help="boot without --gpu-video: vainfo must then list no decode profile")
    ap.add_argument("--codecs", default=",".join(PROFILES), help="comma-separated: " + ", ".join(PROFILES))
    args = ap.parse_args()
    codecs = [c for c in args.codecs.split(",") if c]
    if not codecs or any(c not in PROFILES for c in codecs):
        raise Fail(f"--codecs: pick from {', '.join(PROFILES)}")
    names = [n for n in CLIPS if CLIPS[n][0] in codecs]
    args.linux_dir = args.linux_dir or linux_dir()
    image = args.image or os.path.join(args.linux_dir, "debian-desktop.img")
    gu.use(image)
    for f in (args.tuxvm, image, os.path.join(args.linux_dir, "Image"), os.path.join(args.linux_dir, "initrd.img"),
              os.path.join(args.linux_dir, "debian-desktop.partuuid")):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    results = {}
    with tempfile.TemporaryDirectory(prefix="vdec-", dir=args.work_dir) as tmp:
        share = args.clips or os.path.join(tmp, "share")
        os.makedirs(share, exist_ok=True)
        make_clips(share, args.seconds, names)
        disk, err_log = os.path.join(tmp, "disk.img"), os.path.join(tmp, "tuxvm.stderr")
        r = subprocess.run(["/bin/cp", "-c", image, disk], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {image}: {r.stderr.strip()}")
        p = boot(args, disk, share, err_log)
        ok = True
        try:
            install(p)
            if args.no_video:
                out, rc = sh(p, f"vainfo --display drm --device {RENDER} 2>&1 | grep -c VAEntrypointVLD", 120)
                if out.strip().splitlines()[-1].strip() != "0":
                    raise Fail(f"without --gpu-video vainfo still lists decode profiles: {out.strip()}")
                print("ok   without --gpu-video vainfo lists no decode profile")
            else:
                results["vainfo"] = check_vainfo(p, codecs)
                fetch_clips(p, names)
                sums = []
                for name in names:
                    good, line = framemd5(p, name)
                    ok &= good
                    sums.append(line)
                results["checksum"] = "; ".join(sums)
                speed = []
                for codec in codecs:
                    name = next(n for n in names if CLIPS[n][0] == codec)
                    hw = [bench(p, p.pid, name, True) for _ in range(args.bench)]
                    hw_fps, hw_line = sorted(hw)[len(hw) // 2]
                    if args.bench > 1:
                        hw_line = f"median of {args.bench}: {hw_line}"
                    _, sw_line = bench(p, p.pid, name, False)
                    speed.append(f"[{name}] {hw_line}; {sw_line}")
                    if hw_fps <= FPS:
                        print(f"FAIL [{name}] the hardware path decodes {hw_fps:.1f} fps, not faster than real time ({FPS} fps)")
                        ok = False
                    else:
                        print(f"ok   [{name}] the hardware path decodes {hw_fps:.1f} fps > {FPS} fps (real time)")
                results["speed"] = "; ".join(speed)
                name = names[0]
                if not args.no_mpv:
                    line = mpv(p, name, args.seconds)
                    print(f"     {line}")
                    results["speed"] += f"; {line}"
                out, _ = sh(p, "sudo dmesg | grep -i -E 'virtio_gpu.*(error|fail|timed? ?out)|\\[drm.*(error|fail)|\\*ERROR\\*'")
                if out.strip():
                    print(f"FAIL the guest logged virtio_gpu or DRM errors:\n{out.strip()}")
                    ok = False
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
            sessions, done, bad, started, copies = host_log(err_log)
            if args.keep_log and os.path.exists(err_log):
                shutil.copy(err_log, args.keep_log)
            print(f"     tuxvm: {len(sessions)} VideoToolbox session(s): " + ", ".join(f"{c} {s} {k}" for c, s, k in sessions[:8]))
            for c in done:
                print(f"     tuxvm {c[0]} codec: {c[1]} frames decoded on VideoToolbox, {c[2]} failed, {c[3]} skipped, "
                      f"{c[4]} session(s), {c[5]} format updates, at most {c[6]} slice(s) per decode call")
            if copies:
                n = sum(c[0] + c[1] for c in copies)
                print(f"     tuxvm plane copies: {sum(c[0] for c in copies):.0f} frames on the GPU, {sum(c[1] for c in copies):.0f} "
                      f"on the CPU, at most {max(c[2] for c in copies):.0f} output surfaces per codec, "
                      f"{1000 * sum(c[3] for c in copies) / max(n, 1):.0f} us CPU per frame in the copies")
            if copies and not CPU_COPY and any(c[1] for c in copies):
                print("FAIL some frames were copied on the CPU: the IOSurface pbuffer path failed")
                ok = False
            if bad:
                print(f"FAIL tuxvm logged {len(bad)} video errors, first: {bad[0].strip()}")
                ok = False
            if args.keep_image:
                shutil.move(disk, args.keep_image)
                print(f"     kept the guest disk as {args.keep_image}")
        if p.exitstatus != 0:
            raise Fail(f"tuxvm exit status {p.exitstatus}, expected 0 after poweroff")
        print("ok   power off: exit status 0")
        if args.no_video:
            if started or sessions or done:
                raise Fail("without --gpu-video the VideoToolbox back end still started")
            print("ok   without --gpu-video the VideoToolbox back end did not start")
        else:
            if not sessions or any(k != "hardware" for _, _, k in sessions):
                print("FAIL not every VideoToolbox session used the hardware decoder")
                ok = False
            # each framemd5 run, each benchmark, mpv: each run's codec decodes the whole clip on VideoToolbox
            want = {"h264": "H.264", "vp9": "VP9", "av1": "AV1"}
            lines = []
            for codec in codecs:
                runs = sum(CLIPS[n][0] == codec for n in names) + args.bench + (1 if codec == CLIPS[names[0]][0] and not args.no_mpv else 0)
                mine = [c for c in done if c[0] == want[codec]]
                whole = [c for c in mine if c[1] >= FPS * args.seconds and not c[2] and not c[3]]
                lines.append(f"{want[codec]}: {len(whole)} of {runs} VA-API runs decoded all {FPS * args.seconds} frames on "
                             f"VideoToolbox, {sum(c[2] for c in mine)} failed, {sum(c[3] for c in mine)} skipped")
                if len(whole) < runs or any(c[2] or c[3] for c in mine):
                    print(f"FAIL {lines[-1]}")
                    ok = False
                else:
                    print(f"ok   {lines[-1]}")
            results["host"] = "; ".join(lines)
    for k, v in results.items():
        print(f"RESULT {k}: {v}")
    if not ok:
        raise Fail("see the FAIL lines above")


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
