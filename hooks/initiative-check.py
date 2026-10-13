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
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
schema = cfg.get("initiative_schema")
issues = []


# WIKI_CHECK_INDEX=1 (set by pre-commit) reads the staged version of each file, so the gate
# judges what is being committed rather than whatever else is dirty in the tree.
INDEX = os.environ.get("WIKI_CHECK_INDEX") == "1"


def src(rel):
    if not INDEX:
        return wikilib.read(KB, rel)
    r = subprocess.run(["git", "show", ":" + rel], cwd=KB, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


if schema:
    queue_max = schema.get("queue_max", 0)
    state_budget = schema.get("state_word_budget", 0)

    owner, _ = wikilib.queue_owner(schema)
    owner_asks = 0
    # Transition rules compare each page with HEAD (following a staged rename), so a page
    # already in a state is grandfathered and only the change into it is judged.
    renames = wikilib.renamed_from(KB, index=INDEX)
    n_active = wikilib.active_count(KB, index=INDEX) if schema.get("active_max") else None
    for f in wikilib.git_files(KB):
        if not f.startswith("initiatives/") or os.path.basename(f) == "index.md":
            continue
        text = src(f)
        fmblock = re.match(r"^---\n(.*?)\n---", text, re.S)
        if not fmblock:
            continue
        fm = fmblock.group(1)
        if wikilib.frontmatter_value(fm, "type") != "initiative":
            continue
        if wikilib.frontmatter_value(fm, "board") == "false":
            continue
        prev = wikilib.previous_frontmatter(KB, f, renames=renames)
        for field, msg in wikilib.initiative_issues(schema, fm, prev, n_active):
            issues.append(f"  INIT-FAIL {f} {field}: {msg}")
        if (wikilib.frontmatter_value(fm, "waiting_on") or "none") == owner:
            owner_asks += 1

    oa_text = src(f"open-asks/{owner}.md")
    oa_items = len(re.findall(r"(?m)^- ", oa_text))
    queue_total = owner_asks + oa_items
    if queue_max and queue_total > queue_max:
        issues.append(f"  INIT-FAIL open-asks/{owner}.md queue: {queue_total} items > {queue_max} cap")
    if schema.get("queue_dated"):
        for it in wikilib.parse_queue(oa_text):
            if not it["date"]:
                head = it["raw"].split("\n")[0][:60]
                issues.append(f"  INIT-FAIL open-asks/{owner}.md line shape: '{head}' must start "
                               "'- [ ] YYYY-MM-DD · <who asked, or self> · '")

    state_text = src("STATE.md")
    if state_text:
        m = re.search(r"(?ms)^## Inbox\b.*?(?=^## |\Z)", state_text)
        if m and re.search(r"(?m)^- ", m.group(0)):
            issues.append("  INIT-FAIL STATE.md Inbox: bullet found under the tombstone "
                           "heading; write the initiative's frontmatter and a journal line")
        if state_budget:
            stripped = re.sub(r"(?s)<!-- board:begin.*?board:end -->", "", state_text)
            if len(stripped.split()) > state_budget:
                issues.append(f"  INIT-FAIL STATE.md hand-written: {len(stripped.split())}w > "
                               f"{state_budget}w cap")

aims_conf = cfg.get("aims") or {}
if aims_conf.get("file") and aims_conf.get("heading"):
    _, aim_errors = wikilib.parse_aims(KB, cfg, text=src(aims_conf["file"]))
    for err in aim_errors:
        issues.append(f"  INIT-FAIL {err}")

for line in issues:
    print(line)
print(f"INIT-FAIL={len(issues)}")
