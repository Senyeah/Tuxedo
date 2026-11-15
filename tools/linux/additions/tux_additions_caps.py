#!/usr/bin/python3
"""What the guest has (the caps of a report) and the report script of Tuxedo Additions.
The agent on the media imports this file. tux-guest keeps a copy as /usr/lib/tux/tux-additions-report,
which tux-status (at boot) and the dpkg hook (after each dpkg run) start.
  tux-additions-report [--print] [--n N]
With --print it shows the caps and sends nothing. Python 3 standard library only. Contract: docs/guest-additions-design.md 5.3, 5.4."""
import codecs
import http.client
import json
import os
import re
import select
import socket
import subprocess
import sys
import threading
import time
from collections import namedtuple

PROTOCOL = 1
EVENT_MAX = 64 * 1024
PATH = "/.tux/additions"
PKG_STATE = "/var/lib/tux/additions"
LAST_REPORT = "/var/lib/tux/additions.json"
ACCOUNT_MARKER = "/var/lib/tux/account.json"
TUX_PACKAGES = ("tux-guest", "tux-va", "tux-ffmpeg", "tux-codec-dkms")
DESKTOP_PACKAGES = (("labwc", "labwc"), ("plasma", "plasma-workspace"), ("xfce", "xfce4-session"))
SSH_CONF = "/etc/ssh/sshd_config.d/10-tux.conf"
MARKER_NAME_RE = re.compile(r"[a-z_][a-z0-9_-]{0,31}\Z")  # the name that tux-console-login accepts

Result = namedtuple("Result", "rc out")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def host_path(root, path):
    return path if root in ("", "/") else os.path.join(root, path.lstrip("/"))


def read_text(root, path):
    try:
        with open(host_path(root, path), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


class Runner:
    """The one place that starts programs. Tests give the agent another object with the same run()."""

    PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    def run(self, argv, input=None, timeout=None, env=None, on_output=None):
        e = dict(os.environ, PATH=self.PATH, LC_ALL="C", **(env or {}))
        try:
            p = subprocess.Popen(argv, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e)
        except OSError as err:
            return Result(127, "%s: %s\n" % (argv[0], err.strerror))
        if input is not None:
            try:
                p.stdin.write(input.encode())
                p.stdin.close()
            except OSError:
                pass
        dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
        out = []
        fd = p.stdout.fileno()
        deadline = time.monotonic() + timeout if timeout else None

        def take(block):
            if not select.select([fd], [], [], block)[0]:
                return None
            b = os.read(fd, 4096)
            if not b:
                return False
            t = dec.decode(b)
            out.append(t)
            if on_output and t:
                on_output(t)
            return True

        while True:
            got = take(1.0)
            if got is False:
                break
            if got is None and p.poll() is not None:
                while take(0):
                    pass
                break
            if deadline and time.monotonic() > deadline:
                p.kill()
                out.append("\n[timeout]\n")
                break
        rc = p.wait()
        p.stdout.close()
        tail = dec.decode(b"", final=True)
        if tail:
            out.append(tail)
        return Result(rc, "".join(out))


def parse_passwd(text):
    """{name: {"uid": int, "gid": int, "home": str, "shell": str}} from the text of /etc/passwd."""
    users = {}
    for line in (text or "").splitlines():
        f = line.split(":")
        if len(f) >= 6 and f[2].isdigit() and f[3].isdigit():
            users[f[0]] = {"uid": int(f[2]), "gid": int(f[3]), "home": f[5], "shell": f[6] if len(f) > 6 else ""}
    return users


def parse_group(text):
    """{group: set of member names} from the text of /etc/group."""
    groups = {}
    for line in (text or "").splitlines():
        f = line.split(":")
        if len(f) >= 4:
            groups[f[0]] = {m for m in f[3].split(",") if m}
    return groups


def shadow_hash(text, name):
    for line in (text or "").splitlines():
        f = line.split(":")
        if f and f[0] == name and len(f) > 1:
            return f[1]
    return None


def password_is_set(field):
    """A hash counts, locked or not. An empty field, "*", "!" and "!!" do not."""
    return bool(field) and field not in ("*", "!", "!!", "!*")


def installed_packages(runner):
    """{package: version} for each package that dpkg has fully installed."""
    r = runner.run(["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${binary:Package}\t${Version}\n"], timeout=60)
    pk = {}
    for line in r.out.splitlines():
        f = line.split("\t")
        if len(f) == 3 and len(f[0]) >= 2 and f[0][1] == "i":
            pk[f[1].split(":")[0]] = f[2]
    return pk


def parse_sshd_config(texts):
    """The first value of each keyword wins, as in sshd. Texts come in this order: the drop-ins, then sshd_config."""
    out = {}
    for text in texts:
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            kw, _, val = line.partition(" ")
            kw = kw.lower()
            if kw == "include":
                continue
            out.setdefault(kw, val.strip())
    return out


def ssh_caps(runner, root, pk):
    caps = {"installed": "openssh-server" in pk, "enabled": False, "port": 22, "password_auth": True}
    texts = []
    d = host_path(root, "/etc/ssh/sshd_config.d")
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".conf"))
    except OSError:
        names = []
    for n in names:
        t = read_text(root, "/etc/ssh/sshd_config.d/" + n)
        if t:
            texts.append(t)
    main = read_text(root, "/etc/ssh/sshd_config")
    if main:
        texts.append(main)
    cfg = parse_sshd_config(texts)
    port = cfg.get("port", "22").split()[0]
    caps["port"] = int(port) if port.isdigit() and 0 < int(port) < 65536 else 22
    caps["password_auth"] = cfg.get("passwordauthentication", "yes").lower() != "no"
    if caps["installed"]:
        r = runner.run(["systemctl", "is-enabled", "ssh.service"], timeout=15)
        caps["enabled"] = r.rc == 0 and r.out.strip() in ("enabled", "enabled-runtime")
    return caps


