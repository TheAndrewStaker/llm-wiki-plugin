#!/usr/bin/env bash
# Stop / SessionEnd hook: auto-commit the wiki whenever it has uncommitted changes, so ending or
# force-terminating a session never loses agent-authored findings. If a remote named 'origin' and
# auto_push is enabled and an upstream exists, also push (foreground; a breadcrumb on failure).
#
# Runs the pre-commit lint gate; if lint fails the commit is skipped and the changes stay in the
# working tree for the next turn to fix. A failure is NOT silent: it writes .auto-commit-failed
# (surfaced by session-status.sh at every session start until it clears). No-op when clean.
#
# Gate failures that name a page are attributed first. The session whose transcript wrote a
# failing page gets exit 2 once, with the failing lines, so it fixes them in the same turn.
# Any other session commits everything except the failing pages and exits 0. The log guard
# (log-guard.py) rides the same exit: one block per stop chain, after the commit.
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
# Log guard: a Stop with work events (commits, PRs) recorded since the session last wrote
# to the wiki blocks once with the reason; a continuation never re-evaluates. SessionEnd
# clears the session's record.
guard_msg=""
if command -v python3 >/dev/null 2>&1 && [ -f "$H/log-guard.py" ]; then
  if [ "$event" = "Stop" ] && [ "$stop_active" = "false" ]; then
    guard_msg=$(printf '%s' "$input" | python3 "$H/log-guard.py" "$KB" 2>/dev/null || true)
  elif [ "$event" = "SessionEnd" ]; then
    printf '%s' "$input" | python3 "$H/log-guard.py" "$KB" --clear >/dev/null 2>&1 || true
  fi
fi
finish() { # finish <rc>: the guard's block comes after whatever was committed
  if [ -n "$guard_msg" ]; then
    printf '%s\n' "$guard_msg" >&2
    exit 2
  fi
  exit "$1"
}
[ "$auto_commit" = "true" ] || finish 0

held=""; mine=""; fails=""
GATE_RE='^[[:space:]]*(INIT-FAIL|BROKEN LINK|UNRESOLVED|BADYAML|PORT-DUPKEY|PORT-TAB|PORT-HASH|PORT-STATUS|UNKNOWN-TYPE|UNCHECKABLE-ADDED|ORPHAN|UNINDEXED|DEADEND|MISSED-LINK-ADDED|IGNORED-TARGET) '
gate_pages() { sed -E 's/^[[:space:]]*(BROKEN LINK|[A-Z-]+) ([^ ]+).*/\2/' | sort -u; }
log_event() { # log_event <what> <detail>: machine-local, newest 500 lines kept
  local d; d="$(git rev-parse --absolute-git-dir 2>/dev/null)/compendium"
  mkdir -p "$d" 2>/dev/null || return 0
  { printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$event" "${transcript##*/}" "$1"
    printf '%s\n' "$2" | sed 's/^/\t/'; } >> "$d/auto-commit.log" 2>/dev/null
  tail -n 500 "$d/auto-commit.log" > "$d/auto-commit.log.tmp" 2>/dev/null \
    && mv "$d/auto-commit.log.tmp" "$d/auto-commit.log" 2>/dev/null
  return 0
}
# Stop and SessionEnd can fire together. Serialize the whole add/commit/push transaction.
lock="$(git rev-parse --git-dir)/wiki-auto-commit.lock"
if ! mkdir "$lock" 2>/dev/null; then
  owner=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    finish 0
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

# Queue expiry: at most once a day, on a Stop, inside the lock; commits on its own.
if [ "$event" = "Stop" ] && [ -f "$H/queue-expire.py" ]; then
  stamp="$(git rev-parse --git-dir)/wiki-queue-expire.day"
  if [ "$(cat "$stamp" 2>/dev/null)" != "$(date +%F)" ]; then
    python3 "$H/queue-expire.py" "$KB" --commit >/dev/null 2>"$(git rev-parse --git-dir)/wiki-queue-expire.err"
    case $? in
      0) date +%F > "$stamp"; rm -f "$(git rev-parse --git-dir)/wiki-queue-expire.err" ;;
      3) rm -f "$(git rev-parse --git-dir)/wiki-queue-expire.err" ;;
    esac
  fi
