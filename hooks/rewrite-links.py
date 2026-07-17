#!/usr/bin/env python3
"""Deterministic inbound-link rewrite: repoint every markdown link that resolves to OLD so
it resolves to NEW instead. Used by the merge-split skill after folding a duplicate page
into its survivor, and on any page rename. Dry-run by default (prints the plan); --apply
writes files in place. Anchors (#section) and link titles are preserved; links inside code
fences and inline code are left alone; a file that is not valid UTF-8 is skipped with a
warning rather than rewritten. OLD and NEW are wiki-root-relative paths.
Usage: python3 hooks/rewrite-links.py OLD.md NEW.md [WIKI_ROOT] [--apply]
Ends with: REWRITES=<links> FILES=<files> APPLIED=<0|1>
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

args = sys.argv[1:]
apply_ = "--apply" in args
args = [a for a in args if a != "--apply"]
if len(args) < 2:
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)
old = os.path.normpath(args[0])
new = os.path.normpath(args[1])
KB = wikilib.resolve_root(args[2] if len(args) > 2 else None)
os.chdir(KB)
if old == new:
    print("rewrite-links: OLD and NEW are the same path", file=sys.stderr)
    sys.exit(2)
if not os.path.exists(new):
    print(f"# warning: NEW target {new} does not exist (yet)", file=sys.stderr)

mdlink = re.compile(r"\]\(([^)]+)\)")
fence = re.compile(r"^\s*(```|~~~)")
total = 0
changed_files = 0

for f in wikilib.git_files(KB):
    try:
        raw = open(f, "rb").read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        print(f"# skipped {f} (unreadable or not UTF-8)", file=sys.stderr)
        continue
    d = os.path.dirname(f)
    hits = 0

    def repl(m):
        global hits
        inner = m.group(1)
        parts = inner.split()
        if not parts:
            return m.group(0)
        t = parts[0]
        base = t.split("#")[0]
        anchor = t[len(base):]
        if not base or base.startswith(("http://", "https://", "mailto:", "tel:", "ftp:")):
            return m.group(0)
        resolved = base.lstrip("/") if base.startswith("/") else os.path.normpath(os.path.join(d, base))
        if os.path.normpath(resolved) != old:
            return m.group(0)
        newlink = ("/" + new if base.startswith("/")
                   else os.path.relpath(new, d or ".")).replace(os.sep, "/")
        i = inner.find(t)
        hits += 1
        return "](" + inner[:i] + newlink + anchor + inner[i + len(t):] + ")"

    out, in_fence = [], False
    for line in raw.split("\n"):
        if fence.match(line):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        segs = re.split(r"(`[^`]*`)", line)
        for i, seg in enumerate(segs):
            if not seg.startswith("`"):
                segs[i] = mdlink.sub(repl, seg)
        out.append("".join(segs))
    if hits:
        total += hits
        changed_files += 1
        print(f"  REWRITE {f} ({hits} link{'s' if hits > 1 else ''} -> {new})")
        if apply_:
            with open(f, "w", encoding="utf-8") as fh:
                fh.write("\n".join(out))

print(f"REWRITES={total} FILES={changed_files} APPLIED={1 if apply_ else 0}")