def apt_mirrors(root):
    """(host, port) of each http or https source in /etc/apt/sources.list*, in file order. Disabled stanzas are skipped."""
    files = ["/etc/apt/sources.list"]
    d = host_path(root, "/etc/apt/sources.list.d")
    try:
        files += ["/etc/apt/sources.list.d/" + n for n in sorted(os.listdir(d)) if n.endswith((".list", ".sources"))]
    except OSError:
        pass
    uris = []
    for f in files:
        text = read_text(root, f)
        if text is None:
            continue
        if f.endswith(".sources"):
            for stanza in re.split(r"\n\s*\n", text):
                fields = {}
                for line in stanza.splitlines():
                    k, _, v = line.partition(":")
                    if not line.startswith((" ", "\t", "#")) and v:
                        fields[k.strip().lower()] = v.strip()
                if fields.get("enabled", "yes").lower() in ("no", "false", "0"):
                    continue
                if "deb" in fields.get("types", "").split():
                    uris += fields.get("uris", "").split()
        else:
            for line in text.splitlines():
                m = re.match(r"\s*deb\s+(?:\[[^\]]*\]\s+)?(\S+)", line)
                if m:
                    uris.append(m.group(1))
    seen, out = set(), []
    for u in uris:
        m = re.match(r"(https?)://(?:[^@/]*@)?(\[[^\]]+\]|[^:/]+)(?::(\d+))?", u)
        if not m:
            continue
        hp = (m.group(2).strip("[]"), int(m.group(3) or (443 if m.group(1) == "https" else 80)))
        if hp not in seen:
            seen.add(hp)
            out.append(hp)
    return out


def resolve(host, port, timeout):
    """Addresses of host. getaddrinfo has no timeout, so a thread does it and we stop waiting after timeout."""
    try:
        socket.inet_pton(socket.AF_INET6 if ":" in host else socket.AF_INET, host)
        return [host]
    except OSError:
        pass
    found = []

    def go():
        try:
            found.extend(a[4][0] for a in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM))
        except OSError:
            pass

    t = threading.Thread(target=go, daemon=True)
    t.start()
    t.join(max(timeout, 0))
    return [] if t.is_alive() else found


