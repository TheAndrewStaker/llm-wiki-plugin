#!/usr/bin/env python3
"""PostToolUse hook: record a session's work and log events for the Stop-hook log guard.

One line per event, appended to <state-dir>/sessions/<session_id>.tsv as
`<epoch>\t<kind>\t<detail>`. kind is `work` (a command from log_guard.work_commands, such as
`git commit` or `gh pr create`, run against a directory outside the wiki; or, with
work_writes, a file write outside the wiki) or `log` (a Write/Edit under log_guard.log_dirs
other than an index page, a command from log_guard.log_commands that did not fail, or a
visible Bash write to an initiatives/ page). Subagent tool calls reach this hook on the
parent's session_id, so delegated work and delegated logging both count.

A shell command is split into segments on &&, ||, ;, | and newlines and each segment is
tokenized, so a commit string inside a grep is not a commit, `git -C <dir> commit` is judged
by <dir>, and a `cd` earlier in the same command moves the directory the later segments are
judged in. A command whose response says "nothing to commit", or that was interrupted, is
not work; a log command whose stderr carries its own error prefix is not a log.

The hook is a recorder only; log-guard.py reads the file at Stop. Off unless
log_guard.enabled is true. Silent with exit 0 on everything, errors included.
Standalone: printf '<hook json>' | session-record.py [WIKI_ROOT]
"""
import json
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
SEGMENT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")
GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
NOT_WORK_MARKERS = ("nothing to commit", "nothing added to commit")


def inside(path, root):
    return path == root or path.startswith(root + os.sep)


def resolve(path, cur):
    path = os.path.expanduser(os.path.expandvars(path.strip("'\"")))
    return os.path.realpath(path if os.path.isabs(path) else os.path.join(cur, path))


def segments(cmd):
    for seg in SEGMENT.split(cmd):
        seg = seg.strip()
        if not seg:
            continue
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        if toks:
            yield toks


def is_git(tok):
    return tok == "git" or tok.endswith("/git")


def git_call(toks):
    """(subcommand, -C or --work-tree target) when the segment runs git, else (None, None)."""
    if not toks or not is_git(toks[0]):
        return None, None
    i, target = 1, None
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] in GIT_VALUE_FLAGS:
            if toks[i] in ("-C", "--work-tree") and i + 1 < len(toks):
                target = toks[i + 1]
            i += 2
        else:
            if toks[i].startswith("--work-tree="):
                target = toks[i].split("=", 1)[1]
            i += 1
    return (toks[i] if i < len(toks) else None), target


INTERPRETERS = {"bash", "sh", "zsh", "python3", "python"}


def matches(entry, toks):
    """The tool name when a work_commands or log_commands entry matches a tokenized
    segment (an interpreter in front of a script is skipped), else None."""
    want = entry.split()
    if not want:
        return None
    if want[0] == "git":
        sub, _ = git_call(toks)
        return "git" if (sub == want[1] if len(want) > 1 else sub is not None) else None
    j = 1 if os.path.basename(toks[0]) in INTERPRETERS and len(toks) > 1 else 0
    name = os.path.basename(toks[j]).split(".")[0]
    if name == want[0] and [os.path.basename(t) for t in toks[j + 1:j + len(want)]] == want[1:]:
        return name
    return None


def classify_bash(cmd, cwd, kb_real, conf, text, interrupted):
    cur = os.path.realpath(cwd or os.getcwd())
    events = []
    for toks in segments(cmd):
        if toks[0] in ("cd", "pushd"):
            cur = resolve(toks[1], cur) if len(toks) > 1 else os.path.expanduser("~")
            continue
        name = next((n for n in (matches(e, toks) for e in conf["log_commands"]) if n), None)
        if name:
            # the tool's own error prefix on a line of its output means it did not log
            if re.search(r"(?m)^" + re.escape(name) + r":", text):
                continue
            events.append(("log", " ".join(toks)[:120]))
            continue
        for tok in sorted(set(re.findall(r"[\w./~-]*initiatives/[\w.-]+\.md", " ".join(toks)))):
            if os.path.basename(tok) != "index.md" and wikilib.bash_writes(" ".join(toks), tok):
                events.append(("log", tok))
                break
        else:
            if interrupted or any(m in text for m in NOT_WORK_MARKERS):
                continue
            for entry in conf["work_commands"]:
                if not matches(entry, toks):
                    continue
                _, target = git_call(toks) if entry.startswith("git") else (None, None)
                where = resolve(target, cur) if target else cur
                if not inside(where, kb_real):
                    events.append(("work", " ".join(toks)[:120]))
                break
    return events


def classify(payload, kb, conf):
    name = payload.get("tool_name") or ""
    inp = payload.get("tool_input") or {}
    kb_real = os.path.realpath(kb)
    if name in WRITE_TOOLS:
        p = inp.get("file_path") or inp.get("notebook_path") or ""
        if not p:
            return []
        real = os.path.realpath(os.path.expanduser(p))
        if inside(real, kb_real):
            rel = os.path.relpath(real, kb_real)
            if rel.startswith(tuple(conf["log_dirs"])) and os.path.basename(rel) != "index.md":
                return [("log", rel)]
            return []
        if conf["work_writes"] and not real.startswith(tuple(conf["ignore_write_prefixes"])):
            return [("work", real)]
        return []
    if name != "Bash":
        return []
    resp = payload.get("tool_response")
    if isinstance(resp, dict):
        text = "\n".join(str(resp.get(k) or "") for k in ("stdout", "stderr"))
    else:
        text = resp if isinstance(resp, str) else (json.dumps(resp) if resp is not None else "")
    interrupted = bool(isinstance(resp, dict) and resp.get("interrupted"))
    return classify_bash(inp.get("command") or "", payload.get("cwd"), kb_real, conf, text, interrupted)


def main():
    kb = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
    conf = wikilib.log_guard_config(wikilib.load_config(kb))
    if not conf.get("enabled"):
        return 0
    payload = json.load(sys.stdin)
    sid = re.sub(r"[^A-Za-z0-9._-]", "", str(payload.get("session_id") or ""))
    if not sid:
        return 0
    events = classify(payload, kb, conf)
    if not events:
        return 0
    d = os.path.join(wikilib.state_dir(kb), "sessions")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, sid + ".tsv"), "a", encoding="utf-8") as fh:
        for kind, detail in events:
            detail = detail.replace("\t", " ").replace("\n", " ")
            fh.write(f"{int(time.time())}\t{kind}\t{detail}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
