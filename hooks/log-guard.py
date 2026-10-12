#!/usr/bin/env python3
"""Stop-hook log guard: the one deterministic check that work left a trace in the wiki.

Reads the session's event record written by session-record.py and prints the block reason
when at least log_guard.min_work `work` events follow the last `log` event; prints nothing
otherwise. auto-commit.sh turns a non-empty reason into one exit-2 block (never on a
continuation, so a stop chain blocks at most once). `--clear` deletes the record
(SessionEnd). Off unless log_guard.enabled is true. Silent on any error.

Standalone: printf '{"session_id":"..."}' | log-guard.py [WIKI_ROOT] [--clear]
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib


def pending_work(path):
    pending = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t", 2)
                if len(parts) != 3:
                    continue
                if parts[1] == "log":
                    pending = []
                elif parts[1] == "work":
                    pending.append(parts[2])
    except OSError:
        return []
    return pending


def main():
    args = [a for a in sys.argv[1:] if a != "--clear"]
    clear = "--clear" in sys.argv
    kb = wikilib.resolve_root(args[0] if args else None)
    conf = wikilib.log_guard_config(wikilib.load_config(kb))
    if not conf.get("enabled"):
        return 0
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    sid = re.sub(r"[^A-Za-z0-9._-]", "", str(payload.get("session_id") or ""))
    if not sid:
        return 0
    path = os.path.join(wikilib.state_dir(kb), "sessions", sid + ".tsv")
    if clear:
        try:
            os.remove(path)
        except OSError:
            pass
        return 0
    pending = pending_work(path)
    if len(pending) < max(1, int(conf.get("min_work") or 1)):
        return 0
    shown = "; ".join(pending[-5:])
    log_dirs = ", ".join(conf["log_dirs"])
    print(f"wiki: {len(pending)} work event(s) since this session last wrote to the wiki's "
          f"{log_dirs}: {shown}")
    print("Before stopping, record where the work stands, with one of:")
    print(f"  wiki-fm set {kb}/initiatives/<page>.md next=\"<what is true and open now>\""
          " (add verify=, or waiting_on=/ask= when blocked)")
    print(f"  {kb}/hooks/journal-append.sh \"HH:MM · <slug> · <what happened>\"")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
