#!/usr/bin/env bash
# Stop / SessionEnd hook: auto-commit the wiki whenever it has uncommitted changes, so ending or
# force-terminating a session never loses agent-authored findings. If a remote named 'origin' and
# auto_push is enabled and an upstream exists, also push (foreground; a breadcrumb on failure).
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
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mutation policy is content-coupled and explicit. Missing config preserves local auto-commit,
# while network writes are opt-in.
auto_commit=true
auto_push=false
if command -v python3 >/dev/null 2>&1; then
  read -r auto_commit auto_push < <(python3 - "$H" "$KB" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import wikilib
cfg = wikilib.load_config(sys.argv[2])
print(str(bool(cfg.get("auto_commit", True))).lower(),
      str(bool(cfg.get("auto_push", False))).lower())
PY
)
fi
[ "$auto_commit" = "true" ] || exit 0

# Stop and SessionEnd can fire together. Serialize the whole add/commit/push transaction.
lock="$(git rev-parse --git-dir)/wiki-auto-commit.lock"
if ! mkdir "$lock" 2>/dev/null; then
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    exit 0
  fi
  rm -f "$lock/pid" 2>/dev/null || exit 0
  rmdir "$lock" 2>/dev/null || exit 0
  mkdir "$lock" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" > "$lock/pid"
cleanup_lock() {
  rm -f "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

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
if [ "$auto_push" = "true" ] && git remote get-url origin >/dev/null 2>&1 \
   && git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
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
