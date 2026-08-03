#!/usr/bin/env python3
"""Missed-link advisory: flag pages that MENTION an entity/concept by TITLE in plain text
but never LINK that page even once. Overlink-safe (one link per page is enough); aliases
are excluded on purpose (generic phrase-aliases over-fire). Advisory; exits 0.

Detection is shared with link-mentions.py, which fixes what this reports. Standalone:
    python3 hooks/missed-links.py [WIKI_ROOT]
Ends with: MISSED_LINKS=<page,term pairs>
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)
files = wikilib.corpus_files(KB, cfg)

pairs, by_page = [], collections.Counter()
for f, disp, page, _ in wikilib.missed_mentions(KB, cfg, files):
    pairs.append((f, disp))
    by_page[f] += 1

for f, n in by_page.most_common(10):
    terms = sorted({d for g, d in pairs if g == f})
    print(f"  MISSED-LINK {f} ({n}: {', '.join(terms)[:80]})")
print(f"MISSED_LINKS={len(pairs)}")
