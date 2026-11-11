#!/usr/bin/env python3
"""Summarize the commit gate's log: attempts, commits, and refusals by check.

    python3 hooks/gate-log.py [WIKI_ROOT] [--weeks N] [--all]

The pre-commit hook writes one line per run to <git-dir>/wiki-gate.log, and wiki-commit adds
the commit an attempt produced. Lines sharing an attempt id are one attempt. Telemetry only:
a quiet log does not show the gate is wired; `wiki gate-proof` does.
"""
import argparse
import collections
import datetime
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wikilib

ap = argparse.ArgumentParser(prog="gate-log")
ap.add_argument("root", nargs="?")
ap.add_argument("--weeks", type=int, default=4)
ap.add_argument("--all", action="store_true", help="list each refused attempt")
a = ap.parse_args()

KB = str(wikilib.resolve_root(a.root))
gd = subprocess.run(["git", "rev-parse", "--git-dir"], cwd=KB, capture_output=True,
                    text=True).stdout.strip()
path = os.path.join(KB, gd, "wiki-gate.log")
if not gd or not os.path.isfile(path):
    print(f"no gate log at {path}: the hook has not run since logging was installed")
    sys.exit(0)

since = (datetime.datetime.now(datetime.timezone.utc)
         - datetime.timedelta(weeks=a.weeks)).strftime("%Y-%m-%dT%H:%M:%SZ")
attempts = collections.OrderedDict()
for line in open(path, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 5 or parts[0] < since:
        continue
    ts, attempt, outcome, checks, ref = parts
    rec = attempts.setdefault(attempt, {"ts": ts, "runs": 0, "refused": set(), "commit": None,
                                        "passed": False})
    if outcome == "committed":
        rec["commit"] = ref
    else:
        rec["runs"] += 1
        if outcome == "refused":
            rec["refused"].update(c for c in checks.split(",") if c)
        else:
            rec["passed"] = True

committed = [r for r in attempts.values() if r["commit"]]
refused = [r for r in attempts.values() if not r["commit"] and not r["passed"]]
unrecorded = [r for r in attempts.values() if not r["commit"] and r["passed"]]
print(f"Gate log since {since[:10]} ({a.weeks} weeks): {path}")
print(f"Attempts: {len(attempts)}  committed: {len(committed)}  refused: {len(refused)}"
      f"  passed with no recorded commit: {len(unrecorded)}")
by_check = collections.Counter(c for r in refused for c in r["refused"])
if by_check:
    print("Refused attempts, by check:")
    for name, n in by_check.most_common():
        print(f"  {name:<22} {n}")
if a.all:
    for r in refused:
        print(f"  {r['ts']}  {','.join(sorted(r['refused']))}")
