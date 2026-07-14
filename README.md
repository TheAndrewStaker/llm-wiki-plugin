# llm-wiki-plugin

> Working name. The published name will be **compendium**; this repo is private during dogfooding and internal sharing.

A compounding, file-based knowledge wiki for AI agents, packaged for Claude Code and Codex from one
shared skill tree. Markdown + YAML frontmatter, a deterministic lint gate, agentic lexical search, and
skills for setup / migrate / ingest / query / reflect / wrap.

The model-neutral entry point is `bin/wiki`: `status`, `query`, `health`, `eval`, `lint`, `stage`, `pointer`, and
`okf` expose the deterministic substrate without requiring either agent harness.

For local Codex development, register this checkout as a marketplace with
`codex plugin marketplace add /path/to/llm-wiki-plugin`, then install
`codex plugin add llm-wiki-plugin@llm-wiki-plugin`. Restart Codex after installation so it rebuilds the
skill catalog. The repository-local marketplace points back to this plugin root, so development updates
remain testable without publishing.

## Lineage

This implements three published conventions and adopts their shared vocabulary:

- **Karpathy, "LLM Wiki"** — the pattern: three layers (raw sources / the wiki / the schema), three operations (Ingest / Query / Lint), an index + a log, and *compounding* knowledge rather than query-time RAG.
- **Google Cloud, Open Knowledge Format (OKF) v0.1** — the on-disk format: markdown + YAML frontmatter, one required field `type:`, concept-id = file path, a markdown-link graph.
- **Anthropic context engineering** — filesystem-as-substrate, agentic search before semantic retrieval, human-authored schema vs. agent-authored content, progressive disclosure, subagents for context isolation.

### OKF compatibility

The private working tree is **OKF-aligned, not itself an interchange bundle**: it also contains raw sources, agent instructions, configuration, hooks, and git history. Run `bin/wiki-okf export <wiki-root> <empty-destination>` to produce the public, Markdown-only boundary, then `bin/wiki-okf validate <destination>` to check its structure. The exporter excludes operational/private material along with working-tree `index.md`/`log.md` files, and generates canonical navigation indexes instead; the bundle-root index declares `okf_version: "0.1"`.

Concept pages map directly to OKF v0.1: Markdown + YAML frontmatter with `type:` as the only required field; `title` / `description` / `tags` / `timestamp` carry OKF's recommended semantics; file paths identify concepts; relative Markdown links form the graph. `resource:` keeps its OKF meaning (the asset a concept describes) and is distinct from plugin extensions such as `synthesized_from:`, `reviewed:`, and `aliases:`. Validation is conservative and fail-closed: it uses PyYAML when installed or Ruby's YAML parser otherwise, and refuses to certify a bundle when neither parser is available.

## What it does (the lifecycle)

