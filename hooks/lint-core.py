#!/usr/bin/env python3
"""Deterministic wiki lint, single-pass (fast). Checks: broken relative links, missing
type: frontmatter, commit-gate tokens, stale timestamps, orphan pages, title/alias
collisions (two pages claiming the same name), pages missing from their dir's index.md,
per-type required frontmatter fields, dead-end pages (no outgoing wiki links), live
pages linking a superseded page, and superseded pages chaining to superseded pages.
Always exits 0; lint.sh decides the gate.
Standalone: python3 hooks/lint-core.py [WIKI_ROOT]
Ends with a machine line (all counts on one line):
    CORE broken= unresolved= badyaml= notype= stale= orphan= collision= unindexed=
         missingfield= deadend= staleptr= chain=
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
    return (b in type_exempt_files or b in ("index.md", "log.md") or b.endswith("SKILL.md")
            or wikilib.is_memory(f) or f.startswith(("sources/", "commands/")))


def orphan_exempt(f, b):
    return (b in orphan_exempt_files or b.endswith("index.md") or b.endswith("SKILL.md")
            or wikilib.is_memory(f) or f.startswith(("archive/", "sources/", "commands/")))


mdlink = re.compile(r"\]\(([^)]+)\)")
fence = re.compile(r"^\s*(```|~~~)")
keyline = re.compile(r"^([A-Za-z_][\w-]*):[ \t]*(.*)$")
issues, linked = [], set()
broken = unresolved = notype = stale = orphan = badyaml = collision = unindexed = 0
missingfield = deadend = staleptr = chain = 0

content_dirs = tuple(cfg["content_dirs"])
collision_stop = {s.lower() for s in cfg["collision_exempt"]}
type_reqs = cfg["type_requirements"]
names = {}          # normalized title/alias -> (display, [pages claiming it])
dir_indexes = {}    # content dir -> [its index.md files]
index_targets = {}  # index file -> set of resolved link targets
page_targets = {}   # file -> set of resolved existing link targets
out_md = {}         # file -> count of outgoing wiki (.md) links
superseded = set()  # pages carrying the supersede token / superseded_by:


def content_page(f, b):
    return (f.startswith(content_dirs) and b != "index.md"
            and not f.endswith(".base") and not wikilib.is_memory(f))


fm_aliases = wikilib.fm_aliases


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
    b = os.path.basename(f)
    is_index = b == "index.md" and f.startswith(content_dirs)
    if is_index:
        for cd in content_dirs:
            if f.startswith(cd):
                dir_indexes.setdefault(cd, []).append(f)
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
            if t.endswith(".md"):
                out_md[f] = out_md.get(f, 0) + 1
            tgt = t.lstrip("/") if t.startswith("/") else os.path.normpath(os.path.join(d, t))
            if os.path.exists(tgt):
                linked.add(tgt)
                page_targets.setdefault(f, set()).add(tgt)
                if is_index:
                    index_targets.setdefault(f, set()).add(tgt)
            else:
                issues.append(f"  BROKEN LINK {f} -> {t}")
                broken += 1
    if re.search(r"(?im)^\s*(Status:\s*Unresolved|Contradiction severity:\s*hard)", text):
        issues.append(f"  UNRESOLVED {f}")
        unresolved += 1
    fmblock = re.match(r"^---\n(.*?)\n---", text, re.S)
    # supersede token: search with fences and inline code stripped so a page that merely
    # DOCUMENTS the convention is not marked superseded; superseded_by: must sit in the
    # real frontmatter block
    stripped = re.sub(r"(?s)(```|~~~).*?(\1|\Z)", "", text)
    stripped = re.sub(r"`[^`]*`", "", stripped)
    if (re.search(r"(?im)^\s*Status:\s*Superseded", stripped)
            or (fmblock and re.search(r"^superseded_by:\s*\S", fmblock.group(1), re.M))):
        superseded.add(f)
    # collect the names (title + aliases) each content page claims, for the collision check
    if fmblock and content_page(f, b):
        claimed = set()
        tm = re.search(r"^title:\s*(.+)$", fmblock.group(1), re.M)
        if tm:
            claimed.add(tm.group(1).strip().strip("'\""))
        claimed.update(fm_aliases(fmblock.group(1)))
        for name in claimed:
            norm = re.sub(r"\s+", " ", name).strip().lower()
            if len(norm) >= 3 and norm not in collision_stop:
                names.setdefault(norm, (name, []))[1].append(f)
    # per-type required frontmatter (Wikidata-style constraint: a hint, not a gate)
    if fmblock and content_page(f, b):
        tv = re.search(r"^type:\s*(\S+)", fmblock.group(1), re.M)
        for field in (type_reqs.get(tv.group(1), []) if tv else []):
            if not re.search(rf"^{re.escape(field)}:\s*\S", fmblock.group(1), re.M):
                issues.append(f"  MISSING-FIELD {f} (type {tv.group(1)} expects {field}:)")
                missingfield += 1
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

# collision: the same title/alias claimed by more than one content page breaks
# "one home per fact" (and makes search/alias resolution ambiguous). Advisory.
for norm in sorted(names):
    disp, pages = names[norm]
    if len(set(pages)) > 1:
        issues.append(f"  COLLISION \"{disp}\" -> {', '.join(sorted(set(pages)))}")
        collision += 1

# index drift: every content page should be reachable from an index.md of its own
# type-dir (Ingest contract step 4). Dirs without any index.md are skipped. Advisory.
for cd, idxs in sorted(dir_indexes.items()):
    reachable = set()
    for idx in idxs:
        reachable |= index_targets.get(idx, set())
    for f in files:
        if content_page(f, os.path.basename(f)) and f.startswith(cd) and f not in reachable:
            issues.append(f"  UNINDEXED {f} (not linked from an index.md under {cd})")
            unindexed += 1

# dead end: a content page with zero outgoing wiki links contributes nothing to the
# graph; a weak-crosslink signal for reflect. Advisory.
for f in files:
    if content_page(f, os.path.basename(f)) and f not in superseded and not out_md.get(f):
        issues.append(f"  DEADEND {f} (no outgoing wiki links)")
        deadend += 1

# supersede hygiene: live content should link the successor, not the superseded page;
# and a superseded page's pointer should not target another superseded page. Advisory.
for f in files:
    for t in sorted(page_targets.get(f, ())):
        if t not in superseded:
            continue
        if f in superseded:
            issues.append(f"  CHAIN {f} -> {t} (superseded points at superseded; collapse the chain)")
            chain += 1
        elif content_page(f, os.path.basename(f)):
            issues.append(f"  STALE-POINTER {f} -> {t} (superseded; link the successor)")
            staleptr += 1

for line in issues:
    print(line)
print(f"CORE broken={broken} unresolved={unresolved} badyaml={badyaml} notype={notype} "
      f"stale={stale} orphan={orphan} collision={collision} unindexed={unindexed} "
      f"missingfield={missingfield} deadend={deadend} staleptr={staleptr} chain={chain}")
