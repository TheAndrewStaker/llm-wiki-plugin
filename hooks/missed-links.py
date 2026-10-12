#!/usr/bin/env python3
"""Missed-link advisory: flag pages that MENTION an entity/concept by TITLE in plain text
but never LINK that page even once. Overlink-safe (one link per page is enough); aliases
are excluded on purpose (generic phrase-aliases over-fire). Advisory; exits 0.

Detection is shared with link-mentions.py, which fixes what this reports. Standalone:
    python3 hooks/missed-links.py [WIKI_ROOT]            whole-wiki count
    python3 hooks/missed-links.py --delta [WIKI_ROOT]    pages changed against HEAD only
Ends with: MISSED_LINKS=<page,term pairs>, or MISSED_LINKS_ADDED=<pages> for --delta.

--delta judges a commit, not the wiki: for each changed page it reports the targets the
page now names without linking that its HEAD version did not, so the author of a new
unlinked mention is the one who hears about it and nobody else's commit is blocked by a
total they did not raise. WIKI_CHECK_INDEX=1 reads the staged version of each page.
"""
import collections
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

args = [a for a in sys.argv[1:] if a != "--delta"]
DELTA = "--delta" in sys.argv
KB = wikilib.resolve_root(args[0] if args else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)
files = wikilib.corpus_files(KB, cfg)

if DELTA:
    index_mode = os.environ.get("WIKI_CHECK_INDEX") == "1"
    diff = ["git", "diff"] + (["--cached"] if index_mode else []) + ["--name-only", "HEAD", "--", "*.md"]
    changed = subprocess.run(diff, cwd=KB, capture_output=True, text=True).stdout.split()
    if not index_mode:
        changed += subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "*.md"],
                                  cwd=KB, capture_output=True, text=True).stdout.split()
    prose_dirs = tuple(cfg["prose_dirs"])
    idx = wikilib.mention_index(KB, cfg, files)
    renames = wikilib.renamed_from(KB, index=index_mode)
    added = 0
    for f in sorted(set(changed)):
        if not f.startswith(prose_dirs) or os.path.basename(f) == "index.md" or f.endswith(".base"):
            continue
        new_text = wikilib.git_text(KB, f, "") if index_mode else wikilib.read(KB, f)
        if not new_text:
            continue
        old_text = wikilib.git_text(KB, renames.get(f, f), "HEAD")
        now = {page: disp for _, disp, page, _ in wikilib.missed_mentions_text(idx, f, new_text)}
        before = {page for _, _, page, _ in wikilib.missed_mentions_text(idx, f, old_text)} if old_text else set()
        gained = sorted(now[p] for p in now if p not in before)
        if gained:
            print(f"  MISSED-LINK-ADDED {f} ({len(gained)}: {', '.join(gained)[:80]})")
            added += 1
    print(f"MISSED_LINKS_ADDED={added}")
    sys.exit(0)

pairs, by_page = [], collections.Counter()
for f, disp, page, _ in wikilib.missed_mentions(KB, cfg, files):
    pairs.append((f, disp))
    by_page[f] += 1

for f, n in by_page.most_common(10):
    terms = sorted({d for g, d in pairs if g == f})
    print(f"  MISSED-LINK {f} ({n}: {', '.join(terms)[:80]})")
print(f"MISSED_LINKS={len(pairs)}")
