#!/usr/bin/env python3
"""Frontmatter cross-parser portability lint. The wiki is read by YAML 1.1 parsers
(PyYAML), YAML 1.2 parsers (js-yaml v4, Obsidian), and line-based scanners (wikilib,
wiki-query's catalog), so frontmatter must lint to the INTERSECTION of what they all
agree on. Deterministic, stdlib-only, line-based (deliberately not PyYAML: adopting one
parser's semantics is the bug this guards against).

Checks (frontmatter block only, per tracked page):
  DUPKEY      duplicate top-level key -- every major parser silently last-wins, so one
              value is lost invisibly (hard-gate material)
  TAB         tab character inside the block -- illegal YAML indentation, failure mode
              differs per parser (hard-gate material)
  AMBIG       unquoted scalar that type-flips between YAML 1.1 and 1.2: the Norway
              problem (yes/no/on/off), sexagesimal NN:NN, leading * or & (alias/anchor)
  SINGULAR    deprecated singular keys tag:/alias:/cssclass: -- Obsidian 1.9 removed
              them; plural list forms are the OKF/Obsidian convention
  NONLIST     tags:/aliases: value that is neither a flow list [..] nor a block list
  DESC        description: not a single plain line under 200 chars -- it is the level-1
              retrieval surface; folded/multiline values read as EMPTY to the line-based
              catalog and to agents scanning frontmatter
  TITLECOLON  unquoted title:/description: containing ": " -- parses as a nested
              mapping or errors, silently breaking the page's whole frontmatter

Bare ISO dates (timestamp: 2026-07-16) are deliberately NOT flagged: they are the
wiki's own convention; 1.1 parsers see a date object and 1.2 a string, but both
round-trip the same text and the lint/catalog layer only ever compares text.

Advisory only, always exits 0; lint.sh decides the gate. Standalone:
    python3 hooks/frontmatter-portability.py [WIKI_ROOT]
Ends with a machine line:
    PORT dupkey=<n> tab=<n> ambig=<n> singular=<n> nonlist=<n> desc=<n> titlecolon=<n>
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
os.chdir(KB)
files = wikilib.git_files(KB)

keyline = re.compile(r"^([A-Za-z_][\w-]*):[ \t]*(.*)$")
quoted = re.compile(r"""^(['"]).*\1$""")
ambig_word = {"yes", "no", "on", "off"}
sexagesimal = re.compile(r"^\d+:\d+(:\d+)*$")

dupkey = tab = ambig = singular = nonlist = desc = titlecolon = 0
issues = []


def flag(kind, f, detail):
    issues.append(f"  PORT-{kind} {f} ({detail})")


for f in files:
    if f.startswith("sources/") or wikilib.is_memory(f):
        continue
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        continue
    block = m.group(1)
    lines = block.split("\n")
    if "\t" in block:
        flag("TAB", f, "tab character in frontmatter; YAML forbids tab indentation")
        tab += 1
    seen = {}
    for i, line in enumerate(lines):
        km = keyline.match(line)
        if not km:
            continue
        key, val = km.group(1), km.group(2).strip()
        val = re.sub(r"\s+#.*$", "", val).strip()  # trailing comment
        if key in seen:
            flag("DUPKEY", f, f"key '{key}' repeated; parsers keep only the last value")
            dupkey += 1
        seen[key] = val
        if key in ("tag", "alias", "cssclass"):
            flag("SINGULAR", f, f"'{key}:' was removed in Obsidian 1.9; use plural '{key}s{'es' if key == 'alias' else ''}:'".replace("aliass", "alias"))
            singular += 1
        if key in ("tags", "aliases"):
            if val and not val.startswith("["):
                flag("NONLIST", f, f"'{key}:' should be a YAML list ([a, b] or block list), got scalar '{val[:40]}'")
                nonlist += 1
            elif not val:
                nxt = lines[i + 1].lstrip() if i + 1 < len(lines) else ""
                if not nxt.startswith("- "):
                    flag("NONLIST", f, f"'{key}:' is empty and no block-list items follow")
                    nonlist += 1
        if val and not quoted.match(val):
            if val.lower() in ambig_word:
                flag("AMBIG", f, f"'{key}: {val}' is a boolean in YAML 1.1 but a string in 1.2; quote it")
                ambig += 1
            elif sexagesimal.match(val) and key != "timestamp":
                flag("AMBIG", f, f"'{key}: {val}' parses base-60 in YAML 1.1; quote it")
                ambig += 1
            elif val[0] in "*&":
                flag("AMBIG", f, f"'{key}:' value starts with '{val[0]}' (YAML alias/anchor); quote it")
                ambig += 1
        if key in ("title", "description") and val and not quoted.match(val) and ": " in val:
            flag("TITLECOLON", f, f"unquoted '{key}:' contains ': ' -- breaks the whole frontmatter in strict parsers; quote the value")
            titlecolon += 1
        if key == "description":
            if not val or val in (">", ">-", "|", "|-"):
                flag("DESC", f, "description is folded/multiline; line-based catalogs and agents scanning frontmatter see it as empty -- make it one plain line")
                desc += 1
            elif len(val) > 200:
                flag("DESC", f, f"description is {len(val)} chars; keep the level-1 retrieval line under 200")
                desc += 1

for line in issues:
    print(line)
print(f"PORT dupkey={dupkey} tab={tab} ambig={ambig} singular={singular} "
      f"nonlist={nonlist} desc={desc} titlecolon={titlecolon}")