fi

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

  # Every gate line that names a page is attributed: the schema gate, the hard checks, and
  # any advisory counter a budget turned into a gate. The staged view is what gets judged.
  if [ -f "$H/lint.sh" ]; then
    fails=$(GIT_INDEX_FILE="$view" WIKI_CHECK_INDEX=1 WIKI_LINT_GATE_ONLY=1 bash "$H/lint.sh" "$KB" 2>/dev/null \
      | grep -E "$GATE_RE" || true)
    if [ -n "$fails" ]; then
      files=$(printf '%s\n' "$fails" | gate_pages)
      if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        # shellcheck disable=SC2086
        mine=$(python3 "$H/session-touched.py" "$transcript" "$KB" $files 2>/dev/null || true)
      fi
      if [ -n "$mine" ] && [ "$event" = "Stop" ] && [ "$stop_active" = "false" ]; then
        rm -f "$view"
        log_event "writer blocked by the commit gate" "$fails"
        {
          echo "wiki: pages this session wrote fail the commit gate, so nothing was committed:"
          printf '%s\n' "$fails" | grep -F -f <(printf '%s\n' "$mine")
          echo "Fix them now: frontmatter with wiki-fm set <page> <field>=<value> (it validates"
          echo "before writing); a missing index line, link or target by editing the page named."
          [ -n "$guard_msg" ] && printf '%s\n' "$guard_msg"
        } >&2
        exit 2
      fi
      held=$files
      log_event "held back by the commit gate" "$fails"
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
    # The commit re-reads the tree, which another session may have changed since the check
    # above. A page the commit gate then names is held back like any other, and the rest
    # commits; only a failure that names no committed page is reported as one.
    committed=false; tries=0
    while [ "${#paths[@]}" -gt 0 ] && [ "$tries" -lt 4 ]; do
      tries=$((tries + 1))
      if out=$(WIKI_LINT_GATE_ONLY=1 WIKI_LINT_HOOKS="$H" python3 "$H/../bin/wiki-commit" --root "$KB" \
            -m "session auto-save: wiki findings ($(date +%Y-%m-%d))" -- "${paths[@]}" 2>&1); then
        committed=true; break
      fi
      late=$(printf '%s\n' "$out" | grep -E "$GATE_RE" || true)
      bad=$(printf '%s\n' "$late" | gate_pages | grep -xF -f <(printf '%s\n' "${paths[@]}") || true)
      [ -n "$bad" ] || break
      if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        # shellcheck disable=SC2086
        late_mine=$(python3 "$H/session-touched.py" "$transcript" "$KB" $bad 2>/dev/null || true)
        if [ -n "$late_mine" ] && [ "$event" = "Stop" ] && [ "$stop_active" = "false" ]; then
          log_event "writer blocked by the commit gate" "$late"
          {
            echo "wiki: pages this session wrote fail the commit gate, so nothing was committed:"
            printf '%s\n' "$late" | grep -F -f <(printf '%s\n' "$late_mine") | sed 's/^[[:space:]]*/  /'
            echo "Fix them now: frontmatter with wiki-fm set <page> <field>=<value> (it validates"
            echo "before writing); a missing index line, link or target by editing the page named."
            [ -n "$guard_msg" ] && printf '%s\n' "$guard_msg"
          } >&2
          exit 2
        fi
        mine=$(printf '%s\n%s\n' "$mine" "$late_mine" | sed '/^$/d' | sort -u)
      fi
      log_event "held back by the commit gate" "$late"
      held=$(printf '%s\n%s\n' "$held" "$bad" | sed '/^$/d' | sort -u)
      fails=$(printf '%s\n%s\n' "$fails" "$late" | sed '/^$/d')
      keep=()
      for p in "${paths[@]}"; do printf '%s\n' "$bad" | grep -qxF "$p" || keep+=("$p"); done
      paths=("${keep[@]+"${keep[@]}"}")
    done
    if [ "$committed" = "true" ] || [ "${#paths[@]}" -eq 0 ]; then
      rm -f "$KB/.auto-commit-failed"
    else
      log_event "commit failed" "$out"
      {
        echo "auto-commit failed $(date '+%Y-%m-%d %H:%M') -- commit aborted, changes remain uncommitted"
        printf '%s\n' "$out"
      } > "$KB/.auto-commit-failed"
      echo "wiki auto-commit FAILED -- see $KB/.auto-commit-failed; run the wiki lint" >&2
      finish 1
    fi
  fi
fi

if [ -n "$held" ]; then
  {
    echo "auto-commit held back $(date '+%Y-%m-%d %H:%M') -- these pages fail the commit gate and stay uncommitted:"
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
finish "${hook_rc:-0}"
