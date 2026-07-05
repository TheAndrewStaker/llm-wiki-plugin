---
name: merge-split
description: >-
  Consolidate two wiki pages that turn out to be the same concept (merge), or split one
  overloaded page into qualified pages (split), repointing every inbound link so nothing
  dangles. Use when lint reports a COLLISION, when a query surfaces two pages for one
  thing, or when one page has accreted two distinct meanings. Supersede, never delete.
---

# merge-split: one home per fact, mechanically enforced

The repair operation behind the "one home per fact" rule. Lint's COLLISION advisory (same
title/alias on two pages) is the usual trigger; the fix is judgment (which page survives, what
content moves) plus a deterministic link rewrite so the graph never dangles.

Resolve the wiki root from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`; run scripts
from `$WIKI_ROOT/hooks/`. **Present the plan and get confirmation before writing anything.**

## Merge (two pages, one concept)

1. **Diagnose.** Read both pages and their inbound links (`rewrite-links.py <loser> <survivor>`
   dry-run enumerates them). Confirm they truly are one concept; if the overlap is partial, this
   is a split of one of them instead.
2. **Pick the survivor** (richer page, better home dir, more inbound links) and propose the plan:
   what folds in, what the survivor's `aliases:` gains (the loser's title), which links repoint.
   Get confirmation.
3. **Fold content** into the survivor: merge unique claims (keep `synthesized_from:` provenance
   for anything that moves), add the loser's title/aliases to the survivor's `aliases:`, bump the
   survivor's `timestamp:`.
4. **Repoint inbound links deterministically:**
   ```bash
   python3 "$WIKI_ROOT/hooks/rewrite-links.py" <loser.md> <survivor.md>          # plan
   python3 "$WIKI_ROOT/hooks/rewrite-links.py" <loser.md> <survivor.md> --apply  # write
   ```
5. **Supersede the loser** (never delete): move it under `archive/` with a status token and a
   relative-md pointer to the survivor, per the KNOWLEDGE.md supersede convention. Remove its
   entry from its old dir index.
6. **Verify:** `git add -A`, run `bash "$WIKI_ROOT/hooks/lint.sh"` (green: no broken links, the
   COLLISION cleared), commit ("Merge <loser> into <survivor>").

## Split (one page, two meanings)

1. **Diagnose.** Name the distinct meanings and propose qualified page names
   (`mercury-planet.md` / `mercury-element.md` style). Get confirmation.
2. **Create the qualified pages**, dividing the original's content by meaning; each keeps the
   provenance (`synthesized_from:`) of the claims it received.
3. **Repoint inbound links BY MEANING** (this is per-link judgment, not one bulk rewrite): use
   the dry-run to enumerate linking pages, read each linking context, and edit each link to the
   right qualified page. A bulk `rewrite-links.py --apply` is correct only when every inbound
   link means the same one of the new pages.
4. **Supersede the original** as in merge step 5 (archive + pointer to both successors), or keep
   it as a one-paragraph disambiguation page linking both, whichever the user prefers.
5. **Verify:** index entries updated, lint green, commit ("Split <page> into <a> and <b>").

## Principles

Confirm before writing · survivor keeps the history (supersede via `archive/`, never delete) ·
deterministic rewrite for mechanical repointing, per-link judgment when meaning diverges · the
loser's name lives on as an alias so search still finds it · end green: lint must show the
collision gone and zero broken links.
