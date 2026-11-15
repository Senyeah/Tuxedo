#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.9"
# ///
"""Tests the tux-guest 1.11.0 scripts for Tuxedo Additions with no guest (docs/guest-additions-design.md, section 6):

  tux-additions-launch   a signed copy runs the agent; bad media gets exit 4 and a bad-media event
  tux-console-login      the agetty command for each marker, on the serial console and on tty1
  tux-additions-report   the copy of the media's caps script, the account object, and the POST
  tux-status             asks for the report once the app answers

The launcher tests need gpg and gpgv (Debian: gnupg and gpgv); without them they are skipped and say so.
Run: uv run tools/linux/test_tux_guest_scripts.py
"""
import hashlib
import http.server
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "tux-guest", "usr", "lib", "tux")
LAUNCH = os.path.join(LIB, "tux-additions-launch")
LOGIN = os.path.join(LIB, "tux-console-login")
REPORT = os.path.join(LIB, "tux-additions-report")
HAVE_GPG = bool(shutil.which("gpg") and shutil.which("gpgv"))
UNIT_DIR = os.path.join(HERE, "tux-guest", "usr", "lib", "systemd", "system")


def real(path):
    return os.path.realpath(path)


def media_version_of(state):
    with open(os.path.join(state, "current", "versions.json")) as f:
        return json.load(f)["additions"]


