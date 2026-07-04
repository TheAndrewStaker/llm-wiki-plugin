---
name: wiki-setup
description: >-
  One-time scaffolding of a knowledge wiki after installing the plugin: create the wiki
  directory from templates, install the deterministic lint gate, and (with confirmation)
  git-init, append the CLAUDE.md contract stanza, and configure Obsidian. Consent-first and
  entry-path aware — never annexes an existing config directory. Use right after installing
  the plugin, or when the user says "set up the wiki", "initialize my wiki", "scaffold a wiki".
---

# wiki-setup: scaffold a wiki (consent-first)

Turn a fresh install into a working wiki. **Every mutation of pre-existing state is an OFFER, not a
default** — this skill must be safe to run against a directory that already holds the user's files.

## Step 1 — Resolve and confirm the wiki root
- Read `WIKI_ROOT` from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT`, else `$WIKI_ROOT`, else default `~/wiki`.
- **State the resolved path and confirm it** before writing anything.
- If the path is `~/.claude` (the power-user layout): warn explicitly — "this shares your Claude Code config
  dir; git-init here will track your personal config unless we use an allowlist gitignore." Only proceed if
  the user confirms; then use the allowlist variant noted in the template `gitignore`.

## Step 2 — Detect the entry situation
- **Fresh** (dir missing or empty) → greenfield: proceed through all steps.
- **Populated** (dir has unrelated files, e.g. an existing `~/.claude`) → ADOPT: create-only. Never
  overwrite an existing file; list what you would add and confirm before each git/CLAUDE.md action.
- **Already a wiki** (has `KNOWLEDGE.md`) → this is a re-run: only fill gaps, idempotently.

## Step 3 — Scaffold the tree (create-only)
Copy `${CLAUDE_PLUGIN_ROOT}/templates/tree/.` into the wiki root, **skipping any file that already exists**.
Rename the template `gitignore` → `.gitignore`. Stamp `timestamp:` in `KNOWLEDGE.md`/`STATE.md`/`ROADMAP.md`
to today (so a fresh wiki isn't born stale). Fill the KNOWLEDGE.md "Local configuration" section by asking
the user the few questions there (name/voice, source inbox, corroboration sources, review gates).

## Step 4 — Install the wiki's own lint scripts
Copy `${CLAUDE_PLUGIN_ROOT}/hooks/`{lint.sh, lint-core.py, graph-check.py, missed-links.py, stale-source.py,
reflect-scope.py, wikilib.py, pre-commit} into `<wiki>/hooks/`. This makes the wiki self-contained — a bare
clone lints without the plugin. (The plugin's SessionStart hook keeps these in sync on version change; it
only overwrites a copy that matches a known prior version, never a locally-modified one.)

## Step 5 — OFFER git + the gate (confirm)
Offer, don't assume: `git init` (if not already a repo), `git config core.hooksPath hooks`, and make the
initial commit yourself (`git add -A && git commit`), showing the user exactly what is in it first. If the
user declines the gate, the wiki still works; lint is just manual.

## Step 6 — OFFER the CLAUDE.md contract stanza (confirm, idempotent)
This is what makes the wiki non-inert — without it, no session knows to consult the wiki. Offer to append
`${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.stanza.md` to `~/.claude/CLAUDE.md`, substituting the real
`WIKI_ROOT` for the placeholder. **Never rewrite CLAUDE.md wholesale; append only, and skip if the stanza is
already present** (idempotent).

## Step 7 — OFFER Obsidian config (confirm)
If the user uses Obsidian: offer to set `.obsidian/app.json` so "Use [[Wikilinks]]" is OFF and new links are
relative-path (load-bearing for cross-tool clickability). Optional; blocks nothing.

## Step 8 — Report + the auto-commit ceremony line
Summarize what was created. State plainly: **"From now on, changes under your wiki auto-commit at the end of
each turn"** (via the plugin's Stop hook), how to see them (`git -C <wiki> log`), and how to turn it off
(disable the plugin, or `wiki-setup --remove-gate`). If a content remote exists, note that commits also push.
Then point the user at `wiki-init` if they have existing docs to migrate.
