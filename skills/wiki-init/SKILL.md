---
name: wiki-init
description: >-
  Populate a wiki from an existing pile of documentation using a multi-agent migration: scan
  and classify sources, get the user to approve an inventory manifest, then fan out agents to
  draft pages on a review branch. Create-only and reversible via git. Use when the user wants to
  migrate/import existing docs into the wiki, "bootstrap the wiki from my notes", or bring a
  documentation folder into the knowledge base.
---

# wiki-init: migrate an existing doc pile into the wiki

Populate a wiki from documents that already exist. This is a **multi-agent** migration, so it runs as a
**Workflow** (deterministic phases + resume). It is **create-only** (never edits/moves originals) and
**reversible** (output lands on a git branch; merge = apply). Requires the user's opt-in to run a workflow.

## Entry paths (pick first)
- **greenfield** — no docs to migrate → there is nothing to do here; use `wiki-setup` and start capturing.
- **migrate** — a folder/repo of existing notes → the full flow below.
- **adopt** — a coworker with their own populated `~/.claude` → same flow, but the wiki root is a SEPARATE
  dir (default `~/wiki`); never annex their config dir, and append-don't-overwrite any existing files.
- **clone** — a wiki that already exists on another machine → do NOT init; `git clone` the content remote,
  run the lint gate to verify, done.

## Phase 1 — Scan + classify → an approval manifest (MANDATORY human gate)
1. Deterministic scan of the source location(s): list every candidate doc (path, size, format).
2. One classification agent produces a **manifest table**: `source → proposed type → target page → action`
   (create / merge-into-existing / skip). Types come from the taxonomy in `KNOWLEDGE.md`.
3. **Stop and present the manifest for approval.** This is the scope gate and the cheap place to catch
   misclassification. Keyed by source path + content hash, the approved manifest is also the **watermark
   ledger** for idempotent re-runs and cross-session resume.

## Phase 2 — Draft pages (fan out, sharded by SOURCE BATCH)
Shard the approved manifest into batches of ~10–15 sources; give **each agent a batch plus the full type
taxonomy rubric** (not one agent per category — categories are output labels, and a single-category agent
over dozens of docs overflows). Each agent writes pages into a **git branch** of the wiki (never the working
tree directly): OKF frontmatter, `synthesized_from:` pointing at the ORIGINAL source path (so
`stale-source.py --standing` can watch it), relative-md cross-links. Copy any raw originals into `sources/`;
never move or edit them. `log()` anything skipped (no silent caps).

## Phase 3 — Fan-in: dedupe, cross-link, lint
- Dedupe against existing page slugs before linking (a batch may have proposed a page that already exists →
  merge or skip, don't duplicate).
- Build the indexes and cross-links across all new pages.
- Run `bash "$WIKI_ROOT/hooks/lint.sh"` and `python3 "$WIKI_ROOT/bin/wiki-query" --catalog`; the branch must be lint-green.

## Phase 4 — Review = git, apply = merge
Present the branch as the proposal: `git -C <wiki> diff --stat main..<branch>` plus spot-checks of a few
pages. The user reviews and merges (= apply). Reserve reflect-style checkbox logs only for the minority of
**edits to existing pages**; 100+ brand-new pages are reviewed as a diff, not as checkboxes.

## Guardrails
- **Create-only**: edits to existing pages route to the `reflect` skill, not here.
- Refuse to run against a **non-empty wiki** without an explicit merge mode the user chose.
- **Pilot batch first**: draft ~10 pages, get a human read, then run the rest.
- Everything reversible: it's a branch until the user merges.
