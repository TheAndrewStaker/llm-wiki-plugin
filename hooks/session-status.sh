#!/usr/bin/env bash
# SessionStart hook: inject the wiki's current focus + health into the session context.
# Read-only and fast. Silent until the wiki is initialized (no nagging before wiki-setup runs).
#   - pulls (rebase, autostash) if an upstream is configured, bounded so a stalled remote
#     can't hang session start, so a second machine starts current
#   - injects STATE.md's Focus section (the handoff)
#   - surfaces wiki-health problems (failed auto-commit/push, missing lint gate, an
#     over-cap Inbox)
#   - young-wiki hint (capture, don't query) + STATE freshness nudge (protect the loop)
#   - sources org/personal drop-ins from $KB/status.d/*.sh (extension point)
set -uo pipefail

KB="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-${WIKI_ROOT:-$HOME/wiki}}"
KB="${KB/#\~/$HOME}"

# Not initialized yet -> stay completely silent (adopters haven't run wiki-setup).
[ -f "$KB/KNOWLEDGE.md" ] || exit 0

ctx=""
warn=""
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 0. Sync down first, BOUNDED: never let a stalled remote block session start. Only
#    attempted when origin + an upstream are configured. macOS ships no GNU `timeout`, so
#    this backgrounds the pull and polls briefly instead: past PULL_TIMEOUT seconds it
#    stops waiting (the pull keeps running detached; it lands on its own, or the next
#    session's pull retries). Override the wait via $WIKI_PULL_TIMEOUT (tests only).
if git -C "$KB" remote get-url origin >/dev/null 2>&1 \
   && git -C "$KB" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  PULL_TIMEOUT="${WIKI_PULL_TIMEOUT:-5}"
  ( git -C "$KB" pull --rebase --autostash -q >/dev/null 2>&1 ) &
  pull_pid=$!
  waited=0
  while [ "$waited" -lt "$PULL_TIMEOUT" ] && kill -0 "$pull_pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pull_pid" 2>/dev/null; then
    warn="wiki pull --rebase exceeded ${PULL_TIMEOUT}s (slow/stalled remote) -- skipped for this session; it keeps running in the background"
    disown "$pull_pid" 2>/dev/null || true
  else
    wait "$pull_pid"
    pull_rc=$?
    [ "$pull_rc" -ne 0 ] && warn="wiki pull --rebase failed (diverged?) -- resolve in $KB before it drifts"
  fi
fi

# 1. Health: a failed auto-commit/push or a missing lint gate must not stay silent.
[ -f "$KB/.auto-commit-failed" ] && warn="${warn:+$warn | }wiki auto-commit is FAILING (see $KB/.auto-commit-failed) -- run the wiki lint and fix, or changes stay uncommitted"
[ -f "$KB/.push-failed" ] && warn="${warn:+$warn | }wiki push is FAILING (see $KB/.push-failed) -- commits are local-only"
if [ "$(git -C "$KB" config core.hooksPath 2>/dev/null)" != "hooks" ]; then
  warn="${warn:+$warn | }wiki lint gate not installed -- run: git -C $KB config core.hooksPath hooks"
fi
# Contract check: a wiki nobody's CLAUDE.md points at is inert (no session knows to consult it).
# Warn if the always-loaded ~/.claude/CLAUDE.md doesn't reference the wiki (by root path, KNOWLEDGE.md,
# or wiki-query). This is the guard behind wiki-setup's *offered* contract stanza.
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && ! grep -qiE "KNOWLEDGE\.md|wiki-query|$KB" "$CLAUDE_MD" 2>/dev/null; then
  warn="${warn:+$warn | }wiki exists but ~/.claude/CLAUDE.md doesn't reference it -- run the wiki-setup skill to add the contract stanza, or sessions won't consult the wiki"
fi
# Inbox soft-cap: one-line nudge if STATE.md's ## Inbox has grown past its configured soft
# cap (disabled by default; wiki.config.json inbox_soft_max_items / inbox_soft_max_words).
if command -v python3 >/dev/null 2>&1; then
  inbox_over=$(python3 "$H/inbox-check.py" "$KB" 2>/dev/null | sed -n 's/^  INBOX-OVER STATE.md (\(.*\))$/\1/p')
  [ -n "$inbox_over" ] && warn="${warn:+$warn | }wiki STATE.md Inbox is over its soft cap ($inbox_over) -- triage into Focus/Up next/ROADMAP/initiatives"
fi

# 2. Current focus from STATE.md (the handoff; absence is normal).
if [ -f "$KB/STATE.md" ]; then
  focus=$(awk '/^## Focus/{f=1;next} /^## /{f=0} f' "$KB/STATE.md" 2>/dev/null | sed '/^[[:space:]]*$/d')
  [ -n "${focus:-}" ] && ctx+="STATE — focus ($KB/STATE.md):"$'\n'"${focus}"$'\n\n'
  # freshness nudge: STATE last touched N days ago (protect-the-loop signal)
  last=$(git -C "$KB" log -1 --format=%cs -- STATE.md 2>/dev/null)
  if [ -n "$last" ] && command -v python3 >/dev/null 2>&1; then
    age=$(python3 -c "import datetime,sys;print((datetime.date.today()-datetime.date.fromisoformat(sys.argv[1])).days)" "$last" 2>/dev/null)
    [ -n "${age:-}" ] && [ "$age" -gt 7 ] && ctx+="(STATE.md last updated ${age}d ago -- refresh the focus block if it's stale.)"$'\n\n'
  fi
fi

# 3. Young-wiki hint: below the configured threshold, bias toward capture over query.
#    content_dirs + young_wiki_pages come from wiki.config.json (via wikilib defaults), not hardcoded.
if command -v python3 >/dev/null 2>&1; then
  read -r threshold globs < <(python3 - "$H" "$KB" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import wikilib
cfg = wikilib.load_config(sys.argv[2])
print(cfg["young_wiki_pages"], " ".join(d.rstrip("/") + "/*.md" for d in cfg["content_dirs"]))
PY
)
  if [ -n "${globs:-}" ]; then
    pages=$(git -C "$KB" ls-files ${globs} 2>/dev/null | wc -l | tr -d ' ')
    if [ -n "${threshold:-}" ] && [ "${pages:-0}" -lt "$threshold" ]; then
      ctx+="(Wiki is young (${pages:-0} content pages): capture findings as pages; don't expect query to retrieve much yet.)"$'\n\n'
    fi
  fi
fi

# 4. Org/personal drop-ins (e.g. an assignment injector). Each prints raw context to stdout.
if [ -d "$KB/status.d" ]; then
  for s in "$KB"/status.d/*.sh; do
    [ -f "$s" ] || continue
    out=$(WIKI_ROOT="$KB" bash "$s" 2>/dev/null || true)
    [ -n "$out" ] && ctx+="$out"$'\n\n'
  done
fi

[ -z "$ctx" ] && [ -z "$warn" ] && exit 0

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" --arg w "$warn" '
    (if $c != "" then {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}} else {} end)
    + (if $w != "" then {systemMessage: ("wiki: " + $w)} else {} end)'
else
  # jq absent: still surface context on stdout (SessionStart treats stdout as context).
  [ -n "$ctx" ] && printf '%s\n' "$ctx"
  [ -n "$warn" ] && printf 'wiki: %s\n' "$warn" >&2
fi
exit 0
