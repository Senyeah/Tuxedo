#!/usr/bin/env -S uv run
# SPDX-License-Identifier: GPL-2.0-or-later
# /// script
# requires-python = ">=3.9"
# ///
"""Tests the Tuxedo Additions part of tux-files (docs/guest-additions-design.md, section 6) with no guest.

The script is loaded as a module. systemctl and the app's link are replaced, and the state file is in a temp
directory. Run: uv run tools/linux/test_tux_files_additions.py
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "tux-guest", "usr", "lib", "tux", "tux-files")


def load(tmp):
    """A fresh copy of the module, as a new start of the service would have, with the state in tmp."""
    loader = importlib.machinery.SourceFileLoader("tux_files", SCRIPT)
    spec = importlib.util.spec_from_loader("tux_files", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    m.STATE = os.path.join(tmp, "files.json")
    m.LOCK = os.path.join(tmp, "files.lock")
    m.BUSY = os.path.join(tmp, "additions-busy")
    m.calls = []
    m.sh = lambda *cmd: (m.calls.append(cmd), (0, ""))[1]
    m.log = lambda *a: None
    return m


def folder(name="tux-additions", n=1, **extra):
    f = {"id": "id-" + name, "name": name, "mode": "ro", "state": "ready", "index": 8, "kind": "additions", "n": n}
    f.update(extra)
    return f


def user_folder(name="docs"):
    return {"id": "id-" + name, "name": name, "mode": "rw", "state": "ready", "index": 0}


STOP = ("systemctl", "stop", "tux-additions-agent@*")


def start(n):
    return ("systemctl", "start", "--no-block", f"tux-additions-agent@{n}.service")


class Additions(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.m = load(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def mounted(self, *names):
        """The state reconcile leaves for folders that are mounted."""
        self.m.write_state({n: {"id": "id-" + n, "key": "k", "mode": "ro"} for n in names}, self.m.additions_n())

    def state_file(self):
        with open(self.m.STATE) as f:
            return json.load(f)

    def test_new_n_stops_old_and_starts_without_blocking(self):
        self.mounted("tux-additions")
        self.m.do_additions({"folders": [folder(n=3)]})
        self.assertEqual(self.m.calls, [STOP, start(3)])
        self.assertEqual(self.m.additions_n(), 3)

    def test_same_n_does_not_run_again(self):
        self.mounted("tux-additions")
        t = {"folders": [folder(n=3)]}
        self.m.do_additions(t)
        self.m.calls.clear()
        self.m.do_additions(t)
        self.assertEqual(self.m.calls, [])

    def test_restart_of_the_helper_does_not_run_the_same_n(self):
        self.mounted("tux-additions")
        t = {"folders": [folder(n=3)]}
        self.m.do_additions(t)
        again = load(self.dir.name)  # new process, same /run/tux/files.json
        again.do_additions(t)
        self.assertEqual(again.calls, [])

    def test_next_n_runs_again(self):
        self.mounted("tux-additions")
        self.m.do_additions({"folders": [folder(n=1)]})
        self.m.calls.clear()
        self.m.do_additions({"folders": [folder(n=2)]})
        self.assertEqual(self.m.calls, [STOP, start(2)])

    def test_waits_until_the_entry_is_mounted(self):
        t = {"folders": [folder(n=1)]}
        self.m.do_additions(t)  # not in the state yet
        self.assertEqual(self.m.calls, [])
        self.assertIsNone(self.m.additions_n())
        self.mounted("tux-additions")
        self.m.do_additions(t)
        self.assertEqual(self.m.calls, [STOP, start(1)])

    def test_bad_n_is_ignored(self):
        self.mounted("tux-additions")
        for n in (0, -1, "2", None, True, 1.5):
            self.m.do_additions({"folders": [folder(n=n)]})
        self.assertEqual(self.m.calls, [])

    def test_other_folders_are_ignored(self):
        self.mounted("docs")
        self.m.do_additions({"folders": [user_folder()]})
        self.assertEqual(self.m.calls, [])

    def test_media_gone_with_no_job_stops_the_agent(self):
        self.mounted("tux-additions")
        self.m.do_additions({"folders": [folder(n=4)]})
        self.m.calls.clear()
        self.m.job_running = lambda: False
        self.m.do_additions({"folders": []})
        self.assertEqual(self.m.calls, [STOP])
        self.assertIsNone(self.m.additions_n())
        self.m.calls.clear()
        self.m.do_additions({"folders": []})  # nothing is left to stop
        self.assertEqual(self.m.calls, [])

    def test_media_gone_with_a_job_keeps_the_agent(self):
        self.mounted("tux-additions")
        self.m.do_additions({"folders": [folder(n=4)]})
        self.m.calls.clear()
        self.m.job_running = lambda: True
        self.m.do_additions({"folders": []})
        self.assertEqual(self.m.calls, [])
        self.assertEqual(self.m.additions_n(), 4)  # tried again at the next pass
        self.m.job_running = lambda: False
        self.m.do_additions({"folders": []})
        self.assertEqual(self.m.calls, [STOP])

    def test_media_gone_with_the_app_out_of_reach_keeps_the_agent(self):
        self.mounted("tux-additions")
        self.m.do_additions({"folders": [folder(n=4)]})
        self.m.calls.clear()
        self.m.job_running = lambda: None
        self.m.do_additions({"folders": []})
        self.assertEqual(self.m.calls, [])
        self.assertEqual(self.m.additions_n(), 4)

    def test_a_failed_start_does_not_stop_the_helper(self):
        self.mounted("tux-additions")

        def sh(*cmd):
            self.m.calls.append(cmd)
            raise FileNotFoundError("systemctl")
        self.m.sh = sh
        self.m.do_additions({"folders": [folder(n=1)]})
        self.assertEqual(self.m.additions_n(), 1)  # and not run again: the app nudges for another go


class Busy(unittest.TestCase):
    """The agent holds /run/tux/additions-busy while a job runs: a new n must not stop it."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.m = load(self.dir.name)
        # a live process whose command line has "agent", as the real agent's has
        self.proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "agent"])
        self.addCleanup(self.proc.wait)
        self.addCleanup(self.proc.kill)
        self.m.write_state({"tux-additions": {"id": "id-tux-additions", "key": "k", "mode": "ro"}}, None)

    def tearDown(self):
        self.dir.cleanup()

    def busy(self, pid=None, text=None):
        with open(self.m.BUSY, "w") as f:
            f.write(text if text is not None else json.dumps({"pid": pid or self.proc.pid, "job": "j-1"}))

    def free(self):
        os.unlink(self.m.BUSY)

    def table(self, n):
        return {"folders": [folder(n=n)]}

    def started(self, n):
        self.m.do_additions(self.table(n))
        self.m.calls.clear()

    def test_a_new_n_does_not_stop_a_running_job(self):
        self.started(1)
        self.busy()
        self.assertIs(self.m.do_additions(self.table(2)), True)
        self.assertEqual(self.m.calls, [])
        self.assertEqual((self.m.additions_n(), self.m.additions_pending()), (1, 2))

    def test_the_waiting_n_starts_when_the_file_goes(self):
        self.started(1)
        self.busy()
        self.m.do_additions(self.table(2))
        self.free()
        self.assertIs(self.m.do_additions(self.table(2)), False)
        self.assertEqual(self.m.calls, [STOP, start(2)])
        self.assertEqual((self.m.additions_n(), self.m.additions_pending()), (2, None))
        self.m.calls.clear()
        self.m.do_additions(self.table(2))
        self.assertEqual(self.m.calls, [])

    def test_a_restart_of_the_helper_keeps_the_waiting_n(self):
        self.started(1)
        self.busy()
        self.m.do_additions(self.table(2))
        again = load(self.dir.name)
        self.assertIs(again.do_additions(self.table(2)), True)
        self.assertEqual(again.calls, [])
        self.assertEqual(again.additions_pending(), 2)
        self.free()
        again.do_additions(self.table(2))
        self.assertEqual(again.calls, [STOP, start(2)])

    def test_a_newer_n_replaces_the_waiting_one(self):
        self.started(1)
        self.busy()
        self.m.do_additions(self.table(2))
        self.m.do_additions(self.table(3))
        self.assertEqual(self.m.additions_pending(), 3)
        self.free()
        self.m.do_additions(self.table(3))
        self.assertEqual(self.m.calls, [STOP, start(3)])

    def test_the_same_n_again_clears_the_wait(self):
        self.started(1)
        self.busy()
        self.m.do_additions(self.table(2))
        self.assertIs(self.m.do_additions(self.table(1)), False)
        self.assertIsNone(self.m.additions_pending())
        self.free()
        self.m.do_additions(self.table(1))
        self.assertEqual(self.m.calls, [])

    def test_a_file_that_names_a_dead_process_does_not_hold_the_agent(self):
        self.started(1)
        done = subprocess.Popen([sys.executable, "-c", "pass"])
        done.wait()
        self.busy(pid=done.pid)
        self.assertIs(self.m.do_additions(self.table(2)), False)
        self.assertEqual(self.m.calls, [STOP, start(2)])

    def test_a_file_that_is_garbage_does_not_hold_the_agent(self):
        for text in ("", "not json", "[1]", "{}", '{"pid": "7"}', '{"pid": 0}', '{"pid": 1.5}', '{"pid": true}'):
            self.setUp()
            self.started(1)
            self.busy(text=text)
            self.assertIs(self.m.do_additions(self.table(2)), False, text)
            self.assertEqual(self.m.calls, [STOP, start(2)], text)

    def test_no_file_is_not_busy(self):
        self.assertFalse(self.m.agent_busy())

    @unittest.skipUnless(os.path.isdir("/proc/self"), "no /proc here: the pid check cannot tell")
    def test_a_pid_that_is_not_an_agent_any_more_does_not_hold_the_agent(self):
        other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        self.busy(pid=other.pid)
        self.assertFalse(self.m.agent_busy())

    def test_media_gone_while_busy_keeps_the_agent_and_drops_the_wait(self):
        self.started(1)
        self.busy()
        self.m.do_additions(self.table(2))
        self.m.job_running = lambda: False  # the agent's job is no longer in the host's "job" (the agent took it)
        self.assertIs(self.m.do_additions({"folders": []}), False)
        self.assertEqual(self.m.calls, [])
        self.assertEqual((self.m.additions_n(), self.m.additions_pending()), (1, None))
        self.free()
        self.m.do_additions({"folders": []})
        self.assertEqual(self.m.calls, [STOP])

    def test_state_helpers_keep_the_pending_n_and_hide_it_from_the_folders(self):
        self.m.write_state({}, 1, 4)
        self.m.save_state({"docs": {"id": "d", "key": "d", "mode": "rw"}})
        self.assertEqual((self.m.additions_n(), self.m.additions_pending()), (1, 4))
        self.assertEqual(list(self.m.load_state()), ["docs"])
        self.m.save_additions_n(2)
        self.assertEqual((self.m.additions_n(), self.m.additions_pending()), (2, 4))
        self.m.save_additions_n(2, None)
        self.assertIsNone(self.m.additions_pending())

    def test_a_waiting_n_shortens_the_poll(self):
        self.started(1)
        self.busy()
        self.assertTrue(self.m.do_additions(self.table(2)))  # run() polls for 10 s, not 130 s, while this is true


