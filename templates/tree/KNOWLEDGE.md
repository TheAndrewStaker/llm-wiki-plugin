---
type: index
title: Knowledge base — entry map + conventions
schema_version: "0.1"
timestamp: 2026-01-01
---

The single door into this knowledge base (the "wiki"). Structure: markdown + YAML frontmatter, in
type-named directories, versioned in git; file paths are identity and relative links form the
cross-reference graph. **You curate the content; the agent keeps it current and cross-linked.**

## Conventions (the standard for every file here)
- **Format:** markdown body + YAML frontmatter. Frontmatter must include `type:`; add `title`, `timestamp`,
  and links/status as useful. (Only `type:` is required.)
- **Types (the default set; extensible per-wiki):** content — `entity`, `concept`, `notes` (source-summary
  pages), `comparison`, `synthesis`, `analysis`, `map`; work overlay — `index`, `state`, `roadmap`,
  `initiative`, `decision-log`, `open-asks`, `reference`, `archive`, `draft`. The lint only requires that
  `type:` is present, not that it is one of these — so a domain-specific wiki may define its OWN types
  (declare them here + add their dirs to `wiki.config.json`); no code change needed. If you rename types,
  keep `type_requirements` in `wiki.config.json` keyed to the same vocabulary — a key that matches no
  `type:` value silently never fires.
- **Layering by horizon:** `STATE.md` = current focus (crisp handoff) · `ROADMAP.md` = long-horizon/parked ·
  `initiatives/<name>.md` = per-initiative deep state · `archive/<period>.md` = done (append-only).
- **Decisions — routing:** a decided record with rationale → `decisions/<name>.md` (`type: decision-log`);
  an open question you owe someone → `open-asks/<who>.md` (open-only; remove once answered).
- **Link, don't duplicate:** one source of truth per fact; link to it rather than restating it.
- **Link format:** cross-link with **relative markdown links** `[name](path.md)` — this is the
  cross-reference graph, portable (no hardcoded home path), and clickable in most editors. Always include
  the real relative path ending in `.md`. (Reserve absolute URLs for output to a human, not for links
  inside these files.)
- **Red links:** an unresolved `[[name]]` is the deliberate marker for a page worth writing later (it is
  not an error). `hooks/wanted-pages.py` ranks these by mention count — the wanted-pages report — so the
  most-referenced missing pages get written first.
- **Casing:** top-level landmark singletons UPPERCASE (`CLAUDE.md`, `STATE.md`, `ROADMAP.md`,
  `KNOWLEDGE.md`) so they sort to the top; content inside type-dirs lowercase (the dir name carries the
  type).
- **Keep the focus block small.** Bloat that buries the priority is the failure mode; move detail out to
  `initiatives/` as it lands.

## Alignment & vocabulary — Karpathy LLM-Wiki · Google OKF · Anthropic
This base follows three published conventions and adopts their shared vocabulary:
- **Karpathy, "LLM Wiki"** — the pattern: three layers; Ingest/Query/Lint; index/log; compounding-not-RAG.
- **Google Cloud, Open Knowledge Format (OKF) v0.1** — the on-disk format: markdown + YAML frontmatter; one
  required field `type`; concept-id = file path; markdown-link graph.
- **Anthropic context engineering** — filesystem-as-substrate + agentic search first (add semantic
  retrieval only if needed); human-authored schema vs. agent-authored content; progressive disclosure;
  subagents for context isolation.

| Term | Here |
|---|---|
| **the wiki** | this curated tree — synthesized, cross-linked markdown the agent writes and you curate |
| **raw sources** (immutable) | `sources/` — dropped-in originals; skills read, never edit |
| **the schema** | your `CLAUDE.md` (working prefs) + this `KNOWLEDGE.md` (conventions + the Ingest contract) |
| **Ingest / Query / Lint** | the three operations — the contract below + `hooks/lint.sh` |
| **index** | this `KNOWLEDGE.md` + per-dir `index.md`; read FIRST on a query |
| **log** | git history (`git log --oneline -- '*.md'`) + `archive/` |

**OKF frontmatter:** `type:` is the one required field; also `title`, `description`, `tags`, `timestamp`
(the last *meaningful* change). `resource:` keeps its OKF meaning: the asset a concept *describes* (a
dataset, a system). The **source a page was synthesized from** is `synthesized_from:` (watched by the
freshness check); optional `reviewed:` records the last re-verification.

## Operations — Ingest · Query · Lint
**Ingest** (drop a source → process it): 1. Read the source from `sources/` (immutable). 2. Discuss
takeaways (heavy source = interactive; trivial = propose-then-confirm). 3. Write/update a synthesis page in
the right type-dir. 4. Update the relevant index. 5. Update linked entity/concept pages. 6. Extract any
decisions → the decision routing above. 7. Cross-link with relative md links, then backlink-sweep: run
`hooks/missed-links.py` and link any flagged mention of (or by) the pages you touched, both directions.
The git commit is the log.

