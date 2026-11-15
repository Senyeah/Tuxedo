#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Checks on a built Tuxedo Additions media (tools/linux/package-additions.sh, docs/guest-additions-design.md 4 and 9).
  test_package_additions.py [--tree DIR] [--offline] [--rebuild] [--other DIR]
--tree     the media (default: $TUX_LINUX_OUT/additions/tux-additions, as package-additions.sh puts it)
--offline  skip the check of the catalogue against the Debian package index (it needs snapshot.debian.org)
--rebuild  build the media a second time (the Debian downloads are kept, so it takes a few minutes) and compare
--other    compare with another tree: the same bytes, apart from the four signature files"""
import argparse
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
KEYRING = HERE / "tux-guest/usr/share/keyrings/tux-archive.gpg"
DEPS_MAX_BYTES = 25_000_000
SIGNED = {"InRelease", "Release.gpg", "SHA256SUMS", "SHA256SUMS.gpg"}
TOP = {"install", "agent", "tux_additions_caps.py", "actions.json", "versions.json", "install-order.txt", "README.txt",
       "desktop-labwc", "desktop-plasma", "SHA256SUMS", "SHA256SUMS.gpg", "tux-archive.gpg", "apt", "source"}
REQUIRED_APPS = ["firefox", "chromium", "libreoffice", "thunderbird", "vlc", "mpv", "gimp", "inkscape", "kate", "git",
                 "build-essential", "python3-pip", "htop", "curl", "tmux", "neovim"]
GROUPS = {"web", "office", "media", "graphics", "develop", "tools"}
PEM = [b"BEGIN PGP PRIVATE KEY", b"BEGIN PRIVATE KEY", b"BEGIN RSA PRIVATE KEY", b"BEGIN OPENSSH PRIVATE KEY",
       b"BEGIN EC PRIVATE KEY", b"private-keys-v1.d", b".tux-apt-key", b"/Users/"]
ARGS = None


def default_out():
    if os.environ.get("TUX_LINUX_OUT"):
        return Path(os.environ["TUX_LINUX_OUT"])
    common = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip()
    return Path(common).parent / "build/linux"


def env_file(name):
    for line in (HERE / "versions.env").read_text().splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    raise KeyError(name)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def files_of(tree):
    return sorted(str(p.relative_to(tree)) for p in tree.rglob("*") if p.is_file())


def ar_members(path):
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("%s is not a deb" % path)
        while True:
            head = f.read(60)
            if len(head) < 60:
                return
            name, size = head[:16].decode().strip().rstrip("/"), int(head[48:58])
            data = f.read(size)
            if size % 2:
                f.read(1)
            yield name, data


def deb_control(path):
    """The control fields of a deb as a dict, or None when its control.tar is zstd and this Python cannot read it."""
    for name, data in ar_members(path):
        if name.startswith("control.tar"):
            if name.endswith(".zst"):
                return None
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as t:
                text = t.extractfile(next(m for m in t.getmembers() if m.name.lstrip("./") == "control")).read().decode()
            out = {}
            for line in text.splitlines():
                if line and not line[0].isspace() and ":" in line:
                    k, v = line.split(":", 1)
                    out[k] = v.strip()
            return out
    raise ValueError("no control.tar in %s" % path)


def deb_data(path):
    """The data.tar of a deb as a TarFile, or None for zstd."""
    for name, data in ar_members(path):
        if name.startswith("data.tar"):
            if name.endswith(".zst"):
                return None
            return tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    raise ValueError("no data.tar in %s" % path)


def parse_packages(text):
    out = []
    for stanza in text.strip().split("\n\n"):
        d = {}
        for line in stanza.splitlines():
            if line and not line[0].isspace() and ":" in line:
                k, v = line.split(":", 1)
                d[k] = v.strip()
        if d:
            out.append(d)
    return out


def verifier(keyring, sig, data):
    """True, False, or None when neither gpgv nor sqv is installed."""
    if shutil.which("gpgv"):
        with tempfile.TemporaryDirectory() as home:
            r = subprocess.run(["gpgv", "--homedir", home, "--keyring", str(keyring), str(sig), str(data)], capture_output=True)
        return r.returncode == 0
    if shutil.which("sqv"):
        return subprocess.run(["sqv", "--keyring", str(keyring), str(sig), str(data)], capture_output=True).returncode == 0
    return None


class Media(unittest.TestCase):
    tree = None

    @classmethod
    def setUpClass(cls):
        cls.tree = Path(ARGS.tree) if ARGS.tree else default_out() / "additions/tux-additions"
        if not cls.tree.is_dir():
            raise unittest.SkipTest("no media at %s: run tools/linux/package-additions.sh" % cls.tree)
        cls.suite = env_file("DEBIAN_SUITE")
        cls.apt = cls.tree / "apt"
        cls.dists = cls.apt / "dists" / cls.suite

    def j(self, name):
        return json.loads((self.tree / name).read_text())

    def pool(self, comp):
        return sorted((self.apt / "pool" / comp).rglob("*.deb"))

    # layout and sums
    def test_layout(self):
        names = {p.name for p in self.tree.iterdir()}
        self.assertEqual(names - TOP, set(), "files the design does not name")
        self.assertEqual(TOP - names, set(), "files the design names")
        self.assertTrue(os.access(self.tree / "install", os.X_OK))
        self.assertTrue(os.access(self.tree / "agent", os.X_OK))
        self.assertTrue((self.tree / "source/SOURCES.txt").is_file())
        self.assertTrue((self.tree / "desktop-labwc/files.json").is_file())
        for p in self.tree.rglob("*"):
            self.assertNotIn(p.name, (".DS_Store", "__pycache__"), str(p))
            self.assertNotRegex(p.name, r"\s", "a file name with a space: %s" % p)
        r = subprocess.run(["sh", "-n", str(self.tree / "install")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_install_checks_a_copy_and_installs_from_the_copy(self):
        text = (self.tree / "install").read_text()
        copy, check, plain = text.index('cp -R "$HERE/." "$STATE/media/"'), text.index("gpgv --homedir"), text.index("! -type f ! -type d")
        self.assertLess(copy, plain)
        self.assertLess(plain, check)
        self.assertLess(copy, text.index("sha256sum -c --strict"))
        rest = text[copy + 1:]
        for bad in ('$HERE/apt', '$HERE/install-order', '$HERE/SHA256SUMS', '$HERE/tux-archive'):
            self.assertNotIn(bad, rest, "after the copy, only the checked copy may be used")
        self.assertIn("file:$M/apt", text)
        self.assertIn('deb=$M/apt/$rel', text)

    def test_sums_are_complete_and_right(self):
        lines = (self.tree / "SHA256SUMS").read_text().splitlines()
        listed = {}
        for line in lines:
            m = re.fullmatch(r"([0-9a-f]{64})  (\S.*)", line)
            self.assertIsNotNone(m, "bad line %r" % line)
            self.assertNotIn(m.group(2), listed, "listed twice")
            self.assertFalse(m.group(2).startswith(("/", "../")) or "/../" in m.group(2) or m.group(2).startswith("./"))
            listed[m.group(2)] = m.group(1)
        want = [f for f in files_of(self.tree) if f not in ("SHA256SUMS", "SHA256SUMS.gpg")]
        self.assertEqual(sorted(listed), want, "SHA256SUMS must name every file but itself and its signature")
        self.assertEqual([l.split("  ", 1)[1] for l in lines], sorted(want, key=lambda s: s.encode()), "the list is sorted")
        for f, h in listed.items():
            self.assertEqual(sha256(self.tree / f), h, f)

    def test_signatures_verify_with_the_key_in_tux_guest(self):
        self.assertEqual((self.tree / "tux-archive.gpg").read_bytes(), KEYRING.read_bytes(),
                         "tux-archive.gpg must be the bytes of the key in tux-guest")
        rel = self.dists
        results = {"SHA256SUMS.gpg": verifier(KEYRING, self.tree / "SHA256SUMS.gpg", self.tree / "SHA256SUMS"),
                   "Release.gpg": verifier(KEYRING, rel / "Release.gpg", rel / "Release")}
        if shutil.which("gpgv"):  # InRelease is signed inline: only gpgv reads it
            with tempfile.TemporaryDirectory() as home:
                results["InRelease"] = subprocess.run(["gpgv", "--homedir", home, "--keyring", str(KEYRING), str(rel / "InRelease")],
                                                      capture_output=True).returncode == 0
        if all(v is None for v in results.values()):
            self.skipTest("no gpgv and no sqv")
        for name, ok in results.items():
            self.assertTrue(ok, "%s does not verify" % name)
        # a changed byte must fail: the check is not a no-op
        with tempfile.TemporaryDirectory() as t:
            shutil.copy(self.tree / "SHA256SUMS", Path(t) / "S")
            shutil.copy(self.tree / "SHA256SUMS.gpg", Path(t) / "S.gpg")
            with open(Path(t) / "S", "ab") as f:
                f.write(b"x")
            self.assertFalse(verifier(KEYRING, Path(t) / "S.gpg", Path(t) / "S"))

    # the apt repository
    def test_release_has_no_valid_until_and_matches_the_indexes(self):
        text = (self.dists / "Release").read_text()
        self.assertNotIn("Valid-Until", text)
        self.assertNotIn("Valid-Until", (self.dists / "InRelease").read_text())
        fields = dict(l.split(": ", 1) for l in text.splitlines() if re.match(r"^[A-Z][A-Za-z0-9-]*: ", l))
        self.assertEqual(fields["Components"].split(), ["main", "deps"])
        self.assertEqual(fields["Architectures"].split(), ["arm64", "all"])
        self.assertEqual(fields["Codename"], self.suite)
        block = text.split("SHA256:\n", 1)[1]
        got = {}
        for line in block.splitlines():
            if not line.startswith(" "):
                break
            h, size, name = line.split()
            got[name] = (h, int(size))
        for comp in ("main", "deps"):
            for arch in ("arm64", "all"):
                for n in ("Packages", "Packages.xz"):
                    rel = "%s/binary-%s/%s" % (comp, arch, n)
                    p = self.dists / rel
                    self.assertIn(rel, got)
                    self.assertEqual(got[rel], (sha256(p), p.stat().st_size), rel)
                self.assertEqual(lzma.decompress((self.dists / comp / ("binary-%s" % arch) / "Packages.xz").read_bytes()),
                                 (self.dists / comp / ("binary-%s" % arch) / "Packages").read_bytes(), "xz differs from plain")

    def test_packages_entries_match_the_debs(self):
        for comp in ("main", "deps"):
            seen = set()
            for arch in ("arm64", "all"):
                for e in parse_packages((self.dists / comp / ("binary-%s" % arch) / "Packages").read_text()):
                    fn = e["Filename"]
                    self.assertTrue(fn.startswith("pool/%s/" % comp), fn)
                    p = self.apt / fn
                    self.assertTrue(p.is_file(), fn)
                    self.assertEqual((int(e["Size"]), e["SHA256"]), (p.stat().st_size, sha256(p)), fn)
                    self.assertIn(e["Architecture"], ("arm64", "all"))
                    self.assertRegex(fn, r"/%s_.*_%s\.deb$" % (re.escape(e["Package"]), e["Architecture"]))
                    seen.add(fn)
            self.assertEqual(seen, {str(p.relative_to(self.apt)) for p in self.pool(comp)}, "pool/%s and the indexes differ" % comp)

    def test_main_is_the_four_tuxedo_debs(self):
        names = sorted(p.name.split("_")[0] for p in self.pool("main"))
        self.assertEqual(names, ["tux-codec-dkms", "tux-ffmpeg", "tux-guest", "tux-va"])
        for p in self.pool("deps"):
            self.assertFalse(p.name.startswith("tux-"), p.name)

    def test_deps_size_limit(self):
        total = sum(p.stat().st_size for p in self.pool("deps"))
        self.assertLessEqual(total, DEPS_MAX_BYTES, "deps are %d bytes" % total)
        names = {p.name.split("_")[0] for p in self.pool("deps")}
        for need in ("openssh-server", "openssh-client", "openssh-sftp-server"):
            self.assertIn(need, names)
        print("\n  deps: %d debs, %d bytes; main: %d bytes; tree: %d bytes" % (
            len(self.pool("deps")), total, sum(p.stat().st_size for p in self.pool("main")),
            sum((self.tree / f).stat().st_size for f in files_of(self.tree))))

    # versions.json
    def test_versions_json_matches_the_debs(self):
        v = self.j("versions.json")
        self.assertRegex(v["additions"], r"^\d+\.\d+\.\d+\+\d+$")
        self.assertRegex(v["built"], r"^\d\d/\d\d/\d{4}$")
        self.assertEqual((v["suite"], v["arch"], v["snapshot"]), (self.suite, "arm64", env_file("DEBIAN_SNAPSHOT")))
        self.assertEqual(v["protocol"], self.j("actions.json")["protocol"])
        main = {}
        for p in self.pool("main"):
            c = deb_control(p)
            self.assertIsNotNone(c, "cannot read %s" % p.name)
            main[c["Package"]] = c["Version"]
        self.assertEqual(v["packages"], main)
        self.assertEqual(v["optional"], ["tux-codec-dkms"], "the app skips this package in its list of missing ones")
        self.assertTrue(set(v["optional"]) <= set(v["packages"]))
        self.assertEqual(v["additions"].split("+")[0], main["tux-guest"])
        self.assertEqual(v["deps_bytes"], sum(p.stat().st_size for p in self.pool("deps")))
        self.assertEqual(v["deps_count"], len(self.pool("deps")))
        order = (self.tree / "install-order.txt").read_text().splitlines()
        self.assertEqual(order, v["deps_order"])
        for rel in order:
            self.assertTrue((self.apt / rel).is_file(), rel)
        self.assertEqual(len(order), len(set(order)))
        tail = [Path(r).name.split("_")[0] for r in order[-3:]]
        self.assertEqual(sorted(tail), ["tux-ffmpeg", "tux-guest", "tux-va"], "the Tuxedo debs come last")
        for rel in order[:-3]:
            self.assertTrue(rel.startswith("pool/deps/"), rel)

    def test_each_deb_matches_its_index_entry_and_name(self):
        for comp in ("main", "deps"):
            for p in self.pool(comp):
                c = deb_control(p)
                if c is None:
                    continue
                ver = re.sub(r"^\d+:", "", c["Version"])
                self.assertEqual(p.name, "%s_%s_%s.deb" % (c["Package"], ver, c["Architecture"]))

    def test_tux_guest_carries_the_same_report_script(self):
        deb = next(p for p in self.pool("main") if p.name.startswith("tux-guest_"))
        data = deb_data(deb)
        self.assertIsNotNone(data)
        names = {m.name.lstrip("./"): m for m in data.getmembers()}
        member = names.get("usr/lib/tux/tux-additions-report")
        self.assertIsNotNone(member, "tux-guest has no /usr/lib/tux/tux-additions-report")
        self.assertEqual(data.extractfile(member).read(), (self.tree / "tux_additions_caps.py").read_bytes(),
                         "the guest's tux-additions-report must be tux_additions_caps.py, byte for byte")
        self.assertTrue(member.mode & 0o111, "the report script must be executable")
        # the key in the deb is the key on the media
        key = names.get("usr/share/keyrings/tux-archive.gpg")
        self.assertEqual(data.extractfile(key).read(), (self.tree / "tux-archive.gpg").read_bytes())

    # the catalogue and the session files
    def test_catalogue_shape(self):
        c = self.j("actions.json")
        self.assertEqual(c["protocol"], 1)
        self.assertEqual([d["id"] for d in c["desktops"]], ["labwc", "plasma", "xfce"])
        ids = [a["id"] for a in c["apps"]]
        self.assertEqual(len(ids), len(set(ids)))
        for need in REQUIRED_APPS:
            self.assertIn(need, ids)
        for item in c["desktops"] + c["apps"]:
            self.assertRegex(item["id"], r"^[a-z0-9][a-z0-9_-]{0,31}$")
            self.assertTrue(item["title"])
            self.assertIsInstance(item["size_mb"], int)
            self.assertGreater(item["size_mb"], 0)
            self.assertTrue(item["packages"])
            for p in item["packages"]:
                self.assertRegex(p, r"^[a-z0-9][a-z0-9+.-]+$")
        self.assertEqual({a["group"] for a in c["apps"]} - GROUPS, set())
        self.assertEqual({a["group"] for a in c["apps"]}, GROUPS, "each group has an application")
        self.assertEqual(c["ssh"], {"port_min": 1, "port_max": 65535, "default_port": 22})
        # the agent accepts the file
        import importlib.machinery
        import importlib.util
        sys.path.insert(0, str(self.tree))
        loader = importlib.machinery.SourceFileLoader("agent_of_the_tree", str(self.tree / "agent"))
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(mod)
        mod.validate_catalogue(c)
        self.assertEqual(c, json.loads((HERE / "additions/actions.json").read_text()), "the media's catalogue is the source's")

    def test_labwc_packages_are_the_desktop_images(self):
        text = (HERE / "build-image.sh").read_text()
        extra = re.search(r'PKGS="\$PKGS,(labwc,[^"]+)"', text)
        self.assertIsNotNone(extra)
        want = [p for p in extra.group(1).split(",")]
        got = next(d for d in self.j("actions.json")["desktops"] if d["id"] == "labwc")["packages"]
        self.assertEqual(sorted(set(got)), sorted(set(want)), "labwc packages differ from PKGS in build-image.sh")

    def test_session_files_are_copies_of_the_desktop_image(self):
        base = self.tree / "desktop-labwc"
        entries = json.loads((base / "files.json").read_text())
        mapped = set()
        for e in entries:
            src = base / e["src"]
            self.assertTrue(src.is_file(), e["src"])
            mapped.add(e["src"])
            self.assertTrue(e["dst"].startswith(("/etc/", "/usr/local/bin/", "/usr/share/")), e["dst"])
            self.assertRegex(e["mode"], r"^0[0-7]{3}$")
            orig = HERE / "rootfs-desktop" / e["src"]
            if orig.is_file():
                want = orig.read_bytes()
                if e.get("subst"):
                    want = want.replace(b"--autologin tux ", b"--autologin @USER@ ")
                self.assertEqual(src.read_bytes(), want, "%s differs from rootfs-desktop" % e["src"])
                self.assertEqual(bool(orig.stat().st_mode & 0o111), bool(int(e["mode"], 8) & 0o111), "exec bit of %s" % e["src"])
        # the tty1 sign-in as the account is written only when the account step chose autologin
        auto = [e for e in entries if e["src"].endswith("getty@tty1.service.d/autologin.conf")]
        self.assertEqual([e.get("when") for e in auto], ["autologin"])
        self.assertEqual([e for e in entries if e.get("when") not in (None, "autologin")], [])
        on_disk = {f[len("desktop-labwc/"):] for f in files_of(self.tree) if f.startswith("desktop-labwc/")} - {"files.json"}
        self.assertEqual(on_disk, mapped, "a session file is not in the map, or the map names a missing file")
        # what tux-session and the labwc autostart start must be in the map
        for need in ("usr/local/bin/tux-session", "usr/local/bin/tux-display", "etc/xdg/labwc/autostart",
                     "etc/profile.d/tux-desktop.sh", "etc/systemd/system/getty@tty1.service.d/autologin.conf"):
            self.assertIn(need, mapped)

    def test_plasma_files_are_copies_of_the_desktop_image(self):
        base = self.tree / "desktop-plasma"
        entries = json.loads((base / "files.json").read_text())
        mapped = set()
        for e in entries:
            src = base / e["src"]
            self.assertTrue(src.is_file(), e["src"])
            mapped.add(e["src"])
            want = (HERE / "rootfs-desktop" / e["src"]).read_bytes()
            if e.get("subst"):
                want = want.replace(b'subject.user == "tux"', b'subject.user == "@USER@"')
            self.assertEqual(src.read_bytes(), want, "%s differs from rootfs-desktop" % e["src"])
        on_disk = {f[len("desktop-plasma/"):] for f in files_of(self.tree) if f.startswith("desktop-plasma/")} - {"files.json"}
        self.assertEqual(on_disk, mapped)

    def test_catalogue_names_exist_in_trixie(self):
        if ARGS.offline:
            self.skipTest("--offline: the package names were not checked")
        snap = env_file("DEBIAN_SNAPSHOT")
        cache = default_out() / "additions/cache"
        names = set()
        for arch in ("arm64", "all"):
            f = cache / ("Packages-%s-%s-%s.xz" % (self.suite, snap, arch))
            if not f.exists():
                url = "http://snapshot.debian.org/archive/debian/%s/dists/%s/main/binary-%s/Packages.xz" % (snap, self.suite, arch)
                try:
                    cache.mkdir(parents=True, exist_ok=True)
                    with urllib.request.urlopen(url, timeout=60) as r:
                        data = r.read()
                except OSError as e:
                    self.skipTest("no network (%s): the package names were not checked" % e)
                f.write_bytes(data)
            for line in lzma.decompress(f.read_bytes()).decode().splitlines():
                if line.startswith("Package: "):
                    names.add(line[9:])
        c = self.j("actions.json")
        missing = [(i["id"], p) for i in c["desktops"] + c["apps"] for p in i["packages"] if p not in names]
        self.assertEqual(missing, [], "packages that are not in trixie main (arm64 or all) at %s" % snap)

    # what must not be on the media
    def test_no_secrets_or_host_paths(self):
        needles = [b"PRIVATE KEY", b".gnupg", b"/Users/", str(ROOT).encode(), str(Path.home()).encode(),
                   b".tux-apt-key", b"secring", b"private-keys-v1.d"]
        gh = os.environ.get("TUX_APT_GNUPGHOME")
        if gh:
            needles.append(gh.encode())
        for f in files_of(self.tree):
            if f.startswith("apt/pool/"):
                continue
            data = (self.tree / f).read_bytes()
            for n in needles:
                if n == b".gnupg" and f.endswith("/Packages"):
                    continue  # Debian's package descriptions name ~/.gnupg
                self.assertNotIn(n, data, "%s has %r" % (f, n))
        for deb in self.pool("main"):  # the Tuxedo debs: unpack and look
            data = deb_data(deb)
            if data is None:
                continue
            for m in data.getmembers():
                if m.isfile():
                    body = data.extractfile(m).read()
                    for n in PEM + [str(ROOT).encode()]:
                        self.assertNotIn(n, body, "%s: %s has %r" % (deb.name, m.name, n))
        # no key file on the media, whatever its name
        for f in files_of(self.tree):
            self.assertNotRegex(f, r"(secring|\.key$|private)", f)

    def test_sources_file_names_every_dep(self):
        text = (self.tree / "source/SOURCES.txt").read_text()
        for p in self.pool("deps"):
            self.assertIn(p.name.split("_")[0], text, p.name)
        self.assertIn("tux-ffmpeg", text)
        readme = (self.tree / "README.txt").read_text()
        self.assertNotRegex(readme, r"@[A-Z_]+@", "a placeholder is left in README.txt")
        for word in ("GPL", "source", "install", "SHA256SUMS"):
            self.assertIn(word, readme)

    # the same media twice
    def test_other_tree_is_the_same_apart_from_signatures(self):
        if not ARGS.other:
            self.skipTest("no --other and no --rebuild: reproducibility not compared")
        other = Path(ARGS.other)
        self.assertEqual(files_of(self.tree), files_of(other))
        diff = [f for f in files_of(self.tree) if Path(f).name not in SIGNED and (self.tree / f).read_bytes() != (other / f).read_bytes()]
        self.assertEqual(diff, [], "files that differ between two builds")


def rebuild(first):
    """Builds again into a copy of the work folder (the Debian downloads are kept) and returns the new tree."""
    out = default_out()
    work = out / "additions-rebuild"
    if work.exists():
        shutil.rmtree(work)
    (work / "additions").mkdir(parents=True)
    for d in ("ffmpeg", "va", "codec"):
        shutil.copytree(out / d, work / d, ignore=shutil.ignore_patterns("src", "bin"))
    shutil.copytree(out / "additions/cache", work / "additions/cache", symlinks=True, ignore=shutil.ignore_patterns("Packages-*"))
    env = dict(os.environ, TUX_LINUX_OUT=str(work))
    subprocess.run(["sh", str(HERE / "package-additions.sh")], check=True, env=env)
    return work / "additions/tux-additions"


if __name__ == "__main__":
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--tree")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--other")
    ARGS, rest = ap.parse_known_args()
    if ARGS.rebuild:
        ARGS.other = str(rebuild(ARGS.tree))
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=2)
