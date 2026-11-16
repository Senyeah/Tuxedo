#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Desktop switching end to end (docs/guest-additions-design.md, desktop.install): the agent installs a desktop in a
booted guest, sets /etc/tux/session, restarts the machine (reboot_after), and the session starts on tty1.

Starts from a console image that has tux-guest 1.11.0 and no account (the disk --boot1-disk of additions-check.py, or
build/linux/additions-sim2-boot1.img). Needs build/tuxvm, the media (make linux-additions) and a network (the apt
mirror). Steps, in one machine: a job with the account and Xfce, a restart, the Xfce session; a job with Plasma, a
restart, the Plasma session; a job with the installed Xfce (no apt call), a restart, the Xfce session again.
  --only l|x|p|b   l: the Tuxedo desktop (labwc) alone; x: Xfce; p: x then Plasma; b: x, Plasma, then Xfce again
Exit 1 on a failed check."""
import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import types

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("additions_check", os.path.join(HERE, "additions-check.py"))
ac = importlib.util.module_from_spec(spec)
sys.modules["additions_check"] = ac
spec.loader.exec_module(ac)
PASSWORD = "Dk8-switch!desk-PW-27"


def ok(msg):
    print("ok   " + msg, flush=True)


def restart_and_wait(m, at_log):
    """The guest restarts by itself (reboot_after): tuxvm builds a new machine, with no media in it."""
    m.wait_log("tuxvm: guest restart: building the machine again", 300, at_log)
    m.p.expect(r"login: ", timeout=600)
    if m.p.expect([r"\(automatic login\)", ac.pexpect.TIMEOUT], timeout=10) == 1:
        raise ac.Fail("the console did not sign in after the restart")
    m.p.expect(ac.PROMPT, timeout=90)
    m.who = (m.p.match.group(1), m.p.match.group(2), m.p.match.group(3))
    m.quiet()


def process_up(m, names, limit, what):
    cmd = " || ".join("pgrep -x %s >/dev/null" % n for n in names)
    for _ in range(limit // 3):
        if m.sh(cmd, 20)[1] == 0:
            return
        time.sleep(3)
    ps = m.sh("ps -eo user,pid,args | grep -E 'tux-session|startx|Xorg|xfce|kwin|plasma|labwc|login|agetty' | grep -v grep | cut -c1-150", 20)[0]
    logs = m.sh("cat /run/user/1000/tux-session.log 2>&1 | tail -5; tail -15 ~/.local/share/xorg/Xorg.0.log 2>&1; "
                "tail -20 /var/log/Xorg.0.log 2>&1", 20)[0]
    raise ac.Fail("%s: none of %s runs within %d s\n--- ps\n%s\n--- logs\n%s" % (what, names, limit, ps, logs))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--disk", help="a console image with tux-guest 1.11.0 and no account")
    ap.add_argument("--media")
    ap.add_argument("--only", default="b", choices=["l", "x", "p", "b"])
    ap.add_argument("--tuxvm", default=os.path.join(ROOT, "build", "tuxvm"))
    ap.add_argument("--ram", type=int, default=3072)
    ap.add_argument("--cpus", type=int, default=4)
    a = ap.parse_args()
    d = os.path.join(ROOT, "build", "linux")
    src = a.disk or os.path.join(d, "additions-sim2-boot1.img")
    media = os.path.abspath(a.media or os.path.join(d, "additions", "tux-additions"))
    args = types.SimpleNamespace(tuxvm=a.tuxvm, firmware=os.path.join(d, "u-boot.bin"), ram=a.ram, cpus=a.cpus,
                                 agent_version=__import__("json").load(open(os.path.join(media, "versions.json")))["additions"])
    work = os.path.join(ROOT, "build", "desktop-work")
    os.makedirs(work, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="desktop-check-", dir=work)
    disk = os.path.join(tmp, "d.img")
    subprocess.run(["/bin/cp", "-c", src, disk], check=True)
    os.truncate(disk, 16 << 30)  # tux-grow takes the room at boot
    m = ac.Machine(args, disk, tmp, "m")
    t0 = time.monotonic()
    try:
        m.boot(extra=["--display", "1920x1080"])
        if m.who[0] != "root":
            raise ac.Fail("the first console is %r, not root" % (m.who,))
        k = m.mark()
        n = m.insert(media)
        m.wait_report(k, n, 120)
        ok("media in, agent reports (n %d)" % n)

        def switch(steps, what, desktop_procs):
            k = m.mark()
            jid = "j-" + what
            path = os.path.join(tmp, jid + ".json")
            import json
            with open(path, "w") as f:
                json.dump({"id": jid, "steps": steps, "reboot_after": True}, f)
            at = len(m.host_log())
            m.input_line("additions-job " + path)
            m.wait_log("additions: job set", 10, at)
            at_log = len(m.host_log())
            done = m.wait_event(lambda e: e["t"] == "done" and e["job"] == jid, 1500, "done of " + jid, k)
            got = m.steps_of(jid, k)
            bad = [s for s in got if s[1] == "failed"]
            if bad or not done["ok"]:
                raise ac.Fail("%s: job failed: %s\n%s" % (what, got[-4:], "".join(e.get("text", "") for e in m.events[k:] if e["t"] == "log")[-1500:]))
            if not done["reboot"]:
                raise ac.Fail("%s: done has no reboot flag" % what)
            ok("%s: job done (%s)" % (what, [s[2][:50] for s in got if s[1] == "ok"][-1]))
            restart_and_wait(m, at_log)
            ok("%s: the machine restarted by itself and the console signed in as %s" % (what, m.who[0]))
            m.insert(media)

        account = {"action": "user.setup", "name": "sam", "password": PASSWORD, "sudo": True, "autologin": True, "lock_root": True}
        if a.only == "l":
            switch([account, {"action": "desktop.install", "id": "labwc"}], "labwc", ["labwc"])
            m.need("test \"$(cat /etc/tux/session)\" = labwc", what="session file")
            process_up(m, ["labwc"], 240, "labwc")
            ok("labwc: the session runs on tty1")
            return 0
        switch([account, {"action": "desktop.install", "id": "xfce"}], "xfce", ["xfce4-session"])
        m.need("test \"$(cat /etc/tux/session)\" = xfce", what="session file")
        m.need("! pgrep -x sddm && ! pgrep -x lightdm", what="no display manager runs")
        process_up(m, ["xfce4-session"], 240, "xfce")
        process_up(m, ["Xorg", "Xorg.wrap"], 5, "xfce Xorg")
        ok("xfce: the session runs on tty1 (xfce4-session, Xorg)")
        out = m.sh("ps -o user= -C xfce4-session; loginctl list-sessions --no-legend | cut -c1-80", 20)[0]
        ok("xfce: %s" % " | ".join(out.split("\n")))
        if a.only == "x":
            return 0
        switch([{"action": "desktop.install", "id": "plasma"}], "plasma", ["plasmashell"])
        m.need("test \"$(cat /etc/tux/session)\" = plasma", what="session file")
        process_up(m, ["kwin_wayland"], 300, "plasma")
        process_up(m, ["plasmashell"], 120, "plasma shell")
        ok("plasma: the session runs on tty1 (kwin_wayland, plasmashell)")
        m.need("dpkg -s kscreen upower >/dev/null 2>&1", what="kscreen and upower are installed")
        m.need("ls /usr/share/applications | grep -q -i kscreen", what="the Display settings page (kcm_kscreen) exists")
        m.need("upower -e >/dev/null", what="upower answers on D-Bus")
        ok("plasma: Display settings (kscreen) and the battery service (upower) are there")
        if a.only == "p":
            return 0
        k = m.mark()
        n_apt = m.sh("cat /var/log/apt/history.log | grep -c '^Start-Date'", 20)[0]
        switch([{"action": "desktop.install", "id": "xfce"}], "xfce2", ["xfce4-session"])
        m.need("test \"$(cat /etc/tux/session)\" = xfce", what="session file")
        n_apt2 = m.sh("cat /var/log/apt/history.log | grep -c '^Start-Date'", 20)[0]
        if n_apt != n_apt2:
            raise ac.Fail("switching to an installed desktop ran apt (%s then %s runs)" % (n_apt, n_apt2))
        process_up(m, ["xfce4-session"], 240, "xfce again")
        ok("xfce again: no apt run, the session runs")
        return 0
    except (ac.Fail, ac.pexpect.TIMEOUT, ac.pexpect.EOF) as e:
        print("FAIL: %s" % (str(e)[:3000]), file=sys.stderr)
        print("--- console tail:", open(m.console_log, errors="replace").read()[-2500:], file=sys.stderr)
        print("--- tuxvm stderr tail:", m.host_log()[-1500:], file=sys.stderr)
        return 1
    finally:
        print("took %d s; work folder %s" % (time.monotonic() - t0, tmp))
        m.kill()


if __name__ == "__main__":
    sys.exit(main())
