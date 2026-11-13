#!/usr/bin/env python3
"""ffmpeg-henge(7) must list each *_henge encoder, each of its options and their named values, and each scale_henge
option (docs/guest-video-encode-plan.md, VE3.2). Python 3 standard library only: build-ffmpeg-pkg.sh runs it in the
build container and vcodec-check.py --apt in the guest.

  manpage-check.py [--ffmpeg BIN] PAGE     PAGE: a man page file, or a page name for man(1)
Exit 1 if something is missing."""
import argparse
import os
import re
import subprocess
import sys

FILTERS = ["scale_henge"]


def run(argv, env=None):
    r = subprocess.run(argv, capture_output=True, text=True, env=env)
    if r.returncode:
        sys.exit(f"manpage-check: {' '.join(argv)} gave status {r.returncode}: {r.stderr.strip()[-400:]}")
    return r.stdout


def page_text(page):
    env = dict(os.environ, MANWIDTH="200", MAN_KEEP_FORMATTING="")
    argv = ["man", "-P", "cat"] + (["-l", page] if os.path.exists(page) else [page])
    text = run(argv, env)
    return re.sub(r"\x1b\[[0-9;]*m", "", re.sub(r".\x08", "", text))


def options(help_text):
    """The AVOptions in `ffmpeg -h encoder=X` or `-h filter=X`: (option names, named values)."""
    opts, consts, on = [], [], False
    for line in help_text.splitlines():
        if line.rstrip().endswith("AVOptions:"):
            on = True
            continue
        if not on or not line.strip():
            continue
        if not line.startswith(" "):
            on = False
            continue
        f = line.split()
        if len(f) > 1 and f[1].startswith("<"):
            opts.append(f[0])
        else:
            consts.append(f[0])
    return opts, consts


def terms(text):
    """The leading names of each line: '-color_primaries, -color_trc, -colorspace' gives all three."""
    out = set()
    for line in text.splitlines():
        for tok in line.split():
            out.add(tok.rstrip(","))
            if not tok.endswith(","):
                break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ffmpeg", default="ffmpeg")
    ap.add_argument("page")
    args = ap.parse_args()
    text = page_text(args.page)
    heads = terms(text)
    words = set(re.findall(r"[\w.:-]+", text)) | {w.strip(".") for w in re.findall(r"[\w.:-]+", text)}
    encs = [l.split()[1] for l in run([args.ffmpeg, "-hide_banner", "-encoders"]).splitlines()
            if len(l.split()) > 1 and l.split()[1].endswith("_henge")]
    missing, n = [], 0
    if not encs:
        missing.append("ffmpeg lists no *_henge encoder")
    if "henge" not in run([args.ffmpeg, "-hide_banner", "-hwaccels"]).split() or "-hwaccel" not in heads:
        missing.append("the henge hwaccel")
    for kind, names in (("encoder", encs), ("filter", FILTERS)):
        for name in names:
            n += 1
            if name not in heads:
                missing.append(f"{kind} {name}")
            opts, consts = options(run([args.ffmpeg, "-hide_banner", "-h", f"{kind}={name}"]))
            if not opts:
                missing.append(f"{kind} {name}: ffmpeg shows no options")
            for o in opts:
                n += 1
                if o not in heads:
                    missing.append(f"{kind} {name}: option {o}")
            for c in consts:
                n += 1
                if c not in words:
                    missing.append(f"{kind} {name}: value {c}")
    for m in missing:
        print(f"FAIL ffmpeg-henge(7) does not list {m}")
    print(f"{'ok  ' if not missing else 'FAIL'} ffmpeg-henge(7): {n - len(missing)} of {n} names listed "
          f"({len(encs)} encoders: {', '.join(encs)}; filters: {', '.join(FILTERS)})")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
