#!/usr/bin/env python3
"""Compute a BOUNDED candidate scope for a reflection pass, so the LLM judgment pass stays
scoped (touched/flagged pages + a few oldest) and never runs over the whole wiki.

Scope = union of:
  (a) source-freshness RE-CHECK / ORPHANED-SOURCE pages (hooks/stale-source.py),
  (b) the top missed-link pages (hooks/missed-links.py),
  (c) the N oldest-`timestamp` content pages.
Capped (default 15). Usage:
    python3 hooks/reflect-scope.py [--range A..B] [--oldest N] [WIKI_ROOT]
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

a = sys.argv[1:]
rng = None
if "--range" in a:
    i = a.index("--range")
    rng = a[i + 1]
    del a[i:i + 2]
oldest = 8
if "--oldest" in a:
    i = a.index("--oldest")
    oldest = int(a[i + 1])
    del a[i:i + 2]
CAP = 15
KB = wikilib.resolve_root(a[0] if a else None)
cfg = wikilib.load_config(KB)
H = os.path.dirname(os.path.abspath(__file__))
os.chdir(KB)


def run(script, *extra):
    return subprocess.run(
        [sys.executable, os.path.join(H, script), *extra, KB],
        capture_output=True, text=True,
    ).stdout


scope = set()
stale = run("stale-source.py", *(["--range", rng] if rng else []))
for ln in stale.splitlines():
    m = re.search(r"(?:RE-CHECK|ORPHANED-SOURCE) (\S+)", ln)
    if m:
        scope.add(m.group(1))
for ln in run("missed-links.py").splitlines():
    m = re.search(r"MISSED-LINK (\S+)", ln)
    if m:
        scope.add(m.group(1))

content_dirs = tuple(cfg["content_dirs"])
files = wikilib.git_files(KB)
dated = []
for f in files:
    if not f.startswith(content_dirs) or os.path.basename(f) == "index.md":
        continue
    m = re.search(r"^timestamp:\s*(\d{4}-\d{2}-\d{2})", open(f, encoding="utf-8", errors="replace").read()[:1000], re.M)
    if m:
        dated.append((m.group(1), f))
for _, f in sorted(dated)[:oldest]:
    scope.add(f)

out = sorted(scope)[:CAP]
for f in out:
    print(f"  {f}")
print(f"SCOPE_COUNT={len(out)} (of {len(scope)} candidates; capped at {CAP})")
