#!/usr/bin/env python3
"""Link the first plain-text mention of a page that a prose page never links.

The companion to missed-links.py: that one reports, this one fixes. Detection is shared
via wikilib.missed_mentions, so the report and the repair can never disagree about what
counts as a mention. One link per (page, target), at the first eligible occurrence, which
is exactly what clears the advisory.

Never edits inside frontmatter, fenced code, inline code, an existing link, a URL, a
heading, or a blockquote. Blockquotes matter most: they carry verbatim quotes of other
people, and inserting a link into one silently rewrites what someone said.

Dry-run by default (prints the plan with context); --apply writes in place.
Usage: python3 hooks/link-mentions.py [WIKI_ROOT] [--apply] [--page PATH] [--limit N]
Ends with: LINKED=<insertions> FILES=<files> APPLIED=<0|1>
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

args = sys.argv[1:]
apply_ = "--apply" in args
args = [a for a in args if a != "--apply"]
only_page = limit = None
for flag, cast in (("--page", str), ("--limit", int)):
    if flag in args:
        i = args.index(flag)
        if i + 1 >= len(args):
            print(f"link-mentions: {flag} needs a value", file=sys.stderr)
            sys.exit(2)
        val = cast(args[i + 1])
        if flag == "--page":
            only_page = val
        else:
            limit = val
        del args[i:i + 2]

KB = wikilib.resolve_root(args[0] if args else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)

FENCE = re.compile(r"^\s*(```|~~~)")
SKIP_LINE = re.compile(r"^\s*(#{1,6}\s|>|\||\s*-\s*\[[ xX]\]\s*$)")
PROTECTED = re.compile(r"`[^`]*`|\[\[[^\]]*\]\]|\[[^\]]*\]\([^)]*\)|<[^>]+>|https?://\S+")


def insert(raw, term, target_rel):
    """Return (new_text, context) with term's first eligible mention linked, or None."""
    lines = raw.split("\n")
    body = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                body = i + 1
                break
    pat = wikilib.mention_re(term)
    in_fence = False
    for i in range(body, len(lines)):
        line = lines[i]
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence or SKIP_LINE.match(line) or not line.strip():
            continue
        spans = [m.span() for m in PROTECTED.finditer(line)]
        for m in pat.finditer(line):
            if any(s <= m.start() < e or s < m.end() <= e for s, e in spans):
                continue
            shown = m.group(0)
            lines[i] = f"{line[:m.start()]}[{shown}]({target_rel}){line[m.end():]}"
            return "\n".join(lines), lines[i].strip()[:100]
    return None


files = wikilib.corpus_files(KB, cfg)
edits = {}
plan = []
for f, disp, page, _ in wikilib.missed_mentions(KB, cfg, files):
    if only_page and f != only_page:
        continue
    if limit is not None and len(plan) >= limit:
        break
    raw = edits.get(f) or wikilib.read(KB, f)
    rel = os.path.relpath(page, os.path.dirname(f) or ".").replace(os.sep, "/")
    got = insert(raw, disp, rel)
    if not got:
        continue
    edits[f] = got[0]
    plan.append((f, disp, rel, got[1]))

for f, disp, rel, ctx in plan:
    print(f"  LINK {f}  {disp} -> {rel}")
    print(f"       {ctx}")

if apply_:
    for f, text in edits.items():
        with open(os.path.join(KB, f), "w", encoding="utf-8") as fh:
            fh.write(text)

print(f"LINKED={len(plan)} FILES={len(edits)} APPLIED={1 if apply_ else 0}")