def tcp_connect(host, port, timeout):
    """True when a TCP connection opens. The name lookup and the tries all stay inside timeout (seconds)."""
    end = time.monotonic() + timeout
    for addr in resolve(host, port, timeout):
        left = end - time.monotonic()
        if left <= 0:
            return False
        try:
            socket.create_connection((addr, port), timeout=left).close()
            return True
        except OSError:
            continue
    return False


def have_network(root="/", connect=tcp_connect, budget=3.0):
    """True when a TCP connection to an apt mirror opens within the budget (seconds, all tries together)."""
    end = time.monotonic() + budget
    for host, port in apt_mirrors(root)[:4]:
        left = end - time.monotonic()
        if left <= 0:
            break
        if connect(host, port, left):
            return True
    return False


def fib_trie_ips(text):
    """IPv4 addresses of this host from the text of /proc/net/fib_trie (the Local table), with no loopback or link-local."""
    ips, seen, last, local = [], set(), None, False
    for line in text.splitlines():
        if not line.startswith(" "):
            local = line.startswith("Local")
            continue
        if not local:
            continue
        m = re.match(r"\s*\|-- (\d+\.\d+\.\d+\.\d+)\s*$", line)
        if m:
            last = m.group(1)
        elif last and re.match(r"\s*/32 host LOCAL", line):
            if not last.startswith(("127.", "169.254.")) and last not in seen:
                seen.add(last)
                ips.append(last)
            last = None
    return ips


def global_ips(runner, root="/"):
    """The global IPv4 addresses. The kernel's table gives them with no program; ip is the fallback."""
    text = read_text(root, "/proc/net/fib_trie")
    if text is not None:
        return fib_trie_ips(text)
    r = runner.run(["ip", "-4", "-o", "addr", "show", "scope", "global"], timeout=10)
    return [m for m in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)/", r.out)] if r.rc == 0 else []


def load_catalogue(path):
    try:
        with open(path, encoding="utf-8") as f:
            c = json.load(f)
        return c if isinstance(c, dict) else None
    except (OSError, ValueError):
        return None


def default_catalogue_path(root="/"):
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "actions.json")
    if os.path.exists(here):
        return here
    return host_path(root, PKG_STATE + "/current/actions.json")


def account_caps(root):
    passwd = parse_passwd(read_text(root, "/etc/passwd"))
    groups = parse_group(read_text(root, "/etc/group"))
    marker_text = read_text(root, ACCOUNT_MARKER)
    marker = None
    if marker_text is not None:
        try:
            marker = json.loads(marker_text)
        except ValueError:
            marker = {}
        if not isinstance(marker, dict):
            marker = {}
    first = next((n for n, u in sorted(passwd.items()) if u["uid"] == 1000), None)
    name = marker.get("name") if marker and isinstance(marker.get("name"), str) else None
    name = name or first or "tux"
    exists = name in passwd
    if marker is None:
        autologin = "root"
    else:  # as tux-console-login: a literal true, and a name that exists
        who = marker.get("name")
        ok = marker.get("autologin") is True and isinstance(who, str) and MARKER_NAME_RE.match(who) and who in passwd
        autologin = "user" if ok else "none"
    return {
        "name": name,
        "uid": passwd[name]["uid"] if exists else 1000,
        "exists": exists,
        "password_set": password_is_set(shadow_hash(read_text(root, "/etc/shadow"), name)) if exists else False,
        "configured": marker is not None,
        "sudo": exists and name in groups.get("sudo", set()),
        "autologin": autologin,
    }


def desktops_of(pk):
    return [d for d, p in DESKTOP_PACKAGES if p in pk]


def desktop_of(pk, root="/"):
    """The desktop the machine starts: the one /etc/tux/session names when it is installed, else the first."""
    have = desktops_of(pk)
    if not have:
        return "none"
    session = (read_text(root, "/etc/tux/session") or "").strip()
    return session if session in have else have[0]


