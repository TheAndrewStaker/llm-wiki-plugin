#!/usr/bin/env python3
"""Timestamp-drift advisory: the mirror image of lint-core's STALE check. STALE flags a
page whose declared date is old relative to TODAY; this flags a page whose real git
activity has moved on WITHOUT the declared date following -- content that was edited
after the page claimed to be reviewed/timestamped, a sign `reviewed:`/`timestamp:` was
never bumped to match.

Declared date = frontmatter `reviewed:` if present, else `timestamp:`. Last-edit date =
the most recent commit that touched the file, EXCLUDING commits whose subject matches
config `drift_exempt_commit_pattern` (default "session auto-save": routine autosave
commits are not a real edit). Built in ONE `git log --name-only` pass (newest-first) into
a file -> last-nonexempt-commit-date map -- no per-file git calls.

Config (wiki.config.json):
    timestamp_drift_days         drift threshold in days (default 0 = disabled)
    drift_exempt_commit_pattern  regex (case-insensitive) on commit subject to ignore
                                  (default "session auto-save")

Advisory only, always exits 0. Standalone: python3 hooks/timestamp-drift.py [WIKI_ROOT]
Ends with: DRIFT=<n>
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
DRIFT_DAYS = int(cfg.get("timestamp_drift_days", 0) or 0)
EXEMPT_RE = re.compile(cfg.get("drift_exempt_commit_pattern", "session auto-save"), re.I)

drift = 0
issues = []

if DRIFT_DAYS > 0:
    out = subprocess.run(
        ["git", "log", "--name-only", "--format=@@%cs\x1f%s"],
        cwd=KB, capture_output=True, text=True,
    ).stdout

    # ONE pass, newest-first: for each file, remember the date of the first (= most
    # recent) commit that touches it whose subject is NOT exempt. Exempt commits are
    # skipped entirely -- they neither set nor block an earlier real edit from being found.
    last_date = {}
    exempt = True
    date = None
    for line in out.split("\n"):
        if line.startswith("@@"):
            date, _, subject = line[2:].partition("\x1f")
            exempt = bool(EXEMPT_RE.search(subject))
            continue
        path = line.strip()
        if not path or exempt or date is None:
            continue
        last_date.setdefault(path, date)

    for f in wikilib.git_files(KB):
        text = wikilib.read(KB, f)
        declared = (wikilib.frontmatter_value(text, "reviewed")
                    or wikilib.frontmatter_value(text, "timestamp"))
        last = last_date.get(f)
        if not declared or not last:
            continue
        try:
            d0 = datetime.date.fromisoformat(declared[:10])
            d1 = datetime.date.fromisoformat(last[:10])
        except ValueError:
            continue
        age = (d1 - d0).days
        if age > DRIFT_DAYS:
            issues.append((f, declared[:10], last[:10], age))
            drift += 1

for f, declared, last, age in sorted(issues):
    print(f"  DRIFT {f} (declared {declared}; last edit {last}, +{age}d > {DRIFT_DAYS}d cap)")
print(f"DRIFT={drift}")
