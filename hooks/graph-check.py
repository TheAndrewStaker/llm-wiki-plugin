#!/usr/bin/env python3
"""Deterministic connected-components check for the wiki graph.

Parses BOTH relative-markdown links `](path)` and Obsidian `[[wikilinks]]` over the
git-tracked .md files, computes connected components, and prints any ISLAND (a node not
in the largest component). Fenced code blocks and inline code spans are stripped first
(mirrors lint-core.py's hardening) so a page merely documenting link syntax, including a
whitespace-only target like `[x](  )`, is never parsed as a real link or crash the pass.
Advisory: always exits 0. Standalone:
    python3 hooks/graph-check.py [WIKI_ROOT]
Output ends with a machine line:
    COMPONENTS=<n> ISLAND_NODES=<m>
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
os.chdir(KB)
files = [f for f in wikilib.git_files(KB) if not f.startswith("sources/")]
nodes = set(files)
by_base = collections.defaultdict(list)
for f in files:
    by_base[os.path.basename(f)[:-3]].append(f)

adj = collections.defaultdict(set)
mdlink = re.compile(r"\]\(([^)]+)\)")
wiki = re.compile(r"\[\[([^\]|#]+)")
fence = re.compile(r"^\s*(```|~~~)")
for f in files:
    try:
        txt = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    d = os.path.dirname(f)
    in_fence = False
    for line in txt.split("\n"):
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        stripped = re.sub(r"`[^`]*`", "", line)
        for m in mdlink.finditer(stripped):
            parts = m.group(1).split()
            if not parts:  # whitespace-only target like [x](  ) -> not a link
                continue
            t = parts[0].split("#")[0]
            if not t or t.startswith(("http", "mailto", "tel", "ftp")):
                continue
            tgt = t.lstrip("/") if t.startswith("/") else os.path.normpath(os.path.join(d, t))
            if tgt in nodes:
                adj[f].add(tgt)
                adj[tgt].add(f)
        for m in wiki.finditer(stripped):
            for tgt in by_base.get(m.group(1).strip(), []):
                adj[f].add(tgt)
                adj[tgt].add(f)

seen, comps = set(), []
for f in files:
    if f in seen:
        continue
    stack, comp = [f], []
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x)
        comp.append(x)
        stack += [y for y in adj[x] if y not in seen]
    comps.append(sorted(comp))
comps.sort(key=len, reverse=True)

island_nodes = 0
for c in comps[1:]:
    island_nodes += len(c)
    head = c[0]
    extra = f" (+{len(c) - 1} more in its cluster)" if len(c) > 1 else ""
    print(f"  ISLAND {head}{extra}")
print(f"COMPONENTS={len(comps)} ISLAND_NODES={island_nodes}")
