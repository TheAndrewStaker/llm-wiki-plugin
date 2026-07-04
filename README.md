# llm-wiki-plugin

> Working name. The published name will be **compendium**; this repo is private during dogfooding and internal sharing.

A compounding, file-based knowledge wiki for AI agents, packaged as a Claude Code plugin. Markdown + YAML frontmatter, a deterministic lint gate, agentic lexical search, and skills for ingest / query / reflect / migrate.

## Lineage

This implements three published conventions and adopts their shared vocabulary:

- **Karpathy, "LLM Wiki"** — the pattern: three layers (raw sources / the wiki / the schema), three operations (Ingest / Query / Lint), an index + a log, and *compounding* knowledge rather than query-time RAG.
- **Google Cloud, Open Knowledge Format (OKF) v0.1** — the on-disk format: markdown + YAML frontmatter, one required field `type:`, concept-id = file path, a markdown-link graph.
- **Anthropic context engineering** — filesystem-as-substrate, agentic search before semantic retrieval, human-authored schema vs. agent-authored content, progressive disclosure, subagents for context isolation.

## What's here (status: extraction in progress)

- `hooks/` — the deterministic engine: `lint.sh` (+ `lint-core.py`, `graph-check.py`, `missed-links.py`), `stale-source.py`, `reflect-scope.py`, and lifecycle hooks `session-status.sh` / `auto-commit.sh` / `pre-commit`. All read per-wiki settings from `wiki.config.json` via `wikilib.py`; no host-specific assumptions.
- `bin/` — `wiki-query` lexical search + catalog generator (TODO).
- `templates/` — wiki scaffolding: `KNOWLEDGE.md`, `STATE.md`, `ROADMAP.md`, the CLAUDE.md contract stanza, the allowlist `.gitignore`, type-dir index stubs (TODO).
- `skills/` — `wiki-setup`, `wiki-init`, `reflect`, `ingest-source`, `meeting-notes`, `query`, `wrap` (TODO).
- `tests/` — a fixture mini-wiki + golden-output tests for the lint and query stack.

## Configuration seam

Three seams, each matched to its consumer:

- **Per-machine (paths):** the plugin's `userConfig.WIKI_ROOT` (defaults to `~/wiki`); scripts also honor `$WIKI_ROOT` and an explicit argv path.
- **Per-user, content-coupled:** `wiki.config.json` at the wiki root (content dirs, orphan exemptions, missed-link stoplist, thresholds) — versioned with the content.
- **Per-org:** drop-in extension dirs (`status.d/*.sh` for session-start context injection); nothing host-specific in core.

## License

Apache-2.0 (see `LICENSE`).
