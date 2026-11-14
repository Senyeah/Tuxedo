#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""DS6 check: the device's battery, brightness, volume, clock and time zone reach a Linux guest (LINUX-PLAN-13).

Boots a clone of the desktop image with --share, HV_INPUT_FILE (battery, brightness, volume and tz lines),
HV_STATUS_LOG (the guest's requests on stderr) and HV_SND_CAPTURE. It checks that:
  1. i2c-ocores, sbs-battery, lp855x_bl and gpio-charger load from the tree with no probe error, henge-status
     runs, and nothing in the guest sets the device's volume or brightness at boot or when WirePlumber starts;
  2. no battery is present before a battery line; then sysfs and UPower follow level, state and mains;
  3. the helper writes the backlight for a brightness line, and a guest change comes back as one request;
  4. ALSA's Master is the device's volume both ways, mute plays silence, and PipeWire follows (wpctl);
  5. after a 60 s pause the helper puts the clock right within 3 s, and the RTC stays the host's time;
  6. a tz line sets the guest's time zone, and a bad name is refused.
The image needs henge-guest 1.3.1 (henge-status); the check installs upower and brightnessctl in the clone.
The shared image never changes: the guest writes to a clone. Exit 1 on a failed check.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

import pexpect

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import Fail, login, sh  # noqa: E402

BAT = "/sys/class/power_supply/sbs-0-000b"
AC = "/sys/class/power_supply/ac-power"
BL = "/sys/class/backlight/henge-backlight"
UPBAT = "/org/freedesktop/UPower/devices/battery_sbs_0_000b"
PW = "env XDG_RUNTIME_DIR=/run/user/1000"


class Host:
    """tuxvm's input file and stderr."""

    def __init__(self, inp, err):
        self.inp, self.err = inp, err

    def line(self, text):
        with open(self.inp, "a") as f:
            f.write(text + "\n")

    def log(self):
        return open(self.err, errors="replace").read()

    def requests(self, what, since=0):
        """The guest's requests of one kind (brightness or volume) logged after offset since."""
        return re.findall(rf"tuxvm: status: guest {what} ([0-9.]+)( muted)?", self.log()[since:])


def until(fn, limit, what, step=0.25):
    """Polls fn until it returns something true; returns it and the time it took."""
    t0 = time.monotonic()
    while True:
        got = fn()
        if got:
            return got, time.monotonic() - t0
        if time.monotonic() - t0 > limit:
            raise Fail(f"{what}: not within {limit} s")
        time.sleep(step)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", default=os.path.join(smoke.linux_dir(), "debian-desktop.img"))
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--pause", type=int, default=60, help="seconds of the pause in step 5")
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    args = ap.parse_args()
    kernel, initrd = (os.path.join(smoke.linux_dir(), f) for f in ("Image", "initrd.img"))
    partuuid = open(args.image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    share = tempfile.mkdtemp(prefix="status-", dir="/tmp")  # the share socket's path is limited
    with tempfile.TemporaryDirectory(prefix="statuscheck-", dir=args.work_dir) as tmp:
        clone, err, inp, cap = (os.path.join(tmp, f) for f in ("disk.img", "stderr", "input", "capture.raw"))
        r = subprocess.run(["/bin/cp", "-c", args.image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {args.image}: {r.stderr.strip()}")
        os.truncate(clone, 8 << 30)
        host = Host(inp, err)
        host.line("volume 0.3")  # before boot, as the app does
        argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel,
                "--initrd", initrd, "--append", append, "--disk", clone, "--ram", "2048", "--cpus", str(args.cpus),
                "--share", share]
        env = dict(os.environ, HV_INPUT_FILE=inp, HV_STATUS_LOG="1", HV_SND_CAPTURE=cap)
        p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 220), env=env)
        try:
            run(p, host, args, cap)
        except (Fail, pexpect.ExceptionPexpect) as e:
            print(f"status-check: FAIL: {e}", file=sys.stderr)
            print("console tail:\n" + (p.before or "")[-2000:], file=sys.stderr)
            print("tuxvm stderr tail:\n" + host.log()[-2000:], file=sys.stderr)
            return 1
        finally:
            if p.isalive():
                p.terminate(force=True)
    print("status-check: PASS")
    return 0


def run(p, host, args, cap):
    login(p, None, 300)

    def need(cmd, ok=lambda o: True, what="", limit=60):
        out, rc = sh(p, cmd, limit)
        out = out.strip()
        if rc != 0 or not ok(out):
            raise Fail(f"{what or cmd}: {cmd!r} gave status {rc} and {out[-1500:]!r}")
        return out

    def value(cmd):
        return sh(p, cmd, 30)[0].strip()

    need("systemctl is-system-running --wait || true", lambda o: o.splitlines()[-1] in ("running", "degraded"), "system state", 180)

    # 1. Drivers, the helper, and quiet boot
    mods = need("lsmod | awk '{print $1}' | grep -E '^(i2c_ocores|sbs_battery|lp855x_bl|gpio_charger)$' | sort")
    if mods.split() != ["gpio_charger", "i2c_ocores", "lp855x_bl", "sbs_battery"]:
        raise Fail(f"drivers: only {mods.split()} loaded")
    bad = value("sudo dmesg | grep -iE 'ocores|sbs-battery|lp855x|gpio-charger|ac-power' | grep -iE 'fail|error|unable|timeout' || true")
    if bad:
        raise Fail(f"driver messages: {bad}")
    print("ok: i2c-ocores, sbs-battery, lp855x_bl and gpio-charger loaded from the tree, no probe error", flush=True)
    need("systemctl is-enabled henge-status; systemctl is-active henge-status", lambda o: o.split() == ["enabled", "active"],
         "henge-status runs")
    until(lambda: value(f"{PW} systemctl --user is-active wireplumber") == "active", 120, "WirePlumber starts")
    time.sleep(5)
    if host.requests("volume") or host.requests("brightness"):
        raise Fail(f"the guest set the device at boot: volume {host.requests('volume')}, brightness {host.requests('brightness')}")
    print("ok: henge-status is active; no volume or brightness request at boot or from WirePlumber", flush=True)

    found, _ = sh(p, "command -v upower brightnessctl", 20)
    if len([l for l in found.splitlines() if l.startswith("/")]) < 2:
        need("sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive "
             "apt-get -y -qq install upower brightnessctl >/var/tmp/apt.log 2>&1; tail -2 /var/tmp/apt.log",
             what="install upower and brightnessctl", limit=900)
    need("systemctl show upower -p Environment", lambda o: "UPOWER_CONF_FILE_NAME=/etc/henge/UPower.conf" in o,
         "upower reads Henge's settings")
    need("upower -d | grep critical-action", lambda o: re.search(r"critical-action:\s+Ignore", o), "UPower's critical action is Ignore")

    # 2. Battery
    need(f"cat {BAT}/present", lambda o: o == "0", "no battery before a battery line")
    need(f"upower -e | grep -q battery_sbs || echo absent; upower -i {UPBAT}",
         lambda o: o.startswith("absent") or re.search(r"present:\s+no", o), "UPower: no battery present")
    host.line("battery 87 unplugged")
    until(lambda: value(f"cat {BAT}/present {BAT}/capacity {BAT}/status {AC}/online").split() == ["1", "87", "Discharging", "0"],
          5, "sysfs after battery 87 unplugged")
    out, took = until(lambda: (lambda o: o if re.search(r"percentage:\s+87%", o) and re.search(r"state:\s+discharging", o) else None)(
        value(f"upower -i {UPBAT}")), 15, "UPower after battery 87 unplugged")
    need("upower -d | grep on-battery", lambda o: "yes" in o, "UPower on battery")
    tte0 = re.search(r"time to empty:\s+(.*)", out)
    print(f"ok: battery 87 unplugged: sysfs at once, UPower in {took:.1f} s; time to empty with -1 mA: "
          f"{tte0.group(1).strip() if tte0 else 'none'}", flush=True)
    host.line("battery 87 charging")
    _, took = until(lambda: re.search(r"state:\s+charging", value(f"upower -i {UPBAT}")), 5, "UPower after battery 87 charging")
    need(f"cat {AC}/online", lambda o: o == "1", "mains online while charging")
    print(f"ok: battery 87 charging: UPower in {took:.1f} s, mains online", flush=True)
    host.line("battery 86 unplugged")
    _, took = until(lambda: (lambda o: re.search(r"percentage:\s+86%", o) and re.search(r"state:\s+discharging", o))(
        value(f"upower -i {UPBAT}")), 30, "UPower after battery 86 unplugged")
    print(f"ok: battery 86 unplugged: UPower in {took:.1f} s", flush=True)
    for level in (85, 84):
        time.sleep(20)
        host.line(f"battery {level} unplugged")
    out, _ = until(lambda: (lambda o: o if re.search(r"percentage:\s+84%", o) else None)(value(f"upower -i {UPBAT}")), 30,
                   "UPower after two level steps")
    cur = int(value(f"cat {BAT}/current_now"))
    tte = re.search(r"time to empty:\s+(.*)", out)
    if not -7200 * 1000 * 1.3 < cur < -7200 * 1000 * 0.7:
        raise Fail(f"after 1 % in 20 s the current is {cur} uA, not about -7.2 A")
    print(f"ok: two level steps 20 s apart: current {cur / 1e6:.2f} A; UPower's time to empty: "
          f"{tte.group(1).strip() if tte else 'none'}", flush=True)

    # 3. Brightness
    host.line("brightness 0.25")
    _, took = until(lambda: value(f"cat {BL}/brightness") == "64", 2, "the helper writes 64 for brightness 0.25")
    print(f"ok: brightness 0.25: the backlight is 64 after {took:.1f} s", flush=True)
    # x.5 steps: the helper and the host must round alike, or the helper's own write is a request
    mark = len(host.log())
    for level, want in (("0.3", "77"), ("0.7", "179")):
        host.line(f"brightness {level}")
        until(lambda: value(f"cat {BL}/brightness") == want, 3, f"the helper writes {want} for brightness {level}")
    time.sleep(1)
    if host.requests("brightness", mark):
        raise Fail(f"the helper's own writes were requests: {host.requests('brightness', mark)}")
    print("ok: brightness 0.3 and 0.7: the backlight is 77 and 179, and neither write is a request", flush=True)
    mark = len(host.log())
    need("sudo brightnessctl -q set 50%")
    got, _ = until(lambda: host.requests("brightness", mark), 3, "a guest brightness change reaches the host")
    if len(got) != 1 or abs(float(got[0][0]) - 0.5) > 0.01:
        raise Fail(f"brightness requests {got}, want one of 0.50 and no echo of 0.25")
    time.sleep(3)
    if len(host.requests("brightness", mark)) != 1:
        raise Fail(f"more brightness requests: {host.requests('brightness', mark)}")
    print(f"ok: brightnessctl 50%: one request of {got[0][0]}, no echo", flush=True)

    # 4. Volume
    need("amixer -c 0 sget Master", lambda o: "[30%]" in o, "Master at the device's 30 %")
    host.line("volume 0.45")
    until(lambda: "[45%]" in value("amixer -c 0 sget Master"), 3, "Master follows volume 0.45")
    mark = len(host.log())
    need("amixer -q -c 0 sset Master 70%")
    got, _ = until(lambda: host.requests("volume", mark), 3, "a guest volume change reaches the host")
    if [g[0] for g in got] != ["0.70"]:
        raise Fail(f"volume requests {got}, want one of 0.70")
    print("ok: Master follows the device (30 %, 45 %); amixer 70 % is one request of 0.70", flush=True)
    mark = len(host.log())
    need("amixer -q -c 0 sset Master mute")
    until(lambda: any(g[1] for g in host.requests("volume", mark)), 3, "mute reaches the host")
    n_muted, silent = play(cap, need)
    need("amixer -q -c 0 sset Master unmute")
    n_loud, loud = play(cap, need)
    if n_muted < 500000 or n_loud < 500000 or silent or loud < n_loud // 4:
        raise Fail(f"muted playback: {silent} of {n_muted} bytes not zero; unmuted: {loud} of {n_loud}")
    print(f"ok: muted playback is silence at the host ({silent} of {n_muted} bytes not zero), unmuted is not "
          f"({loud} of {n_loud})", flush=True)
    until(lambda: value(f"{PW} wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null") == "Volume: 0.70", 5, "PipeWire shows 0.70")
    host.line("volume 0.55")
    until(lambda: value(f"{PW} wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null") == "Volume: 0.55", 5, "PipeWire follows volume 0.55")
    mark = len(host.log())
    need(f"{PW} wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.6 2>/dev/null")
    got, _ = until(lambda: host.requests("volume", mark), 3, "a PipeWire volume change reaches the host")
    time.sleep(1)
    if [g[0] for g in host.requests("volume", mark)] != ["0.60"]:
        raise Fail(f"wpctl requests {host.requests('volume', mark)}, want one of 0.60")
    need(f"{PW} systemctl --user stop wireplumber")
    host.line("volume 0.2")
    time.sleep(1)
    mark = len(host.log())
    need(f"{PW} systemctl --user start wireplumber; sleep 8; {PW} wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null",
         lambda o: o.endswith("Volume: 0.20"), "WirePlumber starts at the device's 0.20, not its stored 0.60")
    if host.requests("volume", mark):
        raise Fail(f"WirePlumber's start set the device: {host.requests('volume', mark)}")
    print("ok: wpctl follows the device (0.70, 0.55); set-volume 0.6 is one request; a WirePlumber start keeps 0.20", flush=True)

    # 5. Clock and RTC across a pause
    need("sudo journalctl -b -u henge-status --no-pager | tail -3")
    p.send("\x01s")
    until(lambda: "tuxvm: paused" in host.log(), 10, "tuxvm pauses")
    time.sleep(args.pause)
    p.send("\x01s")
    until(lambda: "tuxvm: resumed" in host.log(), 10, "tuxvm resumes")
    t_resume = time.time()

    def offset():
        out, _ = sh(p, "python3 -c 'import time; print(f\"{time.time():.3f}\")'", 10)
        return float(out.strip().splitlines()[-1]) - time.time()

    _, took = until(lambda: abs(offset()) < 0.5, 3 + 3, "the clock is right after the pause", step=0.2)
    print(f"ok: after a {args.pause} s pause the guest clock is within 0.5 s of the host's {time.time() - t_resume:.1f} s "
          f"after the resume", flush=True)
    need("sudo journalctl -b -u henge-status --no-pager | grep 'clock stepped' | tail -1",
         lambda o: re.search(r"clock stepped by \+(\d+)", o) and int(re.search(r"\+(\d+)", o).group(1)) >= args.pause - 5,
         "henge-status stepped the clock")
    rtc = float(value("cat /sys/class/rtc/rtc0/since_epoch"))
    if abs(rtc - time.time()) > 2:
        raise Fail(f"the RTC is {rtc - time.time():+.0f} s off")
    # RTC_SET_TIME for 2001-01-01, as hwclock --systohc would write it
    need("sudo python3 -c 'import fcntl, struct; fcntl.ioctl(open(\"/dev/rtc0\"), 0x4024700a, struct.pack(\"9i\", 0, 0, 0, 1, 0, 101, 0, 0, 0))'"
         "; cat /sys/class/rtc/rtc0/since_epoch", lambda o: abs(float(o.split()[-1]) - time.time()) < 3,
         "the RTC ignores a guest write")
    print("ok: the RTC is the host's time and ignores a guest write", flush=True)

    # 6. Time zone
    host.line("tz Pacific/Auckland")
    until(lambda: value("timedatectl show -p Timezone --value") == "Pacific/Auckland", 2, "tz Pacific/Auckland")
    host.line("tz ../../etc/passwd")
    until(lambda: "../../etc/passwd: not a time zone name" in host.log(), 3, "tuxvm refuses a bad name")
    need("python3 -c 'import urllib.request as u; print(u.urlopen(\"http://10.0.2.4/.henge/status\", timeout=5).read().decode())'",
         lambda o: "tz Pacific/Auckland" in o and "passwd" not in o, "the endpoint keeps the last good zone")
    host.line("tz Asia/Tokyo")
    until(lambda: value("timedatectl show -p Timezone --value") == "Asia/Tokyo", 2, "tz Asia/Tokyo")
    print("ok: the time zone follows tz lines, and a bad name is refused", flush=True)

    p.sendline("sudo poweroff")
    p.expect(pexpect.EOF, timeout=120)


def play(cap, need):
    """Plays a tone on the hardware (not PipeWire); the bytes the host played, and how many were not zero."""
    size = lambda: os.path.getsize(cap) if os.path.exists(cap) else 0
    start = size()
    need("speaker-test -D plughw:0 -c 2 -t sine -f 440 -l 1 >/dev/null 2>&1", limit=60)
    last = -1
    while size() != last:  # the capture file is written as the host plays
        last = size()
        time.sleep(0.5)
    with open(cap, "rb") as f:
        f.seek(start)
        data = f.read()
    return len(data), len(data) - data.count(0)


if __name__ == "__main__":
    sys.exit(main())