1. **Set up** — the `wiki-setup` skill scaffolds a wiki from `templates/` (type-dir tree, `KNOWLEDGE.md` schema/index, `STATE.md`, allowlist `.gitignore`, `wiki.config.json`), installs the wiki's **own copies** of the lint scripts into `<wiki>/hooks/` (a bare clone lints without the plugin), and — each with confirmation — git-inits, wires the pre-commit gate (`core.hooksPath hooks`), appends the CLAUDE.md contract stanza, and configures Obsidian. Consent-first: every mutation of pre-existing state is an offer.
2. **Migrate existing docs** — the `wiki-init` skill populates the wiki from a doc pile via a multi-agent Workflow: deterministic scan → classification manifest with a **mandatory human approval gate** → fan-out drafting onto a **git review branch** → dedupe/cross-link/lint fan-in → user merges to apply. Create-only and reversible; also covers adopt (coworker's existing config dir) and clone (wiki exists elsewhere) entry paths.
3. **Run the daily loop** —
   - **SessionStart**: `hooks/session-status.sh` injects the wiki's `STATE.md` focus block plus health warnings (and per-org `status.d/*.sh` drop-ins) into every session.
   - **Query**: the `query` skill (index-first, link-walk, answer with citations, file the answer back) on top of `bin/wiki-query` lexical search.
   - **Ingest**: `ingest-source` (articles/PDFs/books) and `meeting-notes` (existing transcripts or locally transcribed audio/video recordings) treat all acquired text as untrusted data, stage immutable bytes in `sources/`, record SHA-256 provenance in `.compendium/ingest-ledger.jsonl`, and write cross-linked synthesis pages.
   - **Reflect**: scoped, reversible staleness/contradiction pass — proposals to a dated log, applied only after user confirmation. `hooks/reflect-scope.py` bounds each pass; `hooks/stale-source.py` flags pages whose `synthesized_from:` source changed.
   - **Audit**: per-page citation check (`audit` skill) — verify each claim against the sources it cites (subagent per source, optional adversarial pass), findings to a checkbox report, applied only after confirmation.
   - **Merge/split**: the `merge-split` skill repairs "one home per fact" violations (lint's COLLISION advisory) — fold duplicates into a survivor or split an overloaded page, with `hooks/rewrite-links.py` repointing every inbound link deterministically; superseded pages archive, never delete.
   - **Wrap**: the `wrap` skill (`$wrap` in Codex; `/wrap` is also recognized in Claude) files a session's durable findings and commits.
   - **Auto-commit**: `hooks/auto-commit.sh` serializes Stop/SessionEnd mutations and commits wiki changes when `auto_commit` is enabled. Network push is separately opt-in with `auto_push`; both live in `wiki.config.json`.
   - **Lint gate**: `hooks/lint.sh` hard-fails on broken links, unresolved commit-gate tokens, and malformed YAML frontmatter (fail-closed: a crash blocks, never passes blind); advisory warnings cover orphans, islands, missed links, missing `type:`, stale dates, title-alias collisions, unindexed pages, per-type missing frontmatter (`type_requirements`), dead-end pages, supersede hygiene (live links to superseded pages, superseded chains), and the wanted-pages red-link ranking. Runs as the wiki's pre-commit and on demand.

## What's here

- `hooks/` — the deterministic engine: `lint.sh` (+ `lint-core.py`, `graph-check.py`, `missed-links.py`, `wanted-pages.py`), `stage-source.py`, `stale-source.py`, `reflect-scope.py`, `rewrite-links.py`, and lifecycle hooks `session-status.sh` / `auto-commit.sh` / `pre-commit`. All read per-wiki settings from `wiki.config.json` via `wikilib.py`; no host-specific assumptions.
- `bin/wiki-query` — deterministic BM25 lexical search (no model, no network): `wiki-query [--type T] [--tag T] [--neighbors] [--limit N] TERMS`, `--catalog` to (re)write `catalog.tsv`, `--health` for a deterministic index-size recall tripwire. **Indexes git-tracked pages only** (`git ls-files`; `sources/` excluded) — a page is findable once committed, which the auto-commit hook does each turn; in a wiki that is not a git repo, search returns nothing.
- `templates/` — wiki scaffolding: the full type-dir tree with index stubs, `KNOWLEDGE.md` / `STATE.md` / `ROADMAP.md`, `wiki.config.json`, the allowlist `gitignore` (renamed on install), and `CLAUDE.stanza.md` (the contract that makes sessions consult the wiki). Plus `ci/wiki-health.yml`, an optional GitHub Actions workflow that runs the deterministic health stack weekly and keeps the report in one recurring issue (the judgment passes stay interactive by design); it also carries an opt-in lychee job for external-URL rot, since CI is where the network lives (local tooling stays offline and reports URLs as UNCHECKABLE).
- `skills/` — `wiki-setup`, `wiki-init`, `reflect`, `audit`, `merge-split`, `ingest-source`, `meeting-notes`, `query`, `wrap`. Both harness manifests point at this one open `SKILL.md` tree. Invoke skills explicitly as `$wrap` in Codex; Claude also recognizes the natural-language and `/wrap` conventions described by the skill.
- `tests/` — self-contained golden-output harness (`bash tests/run.sh`): builds a throwaway fixture wiki with git history and asserts over the lint / query / stale / health stack.
- `evals/` — labeled retrieval-case format for `wiki eval --cases <file>`; reports Recall@k and MRR and can enforce a minimum recall in CI.
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

The core loop (setup → migrate → ingest/query/reflect/wrap, lint gate, auto-commit, session injection) is implemented and dogfooded. This is still a pre-release project: complete [the public release checklist](docs/release-checklist.md) before publishing or treating compatibility as stable.

## Verifying a checkout

```sh
bash tests/run.sh           # golden assertions; must end PASS=n FAIL=0
claude plugin validate .    # manifest check
```

## License

Apache-2.0 (see `LICENSE` and `NOTICE`). Contributions and security reporting are documented in
`CONTRIBUTING.md` and `SECURITY.md`.
