#!/usr/bin/env python3
"""Deterministic wiki lint, single-pass (fast). Checks: broken relative links, missing
type: frontmatter, commit-gate tokens, stale timestamps, orphan pages. Always exits 0;
lint.sh decides the gate. Standalone: python3 hooks/lint-core.py [WIKI_ROOT]
Ends with a machine line:
    CORE broken=<n> unresolved=<n> notype=<n> stale=<n> orphan=<n>
"""
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
STALE_DAYS = int(os.environ.get("STALE_DAYS", cfg["stale_days"]))
os.chdir(KB)
files = wikilib.git_files(KB)
today = datetime.date.today()

landmarks = set(cfg["landmark_files"])
type_exempt_files = landmarks | set(cfg["type_exempt_extra"]) | {"CLAUDE.md"}
orphan_exempt_files = landmarks | set(cfg["orphan_exempt_extra"]) | {"MEMORY.md", "README.md"}


def type_exempt(f, b):
    return (b in type_exempt_files or b.endswith("SKILL.md")
            or wikilib.is_memory(f) or f.startswith(("sources/", "commands/")))


def orphan_exempt(f, b):
    return (b in orphan_exempt_files or b.endswith("index.md") or b.endswith("SKILL.md")
            or wikilib.is_memory(f) or f.startswith(("archive/", "sources/", "commands/")))


mdlink = re.compile(r"\]\(([^)]+)\)")
fence = re.compile(r"^\s*(```|~~~)")
issues, linked = [], set()
broken = unresolved = notype = stale = orphan = 0

for f in files:
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    d = os.path.dirname(f)
    in_fence = False
    for line in text.split("\n"):
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in mdlink.finditer(re.sub(r"`[^`]*`", "", line)):
            parts = m.group(1).split()
            if not parts:  # whitespace-only target like [x](  ) -> not a link
                continue
            t = parts[0].split("#")[0]
            if not t or t.startswith(("http://", "https://", "mailto:", "tel:", "ftp:")):
                continue
            tgt = t.lstrip("/") if t.startswith("/") else os.path.normpath(os.path.join(d, t))
            if os.path.exists(tgt):
                linked.add(tgt)
            else:
                issues.append(f"  BROKEN LINK {f} -> {t}")
                broken += 1
    if re.search(r"(?im)^\s*(Status:\s*Unresolved|Contradiction severity:\s*hard)", text):
        issues.append(f"  UNRESOLVED {f}")
        unresolved += 1
    b = os.path.basename(f)
    if not type_exempt(f, b):
        fm = re.match(r"^---\n(.*?)\n---", text, re.S)
        if not (fm and re.search(r"^type:\s*\S", fm.group(1), re.M)):
            issues.append(f"  NO type: {f}")
            notype += 1
    m = re.search(r"^timestamp:\s*(\d{4}-\d{2}-\d{2})", text[:1000], re.M)
    if m:
        try:
            age = (today - datetime.date.fromisoformat(m.group(1))).days
            if age > STALE_DAYS:
                issues.append(f"  STALE {f} ({age}d)")
                stale += 1
        except ValueError:
            pass

for f in files:
    if orphan_exempt(f, os.path.basename(f)):
        continue
    if f not in linked:
        issues.append(f"  ORPHAN {f}")
        orphan += 1

for line in issues:
    print(line)
print(f"CORE broken={broken} unresolved={unresolved} notype={notype} stale={stale} orphan={orphan}")
