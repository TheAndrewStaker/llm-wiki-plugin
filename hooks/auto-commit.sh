#!/usr/bin/env bash
# Stop / SessionEnd hook: auto-commit the wiki whenever it has uncommitted changes, so ending or
# force-terminating a session never loses agent-authored findings. If a remote named 'origin' and
# auto_push is enabled and an upstream exists, also push (foreground; a breadcrumb on failure).
#
# Runs the pre-commit lint gate; if lint fails the commit is skipped and the changes stay in the
# working tree for the next turn to fix. A failure is NOT silent: it writes .auto-commit-failed
# (surfaced by session-status.sh at every session start until it clears). No-op when clean.
#
# Initiative-gate failures are attributed first. The session whose transcript wrote a failing
# page gets exit 2 once, with the failing lines, so it fixes them in the same turn. Any other
# session commits everything except the failing pages and exits 0.
set -uo pipefail

input=$(cat 2>/dev/null || true)
stop_active=false
case "$input" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) stop_active=true ;; esac
event=Stop
case "$input" in *'"hook_event_name":"SessionEnd"'*|*'"hook_event_name": "SessionEnd"'*) event=SessionEnd ;; esac
transcript=$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("transcript_path") or "")
except Exception: print("")' 2>/dev/null || true)

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

held=""; mine=""; fails=""
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
  # A clean tree means an earlier failure was resolved, by this hook or by hand. Clear the
  # breadcrumb here too, or fixing it manually leaves session-status warning forever.
  rm -f "$KB/.auto-commit-failed"
else
  # A private index: the shared one belongs to every session in this wiki, and this hook must
  # neither commit another session's staging nor unstage it.
  view=$(mktemp "${TMPDIR:-/tmp}/wiki-auto-index.XXXXXX"); rm -f "$view"
  GIT_INDEX_FILE="$view" git read-tree HEAD
  GIT_INDEX_FILE="$view" git add -A

  if [ -f "$H/initiative-check.py" ]; then
    fails=$(GIT_INDEX_FILE="$view" WIKI_CHECK_INDEX=1 python3 "$H/initiative-check.py" "$KB" 2>/dev/null | grep '^  INIT-FAIL ' || true)
    if [ -n "$fails" ]; then
      files=$(printf '%s\n' "$fails" | awk '{print $2}' | sort -u)
      if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        # shellcheck disable=SC2086
        mine=$(python3 "$H/session-touched.py" "$transcript" "$KB" $files 2>/dev/null || true)
      fi
      if [ -n "$mine" ] && [ "$event" = "Stop" ] && [ "$stop_active" = "false" ]; then
        rm -f "$view"
        {
          echo "wiki: pages this session wrote fail the commit gate, so nothing was committed:"
          printf '%s\n' "$fails" | grep -F -f <(printf '%s\n' "$mine")
          echo "Fix them now, preferably with: wiki-fm set <page> <field>=<value>"
          echo "(wiki-fm validates before writing; depth belongs in the page body as a dated log entry)."
        } >&2
        exit 2
      fi
      held=$files
    fi
  fi

  changed=$(GIT_INDEX_FILE="$view" git diff --cached --name-only --no-renames HEAD)
  rm -f "$view"
  if [ -n "$held" ]; then
    changed=$(printf '%s\n' "$changed" | grep -vxF -f <(printf '%s\n' "$held") || true)
  fi

  # A dirty tree can stage to nothing: another committer took the same changes in between,
  # or the difference was stat-only. That is not a failure, and a Stop hook exiting non-zero
  # is reported to the author as a broken session.
  if [ -z "$changed" ]; then
    rm -f "$KB/.auto-commit-failed"
  else
    paths=()
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done <<< "$changed"
    if out=$(WIKI_LINT_GATE_ONLY=1 python3 "$H/../bin/wiki-commit" --root "$KB" \
          -m "session auto-save: wiki findings ($(date +%Y-%m-%d))" -- "${paths[@]}" 2>&1); then
      rm -f "$KB/.auto-commit-failed"
    else
      {
        echo "auto-commit failed $(date '+%Y-%m-%d %H:%M') -- commit aborted, changes remain uncommitted"
        printf '%s\n' "$out"
      } > "$KB/.auto-commit-failed"
      echo "wiki auto-commit FAILED -- see $KB/.auto-commit-failed; run the wiki lint" >&2
      exit 1
    fi
  fi
fi

if [ -n "$held" ]; then
  {
    echo "auto-commit held back $(date '+%Y-%m-%d %H:%M') -- these pages fail the initiative gate and stay uncommitted:"
    printf '%s\n' "$fails"
    echo "Fix with: wiki-fm set <page> <field>=<value>"
  } > "$KB/.auto-commit-failed"
  if [ -n "$mine" ] && [ "$event" = "Stop" ]; then
    echo "wiki: still failing after one fix attempt, held back: $(printf '%s ' $held)" >&2
    hook_rc=1
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
exit "${hook_rc:-0}"
