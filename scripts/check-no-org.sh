#!/usr/bin/env bash
# Guard behind the "no org-specific content" rule (see AGENTS.md). Ships the scanner, never the
# terms: the denylist (one term/ERE per line, # comments allowed) is private to the maintainer.
#
# Usage: check-no-org.sh [--strict] [--staged | --msg FILE | --range REVS]
#   (default)     tracked files as they are in the working tree
#   --staged      the index: staged blob contents and staged paths (what a commit will record)
#   --msg FILE    a commit message file (commit-msg hook); lines starting with # are ignored
#   --range REVS  every commit in a rev-list range: message, paths and full tree at that commit
#   --strict      a missing, empty or unreadable denylist, or an invalid pattern, fails (exit 2)
#                 instead of skipping; the maintainer hooks always pass it
# Denylist: $LLM_WIKI_ORG_DENYLIST, else `git config llmwiki.orgDenylist`, else <repo>/.org-denylist.
# Output names the file or commit and the denylist line number, never the matched term.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=tree strict=0 arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) strict=1 ;;
    --staged) mode=staged ;;
    --msg) mode=msg; arg="${2:?--msg needs a file}"; shift ;;
    --range) mode=range; arg="${2:?--range needs revisions}"; shift ;;
    *) echo "org-scan: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

skip() { # skip <reason>
  if [ "$strict" = 1 ]; then echo "org-scan: FAIL: $1 (strict mode needs the private denylist)"; exit 2; fi
  echo "org-scan: $1 -> skipped (provide a denylist to enable)"; exit 0
}
LIST="${LLM_WIKI_ORG_DENYLIST:-$(git -C "$ROOT" config --get llmwiki.orgDenylist 2>/dev/null || true)}"
LIST="${LIST:-$ROOT/.org-denylist}"
case "$LIST" in "~/"*) LIST="$HOME/${LIST#\~/}" ;; esac
[ -f "$LIST" ] || skip "no denylist at $LIST"
[ -r "$LIST" ] || skip "denylist $LIST is unreadable"
grep -qvE '^[[:space:]]*(#|$)' "$LIST" || skip "denylist $LIST is empty"

hits=0 errors=0
report() { echo "org-scan: FORBIDDEN (denylist line $1) in $2"; hits=$((hits + 1)); }
# match <term>: does stdin contain the term? 0 yes, 1 no, 2 bad pattern
match() { grep -iqE -- "$1"; local rc=$?; [ "$rc" -gt 1 ] && return 2; return "$rc"; }

n=0
while IFS= read -r term || [ -n "$term" ]; do
  n=$((n + 1))
  case "$term" in ''|\#*) continue ;; esac
  [ -z "${term//[[:space:]]/}" ] && continue
  printf '' | match "$term"
  if [ $? -eq 2 ]; then echo "org-scan: denylist line $n is not a valid ERE"; errors=$((errors + 1)); continue; fi
  case "$mode" in
    tree)
      while IFS= read -r -d '' f; do
        [ -f "$ROOT/$f" ] && grep -iIqE -- "$term" "$ROOT/$f" 2>/dev/null && report "$n" "$f"
        printf '%s\n' "$f" | match "$term" && report "$n" "path $f"
      done < <(git -C "$ROOT" ls-files -z)
      ;;
    staged)
      while IFS= read -r f; do report "$n" "staged $f"; done \
        < <(git -C "$ROOT" grep --cached -iIlE -e "$term" 2>/dev/null)
      git -C "$ROOT" diff --cached --name-only | match "$term" && report "$n" "a staged path"
      ;;
    msg)
      grep -v '^#' "$arg" | match "$term" && report "$n" "the commit message"
      ;;
    range)
      # shellcheck disable=SC2086  # REVS may be several words ("<sha> --not --remotes")
      for c in $(git -C "$ROOT" rev-list $arg); do
        short=$(git -C "$ROOT" rev-parse --short "$c")
        git -C "$ROOT" log -1 --format=%B "$c" | match "$term" && report "$n" "commit $short message"
        git -C "$ROOT" ls-tree -r --name-only "$c" | match "$term" && report "$n" "commit $short paths"
        git -C "$ROOT" grep -iIqE -e "$term" "$c" -- 2>/dev/null && report "$n" "commit $short tree"
      done
      ;;
  esac
done < "$LIST"

if [ "$errors" -gt 0 ] && [ "$strict" = 1 ]; then
  echo "org-scan: FAIL ($errors invalid pattern(s))"; exit 2
fi
if [ "$hits" -gt 0 ]; then
  echo "org-scan: FAIL ($hits match(es)); remove org-specific content before commit or push"; exit 1
fi
echo "org-scan: OK ($mode)"; exit 0
