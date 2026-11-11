#!/usr/bin/env python3
"""List what the link graph leaves unconnected, on demand.

    python3 hooks/orphans.py [WIKI_ROOT]

Sections: gated orphans (no inbound link, not exempt), exempt pages with no inbound link
grouped by top-level directory, and islands (nodes outside the largest component).
Exits 1 when a gated orphan exists, else 0.
"""
import collections
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wikilib

KB = str(wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None))


def lines(script, env=None):
    proc = subprocess.run([sys.executable, os.path.join(HERE, script), KB], capture_output=True,
                          text=True, env=dict(os.environ, **(env or {})))
    return [line.strip() for line in proc.stdout.splitlines()]


core = lines("lint-core.py", {"WIKI_LINT_LIST_EXEMPT": "1"})
orphans = sorted(l.split(" ", 1)[1] for l in core if l.startswith("ORPHAN "))
exempt = collections.defaultdict(list)
for l in core:
    if l.startswith("EXEMPT-UNLINKED "):
        f = l.split(" ", 1)[1]
        exempt[f.split("/", 1)[0] + "/" if "/" in f else "(root)"].append(f)
islands = [l.split(" ", 1)[1] for l in lines("graph-check.py") if l.startswith("ISLAND ")]

print(f"Gated orphans (no inbound link, not exempt): {len(orphans)}")
for f in orphans:
    print(f"  {f}")
total = sum(len(v) for v in exempt.values())
print(f"Exempt pages with no inbound link: {total}")
for d in sorted(exempt):
    print(f"  {d} {len(exempt[d])}")
    if "--all" in sys.argv:
        for f in sorted(exempt[d]):
            print(f"    {f}")
print(f"Islands (outside the largest component): {len(islands)}")
by_dir = collections.Counter(i.split("/", 1)[0] + "/" if "/" in i.split(" ")[0] else "(root)" for i in islands)
for d in sorted(by_dir):
    print(f"  {d} {by_dir[d]}")
if "--all" in sys.argv:
    for i in islands:
        print(f"    {i}")
sys.exit(1 if orphans else 0)
