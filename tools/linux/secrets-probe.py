#!/usr/bin/python3
"""Runs in the guest (or a Debian container) for secrets-check.py: one step of the wallet through its D-Bus
clients. Prints "OK ..." and exits 0, or prints "FAIL ..." and exits 1.

  store ATTR              secret-tool store (attribute test=ATTR), the value on stdin
  lookup ATTR [VALUE]     secret-tool lookup; with VALUE, it must match
  absent ATTR             secret-tool lookup finds nothing
  search ATTR             secret-tool search --all lists the item with its label
  clear ATTR              secret-tool clear
  dh ATTR VALUE           a Diffie-Hellman (AES) session: create the item, then read it back
  locked ATTR             the device is locked: the item shows as locked and its secret does not come
  unlock-prompt ATTR      Unlock gives a prompt that completes once the device unlocks (the caller unlocks it)
  kw-write FOLDER KEY VALUE / kw-read FOLDER KEY VALUE / kw-map FOLDER KEY / kw-list FOLDER KEY
  kw-remove FOLDER KEY / kw-locked      the KWallet API (org.kde.kwalletd6)
  kw-cross FOLDER KEY VALUE             a KWallet password shows through the Secret Service, as KF 6.14 keeps it
"""
import os
import struct
import subprocess
import sys
import threading

from jeepney import DBusAddress, MatchRule, MessageType, new_method_call
from jeepney.io.blocking import open_dbus_connection

SS = DBusAddress("/org/freedesktop/secrets", bus_name="org.freedesktop.secrets", interface="org.freedesktop.Secret.Service")
KWD = DBusAddress("/modules/kwalletd6", bus_name="org.kde.kwalletd6", interface="org.kde.KWallet")
APP = "henge-secrets-probe"


def ok(*a):
    print("OK", *a, flush=True)
    sys.exit(0)


def fail(*a):
    print("FAIL", *a, flush=True)
    sys.exit(1)


def call(conn, addr, method, sig="", body=(), path=None, iface=None, timeout=10):
    if path or iface:
        addr = DBusAddress(path or addr.object_path, bus_name=addr.bus_name, interface=iface or addr.interface)
    reply = conn.send_and_get_reply(new_method_call(addr, method, sig, body), timeout=timeout)
    if reply.header.message_type == MessageType.error:
        raise RuntimeError(reply.header.fields.get(4, "error") + ": " + str(reply.body[0] if reply.body else ""))
    return reply.body


def tool(*args, stdin=None, timeout=30):
    return subprocess.run(["secret-tool", *args], input=stdin, capture_output=True, timeout=timeout)


def qmap(m):
    out = [struct.pack(">I", len(m))]
    for k, v in m.items():
        for s in (k, v):
            b = s.encode("utf-16-be")
            out.append(struct.pack(">I", len(b)) + b)
    return b"".join(out)


