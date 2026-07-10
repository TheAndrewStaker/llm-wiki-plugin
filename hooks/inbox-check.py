#!/usr/bin/env python3
"""Inbox soft-cap advisory. STATE.md's `## Inbox` section is meant to be triaged quickly
(into Focus / Up next / ROADMAP / an initiative file); left unattended it quietly becomes
a second, untriaged backlog. This flags when the section's top-level item count or word
count crosses a configured soft cap -- a nudge to triage, never a gate.

Section = the text between the `## Inbox` heading and the next `## ` heading (or end of
file). Items = lines starting `- ` (top-level bullets only). Disabled by default so an
existing wiki is unaffected until it opts in.

Config (wiki.config.json):
    inbox_soft_max_items   max top-level `- ` items before OVER (default 0 = disabled)
    inbox_soft_max_words   max words in the section before OVER (default 0 = disabled)

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

state_path = os.path.join(KB, "STATE.md")
if (max_items <= 0 and max_words <= 0) or not os.path.isfile(state_path):
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

items = len(re.findall(r"(?m)^- ", section))
words = len(section.split())

over_items = max_items > 0 and items > max_items
over_words = max_words > 0 and words > max_words
if over_items or over_words:
    print(f"  INBOX-OVER STATE.md (items={items} max={max_items or '-'}, "
          f"words={words} max={max_words or '-'})")
    print("INBOX=OVER")
else:
    print("INBOX=OK")