**Query** (ask the wiki): consult the **index first**; then `wiki-query <terms>` (deterministic lexical
search, `--type/--tag/--neighbors`) to locate pages; link-walk; **answer with citations** (relative-md
links to the pages used); **file good answers back as pages** so explorations compound.

**Lint** (`hooks/lint.sh`, deterministic, pre-commit-gated): broken links, orphans, missing `type:`,
commit-gate tokens, stale dates, title/alias collisions (two pages claiming one name), pages missing
from their dir's `index.md`, per-type required frontmatter (`type_requirements` in `wiki.config.json`),
dead-end pages (no outgoing wiki links), and supersede hygiene (live links to superseded pages; superseded
chains). Two more advisories are opt-in (disabled by default, both 0, in `wiki.config.json`): an Inbox
soft-cap (`hooks/inbox-check.py`, flags STATE.md's `## Inbox` growing past a configured item/word count)
and timestamp-drift (`hooks/timestamp-drift.py`, flags a page whose last real git edit is newer than its
declared `reviewed:`/`timestamp:` by more than a configured number of days). The judgment pass
(contradictions, stale-superseded claims, missing pages, weak links) is the `reflect` skill — it proposes;
you dispose.

## Staleness policy (no calendar sweeps)
- **Structural** (broken links, orphans, missing `type`) — deterministic, caught continuously by lint.
- **Semantic** (a fact that was true and the world moved on) — caught three ways: point-of-contact
  reconcile (every ingest/query touches related pages), source-freshness triage (`stale-source.py`, flags a
  page when its `synthesized_from:` source changed), and scoped reflection (`reflect`, proposes edits to a
  dated log you confirm). No age-based auto-expiry.
- **Supersede:** a replaced page carries the token `Status: Superseded` (or frontmatter
  `superseded_by:`) + a relative-md pointer to its successor (via `archive/`). Lint flags live pages
  still linking a superseded page, and superseded pages whose pointer targets another superseded page.

## The wiki layout
- [entities/](entities/index.md) — one page per person, org, product, data asset (with `aliases:`).
- [concepts/](concepts/index.md) — one page per domain/analytical concept.
- [notes/](notes/index.md) — source-summary pages (meeting notes etc.), date-prefixed.
- [reference/](reference/index.md) — reference docs + glossaries.
- [analyses/](analyses/index.md) — comparisons / syntheses / filed-back query answers.
- [initiatives/](initiatives/index.md), [decisions/](decisions/index.md), [open-asks/](open-asks/index.md) — the work overlay.
- [archive/](archive/index.md) — completed work, dated, append-only.
- `sources/` — raw, immutable originals; skills read, never edit.
- `sources-media/` — gitignored local archive for recordings that have no platform home; transcripts in
  `sources/` point at their recording (platform URL or this archive) via a provenance `NOTE`.
- [STATE.md](STATE.md) / [ROADMAP.md](ROADMAP.md) — current focus / long-horizon.
- `CLAUDE.md` — your working preferences (loaded every session).

## Local configuration (per-user — the agent reads this)
> Fill this in for your setup; the skills consult it.
- **Owner / voice:** <your name and how you want the agent to write for you>
- **Wiki root:** this directory (set the plugin's `WIKI_ROOT` to match).
- **Knowledge routing (topology):** where knowledge lives, and what belongs HERE. Pick one, record it:
  - `single-wiki` — everything lands in this wiki (solo use; no shared repos or teams).
  - `hub-and-spokes` (the default if you work in shared code/docs repos) — this wiki is your private
    hub; a fact whose audience is a team lives in that team's own home (the repo's committed, reviewed
    docs; a handbook) as ordinary files. The hub keeps YOUR view plus a pointer (an entity/initiative
    page with the remote URL + local path) — never a copy of what the team home already records.
  - `shared-wiki` — this wiki itself is shared by several people (bring your own review norms).
  Two rules make any choice work: **one home per fact, chosen by audience**, and **pointers, not
  copies**. Agents: if this entry is unfilled, ask once and record the answer here — don't guess.
- **Source inbox:** where dropped sources land before ingest (e.g. `~/Downloads`, `sources/`).
- **Corroboration sources:** authoritative places to cross-check claims (org docs, a roster, a handbook).
- **Review gates:** which changes need your sign-off vs. proceed-and-report.
- **Machine-readable settings** live in `wiki.config.json` (content dirs, orphan exemptions, missed-link
  stoplist, thresholds). Edit that file, not the hook scripts.
