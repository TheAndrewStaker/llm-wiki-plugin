#!/usr/bin/env bash
# Stop / SessionEnd hook: auto-commit the wiki whenever it has uncommitted changes, so ending or
# force-terminating a session never loses agent-authored findings. If a remote named 'origin' and
# an upstream exist, also push (foreground; a breadcrumb on failure) so a second machine stays in
# sync. Note: the push runs synchronously, so a slow remote adds latency to the turn's end.
#
# Runs the pre-commit lint gate; if lint fails the commit is skipped and the changes stay in the
# working tree for the next turn to fix. A failure is NOT silent: it writes .auto-commit-failed
# (surfaced by session-status.sh at every session start until it clears). No-op when clean.
set -uo pipefail

input=$(cat 2>/dev/null || true)
# avoid Stop-hook continuation loops
case "$input" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac

KB="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-${WIKI_ROOT:-$HOME/wiki}}"
KB="${KB/#\~/$HOME}"
cd "$KB" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# nothing to commit (no tracked diff AND no allowlisted untracked files) -> no-op
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  # still try to push if we are behind-free but have unpushed commits
  :
else
  git add -A
  if out=$(git commit -q -m "session auto-save: wiki findings ($(date +%Y-%m-%d))" 2>&1); then
    rm -f "$KB/.auto-commit-failed"
  else
    {
      echo "auto-commit failed $(date '+%Y-%m-%d %H:%M') -- commit aborted (lint gate?); changes remain uncommitted"
      printf '%s\n' "$out"
    } > "$KB/.auto-commit-failed"
    echo "wiki auto-commit FAILED (lint gate?) -- see $KB/.auto-commit-failed; run the wiki lint" >&2
    exit 1
  fi
fi

# Push if origin + an upstream are configured. Never blocks the turn; failure is a breadcrumb only.
if git remote get-url origin >/dev/null 2>&1 && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  perr=$(mktemp "${TMPDIR:-/tmp}/wiki-push.XXXXXX")
  if ! git push -q 2>"$perr"; then
    {
      echo "wiki push failed $(date '+%Y-%m-%d %H:%M') -- commit is local-only; pull/resolve then push"
      cat "$perr" 2>/dev/null
    } > "$KB/.push-failed"
  else
    rm -f "$KB/.push-failed"
  fi
  rm -f "$perr"
fi
exit 0
