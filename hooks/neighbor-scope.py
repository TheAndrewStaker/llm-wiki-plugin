#!/usr/bin/env python3
"""Point-of-contact reconcile nudge: when a content page changes, the pages that LINK TO
it may now state stale claims about it (they summarize or depend on what it says). This
prints, per changed page, its inbound linkers that were NOT edited alongside it, so the
committer reconciles them or consciously leaves them.

Deterministic and bounded (never the whole wiki): changed set = staged files by default
(the pre-commit case), else the last commit; override with --range A..B. Linkers exclude
the changed set itself, per-dir index.md files, landmark singletons (STATE/KNOWLEDGE/
ROADMAP/CLAUDE), and archive/ (append-only, never reconciled). Output capped so this
stays a nudge, not a wall; the machine line carries the true count.

Advisory only, always exits 0. Standalone: python3 hooks/neighbor-scope.py [--range A..B] [WIKI_ROOT]
Ends with: NEIGHBORS=<n>
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

CAP = 10
a = sys.argv[1:]
rng = None
if "--range" in a:
    i = a.index("--range")
    rng = a[i + 1]
    del a[i:i + 2]
KB = wikilib.resolve_root(a[0] if a else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)
content_dirs = tuple(cfg["content_dirs"])
landmarks = set(cfg["landmark_files"]) | {"CLAUDE.md"}


def git_names(*args):
    out = subprocess.run(["git", *args, "--", "*.md"], cwd=KB,
                         capture_output=True, text=True).stdout
    return [f for f in out.splitlines() if f]


if rng:
    changed = git_names("diff", "--name-only", rng)
else:
    changed = git_names("diff", "--cached", "--name-only")
    if not changed:
        changed = git_names("diff", "--name-only", "HEAD~1..HEAD")
changed = set(changed)
targets = {f for f in changed
           if f.startswith(content_dirs) and os.path.basename(f) != "index.md"}
if not targets:
    print("NEIGHBORS=0")
    sys.exit(0)

mdlink = re.compile(r"\]\(([^)]+)\)")
fence = re.compile(r"^\s*(```|~~~)")
inbound = {}  # changed page -> set of unedited linkers

for f in wikilib.git_files(KB):
    b = os.path.basename(f)
    if (f in changed or b == "index.md" or b in landmarks
            or f.startswith(("archive/", "sources/")) or wikilib.is_memory(f)):
        continue
    d = os.path.dirname(f)
    in_fence = False
    for line in wikilib.read(KB, f).split("\n"):
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in mdlink.finditer(re.sub(r"`[^`]*`", "", line)):
            parts = m.group(1).split()
            if not parts:
                continue
            t = parts[0].split("#")[0]
            if not t or t.startswith(("http://", "https://", "mailto:", "tel:", "ftp:")):
                continue
            tgt = t.lstrip("/") if t.startswith("/") else os.path.normpath(os.path.join(d, t)).replace(os.sep, "/")
            if tgt in targets:
                inbound.setdefault(tgt, set()).add(f)

lines = []
for tgt in sorted(inbound):
    for linker in sorted(inbound[tgt]):
        lines.append(f"  NEIGHBOR {linker} links {tgt} (changed) -- reconcile or consciously leave")
total = len(lines)
for line in lines[:CAP]:
    print(line)
if total > CAP:
    print(f"  NEIGHBOR ... and {total - CAP} more (run standalone for the full list)")
print(f"NEIGHBORS={total}")