class Host:
    """A fake app: keeps each POST to /.tux/additions."""

    def __init__(self):
        self.events = []
        events = self.events

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(h):
                events.append((h.path, json.loads(h.rfile.read(int(h.headers["Content-Length"])))))
                h.send_response(200)
                h.send_header("Content-Length", "11")
                h.end_headers()
                h.wfile.write(b'{"seq":"1"}\n')

            def log_message(h, *a):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]
        self.env = {"TUX_ADDITIONS_HOST": "127.0.0.1", "TUX_ADDITIONS_PORT": str(self.port)}

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@unittest.skipUnless(HAVE_GPG, "gpg and gpgv are not installed: the launcher tests did not run")
class Launch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = real(tempfile.mkdtemp(prefix="tux-launch-"))
        cls.homes = []
        cls.keys = {}
        for name in ("tux", "other"):
            home = real(tempfile.mkdtemp(prefix="tl-", dir="/tmp"))  # a short path: gpg-agent's socket is in it
            cls.homes.append(home)
            subprocess.run(["gpg", "--homedir", home, "--batch", "--passphrase", "", "--quick-gen-key",
                            name + "@test.invalid", "ed25519", "sign", "never"], check=True, capture_output=True)
            ring = os.path.join(cls.tmp, name + ".gpg")
            with open(ring, "wb") as f:
                f.write(subprocess.run(["gpg", "--homedir", home, "--export"], check=True, capture_output=True).stdout)
            cls.keys[name] = (home, ring)

    @classmethod
    def tearDownClass(cls):
        for home in cls.homes:
            subprocess.run(["gpgconf", "--homedir", home, "--kill", "all"], capture_output=True)
            shutil.rmtree(home, ignore_errors=True)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.dir = real(tempfile.mkdtemp(prefix="case-", dir=self.tmp))
        self.media = os.path.join(self.dir, "media", "tux-additions")
        self.state = os.path.join(self.dir, "state")
        self.out = os.path.join(self.dir, "agent-ran.json")
        self.host = Host()
        self.addCleanup(self.host.close)
        self.make_media()

    def make_media(self, signer="tux", files=None):
        shutil.rmtree(self.media, ignore_errors=True)
        os.makedirs(os.path.join(self.media, "apt", "pool"))
        files = files or {
            "agent": "import json, os, sys\njson.dump([sys.argv, os.getcwd(), sys.path[0]], open(os.environ['OUT'], 'w'))\n",
            "install": "#!/bin/sh\necho install\n",
            "actions.json": '{"protocol": 1}\n',
            "apt/pool/a.deb": "deb bytes\n",
        }
        for rel, text in files.items():
            with open(os.path.join(self.media, rel), "w") as f:
                f.write(text)
        if "install" in files:
            os.chmod(os.path.join(self.media, "install"), 0o755)
        self.sign(signer)

    def sign(self, signer="tux"):
        lines = []
        for top, _, names in os.walk(self.media):
            for n in sorted(names):
                p = os.path.join(top, n)
                rel = os.path.relpath(p, self.media)
                if rel in ("SHA256SUMS", "SHA256SUMS.gpg"):
                    continue
                with open(p, "rb") as f:
                    lines.append("%s  %s\n" % (hashlib.sha256(f.read()).hexdigest(), rel))
        with open(os.path.join(self.media, "SHA256SUMS"), "w") as f:
            f.write("".join(sorted(lines)))
        sig = os.path.join(self.media, "SHA256SUMS.gpg")
        if os.path.exists(sig):
            os.remove(sig)
        subprocess.run(["gpg", "--homedir", self.keys[signer][0], "--batch", "--detach-sign", "-o", sig,
                        os.path.join(self.media, "SHA256SUMS")], check=True, capture_output=True)

    def launch(self, *args, key="tux", media=None, env=None):
        env = {"PATH": os.environ["PATH"], "TUX_ADDITIONS_MEDIA": media or self.media, "TUX_ADDITIONS_STATE": self.state,
               "TUX_ADDITIONS_KEY": self.keys[key][1], "OUT": self.out, **self.host.env, **(env or {})}
        return subprocess.run([sys.executable, LAUNCH, *(args or ("7",))], env=env, capture_output=True, text=True,
                              timeout=60)

    def refused(self, r, why):
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertEqual(len(self.host.events), 1)
        path, ev = self.host.events[0]
        self.assertEqual(path, "/.tux/additions")
        self.assertEqual(ev["t"], "bad-media")
        self.assertEqual(ev["n"], 7)
        self.assertIn(why, ev["why"])
        self.assertFalse(os.path.exists(self.out), "the agent ran")
        self.assertFalse(os.path.exists(os.path.join(self.state, "7.new")), "a half copy stayed")
        self.assertFalse(os.path.exists(os.path.join(self.state, "7")))

    def versioned(self, version, **extra):
        """Good media that says it is release `version` (versions.json is signed with the rest)."""
        files = {"agent": "import json, os, sys\njson.dump([sys.argv, os.getcwd(), sys.path[0]], open(os.environ['OUT'], 'w'))\n",
                 "install": "#!/bin/sh\necho install\n", "actions.json": '{"protocol": 1}\n',
                 "apt/pool/a.deb": "deb bytes\n"}
        if version is not None:
            files["versions.json"] = json.dumps({"additions": version}) + "\n"
        files.update(extra)
        self.make_media(files=files)

    def test_good_media_runs_the_agent_from_the_copy(self):
        r = self.launch()
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.out) as f:
            argv, cwd, path0 = json.load(f)
        current = os.path.join(self.state, "current")
        self.assertEqual(argv, [os.path.join(current, "agent"), "run", "--n", "7"])
        self.assertEqual(real(cwd), os.path.join(self.state, "7"))
        self.assertEqual(real(path0), os.path.join(self.state, "7"))
        self.assertEqual(os.readlink(current), "7")
        self.assertEqual(self.host.events, [])
        self.assertTrue(os.path.isfile(os.path.join(self.state, "7", "apt", "pool", "a.deb")))

    def test_modes_of_the_copy(self):
        self.launch()
        t = os.path.join(self.state, "7")
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(t, "install")).st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(t, "agent")).st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(t, "apt")).st_mode), 0o755)

    def test_older_trees_go_and_current_follows(self):
        os.makedirs(os.path.join(self.state, "5", "x"))
        os.makedirs(os.path.join(self.state, "6.new"))
        os.makedirs(os.path.join(self.state, "keep-me"))
        self.assertEqual(self.launch("7").returncode, 0)
        self.assertEqual(self.launch("8").returncode, 0)
        self.assertEqual(sorted(os.listdir(self.state)), ["8", "current", "keep-me"])
        self.assertEqual(os.readlink(os.path.join(self.state, "current")), "8")

    def test_a_changed_byte_is_refused_and_the_old_tree_stays(self):
        self.assertEqual(self.launch("6").returncode, 0)
        os.remove(self.out)
        with open(os.path.join(self.media, "apt", "pool", "a.deb"), "w") as f:
            f.write("deb byteS\n")
        r = self.launch("7")
        self.refused(r, "sums do not match")
        self.assertEqual(os.readlink(os.path.join(self.state, "current")), "6")
        self.assertTrue(os.path.isdir(os.path.join(self.state, "6")))

    def test_a_signature_by_another_key_is_refused_before_the_copy(self):
        self.make_media(signer="other")
        r = self.launch()
        self.refused(r, "bad signature")
        self.assertEqual(os.listdir(self.state) if os.path.isdir(self.state) else [], [])

    def test_changed_sums_file_is_refused(self):
        with open(os.path.join(self.media, "SHA256SUMS"), "a") as f:
            f.write("0" * 64 + "  agent\n")
        self.refused(self.launch(), "bad signature")

    def test_no_signature_file_is_refused(self):
        os.remove(os.path.join(self.media, "SHA256SUMS.gpg"))
        self.refused(self.launch(), "no SHA256SUMS.gpg")

    def test_a_file_the_sums_do_not_list_is_refused(self):
        with open(os.path.join(self.media, "json.py"), "w") as f:
            f.write("# would shadow the standard json module\n")
        self.refused(self.launch(), "json.py")

    def test_a_link_is_refused(self):
        os.symlink("/etc/passwd", os.path.join(self.media, "passwd"))
        self.refused(self.launch(), "not a plain file")

    def test_a_listed_path_outside_the_tree_is_refused(self):
        self.make_media(files={"agent": "pass\n"})
        sums = os.path.join(self.media, "SHA256SUMS")
        with open(sums, "a") as f:
            f.write("0" * 64 + "  ../../etc/passwd\n")
        os.remove(os.path.join(self.media, "SHA256SUMS.gpg"))
        subprocess.run(["gpg", "--homedir", self.keys["tux"][0], "--batch", "--detach-sign", "-o",
                        os.path.join(self.media, "SHA256SUMS.gpg"), sums], check=True, capture_output=True)
        self.refused(self.launch(), "not valid")

    def test_media_without_an_agent_is_refused(self):
        self.make_media(files={"install": "#!/bin/sh\n"})
        self.refused(self.launch(), "no agent")

    def test_the_installed_key_is_the_only_trust(self):
        # the key on the media does not count; neither does one in the default gpg home
        shutil.copy(self.keys["other"][1], os.path.join(self.media, "tux-archive.gpg"))
        self.sign("other")
        self.refused(self.launch(key="tux"), "bad signature")

    def test_a_missing_key_is_refused(self):
        env = {"PATH": os.environ["PATH"], "TUX_ADDITIONS_MEDIA": self.media, "TUX_ADDITIONS_STATE": self.state,
               "TUX_ADDITIONS_KEY": os.path.join(self.dir, "no-key.gpg"), "OUT": self.out, **self.host.env}
        r = subprocess.run([sys.executable, LAUNCH, "7"], env=env, capture_output=True, text=True, timeout=60)
        self.refused(r, "bad signature")

    def test_a_media_path_with_a_link_is_refused(self):
        link = os.path.join(self.dir, "link")
        os.symlink(self.media, link)
        self.refused(self.launch(media=link), "link")

    def test_a_media_path_that_is_not_there_is_refused(self):
        self.refused(self.launch(media=os.path.join(self.dir, "gone")), "no SHA256SUMS")

    def failed_to_launch(self, r, word):
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertEqual([(path, ev["t"], ev["n"]) for path, ev in self.host.events], [("/.tux/additions", "launch-error", 7)])
        self.assertIn(word, self.host.events[0][1]["why"])
        self.assertLessEqual(len(self.host.events[0][1]["why"]), 200)
        self.assertFalse(os.path.exists(self.out), "the agent ran")

    def test_a_full_disk_is_a_launch_error_and_not_bad_media(self):
        with open(self.state, "w") as f:  # a file where the folder of the trees should be: makedirs fails like a full disk
            f.write("x")
        r = self.launch()
        self.failed_to_launch(r, "could not use the media")

    def test_a_missing_gpgv_is_a_launch_error_and_not_bad_media(self):
        r = self.launch(env={"PATH": "/nonexistent"})
        self.failed_to_launch(r, "gpgv")
        self.assertFalse(os.path.exists(os.path.join(self.state, "7")))

    def test_a_release_older_than_the_installed_one_is_refused(self):
        self.versioned("1.11.0+2")
        self.assertEqual(self.launch("6").returncode, 0)
        os.remove(self.out)
        self.versioned("1.11.0+1")
        r = self.launch("7")
        self.refused(r, "older than 1.11.0+2")
        self.assertEqual(os.readlink(os.path.join(self.state, "current")), "6")
        self.assertTrue(os.path.isdir(os.path.join(self.state, "6")))

    def test_releases_compare_by_their_numbers(self):
        self.versioned("1.11.0+9")
        self.assertEqual(self.launch("1").returncode, 0)
        current = "1.11.0+9"
        for i, (version, accepted) in enumerate((("1.11.0+9", True), ("1.11.0+10", True), ("1.12.0+1", True),
                                                 ("1.12.0+0", False), ("1.11.9+99", False), ("1.12.0+1", True))):
            self.versioned(version)
            if os.path.exists(self.out):
                os.remove(self.out)
            self.host.events.clear()
            r = self.launch(str(10 + i))
            self.assertEqual(r.returncode, 0 if accepted else 4, (version, r.stderr))
            if accepted:
                current = version
            else:
                self.assertEqual(self.host.events[0][1]["t"], "bad-media")
                self.assertIn("older", self.host.events[0][1]["why"])
            self.assertEqual(media_version_of(self.state), current)

    def test_a_media_with_no_version_is_refused_when_a_release_is_installed(self):
        self.versioned("1.11.0+1")
        self.assertEqual(self.launch("6").returncode, 0)
        os.remove(self.out)
        self.versioned(None)
        self.refused(self.launch("7"), "no version")

    def test_the_first_media_and_one_after_an_unversioned_media_are_accepted(self):
        self.versioned(None)
        self.assertEqual(self.launch("6").returncode, 0)  # nothing is installed yet
        self.versioned("1.0.0+1")
        self.assertEqual(self.launch("7").returncode, 0)  # the installed one has no version: nothing to compare
        self.versioned("1.0.0+1")
        self.assertEqual(self.launch("8").returncode, 0)

    def test_the_test_override_allows_an_older_release(self):
        self.versioned("1.11.0+2")
        self.assertEqual(self.launch("6").returncode, 0)
        self.versioned("1.10.0+1")
        r = self.launch("7", env={"TUX_ADDITIONS_ALLOW_OLDER": "1"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(media_version_of(self.state), "1.10.0+1")

    def test_a_version_that_is_not_text_of_the_shape_counts_as_none(self):
        self.versioned("1.11.0+1")
        self.assertEqual(self.launch("6").returncode, 0)
        os.remove(self.out)
        self.versioned("not a version\n; rm -rf /")
        self.refused(self.launch("7"), "no version")

    def test_usage(self):
        for args in ([], ["0"], ["07"], ["../x"], ["1", "2"], ["-1"], ["1x"]):
            env = {"PATH": os.environ["PATH"], **self.host.env}
            r = subprocess.run([sys.executable, LAUNCH, *args], env=env, capture_output=True, text=True, timeout=30)
            self.assertNotIn(r.returncode, (0, 4), args)
            self.assertIn("usage", r.stderr)
        self.assertEqual(self.host.events, [])

    def test_the_app_being_out_of_reach_does_not_hide_the_refusal(self):
        self.host.close()
        env = {"PATH": os.environ["PATH"], "TUX_ADDITIONS_MEDIA": self.media + ".none", "TUX_ADDITIONS_STATE": self.state,
               "TUX_ADDITIONS_KEY": self.keys["tux"][1], "TUX_ADDITIONS_HOST": "127.0.0.1", "TUX_ADDITIONS_PORT": "1",
               "OUT": self.out}
        r = subprocess.run([sys.executable, LAUNCH, "7"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 4)
        self.assertIn("did not get", r.stderr)


class ConsoleLogin(unittest.TestCase):
    def setUp(self):
        self.dir = real(tempfile.mkdtemp(prefix="login-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        self.args = os.path.join(self.dir, "args")
        with open(os.path.join(self.bin, "agetty"), "w") as f:
            f.write('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "$ARGS_OUT"\n')
        with open(os.path.join(self.bin, "getent"), "w") as f:  # knows the user tux and nobody else
            f.write('#!/bin/sh\n[ "$1" = passwd ] && [ "$2" = tux ]\n')
        for n in ("agetty", "getent"):
            os.chmod(os.path.join(self.bin, n), 0o755)
        self.marker = os.path.join(self.dir, "account.json")
        self.root = os.path.join(self.dir, "root")

    def desktop(self, name="labwc"):
        os.makedirs(os.path.join(self.root, "usr", "bin"), exist_ok=True)
        open(os.path.join(self.root, "usr", "bin", name), "w").close()

    def run_login(self, tty, term="vt220", marker=None):
        if marker is not None:
            with open(self.marker, "w") as f:
                f.write(marker if isinstance(marker, str) else json.dumps(marker))
        env = {"PATH": self.bin + ":" + os.environ["PATH"], "TUX_AGETTY": os.path.join(self.bin, "agetty"),
               "TUX_ACCOUNT_MARKER": self.marker, "TUX_LOGIN_ROOT": self.root, "ARGS_OUT": self.args}
        if term:
            env["TERM"] = term
        r = subprocess.run(["sh", LOGIN, tty], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.args) as f:
            return f.read().split("\n")[:-1]

    SERIAL = ["--noreset", "--noclear", "--keep-baud", "115200,57600,38400,9600"]
    VT = ["--noreset", "--noclear"]

    def test_no_marker_serial_is_root(self):
        self.assertEqual(self.run_login("ttyAMA0"), self.SERIAL + ["--autologin", "root", "ttyAMA0", "vt220"])

    def test_no_marker_serial_is_root_even_with_a_desktop(self):
        self.desktop()
        self.assertEqual(self.run_login("ttyAMA0"), self.SERIAL + ["--autologin", "root", "ttyAMA0", "vt220"])

    def test_no_marker_tty1_without_a_desktop_is_root(self):
        self.assertEqual(self.run_login("tty1", "linux"), self.VT + ["--autologin", "root", "tty1", "linux"])

    def test_no_marker_tty1_with_a_desktop_is_the_stock_command(self):
        for name in ("labwc", "plasmashell", "xfce4-session"):
            shutil.rmtree(self.root, ignore_errors=True)
            self.desktop(name)
            self.assertEqual(self.run_login("tty1", "linux"), self.VT + ["tty1", "linux"], name)

    def test_marker_with_autologin_signs_in_as_the_account(self):
        m = {"configured": True, "name": "tux", "autologin": True, "sudo": True}
        self.assertEqual(self.run_login("ttyAMA0", marker=m), self.SERIAL + ["--autologin", "tux", "ttyAMA0", "vt220"])
        self.assertEqual(self.run_login("tty1", "linux"), self.VT + ["--autologin", "tux", "tty1", "linux"])

    def test_marker_that_is_pretty_printed(self):
        m = json.dumps({"configured": True, "name": "tux", "autologin": True, "sudo": False}, indent=2)
        self.assertEqual(self.run_login("ttyAMA0", marker=m)[-3:], ["tux", "ttyAMA0", "vt220"])
        self.assertIn("--autologin", self.run_login("ttyAMA0", marker='{"autologin":true,"name":"tux"}'))

    def test_marker_without_autologin_is_a_prompt(self):
        m = {"configured": True, "name": "tux", "autologin": False, "sudo": True}
        self.assertEqual(self.run_login("ttyAMA0", marker=m), self.SERIAL + ["ttyAMA0", "vt220"])
        self.assertEqual(self.run_login("tty1", "linux"), self.VT + ["tty1", "linux"])

    def test_marker_with_a_desktop_still_follows_the_marker(self):
        self.desktop()
        m = {"configured": True, "name": "tux", "autologin": True}
        self.assertEqual(self.run_login("tty1", "linux", marker=m), self.VT + ["--autologin", "tux", "tty1", "linux"])

    def test_the_account_must_exist(self):
        m = {"configured": True, "name": "gone", "autologin": True}
        self.assertNotIn("--autologin", self.run_login("ttyAMA0", marker=m))

    def test_a_marker_that_is_garbage_is_a_prompt(self):
        for text in ("", "not json", "{", '{"autologin": "true", "name": "tux"}', '{"autologin": true}',
                     '{"autologin": true, "name": "Tux; reboot"}', '{"autologin": true, "name": ""}',
                     '{"autologin": true, "name": "' + "a" * 33 + '"}'):
            self.assertNotIn("--autologin", self.run_login("ttyAMA0", marker=text), text)

    def test_no_term(self):
        # Some sh (macOS) set TERM themselves
        if subprocess.run(["sh", "-c", "echo ${TERM-unset}"], env={}, capture_output=True, text=True).stdout.strip() != "unset":
            self.skipTest("this sh sets TERM itself")
        self.assertEqual(self.run_login("ttyAMA0", term=None), self.SERIAL + ["--autologin", "root", "ttyAMA0"])

    def test_the_options_are_those_of_the_stock_units(self):
        # The option text of Debian's units (systemd 257): serial has --keep-baud, getty has --noreset and --noclear
        self.assertEqual(self.SERIAL[:2], self.VT)
        self.assertIn("--keep-baud", self.SERIAL)

    def test_no_login_options_so_agetty_keeps_its_f_for_the_autologin(self):
        # found in a guest: -o '-- \\u' makes login ask root for a password
        for tty in ("ttyAMA0", "tty1"):
            self.assertNotIn("-o", self.run_login(tty, "linux", marker=None))
            self.assertNotIn("--login-options", self.run_login(tty, "linux", marker=None))


class Report(unittest.TestCase):
    """tux-additions-report is a copy of the media's tux_additions_caps.py (the media's tests cover its caps)."""

    def setUp(self):
        loader = importlib.machinery.SourceFileLoader("tux_additions_report", REPORT)
        spec = importlib.util.spec_from_loader("tux_additions_report", loader)
        self.m = importlib.util.module_from_spec(spec)
        loader.exec_module(self.m)
        self.root = real(tempfile.mkdtemp(prefix="report-"))
        self.addCleanup(shutil.rmtree, self.root, True)

    def put(self, path, text):
        p = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    def test_it_is_the_copy_of_the_media_file(self):
        media = os.path.join(HERE, "additions", "tux_additions_caps.py")
        if not os.path.exists(media):
            self.skipTest("no tools/linux/additions/tux_additions_caps.py")
        with open(media, "rb") as a, open(REPORT, "rb") as b:
            self.assertEqual(a.read(), b.read(), "copy tools/linux/additions/tux_additions_caps.py to tux-guest again")

    def test_account_caps_agree_with_the_console_login(self):
        self.put("etc/passwd", "root:x:0:0::/root:/bin/bash\ntux:x:1000:1000::/home/tux:/bin/bash\n")
        self.put("etc/group", "sudo:x:27:tux\n")
        self.put("etc/shadow", "root:*:1:::::\ntux:$6$x:1:::::\n")
        a = self.m.account_caps(self.root)
        self.assertEqual((a["configured"], a["autologin"]), (False, "root"))
        for marker, want in (({"configured": True, "name": "tux", "autologin": True, "sudo": True}, "user"),
                             ({"configured": True, "name": "tux", "autologin": False, "sudo": True}, "none")):
            self.put("var/lib/tux/account.json", json.dumps(marker))
            a = self.m.account_caps(self.root)
            self.assertEqual(a, {"name": "tux", "uid": 1000, "exists": True, "password_set": True, "configured": True,
                                 "sudo": True, "autologin": want})

    def run_report(self, env, *args):
        return subprocess.run([sys.executable, REPORT, *args], env=dict(os.environ, **env), capture_output=True,
                              text=True, timeout=120)

    def test_post_sends_a_report_event(self):
        host = Host()
        self.addCleanup(host.close)
        r = self.run_report(host.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        (path, ev), = host.events
        self.assertEqual(path, "/.tux/additions")
        self.assertEqual(ev["t"], "report")
        self.assertEqual((ev["protocol"], type(ev["n"]), type(ev["agent"])), (1, int, str))
        self.assertEqual(sorted(ev["caps"]), sorted(["installed", "legacy", "account", "root", "network", "desktop", "desktops", "ssh",
                                                     "apps", "hostname", "disk_free_mb", "image", "ips", "kernel"]))
        self.assertEqual(sorted(ev["caps"]["installed"]), ["tux-codec-dkms", "tux-ffmpeg", "tux-guest", "tux-va"])

    def test_the_app_out_of_reach_is_only_logged(self):
        r = self.run_report({"TUX_ADDITIONS_HOST": "127.0.0.1", "TUX_ADDITIONS_PORT": "1"})
        self.assertEqual(r.returncode, 0)
        self.assertIn("not sent", r.stderr)

    def test_print_sends_nothing(self):
        host = Host()
        self.addCleanup(host.close)
        r = self.run_report(host.env, "--print")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("account", json.loads(r.stdout))
        self.assertEqual(host.events, [])


class StatusReport(unittest.TestCase):
    """tux-status asks for the report once the app answers, and gives up on a device that has no Additions."""

    def load(self, answers):
        loader = importlib.machinery.SourceFileLoader("tux_status", os.path.join(LIB, "tux-status"))
        spec = importlib.util.spec_from_loader("tux_status", loader)
        m = importlib.util.module_from_spec(spec)
        loader.exec_module(m)
        m.ran, m.asked, m.slept = [], [], []
        answers = list(answers)

        def get(path, timeout):
            m.asked.append(path)
            a = answers.pop(0)
            if isinstance(a, Exception):
                raise a
            return a, 0, ""
        m.get = get
        m.time.sleep = m.slept.append
        m.subprocess.run = lambda cmd, **kw: m.ran.append(cmd)
        return m

    def test_runs_the_report_when_the_app_answers(self):
        m = self.load([200])
        m.send_report()
        self.assertEqual(m.ran, [["/usr/lib/tux/tux-additions-report"]])
        self.assertEqual(m.asked, ["/.tux/additions"])

    def test_waits_for_the_link(self):
        m = self.load([OSError("no route"), 503, 200])
        m.send_report()
        self.assertEqual(len(m.ran), 1)
        self.assertEqual(m.slept, [5, 5])

    def test_a_device_with_no_additions_is_left_alone(self):
        m = self.load([404])
        m.send_report()
        self.assertEqual((m.ran, m.slept), ([], []))

    def test_gives_up_after_two_minutes(self):
        m = self.load([OSError("down")] * 24)
        m.send_report()
        self.assertEqual((m.ran, len(m.slept)), ([], 24))


class Files(unittest.TestCase):
    def test_agent_unit(self):
        with open(os.path.join(UNIT_DIR, "tux-additions-agent@.service")) as f:
            text = f.read()
        for want in ("Type=simple", "User=root", "ExecStart=/usr/lib/tux/tux-additions-launch %i",
                     "KillMode=control-group", "Restart=no"):
            self.assertIn(want, text.split("\n"))
        self.assertNotIn("[Install]", text.split("\n"))  # started by tux-files only, never enabled
        self.assertNotIn("ProtectSystem", [line.split("=")[0] for line in text.split("\n")])

    def test_dropins_clear_then_run_the_wrapper(self):
        for rel in ("serial-getty@ttyAMA0.service.d/tux-login.conf", "getty@tty1.service.d/10-tux-login.conf"):
            with open(os.path.join(UNIT_DIR, rel)) as f:
                lines = [x for x in f.read().split("\n") if x and not x.startswith("#")]
            self.assertEqual(lines, ["[Service]", "ExecStart=", "ExecStart=-/usr/lib/tux/tux-console-login %I"])

    def test_tty1_dropin_sorts_before_the_desktop_images_own(self):
        own = os.path.join(HERE, "rootfs-desktop", "etc", "systemd", "system", "getty@tty1.service.d")
        ours = os.path.join(UNIT_DIR, "getty@tty1.service.d")
        names = os.listdir(own) + os.listdir(ours)
        self.assertEqual(sorted(names)[-1], "autologin.conf")

    def test_serial_dropin_sorts_after_the_console_images_own(self):
        own = os.path.join(HERE, "rootfs", "etc", "systemd", "system", "serial-getty@ttyAMA0.service.d")
        ours = os.path.join(UNIT_DIR, "serial-getty@ttyAMA0.service.d")
        # an image with no drop-in of its own (the new images) has nothing to sort against
        names = (os.listdir(own) if os.path.isdir(own) else []) + os.listdir(ours)
        self.assertEqual(sorted(names)[-1], "tux-login.conf")

    def test_control_and_conffiles(self):
        pkg = os.path.join(HERE, "tux-guest", "DEBIAN")
        with open(os.path.join(pkg, "control")) as f:
            self.assertIn("Version: 1.11.0\n", f.read())
        with open(os.path.join(pkg, "conffiles")) as f:
            self.assertIn("/etc/apt/apt.conf.d/50tux-additions", f.read().split("\n"))
        self.assertTrue(os.path.isfile(os.path.join(HERE, "tux-guest", "etc", "apt", "apt.conf.d", "50tux-additions")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
