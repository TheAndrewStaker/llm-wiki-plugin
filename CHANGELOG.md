# Changelog

This project follows Keep a Changelog and intends to use Semantic Versioning after its first public release.

## [Unreleased]

### Added

- Tiers on the board (`initiative_schema.kind_tier`, `tier_labels`; off by default): rows group by
  tier first, so a lower tier always outranks a higher one, and `priority` orders within a tier.
- Dated owner queue (`queue_dated`): bullets in `open-asks/<owner>.md` must start
  `- [ ] YYYY-MM-DD · <source> · `; the gate refuses others, and the board header shows the oldest age.
- `hooks/queue-expire.py`: archives queue bullets without asking, at most once a day from the Stop
  hook. Checked bullets go; others' asks go only when every owner initiative (linked after the last
  `→`) is done; `queue_self_label` bullets also go when owners are parked or the bullet's date is
  older than `queue_self_expire_days`. Each run is its own commit to `archive/<YYYY-MM>.md` plus a
  journal line; it skips when those files have pending edits and rolls back a refused commit.
- SessionStart reads its input: after a compaction, or a `/clear` (the transcript that ran it), it
  points the agent at the earlier transcript and `hooks/user-turns.py`, which prints the user's typed
  turns, so anything asked for only in chat gets filed.
- Log guard (`log_guard` config, off by default): a PostToolUse recorder (`hooks/session-record.py`)
  notes each session's work events (a commit or PR command run outside the wiki; optionally any file
  write outside it) and log events (a write under `initiatives/` or `journal/`, `wiki-fm set`,
  `journal-append`). At Stop, `hooks/log-guard.py` blocks once, through the auto-commit hook's exit,
  when work followed the last log event, naming the work and the two ways to record it. A
  continuation never re-evaluates, so a stop chain blocks at most once. Subagent tool calls arrive
  on the parent session, so delegated work and delegated logging both count.
- Transition rules in `initiative_schema`: `required_at_status` (`{"done": ["verify"]}`) fails a
  page that reaches a status without the field, or that had it and drops it; pages already in the
  status without it are grandfathered. `active_max` fails a page becoming `active` when the active
  count would exceed the cap, and the board header shows `active N/M`. Both are judged against HEAD
  (staged renames followed) by the commit gate, at the edit by `initiative-caps.py`, and against the
  on-disk page by `wiki-fm set`.
- `missed-links.py --delta` and the `missed_links_added` budget: the commit gate can refuse a page
  that newly names a wiki page without linking it, judged per changed page against HEAD, so the
  author hears it and a wiki-wide total never blocks someone else's commit.
- The auto-commit hook attributes every gate line that names a page (schema, hard checks, budgeted
  counters) to the session that wrote the page, not only the initiative schema; a failed budget now
  prints the offending lines, in gate-only mode too.
- Standing aims (`aims` config: file and heading): append-only `aim:<slug>` lines checked for
  grammar, dates and a carrier that is an initiative page at commit; session start names aims whose
  carrier is done or parked or whose review is overdue; the `reflect` skill reviews them against the
  board.
- `templates/scope.md`: a sub-item template (problem, files and interfaces, out of scope, automated
  check, manual check with the setup command, done when).
- OKF v0.2 export: `wiki-okf export` synthesizes `generated`, `verified`, `sources`, `status` and
  offset-bearing timestamps from what pages already carry (config `okf.generated_by`,
  `okf.verifier`), stamps `okf_version: "0.2"`, and the validator accepts any `X.Y` version, rejects
  a `status` outside the spec enum, a timestamp without an offset, and an `Attested Computation`
  without `runtime`. An author's own `status` outside the enum is exported as `wiki_status`.
- The commit gate reads the index being committed (`WIKI_CHECK_INDEX=1`): `wikilib.read` serves
  tracked pages from a one-shot `git cat-file --batch` of the index, so lint-core and graph-check
  judge what the commit contains and another session's uncommitted page can no longer fail it.
- Session start resumes the initiative bound to the directory: `board.py --repo NAME` prints a
  resume block for every initiative whose `repos:` lists NAME (rank, status, `next`, `verify`,
  waiting state, open `### scope · status` headings, page path), whether or not it is waiting on
  someone; the old one-line pointer remains only when no initiative lists the repo, and says so.
  `session-status.sh` resolves a linked worktree to its main repository's name.
- The log-guard recorder tokenizes each shell segment: a commit string inside a grep is not work,
  `git -C <dir> commit` is judged by `<dir>`, a `cd` earlier in the command moves later segments,
  "nothing to commit" and interrupted calls are not work, a log command whose output carries its
  own error prefix is not a log, and an edit to an index page is not a log.

- Optional initiative `verify` field: how to tell `next` is done. Capped by `verify_max_words`
  like `next`, checked by the commit gate and `wiki-fm`, and shown on the board row after `next`.
- Board period auto-derivation: optional `cycle_source` config (glob of per-period markdown
  files, start/end frontmatter fields, label from file name) sets the board's current period and end
  date at generation time; `current_cycle`/`cycle_ends` remain the fallback, and the header names
  which source was used. A missing or unsynced source degrades to the fallback with a visible note.
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
