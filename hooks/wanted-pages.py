#!/usr/bin/env python3
"""Wanted-pages report (the red-link ranking every big wiki grows): unresolved
[[name]] wikilinks are the deliberate marker for "a page worth writing"; this ranks
them by how often they are mentioned, so the most-wanted pages get written first
(MediaWiki's Special:WantedPages, Wikipedia's Most-wanted articles).

A [[name]] is RESOLVED (not wanted) when a tracked page answers to it: its basename
(without .md), its title:, or one of its aliases: matches case-insensitively (spaces
and hyphens are interchangeable). [[target|display]] reads the target part; anchors
are ignored. Advisory report, never a gate; exits 0. Standalone:
    python3 hooks/wanted-pages.py [WIKI_ROOT]
Ends with: WANTED=<distinct names> MENTIONS=<total>
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
os.chdir(KB)
files = wikilib.git_files(KB)


def norm(s):
    return re.sub(r"[\s_-]+", " ", s).strip().lower()


# every name an existing page answers to: basename, title, aliases
known = set()
alias_line = re.compile(r"^aliases:\s*(.*)$", re.M)
for f in files:
    known.add(norm(os.path.splitext(os.path.basename(f))[0]))
    head = wikilib.read(KB, f)[:1200]
    m = re.search(r"^title:\s*(.+)$", head, re.M)
    if m:
        known.add(norm(m.group(1).strip().strip("'\"")))
    m = alias_line.search(head)
    if m and m.group(1).strip().startswith("["):
        for a in m.group(1).strip().strip("[]").split(","):
            if a.strip():
                known.add(norm(a.strip().strip("'\"")))

wikilink = re.compile(r"\[\[([^\]\[]+)\]\]")
fence = re.compile(r"^\s*(```|~~~)")
mentions = collections.Counter()
pages = collections.defaultdict(set)
for f in files:
    in_fence = False
    for line in wikilib.read(KB, f).split("\n"):
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in wikilink.finditer(re.sub(r"`[^`]*`", "", line)):
            target = m.group(1).split("|")[0].split("#")[0].strip()
            if not target or norm(target) in known:
                continue
            mentions[norm(target)] += 1
            pages[norm(target)].add(f)

for name, n in mentions.most_common(20):
    where = ", ".join(sorted(pages[name])[:4])
    issue_line = f"  WANTED [[{name}]] ({n} mention{'s' if n > 1 else ''}: {where})"
    print(issue_line)
print(f"WANTED={len(mentions)} MENTIONS={sum(mentions.values())}")
