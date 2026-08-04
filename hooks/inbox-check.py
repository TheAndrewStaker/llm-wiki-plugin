#!/usr/bin/env python3
"""Inbox soft-cap advisory. STATE.md's `## Inbox` section is meant to be triaged quickly
(into Focus / Up next / ROADMAP / an initiative file); left unattended it quietly becomes
a second, untriaged backlog. This flags when the section's top-level item count or word
count crosses a configured soft cap -- a nudge to triage, never a gate.

Item size is capped separately from the total. An Inbox is a routing slot: one line per
find, body filed on the page it belongs to. The total cap alone cannot tell "many small
entries awaiting triage" from "a few sessions pasting whole reports here", and the second
is the one that wants a different fix. Orchestrated sessions hit this hardest, having
several subagent reports to land and no cheaper place to put them.

Also flags MISFILED entries: a line in the documented Inbox shape (`- [YYYY-MM-DD ...`)
sitting anywhere in STATE.md except the Inbox section. "Append one line to STATE.md"
resolves to "append at the end of the file" for an agent that did not locate the heading
first, so entries land in whatever section happens to be last. The size caps cannot see
that, because the section they measure stays empty and reads clean while the handoff grows.
A wiki that keeps a dated log elsewhere in STATE.md can ignore this one, or disable the
whole checker by leaving the caps at 0.

Section = the text between the `## Inbox` heading and the next `## ` heading (or end of
file). Items = lines starting `- ` (top-level bullets only), plus any continuation lines
indented under them. Disabled by default so an existing wiki is unaffected until it opts in.

Config (wiki.config.json):
    inbox_soft_max_items       max top-level `- ` items before OVER (default 0 = disabled)
    inbox_soft_max_words       max words in the section before OVER (default 0 = disabled)
    inbox_soft_max_item_words  max words in ONE item before OVER (default 0 = disabled)

Advisory only, always exits 0. Standalone: python3 hooks/inbox-check.py [WIKI_ROOT]
Ends with: INBOX=OK|OVER|-   (- means disabled, or no STATE.md / no Inbox section)
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
max_items = int(cfg.get("inbox_soft_max_items", 0) or 0)
max_words = int(cfg.get("inbox_soft_max_words", 0) or 0)
max_item_words = int(cfg.get("inbox_soft_max_item_words", 0) or 0)

state_path = os.path.join(KB, "STATE.md")
if (max_items <= 0 and max_words <= 0 and max_item_words <= 0) or not os.path.isfile(state_path):
    print("INBOX=-")
    sys.exit(0)

text = open(state_path, encoding="utf-8", errors="replace").read()
heading = re.search(r"(?m)^## Inbox\b.*$", text)
if not heading:
    print("INBOX=-")
    sys.exit(0)

rest = text[heading.end():]
nxt = re.search(r"(?m)^## ", rest)
section = rest[:nxt.start()] if nxt else rest

# Entries that carry the Inbox line format but sit outside the Inbox section.
entry_shape = re.compile(r"(?m)^- \[\d{4}-\d{2}-\d{2}\b")
inbox_span = (heading.start(), heading.end() + len(section))
misfiled = []
current = "(before the first heading)"
for line_match in re.finditer(r"(?m)^.*$", text):
    line = line_match.group()
    if line.startswith("## "):
        current = line[3:].split("(")[0].strip()
    elif entry_shape.match(line) and not (inbox_span[0] <= line_match.start() < inbox_span[1]):
        misfiled.append((current, " ".join(line[2:].split())[:90]))

entries = [e for e in re.split(r"(?m)^(?=- )", section) if e.lstrip().startswith("- ")]
items = len(entries)
words = len(section.split())

fat = []
if max_item_words > 0:
    for e in entries:
        n = len(e.split())
        if n > max_item_words:
            head = " ".join(e.strip().split("\n")[0].split()[1:])
            fat.append((n, head[:90]))
    fat.sort(reverse=True)

over_items = max_items > 0 and items > max_items
over_words = max_words > 0 and words > max_words
if over_items or over_words or fat or misfiled:
    if over_items or over_words or fat:
        print(f"  INBOX-OVER STATE.md (items={items} max={max_items or '-'}, "
              f"words={words} max={max_words or '-'})")
    for n, head in fat[:5]:
        print(f"  INBOX-FAT STATE.md ({n}w > {max_item_words}w) {head}")
    if len(fat) > 5:
        print(f"  INBOX-FAT STATE.md (+{len(fat) - 5} more over {max_item_words}w)")
    if misfiled:
        where = ", ".join(sorted({s for s, _ in misfiled}))
        print(f"  INBOX-MISFILED STATE.md ({len(misfiled)} Inbox-shaped entries outside "
              f"the Inbox section, under: {where}) -- append under the '## Inbox' heading, "
              f"not at the end of the file")
        for sec, head in misfiled[:5]:
            print(f"  INBOX-MISFILED STATE.md (in '{sec}') {head}")
        if len(misfiled) > 5:
            print(f"  INBOX-MISFILED STATE.md (+{len(misfiled) - 5} more)")
    print("INBOX=OVER")
else:
    print("INBOX=OK")
