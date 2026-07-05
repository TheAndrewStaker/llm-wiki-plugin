---
name: ingest-source
description: >-
  Ingest a non-transcript source (web article, PDF, blog post, or a book read
  chapter-by-chapter) into the wiki: stage it in sources/, discuss takeaways, write/update a
  synthesis page, update the index + linked pages, file any decisions, and cross-link. Use when
  the user drops a source in (or gives a URL/path) and wants it processed into the knowledge
  base. For meeting transcripts (.vtt) use the meeting-notes skill instead.
---

# Ingest a source into the wiki

This is the **`ingest-source` adapter** of the shared **Ingest** operation. The canonical contract
(steps 0–7) lives in the wiki's `KNOWLEDGE.md` "Operations — Ingest" — read it first and follow it exactly.
This skill only adds the **acquisition** specifics for web/PDF/book sources; the filing (synthesis page,
index, linked pages, decisions, cross-links, the git-commit = log entry) is defined by the contract.

Resolve the wiki root from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`.

> Accuracy over speed — synthesis pages are treated as reference; a wrong fact is worse than a missing one.

## Step 1 — Resolve and stage the source (the immutable raw layer)
- **URL** → clip to markdown or fetch, and save the original under `sources/` (e.g.
  `sources/YYYY-MM-DD-<slug>.md`; images → `sources/assets/`). Never edit a file in `sources/` after saving.
- **PDF / local file** → copy into `sources/` (keep the original name + a date prefix).
- **Already in `sources/`** → use as given.
- Record provenance in the synthesis page's **`synthesized_from:`** (the key the freshness tooling watches):
  the relative path to the staged copy, or the URL. Do NOT use `resource:` (OKF reserves that for the asset a
  concept *describes*).

## Step 2 — Assess extent → strategy (contract step 0)
- **Single-pass** (article, short PDF) → straight through the contract.
- **Chunked-resumable** (a book) → a **parent synthesis page** with a `sections-done:` checklist in
  frontmatter; ingest section-by-section, doing each section's reading/synthesis **in a subagent** and
  returning only the summary (context isolation).

## Step 3 — Weight-conditional involvement (contract step 2)
- **Heavy source** → interactive: surface takeaways, let the user steer emphasis before writing.
- **Trivial source** → propose the synthesis, confirm, write. Don't over-ceremony it.

## Step 4 — Follow the rest of the contract (KNOWLEDGE.md steps 3–7)
Write/update the synthesis page in the right type-dir; update the index; update the entity/concept pages it
touches; extract any decisions (decision routing in `KNOWLEDGE.md`); cross-link with relative markdown links.
If the wiki's declared knowledge topology (KNOWLEDGE.md "Local configuration") routes team-audience material
to a team home, file it there and keep the pointer + your view here.

## Step 5 — Backlink sweep, then verify
- **Backlink sweep** (contract step 7): run `python3 "$WIKI_ROOT/hooks/missed-links.py"` and act on any
  flagged pair that involves a page you created or updated, in both directions: link the new page where
  existing prose already mentions it, and link mentioned entities/concepts from the new page. Leave
  flags on untouched pages for `reflect`.
- The page has `type:` frontmatter (+ `title`, `timestamp`, `synthesized_from:`).
- `git add -A` in the wiki first (lint iterates git-TRACKED files), then run `bash "$WIKI_ROOT/hooks/lint.sh"`;
  it must stay green. The git commit is the log entry.
