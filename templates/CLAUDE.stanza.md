<!--
  wiki-setup appends this stanza to your ~/.claude/CLAUDE.md (with your confirmation).
  It is what tells every session the wiki exists. Edit the path if your WIKI_ROOT differs.
  This file is the template; the real copy lives in your CLAUDE.md.
-->

## Knowledge wiki

I keep a compounding knowledge wiki at `WIKI_ROOT_PLACEHOLDER` (markdown + YAML frontmatter, git-versioned;
follows the Karpathy LLM-Wiki pattern + Google OKF).

- **On any question that might be answered there, read `WIKI_ROOT_PLACEHOLDER/KNOWLEDGE.md` first** (the
  entry map + conventions), then use `python3 "WIKI_ROOT_PLACEHOLDER/bin/wiki-query" <terms>` to locate pages, and cite the pages you used.
- **When I conclude work, hit a blocker, or find something high-priority, update `STATE.md`** and file
  durable findings as wiki pages (don't let them evaporate into the conversation).
- **The body goes on the page it belongs to; the Inbox gets one line pointing at it.** Locate the
  `## Inbox` heading in `STATE.md` and append directly beneath it. Appending to the end of the FILE
  drops the entry into whatever section happens to be last, which is the most common way this goes
  wrong. Never rewrite the focus block from a parallel session; append instead.
- **A subagent's report is not an Inbox entry.** File it as a page first, then leave the one-line
  pointer. Delegated sessions have several reports to land and no cheaper place to put them, which is
  how a handoff meant to be read in one pass becomes a second untriaged backlog.
- Follow the wiki's conventions (in `KNOWLEDGE.md`): `type:` frontmatter, relative-md links, link-don't-
  duplicate, supersede-don't-delete.
