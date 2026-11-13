#!/usr/bin/python3
"""Runs in the container (keyboard-panel-check.sh), inside dbus-run-session: henge-keyboard as KWin's input method.

Installs the package's files and the image's kwinrc as the image has them, starts kwin_wayland --virtual
(1280x800) and a stand-in for the host, and checks with a maximized test window:
with a text field: "show" reaches the host; a keyboard height makes KWin give the window a smaller height, a new
height changes it, and 0 gives the full height back; with no text field (the keyboard opened by hand) the
same, and no "show"; a text field after that is news; a second helper on the bus waits, and sends when the input method stops.
Then KWin without KWIN_IM_SHOW_ALWAYS: the window keeps its size (why the package sets it).
"""
import os
import shutil
import subprocess
import sys
import time
import urllib.request

TOOLS = "/tools"
PORT = 8099
W, H = 1280, 800
RT = "/tmp/rt"
HOSTLOG, WINLOG, KWINLOG = "/tmp/host.log", "/tmp/window.log", "/tmp/kwin.log"
KWIN = ["org.kde.KWin", "/VirtualKeyboard", "org.kde.kwin.VirtualKeyboard"]


class Fail(Exception):
    pass


def lines(path):
    try:
        return open(path).read().split("\n")[:-1]
    except FileNotFoundError:
        return []


def wait(what, test, limit=15):
    end = time.monotonic() + limit
    while not test():
        if time.monotonic() > end:
            raise Fail(f"{what}\n  window sizes: {lines(WINLOG)}\n  host requests: {lines(HOSTLOG)}\n"
                       + "  kwin: " + "\n  kwin: ".join(lines(KWINLOG)[-12:]))
        time.sleep(0.1)


def window_is(w, h, what):
    wait(f"{what}: the window is not {w}x{h}", lambda: lines(WINLOG)[-1:] == [f"{w} {h}"])
    print(f"ok: {what}: {w}x{h}", flush=True)


def set_height(f):
    urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{PORT}/height", data=str(f).encode(), method="PUT")).read()


def active():
    r = subprocess.run(["busctl", "--user", "get-property", *KWIN, "active"], capture_output=True, text=True)
    return r.stdout.strip()


def install():
    """The files where the package and the image put them."""
    for src, dst in (("henge-guest/usr/lib/henge/henge-keyboard", "/usr/lib/henge/henge-keyboard"),
                     ("henge-guest/usr/lib/henge/kwin-keyboard.js", "/usr/lib/henge/kwin-keyboard.js"),
                     ("henge-guest/usr/share/applications/henge-keyboard.desktop", "/usr/share/applications/henge-keyboard.desktop"),
                     ("henge-guest/etc/xdg/plasma-workspace/env/henge-keyboard.sh", "/etc/xdg/plasma-workspace/env/henge-keyboard.sh"),
                     ("rootfs-desktop/etc/xdg/kwinrc", "/etc/xdg/kwinrc")):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(TOOLS, src), dst)
    os.chmod("/usr/lib/henge/henge-keyboard", 0o755)


def start_kwin(show_always):
    env = dict(os.environ, XDG_RUNTIME_DIR=RT, HENGE_HOST=f"127.0.0.1:{PORT}", XDG_CONFIG_DIRS="/etc/xdg")
    env.pop("KWIN_IM_SHOW_ALWAYS", None)
    if show_always:  # as startplasma does: source the env script
        out = subprocess.run(["sh", "-c", ". /etc/xdg/plasma-workspace/env/henge-keyboard.sh; echo \"$KWIN_IM_SHOW_ALWAYS\""],
                             capture_output=True, text=True).stdout.strip()
        if out != "1":
            raise Fail(f"the env script gives KWIN_IM_SHOW_ALWAYS={out!r}")
        env["KWIN_IM_SHOW_ALWAYS"] = out
    for f in (HOSTLOG, WINLOG, KWINLOG):
        open(f, "w").close()
    p = subprocess.Popen(["kwin_wayland", "--virtual", "--width", str(W), "--height", str(H), "--no-lockscreen",
                          "--socket", "wayland-0"], env=env, stdout=open(KWINLOG, "w"), stderr=subprocess.STDOUT)
    wait("KWin did not start", lambda: os.path.exists(f"{RT}/wayland-0") and active().startswith("b "), 30)
    wait("KWin did not start henge-keyboard as its input method",
         lambda: subprocess.run(["pgrep", "-f", "/usr/lib/henge/henge-keyboard"], capture_output=True).returncode == 0
         and lines(HOSTLOG)[:1] == ["hide"], 20)
    return p, env


