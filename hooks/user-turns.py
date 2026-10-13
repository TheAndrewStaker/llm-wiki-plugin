#!/usr/bin/env python3
"""Print the user-typed turns of a Claude Code transcript (JSONL), oldest first, one block per
turn with its timestamp. Skips tool results, meta and sidechain entries, compaction summaries,
slash-command and task-notification wrappers, and messages relayed from other agents.

Usage: user-turns.py TRANSCRIPT [--max-chars N]   (N per turn, default 2000)
"""
import argparse
import json
import sys

SKIP_PREFIXES = (
    "This session is being continued",
    "<command-name>", "<command-message>", "<local-command", "<task-notification>",
    "<system-reminder>", "Another Claude session sent a message", "Base directory for this skill",
    "Caveat:",
)


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
            return ""
        return "\n".join(x.get("text", "") for x in content
                         if isinstance(x, dict) and x.get("type") == "text")
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("transcript")
    ap.add_argument("--max-chars", type=int, default=2000)
    args = ap.parse_args()
    try:
        fh = open(args.transcript, encoding="utf-8", errors="ignore")
    except OSError as exc:
        print(f"user-turns: {exc}", file=sys.stderr)
        return 1
    with fh:
        for line in fh:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "user" or e.get("isMeta") or e.get("isSidechain") \
                    or e.get("isCompactSummary"):
                continue
            t = text_of((e.get("message") or {}).get("content")).strip()
            if not t or t.startswith(SKIP_PREFIXES):
                continue
            if len(t) > args.max_chars:
                t = t[:args.max_chars] + " [...]"
            print(f"--- {e.get('timestamp', '')}\n{t}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
