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
keyline = re.compile(r"^([A-Za-z_][\w-]*):[ \t]*(.*)$")
issues, linked = [], set()
broken = unresolved = notype = stale = orphan = badyaml = 0


def bad_yaml_keys(fm_text):
    """Flag frontmatter keys whose value OPENS a flow collection ([..] / {..}) but is malformed
    — the common breakage: a markdown link as a value (`related: [x](../x.md)`) or unbalanced
    brackets, both of which make the whole frontmatter invalid YAML (breaks Obsidian + any parser).
    Deterministic, stdlib-only, conservative: a valid flow sequence like `tags: [a, b]` passes;
    the fix is to quote the value or use a proper YAML list."""
    lines = fm_text.split("\n")
    bad, i = [], 0
    while i < len(lines):
        m = keyline.match(lines[i])
        if not m:
            i += 1
            continue
        key, val = m.group(1), m.group(2).strip()
        if val[:1] in ("[", "{"):
            openc = val[0]
            closec = "]" if openc == "[" else "}"
            acc, j = val, i
            # join continuation lines (a multi-line flow collection) until brackets balance
            while acc.count(openc) > acc.count(closec) and j + 1 < len(lines) \
                    and not keyline.match(lines[j + 1]) and lines[j + 1].strip():
                j += 1
                acc += " " + lines[j].strip()
            acc = re.sub(r"\s+#.*$", "", acc).strip()   # drop a trailing comment
            if acc.count(openc) != acc.count(closec) or not acc.endswith(closec):
                bad.append(key)
            i = j + 1
            continue
        i += 1
    return bad

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
    fmblock = re.match(r"^---\n(.*?)\n---", text, re.S)
    # malformed-YAML frontmatter (checked on every file that has a frontmatter block)
    if fmblock:
        for k in bad_yaml_keys(fmblock.group(1)):
            issues.append(f"  BADYAML {f} (key '{k}': flow value not valid YAML -- quote it or use a list)")
            badyaml += 1
    if not type_exempt(f, b):
        if not (fmblock and re.search(r"^type:\s*\S", fmblock.group(1), re.M)):
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
print(f"CORE broken={broken} unresolved={unresolved} badyaml={badyaml} notype={notype} stale={stale} orphan={orphan}")
