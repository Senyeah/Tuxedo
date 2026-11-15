"""The guest user and hostname of an image: one place for every check that logs in or names a home folder.

build-image.sh writes guest_user= and guest_host= into the image's .manifest. An image from before Tuxedo has a
manifest without them, and its user is the legacy name. TUX_GUEST_USER (and TUX_GUEST_HOST) override the manifest,
for a disk with no manifest next to it (a --save-image clone).

The serial console signs in as the guest user on images with tux-guest before 1.11.0, and as root on a machine with
no /var/lib/tux/account.json under 1.11.0. shell() matches either prompt. login() and to_user() move a root shell to
the guest user with su, so a check runs as the user it was written for on both.
"""
import os
import re
import subprocess
import sys

LEGACY = "henge"  # legacy name: images built before Tuxedo

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_current = None


def linux_dir():
    """TUX_LINUX_OUT, else build/linux in the main checkout (worktrees share it)."""
    if os.environ.get("TUX_LINUX_OUT"):
        return os.environ["TUX_LINUX_OUT"]
    common = subprocess.run(["git", "-C", _ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(os.path.dirname(common), "build", "linux")


def read(image):
    """(user, host) of the image at this path."""
    user, host = os.environ.get("TUX_GUEST_USER"), os.environ.get("TUX_GUEST_HOST")
    if user:
        return user, host or user
    manifest = re.sub(r"\.img$", "", image) + ".manifest"
    if not os.path.exists(manifest):
        sys.exit(f"guest_user: no manifest next to {image}; set TUX_GUEST_USER (and TUX_GUEST_HOST)")
    keys = dict(line.rstrip("\n").split("=", 1) for line in open(manifest) if re.match(r"guest_(user|host)=", line))
    user = keys.get("guest_user", LEGACY)
    return user, keys.get("guest_host", user)


def use(image):
    """Call once the image is known (after the arguments). Returns the user."""
    global _current
    _current = read(image)
    return _current[0]


def _get():
    return _current or read(os.path.join(linux_dir(), "debian-console.img"))


def user():
    return _get()[0]


def host():
    return _get()[1]


def home():
    return f"/home/{user()}"


def _any(user_path, root_path):
    return rf"(?:{user()}@{host()}:{user_path}\$ |root@{host()}:{root_path}# )"


def shell():
    """The login prompt of the guest user or of root, for pexpect (not anchored: a kernel line can follow it)."""
    return _any(r"\S*", r"\S*")


def shell_wide():
    """The same, where the path part may hold spaces."""
    return _any(r"[^\n]*", r"[^\n]*")


def user_shell():
    """Only the guest user's prompt (after su)."""
    return rf"{user()}@{host()}:[^\n]*\$ "


def prompt_prefix():
    """What re.sub removes from the start of a captured command's output."""
    return rf"^(?:{user()}|root)@{host()}:[^\n$#]*[$#] "


def _text(x):
    return x.decode(errors="replace") if isinstance(x, bytes) else (x or "")


def at_root(p):
    """True when the prompt pexpect matched last is root's."""
    tail = (_text(p.before) + _text(p.after))[-300:]
    return user() != "root" and re.search(rf"root@{re.escape(host())}:[^\n]*# $", tail) is not None


def su_command():
    return f"su - {user()}"


def to_user(p, timeout=60):
    """Call at a prompt that shell() matched. A root shell becomes the guest user's, so checks run as before."""
    if at_root(p):
        p.sendline(su_command())
        p.expect(user_shell(), timeout=timeout)


def login(p, boot_timeout, prompt_timeout=60, wide=True):
    """Waits for the console auto-login and leaves the guest user's shell at the prompt."""
    p.expect(r"\(automatic login\)", timeout=boot_timeout)
    p.expect(shell_wide() if wide else shell(), timeout=prompt_timeout)
    to_user(p, prompt_timeout)
