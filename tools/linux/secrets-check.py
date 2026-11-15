#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# dependencies = ["pexpect"]
# ///
"""Check: tux-secrets keeps the guest's wallet in the host's store (host/secrets.c), scoped to the machine.

Default: boots a clone of the desktop image on tuxvm with --share, --secrets DIR and --machine-id, and drives
the device's lock with HV_INPUT_FILE ("secrets lock|unlock", in place of the app's Face ID check). In the guest,
secrets-probe.py stores, reads, lists and deletes through secret-tool, a Diffie-Hellman session and the KWallet
API; each item must land in DIR/MACHINE/ (mode 0600), and not show while locked; the same item shows through
both APIs; a prompt completes when the device unlocks; no secret is in the journal or tuxvm's log. A second
boot with another machine id must not see the first machine's items. The image needs tux-guest 1.6.1.

--container: the same probe in a Debian trixie container (Docker) against secrets-mock-host.py, with kwallet6
installed: kwallet-query (libkf6wallet) through tux-secrets, a second kwalletd6 that must leave the names
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

import guest_user as gu

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "secrets-probe.py")

# Names the check stores, made distinct so that a log check can look for each of them.
TAG = secrets.token_hex(3)
ATTR = "tux-probe-attr"  # secrets-probe.py's attribute
A, B, C = (f"attr-{x}-{TAG}" for x in "abc")
K1, M1, QKEY, FIRST = f"kw-key-{TAG}", f"kw-map-{TAG}", f"q-key-{TAG}", f"first-{TAG}"


def stored_words(value):
    """Every secret, label and attribute that the check and secrets-probe.py store."""
    secrets_ = [value, "dh-" + value, "kw-" + value, "q-" + value, "other-" + value, FIRST, "v-w-one", "v-w-two", "v-x/y", "sig-value"]
    labels = [f"Tuxedo probe {x}" for x in (A, B, C)] + ["Tuxedo probe"]
    attrs = [ATTR, A, B, C, K1, M1, QKEY, "Passwords", "Maps", "Wild", "SigFolder", "sig-key", "w-one", "w-two", "x/y", "w-map",
             "sam", "https://example.test/", "ünïcode", "Import", "imp-pw-key", "imp-p2", "imp-map", "imp-bin",
             f"imp-pw-{TAG}", f"imp-p2-{TAG}", f"imp-site-{TAG}", f"pass-{TAG}"]
    return secrets_ + labels + attrs


def leaks(text, words):
    return [w for w in words if w in text]


class Fail(Exception):
    pass


# ---- inside the container ----

def inner():
    import urllib.request
    env = dict(os.environ, TUX_SECRETS_HOST="127.0.0.1", TUX_SECRETS_PORT="8099", LANG="C.UTF-8", QT_QPA_PLATFORM="offscreen")
    daemon_bin = "/t/tux-guest/usr/lib/tux/tux-secrets"
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
        print("ok: tux-secrets owns org.freedesktop.secrets, org.kde.kwalletd6 and org.kde.kwalletd5", flush=True)

        control("unlock")
        value = "pw-" + secrets.token_hex(8)
        probe("store", A, stdin=value.encode())
        probe("lookup", A, value)
        probe("search", A)
        probe("dh", B, "dh-" + value)
        probe("kw-write", "Passwords", K1, "kw-" + value)
        probe("kw-read", "Passwords", K1, "kw-" + value)
        probe("kw-list", "Passwords", K1)
        probe("kw-map", "Maps", M1)
        probe("kw-cross", "Passwords", K1, "kw-" + value)
        probe("kw-wildcard")
        probe("kw-signal")
        probe("clients")
        d = dump()
        attrs = [v["meta"].get("attributes") for v in d.values()]
        if {ATTR: A} not in attrs or {"server": "Passwords", "user": K1, "type": "plaintext"} not in attrs:
            raise Fail(f"the host's store: {attrs}")
        m = next(v for v in d.values() if v["meta"].get("attributes", {}).get("type") == "map")
        import base64
        if json.loads(base64.b64decode(m["secret"])) != {"user": "sam", "url": "https://example.test/", "ünïcode": "ē"}:
            raise Fail("a KWallet map is not JSON in the store, as KF 6.14 keeps it")
        print(f"ok: the host's store has {len(d)} items, KWallet entries as KF 6.14 keeps them", flush=True)

        # libkf6wallet's own client. kwallet-query only replaces an entry that exists.
        probe("kw-write", "Passwords", QKEY, FIRST)
        r0 = kwq("-f", "Passwords", "-r", QKEY)
        r = kwq("-f", "Passwords", "-w", QKEY, stdin=b"q-" + value.encode())
        r2 = kwq("-f", "Passwords", "-r", QKEY)
        if r0.stdout.decode().strip() != FIRST or r.returncode or r2.stdout.decode().strip() != "q-" + value:
            raise Fail(f"kwallet-query: {r0.stdout.decode()[-100:]!r} {r.returncode} {r2.returncode} {r2.stderr.decode()[-300:]}")
        probe("kw-read", "Passwords", QKEY, "q-" + value)
        r3 = kwq("-l", "-f", "Passwords")
        r4 = kwq("-f", "Maps", "-r", M1)
        if QKEY not in r3.stdout.decode() or K1 not in r3.stdout.decode() or '"sam"' not in r4.stdout.decode():
            raise Fail(f"kwallet-query -l, or a map: {r3.stdout.decode()[-300:]} {r4.stdout.decode()[-300:]}")
        print("ok: kwallet-query (libkf6wallet 6.13) reads, replaces, lists and reads a map through tux-secrets", flush=True)

        # A second kwalletd6 (pam_kwallet_init, activation) leaves the names alone
        r = subprocess.run(["timeout", "20", "kwalletd6"], capture_output=True, env=env)
        names = {n: owner(n) for n in ("org.freedesktop.secrets", "org.kde.kwalletd6")}
        if r.returncode == 124 or set(names.values()) != {"python3"}:
            raise Fail(f"a second kwalletd6: exit {r.returncode}, names {names}")
        print(f"ok: a second kwalletd6 exits ({r.returncode}) and leaves the names", flush=True)

        control("lock")
        time.sleep(1)
        probe("locked", A)
        probe("kw-locked")
        r = kwq("-f", "Passwords", "-r", QKEY)
        if ("q-" + value) in r.stdout.decode():
            raise Fail("kwallet-query read a secret while locked")
        print(f"ok: kwallet-query reads nothing while locked (exit {r.returncode})", flush=True)

        p = subprocess.Popen(["python3", "/t/secrets-probe.py", "unlock-prompt", A], stdout=subprocess.PIPE, env=env, text=True)
        line = p.stdout.readline()
        if "PROMPT" not in line:
            raise Fail(f"unlock-prompt: {line}")
        time.sleep(1.5)
        control("unlock")
        out = p.stdout.read()
        if p.wait(timeout=60) or "OK" not in out:
            raise Fail(f"unlock-prompt: {out}")
        print("ok: an Unlock prompt completes when the device unlocks", flush=True)
        probe("lookup", A, value)
        probe("kw-remove", "Passwords", K1)
        probe("clear", A)
        probe("absent", A)
        left = [v["meta"].get("attributes") for v in dump().values()]
        if {ATTR: A} in left or any(a.get("user") == K1 for a in left):
            raise Fail(f"deleted items are still in the store: {left}")
        print("ok: deleted items leave the host's store", flush=True)
        log.flush()
        import_check(env, daemon_bin, dump)
        found = leaks(open("/tmp/daemon.log").read(), stored_words(value))
        if found:
            raise Fail(f"the daemon's log has stored words: {found}")
        print(f"ok: the daemon's log has none of the {len(stored_words(value))} stored secrets, labels and attributes", flush=True)
    finally:
        for p in procs:
            p.terminate()
    time.sleep(1)

    # The device has no wallet: tux-secrets, started by D-Bus, runs kwalletd6 in its place
    r = subprocess.Popen(["python3", daemon_bin, "--activated"], env=dict(env, TUX_SECRETS_PORT="8098"), stderr=subprocess.PIPE, text=True)
    for _ in range(150):
        if owner("org.kde.kwalletd6") == "kwalletd6":
            break
        time.sleep(0.2)
    if owner("org.kde.kwalletd6") != "kwalletd6":
        raise Fail("no fallback to kwalletd6")
    r.terminate()
    print("ok: without the device's wallet, D-Bus activation gets kwalletd6", flush=True)


IMPORTED = {("Import", "imp-pw-key"): f"imp-pw-{TAG}", ("Passwords", "imp-p2"): f"imp-p2-{TAG}"}


def qmap(m):
    import struct
    out = [struct.pack(">I", len(m))]
    for k, v in m.items():
        for s in (k, v):
            b = s.encode("utf-16-be")
            out.append(struct.pack(">I", len(b)) + b)
    return b"".join(out)


def make_kwallet(env, password):
    """A kwalletd6 wallet as a PAM login makes it: a salt file, then pamOpen with PBKDF2-SHA512 of the password."""
    import hashlib
    from jeepney import DBusAddress, new_method_call
    from jeepney.io.blocking import open_dbus_connection
    tmp = tempfile.mkdtemp()
    data = os.path.expanduser("~/.local/share/kwalletd")
    os.makedirs(data, exist_ok=True)
    salt = os.urandom(56)
    open(os.path.join(data, "kdewallet.salt"), "wb").write(salt)
    open(f"{tmp}/bus.conf", "w").write(f'<busconfig><type>session</type><listen>unix:dir={tmp}</listen><auth>EXTERNAL</auth>'
                                       '<policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/><allow receive_sender="*"/></policy></busconfig>')
    bus = subprocess.Popen(["dbus-daemon", "--config-file", f"{tmp}/bus.conf", "--nofork", "--print-address=1"], stdout=subprocess.PIPE, text=True)
    address = bus.stdout.readline().strip()
    kwd = subprocess.Popen(["/usr/bin/kwalletd6"], env=dict(env, DBUS_SESSION_BUS_ADDRESS=address), stderr=subprocess.DEVNULL)
    try:
        conn = open_dbus_connection(bus=address)
        addr = DBusAddress("/modules/kwalletd6", bus_name="org.kde.kwalletd6", interface="org.kde.KWallet")

        def kw(method, sig, *a):
            r = conn.send_and_get_reply(new_method_call(addr, method, sig, a), timeout=30)
            if r.header.message_type.name == "error":
                raise Fail(f"kwalletd6 {method}: {r.body}")
            return r.body
        for _ in range(100):
            try:
                kw("isEnabled", "")
                break
            except Fail:
                time.sleep(0.1)
        kw("pamOpen", "sayi", "kdewallet", hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 50000, 56), 0)
        (h,) = kw("open", "sxs", "kdewallet", 0, "maker")
        for (folder, key), v in IMPORTED.items():
            kw("createFolder", "iss", h, folder, "maker")
            kw("writePassword", "issss", h, folder, key, v, "maker")
        kw("writeMap", "issays", h, "Import", "imp-map", qmap({"site": f"imp-site-{TAG}"}), "maker")
        kw("writeEntry", "issays", h, "Import", "imp-bin", b"\0\1\xff" + TAG.encode(), "maker")
        kw("close", "ibs", h, True, "maker")
    finally:
        kwd.terminate()
        kwd.wait(timeout=10)
        bus.terminate()
    if not os.path.getsize(os.path.join(data, "kdewallet.kwl")):
        raise Fail("no wallet file")


def import_check(env, daemon_bin, dump):
    import base64
    make_kwallet(env, f"pass-{TAG}")
    print("ok: a kwalletd6 wallet with 2 passwords, a map and binary data", flush=True)
    command = "/t/tux-guest/usr/bin/tux-secrets"  # the package's command, not the daemon's path
    run = lambda pw, *a: subprocess.run([command, "--import", "--password-stdin", *a], input=pw + "\n",  # noqa: E731
                                        capture_output=True, text=True, env=env, timeout=120)
    r = run("wrong")
    if r.returncode == 0 or "does not open" not in r.stderr:
        raise Fail(f"import with a wrong password: {r.returncode} {r.stderr[-300:]}")
    print("ok: import: a wrong password is refused", flush=True)
    r = run(f"pass-{TAG}")
    if r.returncode or "imported 4 entries in 2 folders" not in r.stdout or "2 passwords, 1 maps, 1 binary" not in r.stdout:
        raise Fail(f"import: {r.returncode} {r.stdout[-300:]} {r.stderr[-300:]}")
    print("ok: import:", r.stdout.strip().split(". ")[0], flush=True)
    items = {(v["meta"]["attributes"].get("server"), v["meta"]["attributes"].get("user")): (v["meta"]["attributes"].get("type"), base64.b64decode(v["secret"]))
             for v in dump().values() if "server" in v["meta"].get("attributes", {})}
    for (folder, key), value in IMPORTED.items():
        if items.get((folder, key)) != ("plaintext", value.encode()):
            raise Fail(f"import: {folder}/{key} is {items.get((folder, key))}")
    if items.get(("Import", "imp-map")) != ("map", json.dumps({"site": f"imp-site-{TAG}"}, separators=(",", ":")).encode()):
        raise Fail(f"import: the map is {items.get(('Import', 'imp-map'))}")
    if items.get(("Import", "imp-bin"), ("", b""))[0] != "base64" or base64.b64decode(items[("Import", "imp-bin")][1]) != b"\0\1\xff" + TAG.encode():
        raise Fail(f"import: the binary entry is {items.get(('Import', 'imp-bin'))}")
    print("ok: import: every entry is in the device's wallet, with its type", flush=True)
    if not os.path.getsize(os.path.expanduser("~/.local/share/kwalletd/kdewallet.kwl")):
        raise Fail("import: the .kwl file went")
    r = run(f"pass-{TAG}")
    if r.returncode == 0 or "imported before" not in r.stderr:
        raise Fail(f"import a second time: {r.returncode} {r.stderr[-300:]}")
    print("ok: import: the .kwl file stays, and a second import needs --force", flush=True)


def firewall():
    """tux-secrets-firewall: only root and tux reach 10.0.2.4:81, and the rule comes back after anything that
    flushes nftables (nftables.service's start, reload and stop, nft flush ruleset). Stopping the follower keeps it."""
    script = "/t/tux-guest/usr/lib/tux/tux-secrets-firewall"
    sh = lambda cmd: subprocess.run(cmd, shell=True, capture_output=True, text=True)  # noqa: E731
    import socketserver
    import threading
    sh("id tux || useradd -M tux; ip addr add 10.0.2.4/32 dev lo")

    class Answer(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.recv(4096)
            self.request.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n")

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    server = socketserver.ThreadingTCPServer(("10.0.2.4", 81), Answer)  # http.server's bind looks the name up, and hangs here
    threading.Thread(target=server.serve_forever, daemon=True).start()
    get = "python3 -c \"import http.client as h; c=h.HTTPConnection('10.0.2.4', 81, timeout=3); c.request('GET','/'); print(c.getresponse().status)\""

    def reach(user):
        prefix = "" if user == "root" else f"setpriv --reuid={user} --regid={user if user == 'tux' else 'nogroup'} --clear-groups "
        return sh(prefix + get).stdout.strip() == "200"

    def guarded(what, wait=5.0):
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if not reach("nobody") and reach("tux") and reach("root"):
                return
            time.sleep(0.2)
        raise Fail(f"firewall {what}: nobody {reach('nobody')}, tux {reach('tux')}, root {reach('root')}")

    try:
        time.sleep(0.5)
        if not reach("nobody"):
            raise Fail("firewall: nobody cannot reach the port before the rule (the test is wrong)")
        follower = subprocess.Popen([script, "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        guarded("after start")
        for what, cmd in (("nft flush ruleset", "nft flush ruleset"),
                          ("nftables.service's start and reload (nft -f /etc/nftables.conf)", "nft -f /etc/nftables.conf"),
                          ("a flush of its own table", "nft flush table inet tux_secrets"),
                          ("a delete of its own table", "nft delete table inet tux_secrets")):
            sh(cmd)
            time.sleep(0.3)
            guarded(f"after {what}")
            print(f"ok: firewall: nobody is refused again after {what}", flush=True)
        os.killpg(follower.pid, 15)  # the unit stops or restarts (systemd ends the whole group): the rule stays
        follower.wait(timeout=5)
        guarded("with the follower stopped", wait=1)
        follower = subprocess.Popen([script, "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        guarded("after a second start")
        print("ok: firewall: the rule stays while the follower stops and starts again", flush=True)
        os.killpg(follower.pid, 15)
        time.sleep(0.5)
        sh(f"{script} remove")
        if not reach("nobody"):
            raise Fail("firewall: remove left the rule")
        print("ok: firewall: remove takes the rule away", flush=True)
    finally:
        server.shutdown()


def package():
    """tux-guest's scripts: the diversions, and the wallet's unit enabled on install and on a reinstall after a
    remove, but an admin's disable kept over an upgrade."""
    import shutil
    shutil.copytree("/t/tux-guest", "/tmp/pkg", dirs_exist_ok=True, symlinks=True)
    subprocess.run("find /tmp/pkg -type d -exec chmod 0755 {} + && find /tmp/pkg -type f -exec chmod 0644 {} + && "
                   "chmod 0755 /tmp/pkg/usr/lib/tux/* /tmp/pkg/DEBIAN/preinst /tmp/pkg/DEBIAN/postinst /tmp/pkg/DEBIAN/prerm /tmp/pkg/DEBIAN/postrm && "
                   "dpkg-deb --root-owner-group --build /tmp/pkg /tmp/tux-guest.deb >/dev/null", shell=True, check=True)

    def dpkg(*a):
        r = subprocess.run(["dpkg", *a], capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"dpkg {' '.join(a)}: {r.stderr[-500:]}")

    def enabled():
        return subprocess.run(["systemctl", "--global", "is-enabled", "tux-secrets.service"], capture_output=True, text=True).stdout.strip()

    def diverted():
        return subprocess.run(["dpkg-divert", "--list", "*tux*"], capture_output=True, text=True).stdout.count("by tux-guest")

    dpkg("-i", "/tmp/tux-guest.deb")
    if enabled() != "enabled" or diverted() != 3 or "kwalletd6" not in open("/usr/share/dbus-1/services/org.kde.kwalletd6.service.tux").read():
        raise Fail(f"install: unit {enabled()}, {diverted()} diversions")
    # The README's command, as the user types it in Konsole: on tux's PATH, and it reaches the import
    as_tux = ["setpriv", "--reuid=tux", "--regid=tux", "--clear-groups", "--reset-env", "sh", "-lc"]
    where = subprocess.run(as_tux + ["command -v tux-secrets"], capture_output=True, text=True).stdout.strip()
    r = subprocess.run(as_tux + ["tux-secrets --import --wallet no-such-wallet"], capture_output=True, text=True)
    if where != "/usr/bin/tux-secrets" or r.returncode == 0 or "no wallet" not in r.stderr:
        raise Fail(f"tux-secrets for tux: {where!r}, import {r.returncode} {r.stderr[-200:]!r}")
    print("ok: package: tux-secrets is on tux's PATH and reaches the import", flush=True)
    dpkg("-r", "tux-guest")
    if enabled() == "enabled" or diverted() != 0 or "kwalletd6" not in open("/usr/share/dbus-1/services/org.kde.kwalletd6.service").read():
        raise Fail(f"remove: unit {enabled()}, {diverted()} diversions")
    dpkg("-i", "/tmp/tux-guest.deb")
    if enabled() != "enabled":
        raise Fail(f"reinstall after a remove: the unit is {enabled()}")
    subprocess.run(["systemctl", "--global", "disable", "tux-secrets.service"], capture_output=True)
    dpkg("-i", "/tmp/tux-guest.deb")
    if enabled() != "disabled":
        raise Fail(f"upgrade after an admin's disable: the unit is {enabled()}")
    dpkg("--purge", "tux-guest")
    if diverted() != 0:
        raise Fail("purge left diversions")
    print("ok: package: diversions, the unit enabled on install and on a reinstall, an admin's disable kept", flush=True)


def container(args):
    dockerfile = ("FROM debian:trixie\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "
                  "python3-jeepney python3-cryptography libsecret-tools dbus dbus-bin systemd kwallet6 "
                  "davfs2 cloud-guest-utils gdisk e2fsprogs tzdata nftables iproute2 && rm -rf /var/lib/apt/lists/*\n")
    env = dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ.get("PATH", ""))
    r = subprocess.run(["docker", "build", "-q", "-t", "tux-secrets-test", "-"], input=dockerfile.encode(), capture_output=True, env=env)
    if r.returncode:
        raise Fail("docker build: " + r.stderr.decode()[-800:])
    r = subprocess.run(["docker", "run", "--rm", "--cap-add", "NET_ADMIN", "-v", f"{HERE}:/t:ro", "tux-secrets-test",
                        "dbus-run-session", "--", "python3", "/t/secrets-check.py", "--inner"], env=env)
    if r.returncode:
        raise Fail("in the container")


# ---- on tuxvm ----

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
            m = re.search(r"tuxvm: secrets (locked|unlocked)\n", open(self.err, errors="replace").read()[before:])
            if m:
                return m.group(1)
        raise Fail("secrets: tuxvm did not answer")


def boot(args, image, store, machine, steps):
    import pexpect
    sys.path.insert(0, HERE)
    import smoke
    from smoke import login, sh
    kernel, initrd = (os.path.join(smoke.linux_dir(), f) for f in ("Image", "initrd.img"))
    for f in (args.tuxvm, kernel, initrd, image):
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
    argv = ["/bin/sh", "-c", 'exec "$@" 2>"$0"', err, args.tuxvm, "--kernel", kernel, "--initrd", initrd,
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
                           sh(p, "journalctl --user -u tux-secrets --no-pager | tail -n 20", 20)[0])
            return out.strip()

        def probe(*a, stdin=None, limit=200):
            feed = f"printf %s '{stdin}' | " if stdin is not None else ""
            out = need(f"{feed}{bus} python3 /tmp/probe.py {' '.join(a)}", f"probe {' '.join(a)}", limit)
            print("ok:", out.splitlines()[-1], flush=True)

        end = time.monotonic() + 120
        while sh(p, "systemctl --user is-active tux-secrets", 20)[0].strip() != "active":
            if time.monotonic() > end:
                raise Fail("tux-secrets is not active 120 s after login")
            time.sleep(2)
        need("journalctl --user -u tux-secrets --no-pager | grep -q 'serving org.freedesktop.secrets org.kde.kwalletd6 org.kde.kwalletd5'",
             "the names")
        print("ok: tux-secrets is active and owns the Secret Service and KWallet names", flush=True)
        import base64
        data = base64.b64encode(open(PROBE, "rb").read()).decode()
        need(": > /tmp/probe.b64")
        for i in range(0, len(data), 600):
            need(f"printf %s '{data[i:i + 600]}' >> /tmp/probe.b64")
        need("base64 -d /tmp/probe.b64 > /tmp/probe.py")
        # The README's command for the guest user, from a login shell as in Konsole
        where = need("bash -lc 'command -v tux-secrets'", f"tux-secrets on {gu.user()}'s PATH").splitlines()[-1]
        out, rc = sh(p, "bash -lc 'tux-secrets --import --wallet no-such-wallet' 2>&1", 60)
        if where != "/usr/bin/tux-secrets" or rc == 0 or "no wallet" not in out:
            raise Fail(f"tux-secrets for {gu.user()}: {where!r}, import {rc} {out.strip()[-200:]!r}")
        print(f"ok: tux-secrets is on {gu.user()}'s PATH and reaches the import", flush=True)
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
                raise Fail("tuxvm did not start unlocked")
            probe("store", A, stdin=value)
            have = files(store, "check-a")
            mine = [v for v in have.values() if v[0].get("attributes") == {ATTR: A}]
            if len(mine) != 1 or mine[0][1] != value.encode() or mine[0][2] != 0o600:
                raise Fail(f"the item is not in the host's store as it should be: {[(m[0], m[2]) for m in mine]}")
            print("ok: the item is in the host's store, under the machine, mode 0600", flush=True)
            probe("lookup", A, value)
            probe("search", A)
            probe("dh", B, "dh-" + value)
            probe("kw-write", "Passwords", K1, "kw-" + value)
            probe("kw-read", "Passwords", K1, "kw-" + value)
            probe("kw-list", "Passwords", K1)
            probe("kw-map", "Maps", M1)
            probe("kw-cross", "Passwords", K1, "kw-" + value)
            probe("kw-wildcard")
            probe("kw-signal")
            probe("clients")
            if not any(v[0].get("attributes", {}).get("server") == "Passwords" for v in files(store, "check-a").values()):
                raise Fail("the KWallet entry is not in the host's store")
            print("ok: the KWallet entry is in the host's store", flush=True)

            # Only the session user (and root) reach the wallet's port; port 80 has no wallet
            get = ("python3 -c \"import http.client as h, sys; c=h.HTTPConnection('10.0.2.4', {port}, timeout=5); "
                   "c.request('GET','/.tux/secrets/state'); print('status', c.getresponse().status)\" 2>&1 | tail -n 1")
            need("systemctl is-active tux-secrets-firewall", "the firewall unit")
            mine = need(get.format(port=81))
            other = need("sudo -u nobody " + get.format(port=81))
            root = need("sudo " + get.format(port=81))
            port80 = need(get.format(port=80))
            if mine != "status 200" or root != "status 200" or "status" in other or port80 != "status 404":
                raise Fail(f"port rule: {gu.user()} {mine!r}, nobody {other!r}, root {root!r}, port 80 {port80!r}")
            print(f"ok: {gu.user()} and root reach the wallet's port, nobody is refused ({other.split(':')[0]}), port 80 has no wallet", flush=True)

            # The rule comes back after whatever flushes nftables, and a restart of its own unit leaves no gap
            for what in ("systemctl restart nftables", "systemctl reload nftables", "systemctl stop nftables",
                         "nft flush ruleset", "systemctl restart tux-secrets-firewall"):
                need(f"sudo {what}", what)
                end = time.monotonic() + 10
                while True:
                    other, mine = need("sudo -u nobody " + get.format(port=81)), need(get.format(port=81))
                    if "status" not in other and mine == "status 200":
                        break
                    if time.monotonic() > end:
                        raise Fail(f"after {what}: nobody {other!r}, {gu.user()} {mine!r}")
                    time.sleep(0.5)
                need("systemctl is-active tux-secrets-firewall", f"the firewall unit after {what}")
                print(f"ok: after {what}, nobody is refused and {gu.user()} reaches the port", flush=True)

            host.line("secrets lock")
            end = time.monotonic() + 60
            while True:  # the guest hears of it through its long poll
                out, rc = sh_probe(need, f"locked {A}")
                if rc == 0:
                    break
                if time.monotonic() > end:
                    raise Fail("locked: " + out)
                time.sleep(1)
            print("ok: locked: the item shows as locked, GetSecret(s) give nothing", flush=True)
            probe("kw-locked")
            iid = next(k for k, v in files(store, "check-a").items() if v[0].get("attributes") == {ATTR: A})
            code = need(f"python3 -c \"import http.client as h; c=h.HTTPConnection('10.0.2.4', 81); c.request('GET','/.tux/secrets/items/{iid}'); print(c.getresponse().status)\"")
            if code.splitlines()[-1] != "423":
                raise Fail(f"the host gave {code} for a read while locked")
            print("ok: the host answers 423 to a read while locked", flush=True)
            need("rm -f /tmp/prompt.out; (env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
                 f"python3 /tmp/probe.py unlock-prompt {A} > /tmp/prompt.out 2>&1 &) ; for i in $(seq 60); do grep -q PROMPT /tmp/prompt.out && break; sleep 0.5; done; grep -q PROMPT /tmp/prompt.out",
                 "a prompt while locked")
            host.line("secrets unlock")
            need("for i in $(seq 120); do grep -q '^OK' /tmp/prompt.out && break; sleep 0.5; done; cat /tmp/prompt.out; grep -q '^OK' /tmp/prompt.out",
                 "the prompt completes")
            print("ok: an Unlock prompt completes when the device unlocks", flush=True)
            probe("lookup", A, value)
            probe("kw-remove", "Passwords", K1)
            probe("clear", A)
            probe("absent", A)
            left = [v[0].get("attributes") for v in files(store, "check-a").values()]
            if {ATTR: A} in left or any(a.get("user") == K1 for a in left):
                raise Fail(f"deleted items are still in the host's store: {left}")
            print("ok: deleted items leave the host's store", flush=True)
            # Every log this check reads: the guest's whole journal (system and user) and tuxvm's stderr
            journal = need("sudo journalctl -b --no-pager -o cat | base64 -w0", limit=120).splitlines()[-1]
            import base64
            found = leaks(base64.b64decode(journal).decode(errors="replace") + open(err, errors="replace").read(), stored_words(value))
            if found:
                raise Fail(f"in the journal or tuxvm's log: {found}")
            print(f"ok: none of the {len(stored_words(value))} stored secrets, labels and attributes is in the journal or tuxvm's log", flush=True)

        def sh_probe(need, step):
            try:
                out = need(f"env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 /tmp/probe.py {step}")
                return out, 0
            except Fail as e:
                return str(e), 1

        boot(args, clone, store, "check-a", first)
        before = files(store, "check-a")

        def second(host, need, probe, err):
            probe("absent", B)  # the first machine's item (dh) is there, but not for this machine
            probe("store", C, stdin="other-" + value)
            mine = files(store, "check-b")
            if len(mine) != 1 or files(store, "check-a") != before:
                raise Fail(f"machine b: {len(mine)} items; machine a changed: {files(store, 'check-a') != before}")
            print("ok: another machine id sees none of the first machine's items, and keeps its own", flush=True)

        boot(args, clone, store, "check-b", second)


def main():
    if "--inner" in sys.argv:
        inner()
        firewall()
        package()
        print("secrets-check (container): all checks passed")
        return
    ap = argparse.ArgumentParser()
    sys.path.insert(0, HERE)
    import smoke
    ap.add_argument("--image", default=os.path.join(smoke.linux_dir(), "debian-desktop.img"))
    ap.add_argument("--tuxvm", default=os.path.join(smoke.ROOT, "build", "tuxvm"))
    ap.add_argument("--cpus", type=int, default=4)
    ap.add_argument("--work-dir", help="where the clone goes (the image's APFS volume)")
    ap.add_argument("--container", action="store_true", help="the probe in a Debian trixie container with kwallet6, not on tuxvm")
    args = ap.parse_args()
    if args.container:
        container(args)
    else:
        gu.use(args.image)
        vm(args)
        print("secrets-check: all checks passed")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL {e}", file=sys.stderr)
        sys.exit(1)