class State(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.m = load(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def test_additions_n_is_beside_the_folders_and_not_a_folder(self):
        self.m.write_state({"docs": {"id": "d", "key": "d", "mode": "rw"}}, 5)
        with open(self.m.STATE) as f:
            raw = json.load(f)
        self.assertEqual(raw["additions_n"], 5)
        self.assertEqual(list(self.m.load_state()), ["docs"])
        self.assertEqual(self.m.additions_n(), 5)

    def test_save_state_keeps_the_n(self):
        self.m.write_state({}, 7)
        self.m.save_state({"docs": {"id": "d", "key": "d", "mode": "rw"}})
        self.assertEqual(self.m.additions_n(), 7)

    def test_state_from_an_older_helper_has_no_n(self):
        with open(self.m.STATE, "w") as f:
            json.dump({"docs": {"id": "d", "key": "d", "mode": "rw"}}, f)
        self.assertIsNone(self.m.additions_n())
        self.assertEqual(list(self.m.load_state()), ["docs"])

    def test_bad_state_file_is_empty(self):
        for text in ("", "[1]", "{", '{"additions_n": "x"}'):
            with open(self.m.STATE, "w") as f:
                f.write(text)
            self.assertIsNone(self.m.additions_n())
            self.assertEqual(self.m.load_state(), {})

    def reconcile(self, table):
        self.m.mounts = lambda: {}
        self.m.mount_one = lambda f: None
        self.m.unmount_one = lambda name, lazy: True
        return self.m.reconcile(table)

    def test_reconcile_mounts_the_entry_like_any_folder_and_keeps_the_n(self):
        self.m.write_state({}, 9)
        self.reconcile({"folders": [folder(n=9), user_folder()]})
        self.assertEqual(sorted(self.m.load_state()), ["docs", "tux-additions"])
        self.assertEqual(self.m.additions_n(), 9)

    def test_reconcile_removes_the_entry_when_it_goes(self):
        self.reconcile({"folders": [folder(n=1)]})
        self.reconcile({"folders": []})
        self.assertEqual(self.m.load_state(), {})

    def test_a_folder_cannot_take_the_key(self):
        self.m.write_state({}, 2)
        self.reconcile({"folders": [user_folder("additions_n")]})
        self.assertEqual(self.m.load_state(), {})
        self.assertEqual(self.m.additions_n(), 2)

    def test_full_flow_through_reconcile(self):
        table = {"folders": [folder(n=1)]}
        self.reconcile(table)
        self.m.do_additions(table)
        self.assertEqual(self.m.calls, [STOP, start(1)])
        self.m.calls.clear()
        table = {"folders": [folder(n=2)]}  # a nudge
        self.reconcile(table)
        self.m.do_additions(table)
        self.assertEqual(self.m.calls, [STOP, start(2)])


class Link(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.m = load(self.dir.name)
        self.server = None
        self.real = self.m.http.client.HTTPConnection
        self.addCleanup(setattr, self.m.http.client, "HTTPConnection", self.real)

    def tearDown(self):
        self.stop()
        self.dir.cleanup()

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None

    def serve(self, status, body):
        import http.server
        import threading

        self.stop()

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(h):
                h.send_response(status)
                h.send_header("Content-Length", str(len(body)))
                h.end_headers()
                h.wfile.write(body)

            def log_message(h, *a):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        port = self.server.server_address[1]
        real = self.real
        self.m.http.client.HTTPConnection = lambda host, p, timeout: real("127.0.0.1", port, timeout=timeout)

    def test_job_running(self):
        self.serve(200, b'{"inserted":true,"n":3,"cancel":false,"cancel_job":null,"job":{"id":"j-1","steps":[]},"taken":null}')
        self.assertIs(self.m.job_running(), True)

    def test_no_job(self):
        self.serve(200, b'{"inserted":false,"n":0,"cancel":false,"cancel_job":null,"job":null,"taken":null}')
        self.assertIs(self.m.job_running(), False)
        self.serve(200, b'{"inserted":true,"n":3,"cancel":false,"cancel_job":null,"job":null,"taken":"j-1"}')
        self.assertIs(self.m.job_running(), False)

    def test_not_found_and_garbage_are_unknown(self):
        self.serve(404, b"no")
        self.assertIsNone(self.m.job_running())
        self.serve(200, b"[1]")
        self.assertIsNone(self.m.job_running())

    def test_no_server_is_unknown(self):
        real = self.real
        self.m.http.client.HTTPConnection = lambda host, p, timeout: real("127.0.0.1", 1, timeout=timeout)
        self.assertIsNone(self.m.job_running())


class Unchanged(unittest.TestCase):
    def test_usage_text_still_lists_the_commands(self):
        m = load(tempfile.gettempdir())
        usage = m.__doc__.split("\n\n", 2)[-1]
        for word in ("tux-files list", "tux-files export", "tux-files reset", "tux-files remount"):
            self.assertIn(word, usage)
        self.assertNotIn("additions", usage)


if __name__ == "__main__":
    unittest.main(verbosity=2)
