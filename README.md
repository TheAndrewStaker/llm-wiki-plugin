# llm-wiki-plugin

> Working name. The published name will be **compendium**; this repo is private during dogfooding and internal sharing.

A compounding, file-based knowledge wiki for AI agents, packaged as a Claude Code plugin. Markdown + YAML frontmatter, a deterministic lint gate, agentic lexical search, and skills for setup / migrate / ingest / query / reflect / wrap.

## Lineage

This implements three published conventions and adopts their shared vocabulary:

- **Karpathy, "LLM Wiki"** — the pattern: three layers (raw sources / the wiki / the schema), three operations (Ingest / Query / Lint), an index + a log, and *compounding* knowledge rather than query-time RAG.
- **Google Cloud, Open Knowledge Format (OKF) v0.1** — the on-disk format: markdown + YAML frontmatter, one required field `type:`, concept-id = file path, a markdown-link graph.
- **Anthropic context engineering** — filesystem-as-substrate, agentic search before semantic retrieval, human-authored schema vs. agent-authored content, progressive disclosure, subagents for context isolation.

## What it does (the lifecycle)

1. **Set up** — the `wiki-setup` skill scaffolds a wiki from `templates/` (type-dir tree, `KNOWLEDGE.md` schema/index, `STATE.md`, allowlist `.gitignore`, `wiki.config.json`), installs the wiki's **own copies** of the lint scripts into `<wiki>/hooks/` (a bare clone lints without the plugin), and — each with confirmation — git-inits, wires the pre-commit gate (`core.hooksPath hooks`), appends the CLAUDE.md contract stanza, and configures Obsidian. Consent-first: every mutation of pre-existing state is an offer.
2. **Migrate existing docs** — the `wiki-init` skill populates the wiki from a doc pile via a multi-agent Workflow: deterministic scan → classification manifest with a **mandatory human approval gate** → fan-out drafting onto a **git review branch** → dedupe/cross-link/lint fan-in → user merges to apply. Create-only and reversible; also covers adopt (coworker's existing config dir) and clone (wiki exists elsewhere) entry paths.
3. **Run the daily loop** —
   - **SessionStart**: `hooks/session-status.sh` injects the wiki's `STATE.md` focus block plus health warnings (and per-org `status.d/*.sh` drop-ins) into every session.
   - **Query**: the `query` skill (index-first, link-walk, answer with citations, file the answer back) on top of `bin/wiki-query` lexical search.
   - **Ingest**: `ingest-source` (articles/PDFs/books) and `meeting-notes` (transcripts) stage raw sources in `sources/` and write cross-linked synthesis pages.
   - **Reflect**: scoped, reversible staleness/contradiction pass — proposals to a dated log, applied only after user confirmation. `hooks/reflect-scope.py` bounds each pass; `hooks/stale-source.py` flags pages whose `synthesized_from:` source changed.
   - **Wrap**: the `/wrap` command files a session's durable findings and commits.
   - **Auto-commit**: `hooks/auto-commit.sh` (Stop/SessionEnd hooks) commits wiki changes at the end of each turn, so the wiki is always versioned without ceremony.
   - **Lint gate**: `hooks/lint.sh` hard-fails on broken links, unresolved commit-gate tokens, and malformed YAML frontmatter (fail-closed: a crash blocks, never passes blind); orphans / islands / missed-links / no-type / stale are advisory. Runs as the wiki's pre-commit and on demand.

## What's here

- `hooks/` — the deterministic engine: `lint.sh` (+ `lint-core.py`, `graph-check.py`, `missed-links.py`), `stale-source.py`, `reflect-scope.py`, and lifecycle hooks `session-status.sh` / `auto-commit.sh` / `pre-commit`. All read per-wiki settings from `wiki.config.json` via `wikilib.py`; no host-specific assumptions.
- `bin/wiki-query` — deterministic BM25 lexical search (no model, no network): `wiki-query [--type T] [--tag T] [--neighbors] [--limit N] TERMS`, `--catalog` to (re)write `catalog.tsv`, `--health` for a deterministic index-size recall tripwire. **Indexes git-tracked pages only** (`git ls-files`; `sources/` excluded) — a page is findable once committed, which the auto-commit hook does each turn; in a wiki that is not a git repo, search returns nothing.
- `templates/` — wiki scaffolding: the full type-dir tree with index stubs, `KNOWLEDGE.md` / `STATE.md` / `ROADMAP.md`, `wiki.config.json`, the allowlist `gitignore` (renamed on install), and `CLAUDE.stanza.md` (the contract that makes sessions consult the wiki).
- `skills/` — `wiki-setup`, `wiki-init`, `reflect`, `ingest-source`, `meeting-notes`, `query`; plus `commands/wrap.md` (the `/wrap` slash command).
- `tests/` — self-contained golden-output harness (`bash tests/run.sh`): builds a throwaway fixture wiki with git history and asserts over the lint / query / stale / health stack.
- `scripts/check-no-org.sh` — org-residue scanner (terms live in a gitignored denylist), run as part of the test suite.

## Configuration seam

Three seams, each matched to its consumer:

- **Per-machine (paths):** the plugin's `userConfig.WIKI_ROOT` (defaults to `~/wiki`); scripts also honor `$WIKI_ROOT` and an explicit argv path.
- **Per-user, content-coupled:** `wiki.config.json` at the wiki root (content dirs, orphan exemptions, missed-link stoplist, thresholds) — versioned with the content.
- **Per-org:** drop-in extension dirs (`status.d/*.sh` for session-start context injection); nothing host-specific in core.

## One wiki or many? (topology)

Exactly **one personal hub per human** gets the machinery — session injection, search, lint gate,
auto-commit. Knowledge whose audience is a team belongs in that team's own home (a repo's committed,
PR-reviewed docs) as ordinary files; the hub links to it with **pointer pages** rather than copies. Two
rules: one home per fact, chosen by audience; pointers, not copies. Each wiki records its chosen topology
in `KNOWLEDGE.md` "Local configuration" (`wiki-setup` asks at scaffold time); if it is unrecorded, agents
should ask once and record the answer, not guess. A shared team wiki is possible — it is just another wiki
with its own review norms — but multi-root sessions and plugin tooling over repo docs deliberately do not
exist: repo docs are already in front of any agent working in that repo.

## Status

The core loop (setup → migrate → ingest/query/reflect/wrap, lint gate, auto-commit, session injection) is implemented and dogfooded daily against the maintainer's live wiki. Remaining work before publishing is packaging, not functionality — see "Publish-gate TODOs" in `CLAUDE.md`.

## Verifying a checkout

```sh
bash tests/run.sh           # golden assertions; must end PASS=n FAIL=0
claude plugin validate .    # manifest check
```

## License

Apache-2.0 (see `LICENSE`).
