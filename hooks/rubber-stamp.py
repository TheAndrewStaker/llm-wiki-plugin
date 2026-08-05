#!/usr/bin/env python3
"""Rubber-stamp advisory: the inverse of timestamp-drift. Templates say clearing a
staleness flag means recording a real re-verification (`reviewed:`), never a silent
`timestamp:` bump. This flags exactly that: a change whose diff touches nothing but a
page's frontmatter `timestamp:` line, where the new value moves forward past both the
old value and the date of the page's last real (non-frontmatter) edit.

Diff-driven, like stale-source.py: staged changes (`git diff --cached`) when any exist,
else the last commit (`HEAD~1..HEAD`).

Not flagged (all legitimate):
  - a timestamp: change accompanied by any body-content change (a real, dated edit).
  - a reviewed:-only bump (reviewed: IS the sanctioned way to record re-verification).
  - a timestamp: corrected BACKWARD to match git history (drift reconciliation, not a
    stamp forward past work that never happened).

Config (wiki.config.json):
    drift_exempt_commit_pattern  regex (case-insensitive) on commit subject to ignore
                                 when finding the last real edit (default "session
                                 auto-save"), shared with timestamp-drift.py.

Advisory only, always exits 0. Standalone: python3 hooks/rubber-stamp.py [WIKI_ROOT]
Ends with: RUBBER-STAMP=<n>
"""
import datetime
import difflib
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
EXEMPT_RE = re.compile(cfg.get("drift_exempt_commit_pattern", "session auto-save"), re.I)
content_dirs = tuple(cfg["content_dirs"])

TS_LINE = re.compile(r"^timestamp:[ \t]*(.+)$")
FM_RE = re.compile(r"^(---\n.*?\n---\n?)(.*)$", re.S)


def sh(*a):
    return subprocess.run(a, cwd=KB, capture_output=True, text=True)


def content_page(f):
    b = os.path.basename(f)
    return (f.endswith(".md") and f.startswith(content_dirs) and b != "index.md"
            and not f.endswith(".base") and not wikilib.is_memory(f))


def show(ref, path):
    r = sh("git", "show", f"{ref}:{path}")
    return r.stdout if r.returncode == 0 else None


def split_fm(text):
    m = FM_RE.match(text or "")
    return (m.group(1), m.group(2)) if m else ("", text or "")


def body_changed(old_text, new_text):
    if old_text is None:
        return True
    _, old_body = split_fm(old_text)
    _, new_body = split_fm(new_text)
    return old_body != new_body


def timestamp_only_bump(old_text, new_text):
    """(old_value, new_value) if the ONLY frontmatter difference between old_text and
    new_text is a single changed timestamp: line and the body is untouched; else None."""
    if old_text is None or body_changed(old_text, new_text):
        return None
    old_fm, _ = split_fm(old_text)
    new_fm, _ = split_fm(new_text)
    if old_fm == new_fm:
        return None
    removed, added = [], []
    for line in difflib.ndiff(old_fm.splitlines(), new_fm.splitlines()):
        code, content = line[:2], line[2:]
        if code == "- ":
            removed.append(content)
        elif code == "+ ":
            added.append(content)
        # "  " (context) and "? " (hint) lines carry no change of their own.
    if len(removed) != 1 or len(added) != 1:
        return None
    rm, am = TS_LINE.match(removed[0]), TS_LINE.match(added[0])
    if not rm or not am:
        return None
    return rm.group(1).strip(), am.group(1).strip()


def last_real_edit(path, skip_hash):
    """Date of the most recent commit whose diff for `path` changed body content (not
    just frontmatter), skipping skip_hash itself and drift_exempt_commit_pattern
    commits -- those neither count as a real edit nor block an earlier one from being
    found, matching timestamp-drift.py's exemption semantics."""
    log = sh("git", "log", "--format=%H\x1f%cs\x1f%s", "--", path).stdout
    for line in log.splitlines():
        if not line:
            continue
        h, date, subject = line.split("\x1f", 2)
        if h == skip_hash or EXEMPT_RE.search(subject):
            continue
        if body_changed(show(f"{h}~1", path), show(h, path)):
            return date
    return None


staged = [f for f in sh("git", "diff", "--cached", "--name-only", "--no-renames")
          .stdout.splitlines() if f]
if staged:
    changed, target_hash, old_ref, new_ref = staged, None, "HEAD", ""
else:
    r = sh("git", "diff", "--name-only", "--no-renames", "HEAD~1..HEAD")
    changed = [f for f in r.stdout.splitlines() if f] if r.returncode == 0 else []
    target_hash = sh("git", "rev-parse", "HEAD").stdout.strip() or None
    old_ref, new_ref = "HEAD~1", "HEAD"

issues = []
for f in changed:
    if not content_page(f):
        continue
    bump = timestamp_only_bump(show(old_ref, f), show(new_ref, f))
    if not bump:
        continue
    old_val, new_val = bump
    try:
        d_old = datetime.date.fromisoformat(old_val[:10])
        d_new = datetime.date.fromisoformat(new_val[:10])
    except ValueError:
        continue
    if d_new <= d_old:
        continue
    last = last_real_edit(f, target_hash)
    if not last:
        continue
    try:
        d_last = datetime.date.fromisoformat(last[:10])
    except ValueError:
        continue
    if d_new > d_last:
        issues.append((f, old_val, new_val, last))

for f, old_val, new_val, last in sorted(issues):
    print(f"  RUBBER-STAMP {f} (timestamp {old_val} -> {new_val}, but last real edit "
          f"{last}; bump records no re-verification)")
print(f"RUBBER-STAMP={len(issues)}")
