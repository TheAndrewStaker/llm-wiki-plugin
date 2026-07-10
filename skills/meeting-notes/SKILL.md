---
name: meeting-notes
description: >-
  Turn a meeting transcript (.vtt or similar) into an enriched, cross-referenced source-summary
  page filed in the wiki at notes/ (with the raw transcript staged in sources/), then update the
  index and touch related entity/concept/decision pages. Use when the user wants to process a
  transcript, "write up the meeting notes", or says they just recorded a meeting. Works with an
  explicit path OR finds the newest unprocessed transcript in the source inbox.
---

# Meeting notes: transcript → enriched source page

The transcript adapter of the **Ingest** operation (shared contract, steps 0–7, in the wiki's `KNOWLEDGE.md`
"Operations — Ingest"). Produce a human-grade, verified source-summary page filed at `notes/` (git-tracked),
with the raw transcript staged in the immutable raw layer `sources/`.

Resolve the wiki root from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`.

> Be accurate over fast — these pages are reference; a wrong name/fact is worse than a missing one.

## Step 1 — Resolve which transcript to process
If the user gave a path, use it. Otherwise search the source inbox (see the "Local configuration" section of
`KNOWLEDGE.md`; default `~/Downloads`), then `~/Desktop`, `~/Documents`, newest-first:
```bash
for d in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents"; do
  [ -d "$d" ] && ls -t "$d"/*.vtt 2>/dev/null
done
```
Filter out already-processed transcripts (a notes page already covers that person/topic). One obvious
newest candidate → state it and proceed; ambiguous → ask which file. Never guess silently.

## Step 2 — Canonical name + stage the raw source
Filename: `YYYY-MM-DD-<person-or-topic>-<slug>.notes.md`, kebab-case (date = the meeting date; default to
the file's modified date). Multi-part meetings → append `-pt1`/`-pt2` to the transcript filenames only; keep
ONE umbrella notes page. **Stage the raw transcript** (copy, don't move) into `sources/YYYY/MM/`.

## Step 3 — Write the enriched page
OKF frontmatter, then body. Read the full transcript; auto-transcripts mis-hear names/jargon — correct and
enrich, don't transcribe.
```yaml
---
type: notes
title: <Meeting title> (YYYY-MM-DD)
timestamp: YYYY-MM-DD
synthesized_from: ../sources/YYYY/MM/<name>.vtt
tags: [meeting, <area>]
---
```
Body: **Header** (people+roles, topic, source, a **Related:** line of relative-md links); a **caveats**
blockquote (every garbled→corrected term, anything still unverified); **synthesized sections** by theme
(meaning, not a dump); **action items** (checkboxes); **open questions / to verify**; **contradictions**
(or "None"); optional **glossary**.

## Step 4 — Verify and cross-reference (do not skip)
Check every person/org against the wiki's `entities/` pages and the corroboration sources listed in
`KNOWLEDGE.md`'s Local-configuration section; don't conflate similar names. Corroborate process/product
claims against those sources. When cross-referenced, say so inline.

## Step 5 — Update index + touch related pages (contract steps 4–6)
Add a row to `notes/index.md`; update the entity/concept pages the meeting touched; file any decisions
(decision routing in `KNOWLEDGE.md`). Link, don't duplicate; relative-md links throughout. A meaningful
edit to an existing page bumps its `timestamp:` to today (cosmetic edits bump nothing; `reviewed:` =
re-verification without change).

## Step 6 — Report + finish
Short summary (who/what, key new facts, anything unverified/contradictory) and the path to the new page.
`git add -A` in the wiki, run `bash "$WIKI_ROOT/hooks/lint.sh"` (green), then commit.