def build_caps(runner=None, root="/", catalogue=None, connect=tcp_connect):
    """The caps object of design 5.4. root, catalogue (a dict) and connect are test hooks."""
    runner = runner or Runner()
    pk = installed_packages(runner)
    if catalogue is None:
        catalogue = load_catalogue(default_catalogue_path(root)) or {}
    apps = {}
    for a in catalogue.get("apps", []):
        if isinstance(a.get("id"), str) and a.get("packages"):
            apps[a["id"]] = all(p in pk for p in a["packages"])
    desktop = desktop_of(pk, root)
    try:
        st = os.statvfs(host_path(root, "/"))
        free = st.f_bavail * st.f_frsize // 1000000
    except OSError:
        free = 0
    host = (read_text(root, "/etc/hostname") or "").strip() or socket.gethostname()
    return {
        "installed": {p: pk.get(p) for p in TUX_PACKAGES},
        "legacy": any(p.startswith("henge-") for p in pk),
        "account": account_caps(root),
        "root": os.geteuid() == 0,
        "network": have_network(root, connect),
        "desktop": desktop,
        "desktops": desktops_of(pk),
        "ssh": ssh_caps(runner, root, pk),
        "apps": apps,
        "hostname": host,
        "disk_free_mb": free,
        "image": "console" if desktop == "none" else "desktop",
        "ips": global_ips(runner, root),
        "kernel": os.uname().release,
    }


def agent_version(root="/"):
    """The additions version of the last media that ran here; "0" when none did."""
    try:
        with open(host_path(root, PKG_STATE + "/current/versions.json"), encoding="utf-8") as f:
            v = json.load(f).get("additions")
        return v if isinstance(v, str) and v else "0"
    except (OSError, ValueError, AttributeError):
        return "0"


def current_n(root="/"):
    try:
        n = json.loads(read_text(root, "/run/tux/files.json") or "{}").get("additions_n", 0)
        return n if isinstance(n, int) and n >= 0 else 0
    except (ValueError, AttributeError):
        return 0


def report_event(n, agent, caps):
    return {"t": "report", "n": n, "agent": agent, "protocol": PROTOCOL, "caps": caps}


def link_endpoint():
    """The host link. The two variables are test hooks."""
    return os.environ.get("TUX_ADDITIONS_HOST", "10.0.2.4"), int(os.environ.get("TUX_ADDITIONS_PORT", "80"))


def post_event(event, timeout=10):
    """POST one event to the host. Returns the sequence number the host gives. Raises OSError, ValueError or RuntimeError."""
    body = json.dumps(event, separators=(",", ":"), ensure_ascii=False).encode()
    if len(body) > EVENT_MAX:
        raise ValueError("event is %d bytes" % len(body))
    host, port = link_endpoint()
    c = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        c.request("POST", PATH, body, {"Content-Type": "application/json"})
        r = c.getresponse()
        data = r.read()
        if r.status != 200:
            raise RuntimeError("host answered %d" % r.status)
        return json.loads(data).get("seq")
    finally:
        c.close()


def save_last_report(event, root="/"):
    """/var/lib/tux/additions.json: the last report. It holds no job and no password."""
    path = host_path(root, LAST_REPORT)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(event, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    show = "--print" in argv
    n = None
    if "--n" in argv:
        try:
            n = int(argv[argv.index("--n") + 1])
        except (IndexError, ValueError):
            print("usage: tux-additions-report [--print] [--n N]", file=sys.stderr)
            return 2
    caps = build_caps()
    if show:
        print(json.dumps(caps, indent=2, sort_keys=True))
        return 0
    event = report_event(current_n() if n is None else n, agent_version(), caps)
    try:
        save_last_report(event)
    except OSError as e:
        log("tux-additions-report: cannot save the report: %s" % e)
    try:
        post_event(event)
    except (OSError, ValueError, RuntimeError) as e:
        log("tux-additions-report: report not sent: %s" % e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
