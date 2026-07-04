#!/usr/bin/env bash
# Guard behind the "no org-specific content" rule (see CLAUDE.md). Ships the SCANNER, never the
# TERMS: reads a gitignored denylist ($LLM_WIKI_ORG_DENYLIST or <repo>/.org-denylist, one
# term/ERE per line, # comments allowed) and fails if any term appears in a git-tracked file.
# Skips (passes) when no denylist is present, so the public repo ships this check without the
# maintainer's private term list. Run standalone or from tests/run.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="${LLM_WIKI_ORG_DENYLIST:-$ROOT/.org-denylist}"
if [ ! -f "$LIST" ]; then echo "org-scan: no denylist at $LIST -> skipped (provide one to enable)"; exit 0; fi
terms=$(grep -vE '^[[:space:]]*(#|$)' "$LIST" || true)
[ -z "$terms" ] && { echo "org-scan: denylist empty -> skipped"; exit 0; }
hits=0
while IFS= read -r term; do
  [ -z "$term" ] && continue
  while IFS= read -r f; do
    if grep -iInE -- "$term" "$ROOT/$f" >/dev/null 2>&1; then
      echo "org-scan: FORBIDDEN /$term/ in $f"
      hits=$((hits + 1))
    fi
  done < <(git -C "$ROOT" ls-files)
done <<< "$terms"
if [ "$hits" -gt 0 ]; then
  echo "org-scan: FAIL ($hits match(es)) -- remove org-specific content before commit/publish"; exit 1
fi
echo "org-scan: OK (no denylisted terms in tracked files)"; exit 0
