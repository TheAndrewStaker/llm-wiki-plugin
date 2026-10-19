#!/usr/bin/env bash
# SessionStart hook: inject the wiki's current focus + health into the session context.
# Read-only and fast. Silent until the wiki is initialized (no nagging before wiki-setup runs).
#   - pulls (rebase, autostash) if an upstream is configured, bounded so a stalled remote
#     can't hang session start, so a second machine starts current
#   - injects STATE.md's generated board (priority-ranked from initiative frontmatter,
#     the single source; see hooks/board.py) plus one where-it-stands pointer for the
#     session's own repo
#   - surfaces wiki-health problems (failed auto-commit/push, missing lint gate)
#   - young-wiki hint (capture, don't query) + per-initiative freshness nudge (protect
#     the loop, capped so several stale initiatives at once doesn't flood session start)
#   - sources org/personal drop-ins from $KB/status.d/*.sh (extension point)
set -uo pipefail

KB="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-${WIKI_ROOT:-$HOME/wiki}}"
KB="${KB/#\~/$HOME}"

# Not initialized yet -> stay completely silent (adopters haven't run wiki-setup).
[ -f "$KB/KNOWLEDGE.md" ] || exit 0

ctx=""
warn=""
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hook_input=""
if [ ! -t 0 ] && command -v python3 >/dev/null 2>&1; then
  hook_input=$(python3 -c 'import select, sys
r, _, _ = select.select([sys.stdin], [], [], 1)
print(sys.stdin.read() if r else "")' 2>/dev/null || true)
fi

# 0. Sync down first, BOUNDED: never let a stalled remote block session start. Only
#    attempted when origin + an upstream are configured. macOS ships no GNU `timeout`, so
#    this backgrounds the pull and polls briefly instead: past PULL_TIMEOUT seconds it
#    terminates the attempt so it cannot mutate the checkout after session context was
#    captured. Override the wait via $WIKI_PULL_TIMEOUT (tests only).
if git -C "$KB" remote get-url origin >/dev/null 2>&1 \
   && git -C "$KB" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  PULL_TIMEOUT="${WIKI_PULL_TIMEOUT:-5}"
  git -C "$KB" pull --rebase --autostash -q >/dev/null 2>&1 &
  pull_pid=$!
  waited=0
  while [ "$waited" -lt "$PULL_TIMEOUT" ] && kill -0 "$pull_pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pull_pid" 2>/dev/null; then
    kill "$pull_pid" 2>/dev/null || true
    wait "$pull_pid" 2>/dev/null || true
    warn="wiki pull --rebase exceeded ${PULL_TIMEOUT}s (slow/stalled remote) -- terminated; retry manually"
  else
    wait "$pull_pid"
    pull_rc=$?
    [ "$pull_rc" -ne 0 ] && warn="wiki pull --rebase failed (diverged?) -- resolve in $KB before it drifts"
  fi
fi

# 1. Health: a failed auto-commit/push or a missing lint gate must not stay silent.
[ -f "$KB/.auto-commit-failed" ] && warn="${warn:+$warn | }wiki auto-commit is FAILING (see $KB/.auto-commit-failed) -- run the wiki lint and fix, or changes stay uncommitted"
qerr="$(git -C "$KB" rev-parse --absolute-git-dir 2>/dev/null)/wiki-queue-expire.err"
[ -s "$qerr" ] && warn="${warn:+$warn | }queue expiry FAILING (see $qerr) -- its archive commit was refused and rolled back"
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

# 1b. Maintenance nudges: an unrun-mechanism detector. Disabled unless wiki.config.json sets
# reflect_nudge_days > 0. Two independent one-line signals, both best-effort (never block).
if command -v python3 >/dev/null 2>&1; then
  nudge_days=$(python3 - "$H" "$KB" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import wikilib
print(wikilib.load_config(sys.argv[2]).get("reflect_nudge_days", 0))
PY
)
  case "${nudge_days:-0}" in
    ''|*[!0-9]*)
      warn="${warn:+$warn | }maintenance: reflect_nudge_days is not a whole number ('${nudge_days}'), ignoring"
      nudge_days=0 ;;
  esac
  if [ "$nudge_days" -gt 0 ]; then
    newest_reflect=$(ls "$KB"/analyses/reflection-*.md 2>/dev/null | sort | tail -1)
    if [ -z "$newest_reflect" ]; then
      warn="${warn:+$warn | }maintenance: reflect has never run (cap ${nudge_days}d)"
    else
      rdate=$(basename "$newest_reflect" | sed -n 's/^reflection-\([0-9-]*\)\.md$/\1/p')
      rage=$(python3 -c "import datetime,sys
try:
    d=datetime.date.fromisoformat(sys.argv[1])
except ValueError:
    sys.exit(1)
print((datetime.date.today()-d).days)" "$rdate" 2>/dev/null)
      if [ -n "${rage:-}" ] && [ "$rage" -gt "$nudge_days" ]; then
        warn="${warn:+$warn | }maintenance: reflect last ran ${rage}d ago (cap ${nudge_days}d)"
      fi
    fi
  fi
fi

# 1b2. Standing aims (config `aims`): one line naming aims whose carrier is finished or
#      parked, or whose reviewed: date is past reflect_nudge_days. Also sweeps log-guard
#      session records older than 7 days. Both best-effort.
if command -v python3 >/dev/null 2>&1; then
  aims_warn=$(python3 - "$H" "$KB" <<'PY' 2>/dev/null
import datetime, glob, os, sys, time
sys.path.insert(0, sys.argv[1])
import wikilib
kb = sys.argv[2]
cfg = wikilib.load_config(kb)
try:
    cutoff = time.time() - 7 * 86400
    for p in glob.glob(os.path.join(wikilib.state_dir(kb), "sessions", "*.tsv")):
        if os.path.getmtime(p) < cutoff:
            os.remove(p)
except OSError:
    pass
aims, errors = wikilib.parse_aims(kb, cfg)
nudge = cfg.get("reflect_nudge_days") or 0
today = datetime.date.today()
out = []
for a in aims:
    if a["superseded"]:
        continue
    age = (today - datetime.date.fromisoformat(a["reviewed"])).days
    if a["carrier_status"] in ("done", "parked"):
        out.append(f"{a['id']} carrier is {a['carrier_status']}")
    elif nudge and age > nudge:
        out.append(f"{a['id']} unreviewed {age}d")
if out:
    print("standing aims: " + "; ".join(out[:4]) + (f"; +{len(out) - 4} more" if len(out) > 4 else ""))
PY
)
  [ -n "$aims_warn" ] && warn="${warn:+$warn | }$aims_warn"
fi

# 1c. Lint-history delta: a one-line summary of which advisory counters changed between the
# last two lint runs (disabled implicitly when fewer than 2 history lines exist).
hist=$(git -C "$KB" rev-parse --absolute-git-dir 2>/dev/null || true)
hist="${hist:+$hist/compendium/lint-history.tsv}"
[ -n "$hist" ] && [ -f "$hist" ] || hist="$KB/.compendium/lint-history.tsv"
if [ -f "$hist" ]; then
  delta=$(python3 - "$hist" <<'PY'
import re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        lines = [l.rstrip("\n") for l in fh if l.strip()]
except OSError:
    lines = []
if len(lines) < 2:
    sys.exit(0)


def parse(line):
    parts = line.split("\t", 1)
    if len(parts) != 2:
        return {}
    return dict(re.findall(r"([\w-]+):(\?|\d+)", parts[1]))


prev, cur = parse(lines[-2]), parse(lines[-1])
changed = []
for key, cval in cur.items():
    pval = prev.get(key)
    if pval is None or pval == cval:
        continue
    note = " (checker failed)" if cval == "?" else ""
    changed.append(f"{key} {pval}->{cval}{note}")
if changed:
    print("advisories since last lint: " + ", ".join(changed))
PY
)
  [ -n "$delta" ] && warn="${warn:+$warn | }$delta"
fi

# 2. Board, generated from initiative frontmatter (STATE.md's Focus/Inbox are retired).
# hooks/pre-commit regenerates it at commit time, so this just reads what's on disk; no
# regeneration here keeps SessionStart read-only and fast.
if [ -f "$KB/STATE.md" ] && [ -f "$H/board.py" ] && command -v python3 >/dev/null 2>&1; then
  # the main repository's name even inside a linked worktree: the common git dir's parent
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  repo_name=""
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
    repo_name="$(basename "$(cd "$common/.." 2>/dev/null && pwd -P)")"
  fi
  if [ -n "$repo_name" ]; then
    board_out=$(python3 "$H/board.py" "$KB" --repo "$repo_name" 2>/dev/null || true)
  else
    board_out=$(python3 "$H/board.py" "$KB" 2>/dev/null || true)
  fi
  [ -n "$board_out" ] && ctx+="STATE — board ($KB/STATE.md):"$'\n'"${board_out}"$'\n\n'
fi

# 2b. Per-initiative freshness nudge (replaces the old single-STATE.md-age check): active
# initiatives whose timestamp: is stale, capped at 3 so several going stale at once doesn't
# flood session start.
if command -v python3 >/dev/null 2>&1; then
  stale_inits=$(python3 - "$H" "$KB" <<'PY'
import sys, os, re, datetime
sys.path.insert(0, sys.argv[1])
import wikilib

kb = sys.argv[2]
today = datetime.date.today()
CAP = 3
out = []
for f in wikilib.git_files(kb):
    if not f.startswith("initiatives/") or os.path.basename(f) == "index.md":
        continue
    text = wikilib.read(kb, f)
    fmblock = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not fmblock:
        continue
    fm = fmblock.group(1)
    if wikilib.frontmatter_value(fm, "type") != "initiative":
        continue
    if wikilib.frontmatter_value(fm, "board") == "false":
        continue
    if wikilib.frontmatter_value(fm, "assignment_status") in ("done", "parked"):
        continue
    ts = wikilib.frontmatter_value(fm, "timestamp")
    if not ts:
        continue
    try:
        age = (today - datetime.date.fromisoformat(ts)).days
    except ValueError:
        continue
    if age > 7:
        out.append((age, f))
out.sort(reverse=True)
shown = out[:CAP]
if shown:
    line = "; ".join(f"{f} ({a}d)" for a, f in shown)
    if len(out) > CAP:
        line += f"; +{len(out) - CAP} more"
    print(line)
PY
)
  [ -n "$stale_inits" ] && ctx+="(initiatives stale >7d: ${stale_inits} -- refresh timestamp: on real edits.)"$'\n\n'
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

# 3b. Chat-only capture: after a compaction or a /clear, what the user asked for in the earlier
#     context survives only in its transcript. Point the agent at it once, at the loss point.
if [ -n "$hook_input" ] && command -v python3 >/dev/null 2>&1; then
  capture=$(printf '%s' "$hook_input" | python3 -c '
import glob, json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
src, tp = d.get("source"), d.get("transcript_path") or ""
if src not in ("compact", "clear") or not tp:
    sys.exit(0)
def ran_clear(f):
    try:
        with open(f, "rb") as fh:
            fh.seek(0, 2)
            start = max(0, fh.tell() - 65536)
            fh.seek(start)
            tail = fh.read().decode("utf-8", "ignore").splitlines()[1 if start else 0:]
    except OSError:
        return False
    for line in reversed(tail):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "user":
            continue
        c = (e.get("message") or {}).get("content")
        return isinstance(c, str) and "<command-name>/clear</command-name>" in c
    return False

prev = tp
if src == "clear":
    others = sorted((f for f in glob.glob(os.path.join(os.path.dirname(tp), "*.jsonl"))
                     if os.path.abspath(f) != os.path.abspath(tp)), key=os.path.getmtime, reverse=True)
    prev = next((f for f in others[:20] if ran_clear(f)), "")
if prev and os.path.isfile(prev):
    print(prev)
' 2>/dev/null)
  if [ -n "$capture" ]; then
    owner=$(python3 - "$H" "$KB" <<'PY' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1])
import wikilib
print(wikilib.queue_owner(wikilib.load_config(sys.argv[2]).get("initiative_schema"))[0])
PY
)
    ctx+="(Context was just compacted or cleared. Before other work, list the user's own turns with \`python3 $H/user-turns.py ${capture}\` and file anything they asked for, committed to, or said they want to do that is not yet in the wiki: an initiative's frontmatter or log when one owns it, else a dated bullet in open-asks/${owner:-owner}.md shaped '- [ ] YYYY-MM-DD · <who asked, or self> · text (source link)'. Skip what is already filed; file nothing that is only chatter.)"$'\n\n'
  fi
fi

# 3b. Signals (external developments) whose next_expected or recheck date is near or past.
if [ -f "$H/signals-board.py" ] && command -v python3 >/dev/null 2>&1; then
  sig=$(python3 "$H/signals-board.py" "$KB" --due 2>/dev/null || true)
  [ -n "$sig" ] && ctx+="$sig"$'\n\n'
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
