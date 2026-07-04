#!/usr/bin/env python3
"""Source-freshness triage (semantic-staleness signal). Triggered tool, NOT a commit gate.

A page declares the source it was synthesized from in `synthesized_from:` (distinct from
OKF's `resource:`, which is the asset a concept *describes*). When that source changes
substantively after the page was last verified, the synthesis may be behind it -> RE-CHECK.

Modes:
  (default)  DIFF-TRIGGERED: flag pages whose synthesized_from appears in a commit range's
             diff (default HEAD~1..HEAD; override with --range A..B). Whitespace-only source
             changes are ignored (git diff -w).
  --standing BACKSTOP for sources OUTSIDE this repo (external abs paths): compare the
             source's commit date to the page's verification date.

Always reported (both modes):
  ORPHANED-SOURCE  synthesized_from is a path that no longer exists.
  UNCHECKABLE      synthesized_from is a URL (no fetch configured) or free-text description.

Verification date = `reviewed:` if present, else `timestamp:`. We do NOT auto-expire by age
(staleness is a symptom, not a timer). Usage:
    python3 hooks/stale-source.py [--range A..B | --standing] [WIKI_ROOT]
"""
import datetime
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

args = sys.argv[1:]
standing = "--standing" in args
args = [a for a in args if a != "--standing"]
rng = "HEAD~1..HEAD"
if "--range" in args:
    i = args.index("--range")
    rng = args[i + 1]
    del args[i:i + 2]
KB = wikilib.resolve_root(args[0] if args else None)
os.chdir(KB)


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout


files = wikilib.git_files(KB)


def verif_date(text):
    return (wikilib.frontmatter_value(text, "reviewed")
            or wikilib.frontmatter_value(text, "timestamp") or "")[:10]


def resolve(page, sf):
    sf = re.sub(r'\s+"[^"]*"$', "", sf).strip()
    if sf.startswith(("http://", "https://", "mailto:")):
        return ("url", sf)
    if " " in sf and not sf.startswith(("/", "~", "./", "../")):
        return ("freetext", sf)
    p = os.path.expanduser(sf)
    if not os.path.isabs(p):
        p = os.path.normpath(os.path.join(os.path.dirname(page), sf))
    return ("path", p)


def git_date(path):
    d = path if os.path.isdir(path) else (os.path.dirname(path) or ".")
    root = sh("git", "-C", d, "rev-parse", "--show-toplevel").strip()
    if root:
        rel = os.path.relpath(path, root)
        follow = [] if os.path.isdir(path) else ["--follow"]
        out = sh("git", "-C", root, "log", "-1", *follow, "--format=%cs", "--", rel).strip()
        if out:
            return out
    try:
        return datetime.date.fromtimestamp(os.path.getmtime(path)).isoformat()
    except OSError:
        return None


changed = set()
if not standing:
    base = sh("git", "diff", "-w", "--name-only", rng).splitlines()
    changed = {os.path.normpath(p) for p in base if p}

recheck, orphaned, uncheckable = [], [], []
for f in files:
    text = open(f, encoding="utf-8", errors="replace").read()
    sf = wikilib.frontmatter_value(text, "synthesized_from")
    if not sf:
        continue
    kind, target = resolve(f, sf)
    if kind in ("url", "freetext"):
        uncheckable.append((f, target, "a URL" if kind == "url" else "free-text"))
        continue
    # realpath both sides so a symlinked root (e.g. macOS /var -> /private/var) doesn't corrupt
    # the relative path computation below.
    real_target = os.path.realpath(target)
    real_kb = os.path.realpath(KB)
    inside_kb = real_target.startswith(real_kb + os.sep)
    if not os.path.exists(target):
        orphaned.append((f, sf))
        continue
    if standing:
        if inside_kb:
            continue
        sd = git_date(target)
        vd = verif_date(text)
        if sd and vd and sd > vd:
            recheck.append((f, sf, f"source {sd} > verified {vd}"))
    else:
        if inside_kb and os.path.isfile(target):
            rel = os.path.normpath(os.path.relpath(real_target, real_kb))
            if rel in changed:
                recheck.append((f, sf, f"changed in {rng}"))

for f, sf, why in sorted(recheck):
    print(f"  RE-CHECK {f}  (synthesized_from {sf}: {why})")
for f, sf in sorted(orphaned):
    print(f"  ORPHANED-SOURCE {f}  (synthesized_from {sf} no longer exists)")
for f, sf, why in sorted(uncheckable):
    print(f"  UNCHECKABLE {f}  (synthesized_from {sf} is {why})")
print(f"RECHECK={len(recheck)} ORPHANED={len(orphaned)} UNCHECKABLE={len(uncheckable)}")
