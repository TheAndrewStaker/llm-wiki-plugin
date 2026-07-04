---
name: query
description: >-
  Answer a question from the wiki the right way: consult the index first, use wiki-query to
  locate pages, link-walk, answer WITH citations, and file a good answer back as a page so
  explorations compound. Use when the user asks something the wiki might know, or says "what do
  we know about X", "check the wiki for", "look up in my notes".
---

# Query the wiki (and file the answer back)

The **Query** operation. The point is not just to answer — it is to answer *from* the compounding artifact
and to *grow* it, so the next query is cheaper. Resolve the wiki root from
`$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`.

## Steps
1. **Index first.** Read the wiki's `KNOWLEDGE.md` and the relevant `*/index.md` — cheap, and it orients the
   search before any retrieval.
2. **Locate with `wiki-query`** (deterministic lexical search; invoke via `python3` for portability,
   the same way the hooks are called):
   ```bash
   python3 "$WIKI_ROOT/bin/wiki-query" <terms>                 # ranked pages
   python3 "$WIKI_ROOT/bin/wiki-query" --type concept <terms>  # filter by frontmatter type
   python3 "$WIKI_ROOT/bin/wiki-query" --tag <tag> <terms>
   python3 "$WIKI_ROOT/bin/wiki-query" --neighbors <terms>     # 1-hop link neighbors of the top hits
   ```
3. **Link-walk** from the top hits (relative-md links) to gather the full picture; read the pages, not just
   the catalog rows.
4. **Answer WITH citations** — reference the wiki pages you used as relative-md links, so the answer is
   traceable and the user can correct the source, not just the answer.
5. **File it back.** If the answer is a genuine synthesis (not already a page), write it as an `analyses/`
   page (or fold it into the right entity/concept page), with `synthesized_from:` if there was a source,
   cross-linked. Folding into an existing page is a meaningful edit — bump that page's `timestamp:` to
   today (cosmetic edits bump nothing; `reviewed:` = re-verification only). Add an index row, run `bash "$WIKI_ROOT/hooks/lint.sh"`, commit. This is the compounding
   move — the cheapest big win in the whole system. Respect the wiki's declared knowledge topology
   (KNOWLEDGE.md "Local configuration"): an answer whose audience is a team belongs in the team's own home,
   with a pointer page here.

## If query keeps missing
When `wiki-query` returns nothing for a fact you know exists (or later file), note it — a systemic pattern of
misses is the signal to add aliases/cross-links, fix an index, or (only past ~100 sources / when the index
stops fitting one read) consider adding semantic retrieval. Until then, agentic search + the catalog suffice.
