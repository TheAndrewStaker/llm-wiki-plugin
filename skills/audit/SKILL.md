---
name: audit
description: >-
  Per-page citation audit: verify every factual claim on a wiki page against the sources it
  cites, flag uncited claims, and propose corrections as a checkbox report the user confirms
  before anything lands (reflect-style propose/apply). Use before sharing or relying on a
  page, after a heavy ingest, or when the user asks to fact-check or audit a page.
---

# audit: fact-check one page against its sources

Reflect finds *structural* rot (contradictions between pages, superseded claims). Audit checks
something reflect never does: whether the page's claims are actually **supported by the sources
they cite**. It is page-scoped, subagent-isolated, and reversible: findings go to a dated report,
and nothing on the target page changes until the user confirms.

Resolve the wiki root from `$CLAUDE_PLUGIN_OPTION_WIKI_ROOT` / `$WIKI_ROOT` / `~/wiki`.

## Phase A — VERIFY (no page edits)

### A1. Scope
One page per run, named by the user (or located via `wiki-query`). Collect its sources: the
frontmatter `synthesized_from:` plus any inline links into `sources/`. If a source is a URL that
was never staged, its claims are **unverifiable-here**, not wrong; say so rather than guessing.

### A2. Extract claims
Read the page and list its checkable factual assertions (names, numbers, dates, quotes, causal
statements). Classify each: **cited** (traceable to a listed source) or **uncited**. Skip pure
opinion/synthesis framing; the unit of audit is a claim a source could confirm or deny.

### A3. Verify in subagents (context isolation)
Spawn one subagent per source; each reads ONLY that source and returns per-claim verdicts, no
page edits: **supported** (with the supporting quote; verbatim quotes must string-match the
source), **unsupported** (source is silent), **contradicted** (source says otherwise; quote it),
or **unverifiable** (source unreadable/URL-only).

### A4. Adversarial pass (optional, for pages that matter)
Spawn one more subagent prompted to REFUTE the page's central claims using only the same sources.
Anything it refutes that A3 called supported becomes a finding with both quotes side by side.

### A5. Write the audit report (the reversible artifact)
Write `analyses/audit-<page-slug>-YYYY-MM-DD.md` (frontmatter `type: analysis`, `title`,
`timestamp`, `synthesized_from:` = the audited page + its sources). Body: one **checkbox per
finding** (uncited / unsupported / contradicted), each quoting the page's claim, the verdict,
the evidence, and the proposed fix (exact replacement text, a citation to add, or removal).
End with the tally (N claims, N supported, N findings). Add a line to `analyses/index.md`, run
`bash "$WIKI_ROOT/hooks/lint.sh"` (green), commit ("Audit <page> YYYY-MM-DD"). The audited page
has not changed.

## Phase B — APPLY (separate invocation, only confirmed items)

1. Act ONLY on items checked `- [x]` in the report: fix the claim, add the citation, or remove
   the unsupportable sentence (supersede conventions apply if a claim moves to `archive/`).
2. Set the page's `reviewed:` to today; do not silently bump `timestamp:`.
3. Mark applied items `- [x] APPLIED`; run lint (green); commit ("Apply audit fixes <page>").

## Principles

Page-scoped, never a whole-wiki sweep · claims verified against sources, not against the model's
memory · verbatim quotes must string-match · unverifiable is an honest verdict, not a failure ·
no unconfirmed writes; propose and apply are separate commits.
