#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect", "numpy"]
# ///
"""P8 check: the Linux snd_virtio driver binds to Henge's virtio-snd and the guest's tones reach the host.

Boots a clone of the image on the virt board with HV_SND_CAPTURE, which makes the host audio backend write
every byte it plays to a file (silence included, while the stream runs). It checks that:
  1. snd_virtio binds with no probe error and ALSA lists the card, one playback stream, no capture stream;
  2. `speaker-test -c2 -t sine -f 440 -l 1` reaches the host as 440 Hz, left channel first, then right;
  3. a 60 s stereo file (440 Hz left, 660 Hz right) played by aplay reaches the host whole: right length,
     level and frequency, no gap or jump (zero crossings stay on a straight line), and the guest takes
     60 s of host wall time to play it, so the guest's audio clock does not drift;
  4. with --pipewire: the same file through pipewire, wireplumber and pw-play.
The console image has no audio tools; the check installs alsa-utils and sox (and with --pipewire the
pipewire packages) in the clone with apt unless --image names a disk that has them. --save-image keeps it.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np
import pexpect

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get("TUX_LINUX_OUT") or os.path.join(os.path.dirname(subprocess.run(
    ["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True, check=True).stdout.strip()), "build", "linux")
SHELL = r"henge@henge:\S*\$ "
MARK = "TUX_RC_"
FMT = {5: np.dtype("<i2"), 17: np.dtype("<i4"), 19: np.dtype("<f4")}
SCALE = {5: 32768.0, 17: 2147483648.0, 19: 1.0}


class Fail(Exception):
    pass


class Vm:
    def __init__(self, args, disk, tmp):
        self.args, self.disk = args, disk
        self.err = os.path.join(tmp, "tuxvm.stderr")
        self.cap = os.path.join(tmp, "capture.raw")

    def boot(self):
        a = self.args
        env = dict(os.environ, HV_SND_CAPTURE=self.cap, HV_SND_LOG="1")
        cmd = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', self.err, a.tuxvm, "--firmware", a.firmware, "--ram", str(a.ram), "--cpus", str(a.cpus), "--disk", self.disk]
        self.p = p = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", timeout=60, env=env)
        self.login()

    def login(self):
        p = self.p
        p.expect(r"\(automatic login\)", timeout=120)
        p.expect(SHELL, timeout=30)
        p.sendline(f"set +m; stty -echo; bind 'set enable-bracketed-paste off'; sudo dmesg -n 1; echo {MARK}$((6 * 7))")
        p.expect(MARK + r"42\r*\n", timeout=30)
        self.need("systemctl is-system-running --wait", lambda o: o == "running", "system state", 120)

    def sh(self, cmd, limit=30):
        p = self.p
        p.sendline(f"{cmd}; echo {MARK}$?")
        p.expect(MARK + r"(\d+)\r*\n", timeout=limit)
        out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", p.before).replace("\r", "")
        out = re.sub(r"^henge@henge:[^\n$]*\$ ", "", out)
        return out.strip(), int(p.match.group(1))

    def need(self, cmd, ok, what, limit=30):
        out, rc = self.sh(cmd, limit)
        if rc != 0 or not ok(out):
            raise Fail(f"{what}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
        return out

    def captured(self):
        try:
            return os.path.getsize(self.cap)
        except OSError:
            return 0

    def poweroff(self):
        self.p.sendline("sudo poweroff")
        self.p.expect(pexpect.EOF, timeout=60)


def load_capture(vm, start, end):
    """The PCM the host played between two byte offsets, as float frames [n, channels], and the rate."""
    ch, fmt, rate = map(int, open(vm.cap + ".fmt").read().split())
    raw = np.fromfile(vm.cap, dtype=np.uint8)[start:end]
    fb = ch * FMT[fmt].itemsize
    raw = raw[: len(raw) // fb * fb]
    x = raw.view(FMT[fmt]).astype(np.float64).reshape(-1, ch) / SCALE[fmt]
    return x, rate


def crossings(x, rate):
    """Times (s) of upward zero crossings, by linear interpolation."""
    i = np.nonzero((x[:-1] < 0) & (x[1:] >= 0))[0]
    return (i + (-x[i]) / (x[i + 1] - x[i])) / rate


def tone(x, rate):
    """Dominant frequency (Hz) and RMS of one channel."""
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    return float(np.fft.rfftfreq(len(x), 1 / rate)[int(np.argmax(spec))]), float(np.sqrt(np.mean(x ** 2)))


def active(x, rate):
    """Trim leading and trailing silence (both channels below 1/1000 of full scale)."""
    loud = np.nonzero(np.abs(x).max(axis=1) > 1e-3)[0]
    if not len(loud):
        raise Fail("the host played only silence")
    return x[loud[0]: loud[-1] + 1], loud[0] / rate, (len(x) - 1 - loud[-1]) / rate


def zero_runs(x, rate, min_ms=1.0):
    """Runs of exact-zero frames inside the active region (a buffer the guest sent late)."""
    z = np.all(x == 0, axis=1).astype(np.int8)
    d = np.diff(np.concatenate(([0], z, [0])))
    s, e = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
    return [(a / rate, (b - a) / rate * 1000) for a, b in zip(s, e) if (b - a) / rate * 1000 >= min_ms]


def analyse_steady(x, rate, fl, fr, secs, what):
    if x.shape[1] != 2:
        raise Fail(f"{what}: the guest opened {x.shape[1]} channels, not 2")
    y, lead, tail = active(x, rate)
    dur = len(y) / rate
    gaps = zero_runs(y, rate)
    ft_l, rms_l = tone(y[:, 0], rate)
    ft_r, rms_r = tone(y[:, 1], rate)
    t = crossings(y[:, 0], rate)
    k = np.arange(len(t))
    slope, icpt = np.polyfit(k, t, 1)
    jitter = np.abs(t - (slope * k + icpt)).max()
    print(f"  {what}: host played {dur:.2f} s (lead {lead:.2f} s, tail {tail:.2f} s); L {ft_l:.1f} Hz rms {rms_l:.3f}, "
          f"R {ft_r:.1f} Hz rms {rms_r:.3f}; {len(t)} crossings, mean period {slope * 1e3:.4f} ms "
          f"(440 Hz: {1e3 / fl:.4f}), worst jitter {jitter * 1e3:.3f} ms; zero runs over 1 ms: {len(gaps)}")
    if abs(dur - secs) > secs * 0.01 + 0.2:
        raise Fail(f"{what}: {dur:.2f} s reached the host, not {secs} s")
    if abs(ft_l - fl) > 2 or abs(ft_r - fr) > 2:
        raise Fail(f"{what}: frequencies {ft_l:.1f}/{ft_r:.1f} Hz, not {fl}/{fr}")
    if rms_l < 0.02 or rms_r < 0.02:
        raise Fail(f"{what}: level too low (rms {rms_l:.4f}/{rms_r:.4f})")
    if gaps:
        raise Fail(f"{what}: {len(gaps)} gaps in the audio, first at {gaps[0][0]:.3f} s of {gaps[0][1]:.1f} ms")
    if jitter > 0.0005:
        raise Fail(f"{what}: the waveform jumps by {jitter * 1e3:.2f} ms (a lost or repeated buffer)")
    if abs(slope * fl - 1) > 0.002:
        raise Fail(f"{what}: the played rate is off by {abs(slope * fl - 1) * 100:.2f} %")
    return dur


def speaker_test(vm):
    n0 = vm.captured()
    vm.need("speaker-test -c2 -t sine -f 440 -l 1 >/var/tmp/speaker-test.log 2>&1; tail -4 /var/tmp/speaker-test.log",
            lambda o: "Playback open error" not in o, "speaker-test", 60)
    time.sleep(0.5)
    x, rate = load_capture(vm, n0, vm.captured())
    y, lead, tail = active(x, rate)
    # speaker-test plays the left speaker, then the right one
    il = np.nonzero(np.abs(y[:, 0]) > 0.02)[0]
    ir = np.nonzero(np.abs(y[:, 1]) > 0.02)[0]
    if not len(il) or not len(ir):
        raise Fail(f"speaker-test: one channel is silent (left {len(il)} loud frames, right {len(ir)})")
    half = int(rate * 0.5)
    f_l, rms_l = tone(y[il[0]: il[0] + half, 0], rate)
    f_r, rms_r = tone(y[ir[0]: ir[0] + half, 1], rate)
    print(f"  speaker-test: {len(y) / rate:.2f} s, left from {il[0] / rate:.2f} s ({f_l:.1f} Hz, rms {rms_l:.3f}), "
          f"right from {ir[0] / rate:.2f} s ({f_r:.1f} Hz, rms {rms_r:.3f})")
    if not il[0] < ir[0]:
        raise Fail("speaker-test: the right channel came before the left")
    if abs(f_l - 440) > 3 or abs(f_r - 440) > 3:
        raise Fail(f"speaker-test: {f_l:.1f} and {f_r:.1f} Hz at the host, not 440 Hz")
    if rms_l < 0.02 or rms_r < 0.02:
        raise Fail("speaker-test: level too low at the host")


def play_file(vm, cmd, what, secs=60):
    n0 = vm.captured()
    t0 = time.monotonic()
    vm.p.sendline(f"{cmd}; echo {MARK}$?")
    vm.p.expect(MARK + r"(\d+)\r*\n", timeout=secs + 60)
    wall = time.monotonic() - t0
    if vm.p.match.group(1) != "0":
        raise Fail(f"{what}: {cmd!r} failed: {vm.p.before[-800:]!r}")
    time.sleep(1)
    x, rate = load_capture(vm, n0, vm.captured())
    played = analyse_steady(x, rate, 440, 660, secs, what)
    print(f"  {what}: the {secs} s file took {wall:.2f} s of host wall time; host played {played:.2f} s of audio")
    if abs(wall - secs) > 2.0:
        raise Fail(f"{what}: the {secs} s file took {wall:.2f} s of wall time (the guest's audio clock drifts)")


def basic(vm):
    vm.need("ls /sys/bus/virtio/drivers/virtio_snd/ 2>/dev/null | grep -c '^virtio'", lambda o: o == "1",
            "snd_virtio is not bound to the device")
    print("  driver: snd_virtio is bound")
    vm.need("sudo dmesg | grep -iE 'virtio.?snd|snd_virtio' | grep -iE 'fail|error|unsupported|invalid' | wc -l",
            lambda o: o == "0", "driver messages")
    cards = vm.need("cat /proc/asound/cards", lambda o: "virtio" in o.lower(), "ALSA card")
    print("  ALSA: " + " ".join(cards.split()))
    out = vm.need("aplay -l", lambda o: "card 0" in o, "aplay -l")
    print("  aplay -l: " + " | ".join(l.strip() for l in out.splitlines() if l.startswith("card")))
    out, _ = vm.sh("arecord -l 2>&1")
    if "card 0" in out:
        raise Fail("arecord lists a capture device, but the device offers only output")
    vm.need("ls /proc/asound/card0/pcm0p >/dev/null && ! ls /proc/asound/card0/pcm0c 2>/dev/null",
            lambda o: True, "one playback stream and no capture stream")


def paths(out):
    return sum(1 for line in out.splitlines() if line.startswith("/"))


def install(vm, args):
    pkgs = "alsa-utils sox"
    need = "speaker-test aplay sox"
    if args.pipewire:
        pkgs += " pipewire pipewire-bin pipewire-alsa wireplumber libpam-systemd dbus-user-session"
        need += " pw-play wpctl"
    # command -v succeeds when some names are found, so count one path for each tool
    found, _ = vm.sh(f"command -v {need}")
    if paths(found) < len(need.split()):
        vm.need("sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive "
                f"apt-get -y -qq install {pkgs} >/var/tmp/apt.log 2>&1; tail -3 /var/tmp/apt.log",
                lambda o: True, "install audio packages", 900)
        vm.need(f"command -v {need}", lambda o: paths(o) >= len(need.split()), "audio tools installed")
    # /dev/snd is group audio; an image built before the group was added needs it and a new login
    vm.need("sudo usermod -aG audio henge && id henge", lambda o: "audio" in o, "audio group")
    vm.p.sendline("sudo reboot")
    vm.login()
    # first boot after apt: let systemd jobs and apt timers finish before the timed play
    vm.need("systemctl is-system-running --wait >/dev/null 2>&1; while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' "
            ">/dev/null; do sleep 2; done; sleep 5; echo settled", lambda o: o.endswith("settled"), "system settles", 180)
    vm.need("sox -n -r 48000 -c 2 -b 16 /var/tmp/music.wav synth 60 sine 440 sine 660 vol 0.5 && ls -l /var/tmp/music.wav",
            lambda o: True, "make the music file", 180)


def pipewire(vm):
    # The serial login has no user session; linger starts one, and the shell then talks to its manager
    # enable-linger is async and can lose to the boot; start the user manager by hand too
    vm.need("sudo loginctl enable-linger henge; sudo systemctl start user@$(id -u).service; "
            "for i in $(seq 60); do [ -S /run/user/$(id -u)/bus ] && break; sleep 1; done; "
            "ls /run/user/$(id -u)/bus 2>&1 || { systemctl status user@$(id -u).service 2>&1 | tail -8; "
            "dpkg -l libpam-systemd dbus-user-session 2>&1 | tail -3; }",
            lambda o: o.endswith("/bus"), "user session manager (linger)", 150)
    vm.need("export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; "
            "systemctl --user start pipewire wireplumber; sleep 3; systemctl --user is-active pipewire wireplumber | sort -u",
            lambda o: o == "active", "pipewire and wireplumber run as user services", 60)
    out = vm.need("wpctl status | sed -n 1,25p", lambda o: "Audio" in o, "wpctl status")
    print("  pipewire: " + " | ".join(l.strip() for l in out.splitlines() if "vol:" in l))
    play_file(vm, "pw-play /var/tmp/music.wav", "pw-play 60 s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(OUT, "debian-console.img"))
    ap.add_argument("--firmware", default=os.path.join(OUT, "u-boot.bin"))
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--size-gb", type=int, default=6)
    ap.add_argument("--ram", type=int, default=2048)
    ap.add_argument("--cpus", type=int, default=2)
    ap.add_argument("--pipewire", action="store_true", help="also play through pipewire and pw-play")
    ap.add_argument("--save-image", help="keep the used disk here (with the packages) for later --image runs")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume; default TMPDIR)")
    ap.add_argument("--keep-capture", help="copy the host's capture here (raw PCM and .fmt)")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="sound-check-", dir=args.work_dir)
    disk = os.path.join(tmp, "disk.img")
    vm = None
    try:
        subprocess.run(["/bin/cp", "-c", args.image, disk], check=True)
        os.truncate(disk, args.size_gb << 30)
        vm = Vm(args, disk, tmp)
        vm.boot()
        install(vm, args)
        basic(vm)
        speaker_test(vm)
        play_file(vm, "aplay -q /var/tmp/music.wav", "aplay 60 s")
        if "virtio-snd: request" not in open(vm.err).read():
            raise Fail("HV_SND_LOG shows no requests")
        if args.pipewire:
            pipewire(vm)
        vm.need("sudo dmesg --level=err,crit,alert,emerg | grep -vE 'usb 1-2|usb1-port2' | wc -l",
                lambda o: o == "0", "dmesg errors")
        vm.poweroff()
        if args.save_image:
            subprocess.run(["/bin/cp", "-c", disk, args.save_image], check=True)
        if args.keep_capture:
            shutil.copy(vm.cap, args.keep_capture)
            shutil.copy(vm.cap + ".fmt", args.keep_capture + ".fmt")
        print("sound-check: PASS")
    except (Fail, pexpect.ExceptionPexpect) as e:
        print(f"sound-check: FAIL: {e}", file=sys.stderr)
        if vm:
            print("console tail:\n" + (vm.p.before or "")[-3000:], file=sys.stderr)
            try:
                print("tuxvm stderr tail:\n" + open(vm.err).read()[-1500:], file=sys.stderr)
            except OSError:
                pass
        return 1
    finally:
        if vm and vm.p.isalive():
            vm.p.terminate(force=True)
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
