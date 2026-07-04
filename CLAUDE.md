# llm-wiki-plugin — contributor guide (for AI agents and humans)

This is a **generic, open-source-bound Claude Code plugin** — a compounding knowledge wiki (Karpathy
LLM-Wiki pattern + Google OKF). Working name `llm-wiki-plugin`; the published name will be **compendium**.
Published PRIVATE under a **personal GitHub account** (`TheAndrewStaker`), intended to work for **anyone**.

## The one rule that overrides everything: NO org-specific content

This repo must work for any user on any machine. **Never** put company/employer-specific information into
it — no org names, people, product names, internal URLs, domain jargon, confidential data, or paths tied to
one workplace. Not in code, not in comments, not in examples, not in test fixtures, not in commit messages.

- Anything a specific user/org needs (orphan exemptions, missed-link stopwords, content dirs, assignment
  injectors) belongs in **that user's** `wiki.config.json` or `status.d/` drop-ins — never hardcoded here.
- The maintainer dogfoods this against a work knowledge base, but that base is a SEPARATE, private thing.
  When porting an improvement from there, **re-author it generically** (strip the specifics) before it lands.
- If you're unsure whether something is too specific: it is. Use a neutral placeholder.

## How it's dogfooded (the live loop)

The maintainer runs this against their own wiki via a **skills-dir symlink**
(`~/.claude/skills/llm-wiki-plugin` → this repo), so edits here are live after `/reload-plugins`. Their
wiki's pre-commit gate also delegates to this repo's `hooks/lint.sh`. So: **improvements and corrections
found while using the wiki get made HERE**, then flow back into daily use immediately.

When you find a bug, missing capability, or rough edge while using the wiki:
1. Fix or add it in this repo (generic — see the rule above).
2. Run `bash tests/run.sh` — it must stay green (9 golden assertions across the lint/query/stale stack).
   Add a new assertion when you add behavior.
3. `claude plugin validate .` must pass.
4. Commit (author identity below). Note anything notable in the maintainer's wiki initiative
   `initiatives/wiki-plugin.md` so the intent survives across sessions.

## Conventions
- **Commit identity:** `Andrew Staker <stephenstaker@gmail.com>`. **No AI co-authorship/attribution** in
  commits or PRs.
- **Portability:** shell is POSIX/bash (no zsh-isms); Python is stdlib-only (no third-party deps). jq is the
  one optional external tool (hooks degrade without it). Windows is out of scope.
- **Config seam:** host-specific values load from the wiki's `wiki.config.json` via `hooks/wikilib.py`;
  the wiki root resolves from `CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`.

## Publish-gate TODOs (before this repo goes public)
- Replace the `LICENSE` stub with the full Apache-2.0 text + a `NOTICE` attributing the Karpathy LLM-Wiki
  gist and Google OKF v0.1.
- Run a secret/PII scan (gitleaks/trufflehog) and a manual read of every file for org residue.
- Rename to `compendium` (repo, marketplace, plugin, skill prefix) in one pass.
