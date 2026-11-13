#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Check: henge-secrets keeps the guest's wallet in the host's store (host/secrets.c), scoped to the machine.

Default: boots a clone of the desktop image on hengevm with --share, --secrets DIR and --machine-id, and drives
the device's lock with HV_INPUT_FILE ("secrets lock|unlock", in place of the app's Face ID check). In the guest,
secrets-probe.py stores, reads, lists and deletes through secret-tool, a Diffie-Hellman session and the KWallet
API; each item must land in DIR/MACHINE/ (mode 0600), and not show while locked; the same item shows through
both APIs; a prompt completes when the device unlocks; no secret is in the journal or hengevm's log. A second
boot with another machine id must not see the first machine's items. The image needs henge-guest 1.6.0.

--container: the same probe in a Debian trixie container (Docker) against secrets-mock-host.py, with kwallet6
installed: kwallet-query (libkf6wallet) through henge-secrets, a second kwalletd6 that must leave the names
alone, and the fallback to kwalletd6 when the device has no wallet. No Plasma session is started.
Exit 1 on a failed check.
"""
import argparse
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "secrets-probe.py")


class Fail(Exception):
    pass


# ---- inside the container ----

def inner():
    import urllib.request
    env = dict(os.environ, HENGE_SECRETS_HOST="127.0.0.1", HENGE_SECRETS_PORT="8099", LANG="C.UTF-8", QT_QPA_PLATFORM="offscreen")
    daemon_bin = "/t/henge-guest/usr/lib/henge/henge-secrets"
    procs = []

    def control(word):
        urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8099/control", data=word.encode(), method="PUT")).read()

    def dump():
        return json.load(urllib.request.urlopen("http://127.0.0.1:8099/control/dump"))

    def probe(*a, stdin=None):
        r = subprocess.run(["python3", "/t/secrets-probe.py", *a], input=stdin, capture_output=True, env=env, timeout=200)
        out = r.stdout.decode().strip()
        if r.returncode:
            raise Fail(f"probe {' '.join(a)}: {out} {r.stderr.decode()[-500:]}")
        print("ok:", out, flush=True)

    def kwq(*a, stdin=None):
        return subprocess.run(["timeout", "30", "kwallet-query", *a, "kdewallet"], input=stdin, capture_output=True, env=env)

    def owner(name):
        r = subprocess.run(["busctl", "--user", "status", name], capture_output=True, text=True, env=env)
        m = re.search(r"^Comm=(\S+)", r.stdout, re.M)
        return m.group(1) if m else None

    try:
        procs.append(subprocess.Popen(["python3", "/t/secrets-mock-host.py", "8099"]))
        time.sleep(0.5)
        log = open("/tmp/daemon.log", "w")
        procs.append(subprocess.Popen(["python3", daemon_bin], stderr=log, env=env))
        for _ in range(50):
            if owner("org.kde.kwalletd6"):
                break
            time.sleep(0.2)
        names = {n: owner(n) for n in ("org.freedesktop.secrets", "org.kde.kwalletd6", "org.kde.kwalletd5")}
        if set(names.values()) != {"python3"}:
            raise Fail(f"names: {names}")
        print("ok: henge-secrets owns org.freedesktop.secrets, org.kde.kwalletd6 and org.kde.kwalletd5", flush=True)

        control("unlock")
        value = "pw-" + secrets.token_hex(8)
        probe("store", "a", stdin=value.encode())
        probe("lookup", "a", value)
        probe("search", "a")
        probe("dh", "b", "dh-" + secrets.token_hex(8))
        probe("kw-write", "Passwords", "k1", "kw-" + value)
        probe("kw-read", "Passwords", "k1", "kw-" + value)
        probe("kw-list", "Passwords", "k1")
        probe("kw-map", "Maps", "m1")
        probe("kw-cross", "Passwords", "k1", "kw-" + value)
        d = dump()
        attrs = [v["meta"].get("attributes") for v in d.values()]
        if {"test": "a"} not in attrs or {"server": "Passwords", "user": "k1", "type": "plaintext"} not in attrs:
            raise Fail(f"the host's store: {attrs}")
        m = next(v for v in d.values() if v["meta"].get("attributes", {}).get("type") == "map")
        import base64
        if json.loads(base64.b64decode(m["secret"])) != {"user": "sam", "url": "https://example.test/", "ünïcode": "ē"}:
            raise Fail("a KWallet map is not JSON in the store, as KF 6.14 keeps it")
        print(f"ok: the host's store has {len(d)} items, KWallet entries as KF 6.14 keeps them", flush=True)

        # libkf6wallet's own client. kwallet-query only replaces an entry that exists.
        probe("kw-write", "Passwords", "qkey", "first")
        r0 = kwq("-f", "Passwords", "-r", "qkey")
        r = kwq("-f", "Passwords", "-w", "qkey", stdin=b"q-" + value.encode())
        r2 = kwq("-f", "Passwords", "-r", "qkey")
        if r0.stdout.decode().strip() != "first" or r.returncode or r2.stdout.decode().strip() != "q-" + value:
            raise Fail(f"kwallet-query: {r0.stdout.decode()[-100:]!r} {r.returncode} {r2.returncode} {r2.stderr.decode()[-300:]}")
        probe("kw-read", "Passwords", "qkey", "q-" + value)
        r3 = kwq("-l", "-f", "Passwords")
        r4 = kwq("-f", "Maps", "-r", "m1")
        if "qkey" not in r3.stdout.decode() or "k1" not in r3.stdout.decode() or '"sam"' not in r4.stdout.decode():
            raise Fail(f"kwallet-query -l, or a map: {r3.stdout.decode()[-300:]} {r4.stdout.decode()[-300:]}")
        print("ok: kwallet-query (libkf6wallet 6.13) reads, replaces, lists and reads a map through henge-secrets", flush=True)

        # A second kwalletd6 (pam_kwallet_init, activation) leaves the names alone
        r = subprocess.run(["timeout", "20", "kwalletd6"], capture_output=True, env=env)
        names = {n: owner(n) for n in ("org.freedesktop.secrets", "org.kde.kwalletd6")}
        if r.returncode == 124 or set(names.values()) != {"python3"}:
            raise Fail(f"a second kwalletd6: exit {r.returncode}, names {names}")
        print(f"ok: a second kwalletd6 exits ({r.returncode}) and leaves the names", flush=True)

        control("lock")
        time.sleep(1)
        probe("locked", "a")
        probe("kw-locked")
        r = kwq("-f", "Passwords", "-r", "qkey")
        if ("q-" + value) in r.stdout.decode():
            raise Fail("kwallet-query read a secret while locked")
        print(f"ok: kwallet-query reads nothing while locked (exit {r.returncode})", flush=True)

        p = subprocess.Popen(["python3", "/t/secrets-probe.py", "unlock-prompt", "a"], stdout=subprocess.PIPE, env=env, text=True)
        line = p.stdout.readline()
        if "PROMPT" not in line:
            raise Fail(f"unlock-prompt: {line}")
        time.sleep(1.5)
        control("unlock")
        out = p.stdout.read()
        if p.wait(timeout=60) or "OK" not in out:
            raise Fail(f"unlock-prompt: {out}")
        print("ok: an Unlock prompt completes when the device unlocks", flush=True)
        probe("lookup", "a", value)
        probe("kw-remove", "Passwords", "k1")
        probe("clear", "a")
        probe("absent", "a")
        left = [v["meta"].get("attributes") for v in dump().values()]
        if {"test": "a"} in left or any(a.get("user") == "k1" for a in left):
            raise Fail(f"deleted items are still in the store: {left}")
        print("ok: deleted items leave the host's store", flush=True)
        log.flush()
        text = open("/tmp/daemon.log").read()
        if value in text or "Passwords" in text or "sam" in text:
            raise Fail("the daemon's log has a secret, a folder or an attribute")
        print("ok: the daemon's log has no secret, label or attribute", flush=True)
    finally:
        for p in procs:
            p.terminate()
    time.sleep(1)

    # The device has no wallet: henge-secrets, started by D-Bus, runs kwalletd6 in its place
    r = subprocess.Popen(["python3", daemon_bin, "--activated"], env=dict(env, HENGE_SECRETS_PORT="8098"), stderr=subprocess.PIPE, text=True)
    for _ in range(150):
        if owner("org.kde.kwalletd6") == "kwalletd6":
            break
        time.sleep(0.2)
    if owner("org.kde.kwalletd6") != "kwalletd6":
        raise Fail("no fallback to kwalletd6")
    r.terminate()
    print("ok: without the device's wallet, D-Bus activation gets kwalletd6", flush=True)


def container(args):
    dockerfile = ("FROM debian:trixie\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "
                  "python3-jeepney python3-cryptography libsecret-tools dbus dbus-bin systemd kwallet6 && rm -rf /var/lib/apt/lists/*\n")
    env = dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ.get("PATH", ""))
    r = subprocess.run(["docker", "build", "-q", "-t", "henge-secrets-test", "-"], input=dockerfile.encode(), capture_output=True, env=env)
    if r.returncode:
        raise Fail("docker build: " + r.stderr.decode()[-800:])
    r = subprocess.run(["docker", "run", "--rm", "-v", f"{HERE}:/t:ro", "henge-secrets-test",
                        "dbus-run-session", "--", "python3", "/t/secrets-check.py", "--inner"], env=env)
    if r.returncode:
        raise Fail("in the container")


# ---- on hengevm ----

class Host:
    def __init__(self, inp, err):
        self.inp, self.err = inp, err

    def line(self, text):
        with open(self.inp, "a") as f:
            f.write(text + "\n")

    def state(self):
        before = len(open(self.err, errors="replace").read())
        self.line("secrets")
        for _ in range(40):
            time.sleep(0.25)
            m = re.search(r"hengevm: secrets (locked|unlocked)\n", open(self.err, errors="replace").read()[before:])
            if m:
                return m.group(1)
        raise Fail("secrets: hengevm did not answer")


def boot(args, image, store, machine, steps):
    import pexpect
    sys.path.insert(0, HERE)
    import smoke
    from smoke import login, sh
    kernel, initrd = (os.path.join(smoke.linux_dir(), f) for f in ("Image", "initrd.img"))
    for f in (args.hengevm, kernel, initrd, image):
        if not os.path.exists(f):
            raise Fail(f"missing {f}")
    partuuid = open(args.image[:-4] + ".partuuid").read().strip()
    append = f"console=ttyAMA0 earlycon=pl011,0x9000000 root=PARTUUID={partuuid} rw"
    share = tempfile.mkdtemp(prefix="sec-", dir="/tmp")
    tmp = tempfile.mkdtemp(prefix="secrun-", dir=args.work_dir)
    err, inp = os.path.join(tmp, "stderr"), os.path.join(tmp, "input")
    open(inp, "w").close()
    open(err, "w").close()
    host = Host(inp, err)
    argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.hengevm, "--board", "virt", "--kernel", kernel, "--initrd", initrd,
            "--append", append, "--disk", image, "--ram", "2048", "--cpus", str(args.cpus), "--display", "1280x720",
            "--share", share, "--secrets", store, "--machine-id", machine]
    p = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", dimensions=(50, 200), env=dict(os.environ, HV_INPUT_FILE=inp))
    try:
        login(p, None, 300)
        bus = "env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"

        def need(cmd, what="", limit=60):
            out, rc = sh(p, cmd, limit)
            if rc != 0:
                raise Fail(f"{what or cmd}: status {rc}: {out.strip()[-1500:]!r}\njournal:\n" +
                           sh(p, "journalctl --user -u henge-secrets --no-pager | tail -n 20", 20)[0])
            return out.strip()

        def probe(*a, stdin=None, limit=200):
            feed = f"printf %s '{stdin}' | " if stdin is not None else ""
            out = need(f"{feed}{bus} python3 /tmp/probe.py {' '.join(a)}", f"probe {' '.join(a)}", limit)
            print("ok:", out.splitlines()[-1], flush=True)

        end = time.monotonic() + 120
        while sh(p, "systemctl --user is-active henge-secrets", 20)[0].strip() != "active":
            if time.monotonic() > end:
                raise Fail("henge-secrets is not active 120 s after login")
            time.sleep(2)
        need("journalctl --user -u henge-secrets --no-pager | grep -q 'serving org.freedesktop.secrets org.kde.kwalletd6 org.kde.kwalletd5'",
             "the names")
        print("ok: henge-secrets is active and owns the Secret Service and KWallet names", flush=True)
        import base64
        data = base64.b64encode(open(PROBE, "rb").read()).decode()
        need(": > /tmp/probe.b64")
        for i in range(0, len(data), 600):
            need(f"printf %s '{data[i:i + 600]}' >> /tmp/probe.b64")
        need("base64 -d /tmp/probe.b64 > /tmp/probe.py")
        steps(host, need, probe, err)
        p.sendline("sudo poweroff")
        p.expect(pexpect.EOF, timeout=120)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        raise Fail(f"{type(e).__name__}; tail:\n" + (p.before or "")[-1500:] + "\n" + open(err).read()[-1500:])
    finally:
        if p.isalive():
            p.terminate(force=True)
        subprocess.run(["rm", "-rf", share, tmp])


def files(store, machine):
    d = os.path.join(store, machine)
    out = {}
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        path = os.path.join(d, name)
        raw = open(path, "rb").read()
        n = int.from_bytes(raw[:4], "little")
        out[name] = (json.loads(raw[4:4 + n] or b"{}"), raw[4 + n:], stat.S_IMODE(os.stat(path).st_mode))
    return out


def vm(args):
    value = "pw-" + secrets.token_hex(8)
    with tempfile.TemporaryDirectory(prefix="seccheck-", dir=args.work_dir) as tmp:
        clone, store = os.path.join(tmp, "disk.img"), os.path.join(tmp, "store")
        r = subprocess.run(["/bin/cp", "-c", args.image, clone], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"cannot clone {args.image}: {r.stderr.strip()}")

        def first(host, need, probe, err):
            if host.state() != "unlocked":
                raise Fail("hengevm did not start unlocked")
            probe("store", "a", stdin=value)
            have = files(store, "check-a")
            mine = [v for v in have.values() if v[0].get("attributes") == {"test": "a"}]
            if len(mine) != 1 or mine[0][1] != value.encode() or mine[0][2] != 0o600:
                raise Fail(f"the item is not in the host's store as it should be: {[(m[0], m[2]) for m in mine]}")
            print("ok: the item is in the host's store, under the machine, mode 0600", flush=True)
            probe("lookup", "a", value)
            probe("search", "a")
            probe("dh", "b", "dh-" + value)
            probe("kw-write", "Passwords", "k1", "kw-" + value)
            probe("kw-read", "Passwords", "k1", "kw-" + value)
            probe("kw-list", "Passwords", "k1")
            probe("kw-map", "Maps", "m1")
            probe("kw-cross", "Passwords", "k1", "kw-" + value)
            if not any(v[0].get("attributes", {}).get("server") == "Passwords" for v in files(store, "check-a").values()):
                raise Fail("the KWallet entry is not in the host's store")
            print("ok: the KWallet entry is in the host's store", flush=True)

            # Only the session user (and root) reach the wallet's port; port 80 has no wallet
            get = ("python3 -c \"import http.client as h, sys; c=h.HTTPConnection('10.0.2.4', {port}, timeout=5); "
                   "c.request('GET','/.henge/secrets/state'); print('status', c.getresponse().status)\" 2>&1 | tail -n 1")
            need("systemctl is-active henge-secrets-firewall", "the firewall unit")
            mine = need(get.format(port=81))
            other = need("sudo -u nobody " + get.format(port=81))
            root = need("sudo " + get.format(port=81))
            port80 = need(get.format(port=80))
            if mine != "status 200" or root != "status 200" or "status" in other or port80 != "status 404":
                raise Fail(f"port rule: henge {mine!r}, nobody {other!r}, root {root!r}, port 80 {port80!r}")
            print(f"ok: henge and root reach the wallet's port, nobody is refused ({other.split(':')[0]}), port 80 has no wallet", flush=True)

            host.line("secrets lock")
            end = time.monotonic() + 60
            while True:  # the guest hears of it through its long poll
                out, rc = sh_probe(need, "locked a")
                if rc == 0:
                    break
                if time.monotonic() > end:
                    raise Fail("locked: " + out)
                time.sleep(1)
            print("ok: locked: the item shows as locked, GetSecret(s) give nothing", flush=True)
            probe("kw-locked")
            iid = next(k for k, v in files(store, "check-a").items() if v[0].get("attributes") == {"test": "a"})
            code = need(f"python3 -c \"import http.client as h; c=h.HTTPConnection('10.0.2.4', 81); c.request('GET','/.henge/secrets/items/{iid}'); print(c.getresponse().status)\"")
            if code.splitlines()[-1] != "423":
                raise Fail(f"the host gave {code} for a read while locked")
            print("ok: the host answers 423 to a read while locked", flush=True)
            need("rm -f /tmp/prompt.out; (env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
                 "python3 /tmp/probe.py unlock-prompt a > /tmp/prompt.out 2>&1 &) ; for i in $(seq 60); do grep -q PROMPT /tmp/prompt.out && break; sleep 0.5; done; grep -q PROMPT /tmp/prompt.out",
                 "a prompt while locked")
            host.line("secrets unlock")
            need("for i in $(seq 120); do grep -q '^OK' /tmp/prompt.out && break; sleep 0.5; done; cat /tmp/prompt.out; grep -q '^OK' /tmp/prompt.out",
                 "the prompt completes")
            print("ok: an Unlock prompt completes when the device unlocks", flush=True)
            probe("lookup", "a", value)
            probe("kw-remove", "Passwords", "k1")
            probe("clear", "a")
            probe("absent", "a")
            left = [v[0].get("attributes") for v in files(store, "check-a").values()]
            if {"test": "a"} in left or any(a.get("user") == "k1" for a in left):
                raise Fail(f"deleted items are still in the host's store: {left}")
            print("ok: deleted items leave the host's store", flush=True)
            leaks = need(f"journalctl --user -u henge-secrets --no-pager | grep -c -e '{value}' -e Passwords || true")
            if leaks.splitlines()[-1] != "0" or value in open(err, errors="replace").read():
                raise Fail("a secret or a folder name is in the journal or hengevm's log")
            print("ok: no secret in the journal or hengevm's log", flush=True)

        def sh_probe(need, step):
            try:
                out = need(f"env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 /tmp/probe.py {step}")
                return out, 0
            except Fail as e:
                return str(e), 1

        boot(args, clone, store, "check-a", first)
        before = files(store, "check-a")

        def second(host, need, probe, err):
            probe("absent", "b")  # the first machine's item (dh) is there, but not for this machine
            probe("store", "c", stdin="other-" + value)
            mine = files(store, "check-b")
            if len(mine) != 1 or files(store, "check-a") != before:
                raise Fail(f"machine b: {len(mine)} items; machine a changed: {files(store, 'check-a') != before}")
            print("ok: another machine id sees none of the first machine's items, and keeps its own", flush=True)

        boot(args, clone, store, "check-b", second)


def main():
    if "--inner" in sys.argv:
        inner()
        print("secrets-check (container): all checks passed")
        return
    ap = argparse.ArgumentParser()
    sys.path.insert(0, HERE)
    import smoke
    ap.add_argument("--image", default=os.path.join(smoke.linux_dir(), "debian-desktop.img"))
    ap.add_argument("--hengevm", default=os.path.join(smoke.ROOT, "build", "hengevm"))
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--container", action="store_true", help="the probe in a Debian trixie container with kwallet6, not on hengevm")
    args = ap.parse_args()
    if args.container:
        container(args)
    else:
        vm(args)
        print("secrets-check: all checks passed")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
