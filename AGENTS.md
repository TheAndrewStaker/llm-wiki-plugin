# llm-wiki-plugin — contributor guide (for AI agents and humans)

This is a generic, open-source-bound, dual-harness agent plugin: a compounding knowledge wiki based on
the Karpathy LLM-Wiki pattern and Google OKF. The working name is `llm-wiki-plugin`; the published name
will be `compendium`.

## The overriding rule: no organization-specific content

This repository must work for any user on any machine. Never add employer-specific information: no
organization names, people, products, internal URLs, private terminology, confidential data, or
machine-specific paths. This applies to code, comments, examples, fixtures, documentation, and commits.

- Host-specific settings belong in that wiki's `wiki.config.json` or `status.d/` extensions.
- Re-author dogfooded improvements generically before they land here.
- If content might be too specific, use a neutral placeholder.

## Development loop

The maintainer dogfoods this repository through live skill links. Improvements found in daily use should
be made here, kept generic, and verified before commit.

1. Read the relevant skill and deterministic scripts before changing behavior.
2. Run `bash tests/run.sh`; add assertions for new behavior.
3. Run both plugin validators when available:
   - `claude plugin validate .`
   - `python3 ~/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .`
4. Keep each behavioral phase in a focused commit.

## Conventions

- Commit identity: `Andrew Staker <stephenstaker@gmail.com>`. Do not add AI attribution trailers.
- Portability: POSIX/bash on Unix-like systems; Python is stdlib-only. `jq` is optional. Windows support
  is not currently promised.
- Configuration: host-specific values load from `wiki.config.json`; root resolution is explicit argument,
  then harness-specific plugin option, then `$WIKI_ROOT`, then `~/wiki`.
- Canonical agent instructions live in `AGENTS.md`. `CLAUDE.md` imports this file for Claude compatibility.
- Shared workflows live once under `skills/`; harness manifests point at the same directory.
- Preserve user changes in dirty worktrees and avoid destructive git operations.

## Publish gate

- Ship the complete Apache-2.0 license and a NOTICE attributing the Karpathy LLM-Wiki gist and Google OKF.
- Run a history-aware secret/PII scan and manually inspect every tracked file for private residue.
- Rename the repository, manifests, marketplace metadata, and skill prefix to `compendium` in one release.
- Document security boundaries, contribution rules, compatibility, and migrations.
