#!/usr/bin/env python3
"""Missed-link advisory: flag pages that MENTION an entity/concept by TITLE in plain text
but never LINK that page even once. Overlink-safe (one link per page is enough); aliases
are excluded on purpose (generic phrase-aliases over-fire). Advisory; exits 0. Standalone:
    python3 hooks/missed-links.py [WIKI_ROOT]
Ends with: MISSED_LINKS=<page,term pairs>
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)
files = wikilib.git_files(KB)

# Only distinctive names: short titles (< 6 chars) and user-listed stopwords over-fire.
STOP = {s.lower() for s in cfg["missed_link_stop"]}
entity_dirs = tuple(cfg["entity_dirs"])
prose_dirs = tuple(cfg["prose_dirs"])

term2page = {}
for f in files:
    if not f.startswith(entity_dirs) or os.path.basename(f) == "index.md":
        continue
    head = open(f, encoding="utf-8", errors="replace").read()[:1000]
    m = re.search(r"^title:\s*(.+)$", head, re.M)
    if m:
        t = m.group(1).strip()
        if len(t) >= 6 and t.lower() not in STOP:
            term2page.setdefault(t.lower(), (t, f))


def strip(t):
    t = re.sub(r"^---\n.*?\n---\n", "", t, flags=re.S)
    t = re.sub(r"```.*?```", "", t, flags=re.S)
    t = re.sub(r"`[^`]*`", "", t)
    t = re.sub(r"\[\[[^\]]*\]\]", "", t)
    t = re.sub(r"\[[^\]]*\]\([^)]*\)", "", t)
    return t


prose = [f for f in files if f.startswith(prose_dirs)
         and not f.endswith(".base") and os.path.basename(f) != "index.md"]

pairs, by_page = [], collections.Counter()
for f in prose:
    raw = open(f, encoding="utf-8", errors="replace").read()
    plain = strip(raw).lower()
    linked = set()
    for tgt in re.findall(r"\]\(([^)#\s]+)", raw):
        p = tgt if tgt.startswith("/") else os.path.normpath(os.path.join(os.path.dirname(f), tgt))
        linked.add(p.lstrip("/"))
    seen = set()
    for term, (disp, page) in term2page.items():
        if f == page or page in seen:
            continue
        if not re.search(r"(?<![\w-])" + re.escape(term) + r"(?![\w-])", plain):
            continue
        if page in linked:
            continue
        pairs.append((f, disp))
        by_page[f] += 1
        seen.add(page)

for f, n in by_page.most_common(10):
    terms = sorted({d for g, d in pairs if g == f})
    print(f"  MISSED-LINK {f} ({n}: {', '.join(terms)[:80]})")
print(f"MISSED_LINKS={len(pairs)}")