def main():
    step, args = sys.argv[1], sys.argv[2:]
    if step == "store":
        r = tool("store", "--label", f"Henge probe {args[0]}", "test", args[0], stdin=sys.stdin.buffer.read())
        ok("stored") if r.returncode == 0 else fail("store", r.returncode, r.stderr.decode()[:200])
    if step == "lookup":
        r = tool("lookup", "test", args[0], timeout=180)
        got = r.stdout.decode()
        if r.returncode != 0:
            fail("lookup", r.returncode, r.stderr.decode()[:200])
        if len(args) > 1 and got != args[1]:
            fail("lookup: another value")
        ok("lookup")
    if step == "absent":
        r = tool("lookup", "test", args[0])
        ok("absent") if r.returncode != 0 and not r.stdout else fail("absent: found", r.returncode)
    if step == "search":
        r = tool("search", "--all", "test", args[0])
        out = r.stdout.decode() + r.stderr.decode()
        ok("search") if f"Henge probe {args[0]}" in out else fail("search", out[:300])
    if step == "clear":
        r = tool("clear", "test", args[0])
        ok("clear") if r.returncode == 0 else fail("clear", r.returncode)

    conn = open_dbus_connection(bus="SESSION")
    if step == "dh":
        from cryptography.hazmat.primitives import hashes, padding
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        prime = int("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
                    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
                    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF", 16)
        priv = int.from_bytes(os.urandom(128), "big") % (prime - 2) + 1
        (out, session) = call(conn, SS, "OpenSession", "sv", ("dh-ietf1024-sha256-aes128-cbc-pkcs7", ("ay", pow(2, priv, prime).to_bytes(128, "big"))))
        shared = pow(int.from_bytes(out[1], "big"), priv, prime).to_bytes(128, "big")
        key = HKDF(algorithm=hashes.SHA256(), length=16, salt=None, info=b"").derive(shared)
        iv = os.urandom(16)
        p = padding.PKCS7(128).padder()
        e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        sealed = e.update(p.update(args[1].encode()) + p.finalize()) + e.finalize()
        (coll,) = call(conn, SS, "ReadAlias", "s", ("default",))
        props = {"org.freedesktop.Secret.Item.Label": ("s", f"Henge probe {args[0]}"),
                 "org.freedesktop.Secret.Item.Attributes": ("a{ss}", {"test": args[0]})}
        (item, prompt) = call(conn, SS, "CreateItem", "a{sv}(oayays)b", (props, (session, iv, sealed, "text/plain"), True),
                              path=coll, iface="org.freedesktop.Secret.Collection")
        ((sess, params, value, ctype),) = call(conn, SS, "GetSecret", "o", (session,), path=item, iface="org.freedesktop.Secret.Item")
        d = Cipher(algorithms.AES(key), modes.CBC(bytes(params))).decryptor()
        u = padding.PKCS7(128).unpadder()
        plain = u.update(d.update(bytes(value)) + d.finalize()) + u.finalize()
        if plain.decode() != args[1] or bytes(value) == args[1].encode():
            fail("dh: the value did not round-trip encrypted")
        ok("dh session: encrypted both ways")
    if step in ("locked", "unlock-prompt"):
        unlocked, locked = call(conn, SS, "SearchItems", "a{ss}", ({"test": args[0]},))
        if unlocked or not locked:
            fail("search while locked", len(unlocked), len(locked))
        if step == "unlock-prompt":
            rule = MatchRule(type="signal", interface="org.freedesktop.Secret.Prompt", member="Completed")
            call(conn, DBusAddress("/org/freedesktop/DBus", bus_name="org.freedesktop.DBus", interface="org.freedesktop.DBus"),
                 "AddMatch", "s", (rule.serialise(),))
            (done, prompt) = call(conn, SS, "Unlock", "ao", (locked,))
            if done or prompt == "/":
                fail("unlock while locked gave no prompt")
            with conn.filter(rule) as q:
                call(conn, SS, "Prompt", "s", ("",), path=prompt, iface="org.freedesktop.Secret.Prompt")
                print("PROMPT", flush=True)  # the caller unlocks the device now
                msg = conn.recv_until_filtered(q, timeout=150)
            dismissed, result = msg.body
            ok("prompt completed") if not dismissed and list(result[1]) == list(locked) else fail("prompt", dismissed)
        (_, session) = call(conn, SS, "OpenSession", "sv", ("plain", ("s", "")))
        (got,) = call(conn, SS, "GetSecrets", "aoo", (locked, session))
        if got:
            fail("GetSecrets gave a secret while locked")
        try:
            call(conn, SS, "GetSecret", "o", (session,), path=locked[0], iface="org.freedesktop.Secret.Item")
            fail("GetSecret gave a secret while locked")
        except RuntimeError as e:
            if "IsLocked" not in str(e):
                fail("GetSecret:", e)
        (coll,) = call(conn, SS, "ReadAlias", "s", ("default",))
        (v,) = call(conn, SS, "Get", "ss", ("org.freedesktop.Secret.Collection", "Locked"), path=coll, iface="org.freedesktop.DBus.Properties")
        ok("locked: shown, not readable") if v[1] is True else fail("collection not locked")

    # KWallet
    if step == "kw-locked":
        (h,) = call(conn, KWD, "open", "sxs", ("kdewallet", 0, APP))
        ok("kwallet open refused while locked") if h < 0 else fail("kwallet opened while locked")
    (h,) = call(conn, KWD, "open", "sxs", ("kdewallet", 0, APP))
    if h < 0:
        fail("kwallet open", h)
    if step == "kw-write":
        (rc,) = call(conn, KWD, "writePassword", "issss", (h, args[0], args[1], args[2], APP))
        ok("kw write") if rc == 0 else fail("kw write", rc)
    if step == "kw-read":
        (v,) = call(conn, KWD, "readPassword", "isss", (h, args[0], args[1], APP))
        (t,) = call(conn, KWD, "entryType", "isss", (h, args[0], args[1], APP))
        ok("kw read") if v == args[2] and t == 1 else fail("kw read", t)
    if step == "kw-map":
        m = {"user": "sam", "url": "https://example.test/", "ünïcode": "ē"}
        (rc,) = call(conn, KWD, "writeMap", "issays", (h, args[0], args[1], qmap(m), APP))
        (raw,) = call(conn, KWD, "readMap", "isss", (h, args[0], args[1], APP))
        (t,) = call(conn, KWD, "entryType", "isss", (h, args[0], args[1], APP))
        b = bytes(raw)
        (n,), at, back = struct.unpack_from(">I", b, 0), 4, {}
        for _ in range(n):
            pair = []
            for _ in range(2):
                (size,) = struct.unpack_from(">I", b, at)
                pair.append(b[at + 4:at + 4 + size].decode("utf-16-be"))
                at += 4 + size
            back[pair[0]] = pair[1]
        ok("kw map") if rc == 0 and back == m and t == 3 else fail("kw map", rc, t)
    if step == "kw-list":
        (folders,) = call(conn, KWD, "folderList", "is", (h, APP))
        (keys,) = call(conn, KWD, "entryList", "iss", (h, args[0], APP))
        (has,) = call(conn, KWD, "hasEntry", "isss", (h, args[0], args[1], APP))
        ok("kw list") if args[0] in folders and args[1] in keys and has else fail("kw list")
    if step == "kw-remove":
        (rc,) = call(conn, KWD, "removeEntry", "isss", (h, args[0], args[1], APP))
        (has,) = call(conn, KWD, "hasEntry", "isss", (h, args[0], args[1], APP))
        ok("kw remove") if rc == 0 and not has else fail("kw remove", rc)
    if step == "kw-cross":
        r = subprocess.run(["secret-tool", "lookup", "server", args[0], "user", args[1], "type", "plaintext"], capture_output=True, timeout=30)
        ok("kwallet entry seen through the Secret Service") if r.stdout.decode() == args[2] else fail("kw cross", r.returncode)
    fail("unknown step", step)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        fail(type(e).__name__, str(e)[:300])
