#!/usr/bin/env python3
"""Point-of-contact reconcile nudge: when a content page changes, the pages that LINK TO
it may now state stale claims about it (they summarize or depend on what it says). This
prints, per changed page, its inbound linkers that were NOT edited alongside it, so the
committer reconciles them or consciously leaves them.

Each linker carries WHY it is listed, because "reconcile or leave" with no reason is a
coin flip an agent cannot act on:

  RESTATES  the linker repeats a value the change touched (a figure, id, date, SHA).
            Highest confidence: the page probably now contradicts its source.
  SYNTHESIS the linker declares the changed page in synthesized_from:, so it was written
            from it.
  MENTIONS  the linker only points at the changed page. Usually nothing to do.

Cosmetic edits do not nudge. A change confined to frontmatter, or that survives `git diff
-w` as nothing, is not a claim change, and nudging on it is what turns a dense link graph
into an unreadable wall.

Deterministic and bounded (never the whole wiki): changed set = staged files by default
(the pre-commit case), else the last commit; override with --range A..B. Linkers exclude
the changed set itself, per-dir index.md files, landmark singletons (STATE/KNOWLEDGE/
ROADMAP/CLAUDE), and archive/ (append-only, never reconciled). Output capped so this
stays a nudge, not a wall; the machine line carries the true count.

Advisory only, always exits 0. Standalone: python3 hooks/neighbor-scope.py [--range A..B] [WIKI_ROOT]
Ends with: NEIGHBORS=<n>
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

CAP = 10
a = sys.argv[1:]
rng = None
if "--range" in a:
    i = a.index("--range")
    if i + 1 >= len(a):
        print("neighbor-scope: --range requires A..B", file=sys.stderr)
        sys.exit(2)
    rng = a[i + 1]
    del a[i:i + 2]
KB = wikilib.resolve_root(a[0] if a else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)
content_dirs = tuple(cfg["content_dirs"])
landmarks = set(cfg["landmark_files"]) | {"CLAUDE.md"}


def git(*args):
    return subprocess.run(["git", *args], cwd=KB, capture_output=True, text=True).stdout


def git_names(*args):
    return [f for f in git(*args, "--", "*.md").splitlines() if f]


if rng:
    changed = git_names("diff", "--name-only", rng)
    diff_args = ["diff", "-w", rng]
else:
    changed = git_names("diff", "--cached", "--name-only")
    diff_args = ["diff", "-w", "--cached"]
    if not changed:
        changed = git_names("diff", "--name-only", "HEAD~1..HEAD")
        diff_args = ["diff", "-w", "HEAD~1..HEAD"]
changed = set(changed)

# A value worth re-checking elsewhere: figures, ids, dates, SHAs. Structure is what makes
# one distinctive, so require punctuation, a unit suffix, a # or a full date. A bare run of
# digits carries nothing on its own, and a bare year carries less than nothing: "2026"
# appears on almost every page, so admitting it would mark the whole wiki as restating.
VALUE = re.compile(
    r"#\d+"                      # PR / issue
    r"|\b[0-9a-f]{7,40}\b"       # SHA
    r"|\b\d{4}-\d{2}-\d{2}\b"    # ISO date
    r"|\b\d[\d,]*\.\d+[A-Za-z%]*\b"  # decimal, optionally suffixed
    r"|\b\d[\d,]*,\d{3}[A-Za-z%]*\b"  # thousands-separated
    r"|\b\d+[A-Za-z%]+\b"        # 4B, 75th, 20%
)
YEAR = re.compile(r"^(19|20)\d{2}$")


def body_changes(page):
    """Values the change touched, or None when the edit is cosmetic (frontmatter only,
    or nothing at all under -w)."""
    out = git(*diff_args, "--", page)
    if not out.strip():
        return None
    touched, substantive, fm_depth = set(), False, 0
    for line in out.split("\n"):
        if line.startswith(("+++", "---", "@@", "diff ", "index ")):
            continue
        if line[:1] not in "+-":
            continue
        payload = line[1:]
        if payload.strip() == "---":
            fm_depth += 1
            continue
        # frontmatter is the first --- ... --- pair; a key: line inside it is not a claim
        if fm_depth < 2 and re.match(r"^\s*[\w-]+:", payload):
            continue
        if payload.strip():
            substantive = True
            touched.update(v for v in VALUE.findall(payload) if not YEAR.match(v))
    return touched if substantive else None


targets = {}
for f in changed:
    if not f.startswith(content_dirs) or os.path.basename(f) == "index.md":
        continue
    vals = body_changes(f)
    if vals is None:
        continue
    targets[f] = vals

if not targets:
    print("NEIGHBORS=0")
    sys.exit(0)

mdlink = re.compile(r"\]\(([^)]+)\)")
fence = re.compile(r"^\s*(```|~~~)")
inbound = {}  # changed page -> {linker: reason}

for f in wikilib.corpus_files(KB, cfg):
    b = os.path.basename(f)
    if (f in changed or b == "index.md" or b in landmarks
            or f.startswith("archive/")):
        continue
    d = os.path.dirname(f)
    raw = wikilib.read(KB, f)
    sources = set()
    for s in wikilib.frontmatter_values(raw, "synthesized_from"):
        sources.add(os.path.normpath(os.path.join(d, s)).replace(os.sep, "/"))
    in_fence = False
    for line in raw.split("\n"):
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in mdlink.finditer(re.sub(r"`[^`]*`", "", line)):
            parts = m.group(1).split()
            if not parts:
                continue
            t = parts[0].split("#")[0]
            if not t or t.startswith(("http://", "https://", "mailto:", "tel:", "ftp:")):
                continue
            tgt = t.lstrip("/") if t.startswith("/") else os.path.normpath(os.path.join(d, t)).replace(os.sep, "/")
            if tgt not in targets:
                continue
            shared = sorted(v for v in targets[tgt] if v and v in raw)
            if shared:
                reason = f"RESTATES {', '.join(shared[:3])}"
            elif tgt in sources:
                reason = "SYNTHESIS synthesized_from names it"
            else:
                reason = "MENTIONS"
            # a stronger reason found later must win
            prev = inbound.setdefault(tgt, {}).get(f, "")
            if not prev or prev.startswith("MENTIONS") or reason.startswith("RESTATES"):
                inbound[tgt][f] = reason

rank = {"R": 0, "S": 1, "M": 2}
lines = []
for tgt in sorted(inbound):
    for linker, reason in sorted(inbound[tgt].items(), key=lambda kv: (rank[kv[1][0]], kv[0])):
        lines.append(f"  NEIGHBOR {linker} links {tgt} ({reason}) -- reconcile or consciously leave")
for line in lines[:CAP]:
    print(line)
if len(lines) > CAP:
    print(f"  NEIGHBOR ... and {len(lines) - CAP} more (run standalone for the full list)")
print(f"NEIGHBORS={len(lines)}")
