#!/usr/bin/env python3
"""Rubber-stamp advisory: the inverse of timestamp-drift. Templates say clearing a
staleness flag means recording a real re-verification (`reviewed:`), never a silent
`timestamp:` bump. This flags exactly that: a change whose only semantic frontmatter
effect is moving `timestamp:` forward, with the body untouched, where the new value
moves past both the old value and the date of the page's last real edit. Frontmatter
is compared as a parsed key->value map, so reordered lines or an inserted blank line
cannot disguise the bump.

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

FM_KEY = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")
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


def fm_map(fm_text):
    """Frontmatter as {key: value}, continuation lines attached to their key and
    trailing blank continuation stripped, so neither line order nor a cosmetic blank
    line changes what a key is worth."""
    entries = {}
    key = None
    for line in fm_text.splitlines():
        if line.strip() == "---":
            key = None
            continue
        m = FM_KEY.match(line)
        if m:
            key = m.group(1)
            entries[key] = [m.group(2).strip()]
        elif key is not None:
            entries[key].append(line.rstrip())
    return {k: "\n".join(v).rstrip() for k, v in entries.items()}


def timestamp_only_bump(old_text, new_text):
    """(old_value, new_value) if the ONLY semantic frontmatter difference between
    old_text and new_text is the timestamp: value and the body is untouched; else
    None."""
    if old_text is None or body_changed(old_text, new_text):
        return None
    old_map = fm_map(split_fm(old_text)[0])
    new_map = fm_map(split_fm(new_text)[0])
    if set(old_map) != set(new_map):
        return None
    changed = [k for k in old_map if old_map[k] != new_map[k]]
    if changed != ["timestamp"]:
        return None
    return ((old_map["timestamp"].splitlines() or [""])[0].strip(),
            (new_map["timestamp"].splitlines() or [""])[0].strip())


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
