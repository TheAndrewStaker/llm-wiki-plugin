---
description: End-of-session wrap-up — synthesize this session's durable findings into the wiki, file decisions, update STATE if focus changed, lint, and commit.
---

Conclude this session by filing its **durable** findings into the wiki, then commit. (Routine capture is
already auto-committed each turn by the plugin's Stop hook; this is the synthesis a hook cannot do.) Resolve
the wiki root from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`.

1. Review what this session did. Separate **durable** findings (decisions, verified facts, syntheses, new
   entities/concepts, refined open-asks) from throwaway chatter. Skip the chatter.
2. File the durable items per the wiki's `KNOWLEDGE.md` (Operations + decision routing):
   - **Route by the wiki's declared knowledge topology first** (KNOWLEDGE.md "Local configuration"): a
     finding whose audience is a team goes to that team's home (the repo's committed docs), and the wiki
     gets your view + a pointer page. If no topology is recorded, ask once and record it.
   - analysis / good Q&A → a page in the right type-dir (`analyses/` / `concepts/` / `entities/` / `notes/`),
     with `synthesized_from:` when there is a source; cross-link with relative md links.
   - decisions → `decisions/<name>.md`; open asks you owe someone → `open-asks/<who>.md`.
   - if the current focus changed, update `STATE.md` (append to `## Inbox`; don't reorder `Focus`/`Up next`).
   - link, don't duplicate.
3. Run `bash "$WIKI_ROOT/hooks/lint.sh"`; fix any broken links or unresolved tokens.
4. Commit the wiki changes.
5. Report a 2-line summary of what was filed. It is now safe to end the session.
