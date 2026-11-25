---
name: brief
description: >-
  Brief the user on one initiative before any work starts, from the wiki's recorded facts plus a
  read-only check of what can have changed on its own. Use at the start of a resumed or launched
  session, when the user says "brief me", "where does X stand", "catch me up on X", or /brief
  [initiative]. Read-only until the user picks what to take.
---

# Brief

A briefing is read-only. Nothing is edited, posted, committed or started until the user says which
thing to take; they may want to discuss the briefing first.

## Steps

1. **Recorded facts.** Run `python3 "${CLAUDE_PLUGIN_ROOT}/bin/wiki-brief-facts" [<initiative-slug>]`
   (outside Claude Code, the `bin/wiki-brief-facts` of the plugin checkout). With no slug it resolves
   the open initiative whose `repos:` lists the current repository; if it lists several, ask which.
   It prints the position (`next`), `verify`, waiting state, the position's age, journal lines tagged
   with the slug and commits since the position was written, and commits in each listed repository
   (found under `repos_root` in `wiki.config.json`).
2. **The page.** Read the initiative page it names: open scopes and the dated log entries since the
   position was written.
3. **What can change on its own.** Check, read-only, each external thing the position points at:
   threads, pull requests under `prs:`, CI runs, deploys. Measure the current state; do not infer it
   from the page.
4. **A stale position.** When the facts mark the position STALE, treat `next` as a claim to verify,
   not as the state. Say in the first line of the briefing what no longer holds.

## The reply

Short, in this order, with a confidence marker on each claim (confirmed, reported, inferred,
unconfirmed):

- Where it stands.
- What changed since the position was written.
- Decisions waiting on the user.
- The one step you recommend.

Then wait.

## After the user picks

- If the position still holds and they confirm it, re-set the same text so the board records the
  re-verification: `wiki-fm set initiatives/<slug>.md next="<the same text>"`.
- If it changed, write the new position as a statement of where things are, never as an instruction.