def start_window(env, *args):
    open(WINLOG, "w").close()
    return subprocess.Popen(["python3", f"{TOOLS}/kwin-panel/window.py", WINLOG, *args], env=dict(env, WAYLAND_DISPLAY="wayland-0"))


def stop(p):
    p.terminate()
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        p.kill()


def main():
    os.makedirs(RT, mode=0o700, exist_ok=True)
    install()
    host = subprocess.Popen(["python3", f"{TOOLS}/kwin-panel/host.py", str(PORT), HOSTLOG])
    print(subprocess.run(["kwin_wayland", "--version"], capture_output=True, text=True).stdout.strip(), flush=True)
    kwin = None
    try:
        kwin, env = start_kwin(True)
        print("ok: KWin starts henge-keyboard from kwinrc's InputMethod; its first request is hide", flush=True)

        # A text field
        win = start_window(env, "--text")
        window_is(W, H, "a maximized window with a text field")
        wait("the text field: no show at the host", lambda: lines(HOSTLOG)[-1:] == ["show"])
        print("ok: the text field has the focus: show", flush=True)
        set_height(0.4)
        window_is(W, H - 320, "the keyboard covers 0.4 of the screen")
        set_height(0.25)
        window_is(W, H - 200, "the keyboard changes to 0.25")
        set_height(0)
        window_is(W, H, "the keyboard goes down")
        stop(win)
        wait("the window closed: no hide at the host", lambda: lines(HOSTLOG)[-1:] == ["hide"])
        print("ok: the window closes: hide", flush=True)

        # A panel at the bottom edge, as Plasma's: the window must end at the keyboard's top edge, not above it
        win = start_window(env, "--text")
        window_is(W, H, "a maximized window")
        dock = subprocess.Popen(["python3", f"{TOOLS}/kwin-panel/dock.py", "bottom", "44"], env=dict(env, WAYLAND_DISPLAY="wayland-0"))
        window_is(W, H - 44, "a 44 px panel at the bottom")
        set_height(0.4)
        window_is(W, H - 320, "the keyboard covers 0.4, with the panel under it")
        set_height(0.02)
        window_is(W, H - 44, "a keyboard lower than the panel")
        set_height(0)
        window_is(W, H - 44, "the keyboard goes down")
        # The keyboard is up when the panel goes and comes back
        set_height(0.4)
        window_is(W, H - 320, "the keyboard covers 0.4")
        stop(dock)
        time.sleep(3)
        window_is(W, H - 320, "the panel goes while the keyboard is up")
        set_height(0)
        window_is(W, H, "the keyboard goes down, no panel")
        # A panel at the top takes nothing from the keyboard's side
        dock = subprocess.Popen(["python3", f"{TOOLS}/kwin-panel/dock.py", "top", "44"], env=dict(env, WAYLAND_DISPLAY="wayland-0"))
        window_is(W, H - 44, "a 44 px panel at the top")
        set_height(0.4)
        window_is(W, H - 320 - 44, "the keyboard covers 0.4, with the panel at the top")
        # A very high keyboard (a phone on its side): the window keeps a least height, with its end under the keyboard
        set_height(0.9)
        window_is(W, 180, "the keyboard covers 0.9")
        set_height(0)
        window_is(W, H - 44, "the keyboard goes down")
        stop(dock)
        window_is(W, H, "no panel")
        stop(win)
        wait("the window closed: no hide at the host", lambda: lines(HOSTLOG)[-1:] == ["hide"])

        # No text field: the person opened the keyboard
        requests = lines(HOSTLOG)
        win = start_window(env)
        window_is(W, H, "a maximized window with no text field")
        set_height(0.4)
        window_is(W, H - 320, "the keyboard opened by hand covers 0.4")
        set_height(0)
        window_is(W, H, "it goes down")
        wait("KWin's input method is still active after the keyboard went down", lambda: active() == "b false")
        if lines(HOSTLOG) != requests:
            raise Fail(f"no text field, but the host got {lines(HOSTLOG)[len(requests):]}")
        print("ok: no request to the host with no text field", flush=True)
        stop(win)
        win = start_window(env, "--text")
        wait("a text field after that: no show at the host", lambda: lines(HOSTLOG)[len(requests):] == ["show"])
        print("ok: a text field after that: show", flush=True)

        # The keyboard is up when the text field gets the focus
        stop(win)
        wait("no hide", lambda: lines(HOSTLOG)[-1:] == ["hide"])
        set_height(0.4)
        win = start_window(env, "--text")
        window_is(W, H - 320, "a window that opens with the keyboard up")
        wait("no show", lambda: lines(HOSTLOG)[-1:] == ["show"])
        set_height(0)
        window_is(W, H, "the keyboard goes down")
        time.sleep(1)
        if lines(HOSTLOG)[-1:] != ["show"]:
            raise Fail(f"the text field still has the focus, but the host got {lines(HOSTLOG)[-1:]}")
        print("ok: the text field keeps its show when the keyboard goes down", flush=True)

        # The helper that the desktop's autostart runs waits: there must be one sender only
        before = lines(HOSTLOG)
        second = subprocess.Popen(["/usr/lib/henge/henge-keyboard"], env=dict(env, WAYLAND_DISPLAY="wayland-0"),
                                  stderr=open("/tmp/second.log", "w"))
        time.sleep(3)
        if second.poll() is not None or lines(HOSTLOG) != before or "waits" not in open("/tmp/second.log").read():
            raise Fail(f"a second helper: status {second.poll()}, log {open('/tmp/second.log').read()!r}, "
                       f"requests {lines(HOSTLOG)[len(before):]}")
        print("ok: a second helper waits and sends nothing", flush=True)

        # The input method stops (the person chose another one): the second helper takes over on the bus
        pids = subprocess.run(["pgrep", "-f", "/usr/lib/henge/henge-keyboard"], capture_output=True, text=True).stdout.split()
        for pid in pids:
            if int(pid) != second.pid:
                os.kill(int(pid), 15)
        wait("the second helper did not take over", lambda: "follows KWin on the bus" in open("/tmp/second.log").read())
        stop(win)
        wait("after the input method stopped: no hide from the second helper", lambda: lines(HOSTLOG)[-1:] == ["hide"])
        time.sleep(1)
        count = len(lines(HOSTLOG))
        win = start_window(env, "--text")
        wait("after the input method stopped: no show from the second helper",
             lambda: lines(HOSTLOG)[count:] == ["show"])
        stop(win)
        wait("after the input method stopped: no hide from the second helper",
             lambda: lines(HOSTLOG)[count:] == ["show", "hide"])
        print("ok: the input method stops: the second helper sends show and hide", flush=True)
        stop(second)
        win = start_window(env)
        stop(win)
        stop(kwin)

        # Without KWIN_IM_SHOW_ALWAYS the last input must be a touch; here there is none
        kwin, env = start_kwin(False)
        win = start_window(env, "--text")
        window_is(W, H, "KWin without KWIN_IM_SHOW_ALWAYS")
        set_height(0.4)
        time.sleep(5)
        if lines(WINLOG)[-1:] != [f"{W} {H}"]:
            raise Fail(f"without KWIN_IM_SHOW_ALWAYS the window changed: {lines(WINLOG)}")
        print("ok: without KWIN_IM_SHOW_ALWAYS KWin does not show the panel: the window keeps its size", flush=True)
        set_height(0)
        stop(win)
    finally:
        if kwin:
            stop(kwin)
        host.kill()
    print("keyboard-panel-check: all checks passed")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
