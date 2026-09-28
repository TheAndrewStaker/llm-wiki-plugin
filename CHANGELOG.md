# Changelog

This project follows Keep a Changelog and intends to use Semantic Versioning after its first public release.

## [Unreleased]

### Added

- Shared Claude Code and Codex plugin/skill discovery.
- Model-neutral `wiki` CLI, deterministic lint/search, retrieval evaluation, and OKF export validation.
- Immutable source staging with SHA-256 provenance and an explicit untrusted-content policy.
- Hub-and-spoke pointer pages, configurable advisory budgets, and serialized lifecycle writes.
- `meeting-notes` companion sources: extract text and screenshots from a note app entry or an
  exported HTML note captured alongside a transcript, keeping each image marker where it sat in the
  text and writing a readable downscaled copy (`skills/meeting-notes/scripts/extract-companion.py`).

- `bin/wiki-fm`: get and set frontmatter fields. `set` validates the whole edit against
  `initiative_schema` (the commit gate's own rules, now shared as `wikilib.initiative_issues`),
  refuses it with the word count or allowed values, re-reads before an atomic write, bumps
  `timestamp`, and regenerates the board.

### Changed

- The Stop hook attributes an initiative-gate failure before committing. The session whose
  transcript wrote a failing page gets exit 2 once with the failing lines; any other session
  commits everything else, holds the failing pages back, and stays quiet. The pre-commit gate
  judges the staged version of each page (`WIKI_CHECK_INDEX=1`) so a held page does not block.
- `bin/wiki-commit`: commits named paths (or `--all`) through a private index and retries on
  a moved HEAD, so parallel sessions stop committing or unstaging each other's staging. The
  Stop hook commits through it. `agent_commit_guard` (opt-in; `agent_env_vars`, default
  `CLAUDECODE`) makes pre-commit refuse a bare `git commit` from an agent shell.
- Lint history moved to `<git-dir>/compendium/lint-history.tsv`: machine-local, never staged, so
  a commit no longer leaves its own history line dirty. `session-status` reads either location.
- `board.py --write` leaves `STATE.md` alone when only the generated-at stamp would change.
- Auto-commits lint in gate-only mode (`WIKI_LINT_GATE_ONLY=1`): only the checks that can fail
  the commit run, plus any advisory checker a configured budget gates. It prints only failing
  lines and writes no history line. Deliberate commits still run the full lint.
- The edit-time cap hook also runs after Bash calls, checking every `initiatives/` page the
  command visibly writes (`wikilib.bash_writes`, shared with the Stop hook's attribution).
- The personal ask queue is configurable: `initiative_schema.owner` names the `waiting_on`
  value and the `open-asks/<owner>.md` file, `owner_label` the board heading. Default `owner`.
- `frontmatter_value` reads the whole frontmatter block instead of its first 1200 characters,
  so a key below a long flow list is no longer read as absent.

- `wanted-pages` honors `wanted_exempt_dirs`. A dated log entry records what happened; it is not
  where the wiki declares a page worth writing, so `[[...]]` there is prose syntax, not a marker.
- Network push is now opt-in (`auto_push: false` by default).
- The project describes working trees as OKF-aligned and exported bundles as the interchange boundary.
