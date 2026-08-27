#!/usr/bin/env python3
"""Hard-gated initiative-frontmatter schema check, the retired STATE.md Inbox's tombstone
rule, and STATE.md's hand-written word budget. Opt-in and fully config-driven: does nothing
unless wiki.config.json carries an `initiative_schema` block, so a wiki without one (or the
plugin's own tests) sees zero INIT-FAIL lines ever. No org-specific enum values live here;
they come from wiki.config.json.

lint.sh hard-fails the commit when INIT-FAIL>0, the same way it already hard-fails on broken
links: this script is NOT wired through advisory_budgets (that block is a closed, hardcoded
tuple of nine unrelated counters and cannot take a new name without editing lint.sh itself).

Standalone: python3 hooks/initiative-check.py [WIKI_ROOT]
Ends with a machine line: INIT-FAIL=<n>
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
schema = cfg.get("initiative_schema")
issues = []


def wc(s):
    return len(s.split()) if s else 0


if schema:
    kinds = set(schema.get("assignment_kind", []))
    statuses = set(schema.get("assignment_status", []))
    waiting = set(schema.get("waiting_on", []))
    summary_max = schema.get("summary_max_words", 0)
    next_max = schema.get("next_max_words", 0)
    ask_max = schema.get("ask_max_words", 0)
    queue_max = schema.get("queue_max", 0)
    state_budget = schema.get("state_word_budget", 0)

    andrew_asks = 0
    for f in wikilib.git_files(KB):
        if not f.startswith("initiatives/") or os.path.basename(f) == "index.md":
            continue
        text = wikilib.read(KB, f)
        fmblock = re.match(r"^---\n(.*?)\n---", text, re.S)
        if not fmblock:
            continue
        fm = fmblock.group(1)
        if wikilib.frontmatter_value(fm, "type") != "initiative":
            continue
        if wikilib.frontmatter_value(fm, "board") == "false":
            continue

        kind = wikilib.frontmatter_value(fm, "assignment_kind")
        status = wikilib.frontmatter_value(fm, "assignment_status")
        priority = wikilib.frontmatter_value(fm, "priority")
        priority_set = wikilib.frontmatter_value(fm, "priority_set")
        cycle = wikilib.frontmatter_value(fm, "cycle")
        summary = wikilib.frontmatter_value(fm, "summary")
        nxt = wikilib.frontmatter_value(fm, "next")
        wo = wikilib.frontmatter_value(fm, "waiting_on") or "none"
        ask = wikilib.frontmatter_value(fm, "ask")

        if kinds and kind not in kinds:
            issues.append(f"  INIT-FAIL {f} assignment_kind: missing or not in {sorted(kinds)}")
        if statuses and status not in statuses:
            issues.append(f"  INIT-FAIL {f} assignment_status: missing or not in {sorted(statuses)}")
        if priority is not None and not priority_set:
            issues.append(f"  INIT-FAIL {f} priority_set: required because priority is set")
        if kind == "pitch" and not cycle:
            issues.append(f"  INIT-FAIL {f} cycle: required because assignment_kind is pitch")
        if waiting and wo not in waiting:
            issues.append(f"  INIT-FAIL {f} waiting_on: '{wo}' not in {sorted(waiting)}")
        if wo != "none" and not ask:
            issues.append(f"  INIT-FAIL {f} ask: required because waiting_on is not '{wo}'")
        if summary_max and summary and wc(summary) > summary_max:
            issues.append(f"  INIT-FAIL {f} summary: {wc(summary)}w > {summary_max}w cap")
        if next_max and nxt and wc(nxt) > next_max:
            issues.append(f"  INIT-FAIL {f} next: {wc(nxt)}w > {next_max}w cap")
        if ask_max and ask and wc(ask) > ask_max:
            issues.append(f"  INIT-FAIL {f} ask: {wc(ask)}w > {ask_max}w cap")
        if wo == "andrew":
            andrew_asks += 1

    oa_text = wikilib.read(KB, "open-asks/andrew.md")
    oa_items = len(re.findall(r"(?m)^- ", oa_text))
    queue_total = andrew_asks + oa_items
    if queue_max and queue_total > queue_max:
        issues.append(f"  INIT-FAIL open-asks/andrew.md queue: {queue_total} items > {queue_max} cap")

    state_text = wikilib.read(KB, "STATE.md")
    if state_text:
        m = re.search(r"(?ms)^## Inbox\b.*?(?=^## |\Z)", state_text)
        if m and re.search(r"(?m)^- ", m.group(0)):
            issues.append("  INIT-FAIL STATE.md Inbox: bullet found under the tombstone "
                           "heading; write the initiative's frontmatter and a journal line")
        if state_budget:
            stripped = re.sub(r"(?s)<!-- board:begin.*?board:end -->", "", state_text)
            if wc(stripped) > state_budget:
                issues.append(f"  INIT-FAIL STATE.md hand-written: {wc(stripped)}w > "
                               f"{state_budget}w cap")

for line in issues:
    print(line)
print(f"INIT-FAIL={len(issues)}")
