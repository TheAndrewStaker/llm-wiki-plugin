#!/usr/bin/env python3
"""PostToolUse hook: record a session's work and log events for the Stop-hook log guard.

One line per event, appended to <state-dir>/sessions/<session_id>.tsv as
`<epoch>\t<kind>\t<detail>`. kind is `work` (a command matching log_guard.work_commands,
such as a commit or a PR, run outside the wiki; or, with work_writes, a file write outside
the wiki) or `log` (a Write/Edit under log_guard.log_dirs, a command from
log_guard.log_commands that did not report a refusal, or a visible Bash write to an
initiatives/ page). Subagent tool calls reach this hook on the parent's session_id, so
delegated work and delegated logging both count.

The hook is a recorder only; log-guard.py reads the file at Stop. Off unless
log_guard.enabled is true. Silent with exit 0 on everything, errors included.
Standalone: printf '<hook json>' | session-record.py [WIKI_ROOT]
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")


def classify(payload, kb, conf):
    name = payload.get("tool_name") or ""
    inp = payload.get("tool_input") or {}
    kb_real = os.path.realpath(kb)
    if name in WRITE_TOOLS:
        p = inp.get("file_path") or inp.get("notebook_path") or ""
        if not p:
            return None
        real = os.path.realpath(os.path.expanduser(p))
        if real == kb_real or real.startswith(kb_real + os.sep):
            rel = os.path.relpath(real, kb_real)
            return ("log", rel) if rel.startswith(tuple(conf["log_dirs"])) else None
        if conf["work_writes"] and not real.startswith(tuple(conf["ignore_write_prefixes"])):
            return ("work", real)
        return None
    if name != "Bash":
        return None
    cmd = inp.get("command") or ""
    first = cmd.strip().split("\n")[0][:120]
    resp = payload.get("tool_response")
    text = resp if isinstance(resp, str) else (json.dumps(resp) if resp is not None else "")
    if any(k in cmd for k in conf["log_commands"]):
        return None if "wiki-fm: refused" in text else ("log", first)
    for tok in sorted(set(re.findall(r"[\w./~-]*initiatives/[\w.-]+\.md", cmd))):
        if wikilib.bash_writes(cmd, tok):
            return ("log", tok)
    if any(k in cmd for k in conf["work_commands"]):
        cwd = os.path.realpath(payload.get("cwd") or os.getcwd())
        in_wiki = cwd == kb_real or cwd.startswith(kb_real + os.sep)
        # a plain commit inside the wiki is the log itself; one aimed elsewhere is work
        if in_wiki and not re.search(r"(^|\s)(cd\s|git\s+-C\s)", cmd):
            return None
        return ("work", first)
    return None


def main():
    kb = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
    conf = wikilib.log_guard_config(wikilib.load_config(kb))
    if not conf.get("enabled"):
        return 0
    payload = json.load(sys.stdin)
    sid = re.sub(r"[^A-Za-z0-9._-]", "", str(payload.get("session_id") or ""))
    if not sid:
        return 0
    event = classify(payload, kb, conf)
    if not event:
        return 0
    d = os.path.join(wikilib.state_dir(kb), "sessions")
    os.makedirs(d, exist_ok=True)
    detail = event[1].replace("\t", " ").replace("\n", " ")
    with open(os.path.join(d, sid + ".tsv"), "a", encoding="utf-8") as fh:
        fh.write(f"{int(time.time())}\t{event[0]}\t{detail}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
