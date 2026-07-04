---
name: reflect
description: >-
  Run a SCOPED, REVERSIBLE semantic-staleness reflection pass over the wiki: surface
  contradictions, stale/superseded claims, missing concept/entity pages, and weak cross-links,
  written as a PROPOSAL to a dated reflection-log note (no page edits) for the user to confirm
  before anything lands. Use after ingesting a source, at a cooldown, or when stale-source.py /
  missed-links flag a cluster. Two phases: propose, then (after confirmation) apply.
---

# Reflect: scoped, reversible semantic-staleness pass

The judgment half of Lint (contradictions, supersession, missing pages, weak cross-refs) that the
deterministic `lint.sh` cannot do. It is **scoped** (never the whole wiki) and **reversible**: it proposes
edits to a dated reflection-log note and changes **nothing** until the user confirms. No model writes to the
wiki on a hook; git is the audit trail. See the Staleness policy in the wiki's `KNOWLEDGE.md`.

Resolve the wiki root from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`; run the scripts from
`$WIKI_ROOT/hooks/`.

## Phase A — PROPOSE (no page edits)

### A1. Compute the bounded scope
```bash
python3 "$WIKI_ROOT/hooks/reflect-scope.py"                  # stale RE-CHECK + missed-links + oldest
python3 "$WIKI_ROOT/hooks/reflect-scope.py" --range <A>..<B> # after a specific ingest/commit range
```
Use the printed list (capped at 15). Do not expand beyond it mid-run.

### A2. Reflect in a SUBAGENT (context isolation)
Spawn a subagent that READS the scoped pages **and their `synthesized_from:` sources** and returns findings
only (it must not edit any page). Per finding: **page** + **kind** (`contradiction` | `stale-superseded` |
`missing-page` | `weak-crosslink` | `data-gap`), the **current** claim (quoted) and the **proposed** change
(exact new text, or "create concepts/x.md"), a **rationale** (cite the source/contradicting page), and a
one-word **confidence**: confirmed / reported / inferred / unconfirmed.

### A3. Write the reflection log (the reversible artifact)
Write to `analyses/reflection-YYYY-MM-DD.md` (do NOT touch target pages). Frontmatter `type: analysis`,
`title`, `timestamp`, `synthesized_from:` = the scope list. Body: one **checkbox per proposed change**,
grouped by page, quoting current + proposed + why + confidence. Add a line to `analyses/index.md`, run the
lint (green), and commit ("Propose reflection edits YYYY-MM-DD"). Nothing in the wiki has changed yet.

### A4. Report
Give the user the path to the reflection log and a 2-line summary (N proposals across M pages). They check
the boxes they approve (or edit/delete items).

## Phase B — APPLY (separate invocation, only confirmed items)
When the user says apply:
1. Read the reflection log; act ONLY on items checked `- [x]`.
2. For each: edit the target page. `stale-superseded` → follow the supersede convention (replace the claim;
   if the old version matters, move it to `archive/` with a status token + a relative-md pointer to the
   successor). `missing-page` → create it (OKF frontmatter + `synthesized_from:`) and link it. Set the
   edited page's **`reviewed:`** to today (records the re-verification; do not silently bump `timestamp`).
3. Mark each applied item `- [x] APPLIED`.
4. Run the lint (green) + `stale-source.py` (touched pages should clear), then commit ("Apply confirmed
   reflection edits YYYY-MM-DD").

## Principles
Reversible (unconfirmed proposals never land; propose and apply are separate commits) · scoped (never a
whole-wiki sweep) · subagent isolation (only findings return) · human-in-the-loop (no unconfirmed writes) ·
one-word confidence, no decay math; supersede, never age-expiry.
