#!/usr/bin/env python3
"""Print which of the given wiki files this session wrote, judged from its transcript.

Used by auto-commit.sh to tell the session that caused a gate failure from the sessions that
merely stopped while it was present. A file counts as written when a Write/Edit/MultiEdit
names it, or a Bash command names it as a redirect target or alongside a write marker (in-place
edit, a file opened for writing, wiki-fm). A read never counts.

Usage: session-touched.py TRANSCRIPT WIKI_ROOT FILE...
Prints one matching FILE per line. Silent on any error.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib  # noqa: E402

def main():
    if len(sys.argv) < 4:
        return
    transcript, kb, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    kb_real = os.path.realpath(kb)
    targets = {f: {os.path.join(kb_real, f), os.path.join(kb, f)} for f in files}
    hit = set()
    with open(transcript, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"tool_use"' not in line:
                continue
            try:
                msg = json.loads(line).get("message") or {}
            except ValueError:
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict) or c.get("type") != "tool_use":
                    continue
                inp = c.get("input") or {}
                name = c.get("name", "")
                if name in ("Write", "Edit", "MultiEdit"):
                    p = inp.get("file_path") or ""
                    real = os.path.realpath(p)
                    for f, forms in targets.items():
                        if p in forms or real in forms:
                            hit.add(f)
                elif name == "Bash":
                    cmd = inp.get("command") or ""
                    for f in files:
                        if wikilib.bash_writes(cmd, f):
                            hit.add(f)
    for f in files:
        if f in hit:
            print(f)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
