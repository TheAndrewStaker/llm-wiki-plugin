#!/usr/bin/env python3
"""PostToolUse hook: report an initiative's frontmatter word-cap breach at the edit that
caused it, instead of at the commit made after the work is done.

`initiative-check.py` already hard-fails the commit on these caps. That is the right gate
at the wrong moment: by then the agent has finished, the Stop hook's auto-commit fails, and
the breach surfaces as a lint line with no memory of the sentence that caused it. On the
wiki this plugin is dogfooded against, every recorded lint failure over three days was one
of these caps and nothing else. They are also undiscoverable before they fire, since a cap
lives in `wiki.config.json` and no file an agent reads before writing frontmatter names it.

So: check one file, at the edit, and exit 2 so the breach reaches the agent while the
sentence it has to shorten is still the thing in hand.

Silent with exit 0 whenever there is nothing to say, which is almost always: no
`initiative_schema` configured, a file outside `initiatives/`, an index page, absent
frontmatter, a non-initiative type, `board: false`, or any unexpected error. A hook that
runs on every Write must never be the reason an edit reports failure.

Reads the Claude Code hook payload on stdin. For a Bash call it checks every initiatives/
page the command visibly writes (see wikilib.bash_writes).
Standalone: python3 hooks/initiative-caps.py <file> [WIKI_ROOT]
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

# Same three caps initiative-check.py gates the commit on, read from the same block, so
# the two can never disagree about what a page owes.
FIELDS = (("summary", "summary_max_words"), ("next", "next_max_words"), ("ask", "ask_max_words"))


def targets(kb):
    """Files the call may have written: argv, a Write/Edit file_path, or every initiatives/
    page a Bash command visibly writes."""
    if len(sys.argv) > 1:
        return [sys.argv[1]]
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return []
    inp = payload.get("tool_input") or {}
    if payload.get("tool_name") != "Bash":
        return [inp["file_path"]] if inp.get("file_path") else []
    cmd = inp.get("command") or ""
    if "initiatives/" not in cmd:
        return []
    cwd = payload.get("cwd") or os.getcwd()
    out = []
    for tok in sorted(set(re.findall(r"[\w./~-]*initiatives/[\w.-]+\.md", cmd))):
        if not wikilib.bash_writes(cmd, tok):
            continue
        path = os.path.expanduser(tok)
        for base in (cwd, kb):
            cand = path if os.path.isabs(path) else os.path.join(base, path)
            if os.path.isfile(cand):
                out.append(cand)
                break
    return out


def over_caps(path, kb, schema):
    if not path.endswith(".md") or os.path.basename(path) == "index.md":
        return []
    # Compare resolved paths: a wiki reached through a symlink still has to match.
    initiatives = os.path.realpath(os.path.join(kb, "initiatives"))
    if os.path.dirname(os.path.realpath(path)) != initiatives:
        return []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    block = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not block:
        return []
    fm = block.group(1)
    if wikilib.frontmatter_value(fm, "type") != "initiative":
        return []
    if wikilib.frontmatter_value(fm, "board") == "false":
        return []
    over = []
    for field, cap_key in FIELDS:
        cap = schema.get(cap_key, 0)
        value = wikilib.frontmatter_value(fm, field)
        if cap and value and len(value.split()) > cap:
            over.append((field, len(value.split()), cap))
    return over


def main():
    kb = wikilib.resolve_root(sys.argv[2] if len(sys.argv) > 2 else None)
    schema = (wikilib.load_config(kb) or {}).get("initiative_schema")
    if not schema:
        return 0
    found = False
    for path in targets(kb):
        over = over_caps(path, kb, schema)
        if not over:
            continue
        found = True
        rel = os.path.relpath(os.path.realpath(path), os.path.realpath(kb))
        print(f"{rel}: frontmatter over the configured cap, which will hard-fail the commit.",
              file=sys.stderr)
        for field, count, cap in over:
            print(f"  {field}: {count} words > {cap} cap", file=sys.stderr)
    if not found:
        return 0
    print("Shorten the field now, ideally with `wiki-fm set <page> <field>=<value>`, which"
          " validates before writing. Depth belongs in the page body as a dated log entry.",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # never fail an edit because this hook could not run
        sys.exit(0)
