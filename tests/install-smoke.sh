#!/usr/bin/env bash
# Install the plugin the way a new user does, then prove it works from the installed copy.
# Opt-in (needs the `claude` CLI; no network, no login): bash tests/install-smoke.sh
#
# Isolation: an absolute temporary CLAUDE_CONFIG_DIR and WIKI_ROOT. HOME is never changed and no
# model session starts, so no credential is read or written. The temp path contains a space, which
# catches unquoted hook commands.
#
# Checks: a local-directory marketplace install registers every skill and 4 hook events; the installed
# SessionStart and Stop hook commands, run as the harness runs them, work against a wiki scaffolded
# from the installed copy; a git-hosted install receives a new commit (the manifest carries no
# version, so each commit is a version), and would not if a version were set and left unbumped.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v claude >/dev/null || { echo "install-smoke: no claude CLI on PATH -> skipped"; exit 0; }
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }

BASE="$(mktemp -d)"; S="$BASE/smoke dir"; mkdir -p "$S"
trap 'rm -rf "$BASE"' EXIT
export CLAUDE_CONFIG_DIR="$S/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
case "$CLAUDE_CONFIG_DIR" in "$HOME"/.claude*) echo "install-smoke: refusing a real config dir"; exit 2 ;; esac
commit() { git -C "$1" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -qm "$2"; }

# What would ship: tracked and not-yet-added files, ignored ones excluded, as they are on disk.
SRC="$S/src/plugin"; mkdir -p "$SRC"
git -C "$ROOT" ls-files -z --cached --others --exclude-standard | (cd "$ROOT" && xargs -0 tar cf -) | (cd "$SRC" && tar xf -)

echo "--- local marketplace install ---"
claude plugin marketplace add "$SRC" >/dev/null 2>&1; check "marketplace add" "0" "$?"
claude plugin install llm-wiki-plugin@llm-wiki-plugin >/dev/null 2>&1; check "install" "0" "$?"
details=$(claude plugin details llm-wiki-plugin@llm-wiki-plugin 2>&1)
nskills=$(find "$SRC/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')
has "all $nskills skills registered" "Skills ($nskills)" "$details"
has "four hook events registered" "Hooks (4)" "$details"
for d in "$SRC"/skills/*/; do
  s=$(basename "$d"); has "skill $s listed" "$s" "$details"
done

echo "--- installed hooks run as the harness runs them ---"
W="$S/my wiki"
out=$(python3 "$SRC/bin/wiki-scaffold" "$W" 2>&1); check "scaffold from the installed copy" "0" "$?"
git -C "$W" init -q; git -C "$W" config core.hooksPath hooks
git -C "$W" add -A; git -C "$W" -c user.name=t -c user.email=t@t commit -qm scaffold >/dev/null 2>&1
check "scaffolded wiki commits through its gate" "0" "$?"
hookcmd() { # hookcmd <event>: the command string from the installed hooks.json, root substituted
  python3 - "$SRC/hooks/hooks.json" "$1" "$SRC" <<'EOF'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"][sys.argv[2]][0]["hooks"][0]["command"]
print(h.replace("${CLAUDE_PLUGIN_ROOT}", sys.argv[3]))
EOF
}
start=$(cd "$W" && printf '{"session_id":"smoke","hook_event_name":"SessionStart","source":"startup"}' \
  | CLAUDE_PLUGIN_ROOT="$SRC" CLAUDE_PLUGIN_OPTION_WIKI_ROOT="$W" WIKI_ROOT="$W" sh -c "$(hookcmd SessionStart)" 2>&1)
check "SessionStart hook exits 0 from a spaced path" "0" "$?"
has "SessionStart hook injects the board" "STATE" "$start"
echo "smoke" > "$W/notes/smoke.md"
(cd "$W" && printf '{"session_id":"smoke","hook_event_name":"Stop","stop_hook_active":true}' \
  | CLAUDE_PLUGIN_ROOT="$SRC" CLAUDE_PLUGIN_OPTION_WIKI_ROOT="$W" WIKI_ROOT="$W" sh -c "$(hookcmd Stop)" >/dev/null 2>&1)
rc=$?
check "Stop hook runs from a spaced path (no 126/127)" "yes" "$([ "$rc" -ne 126 ] && [ "$rc" -ne 127 ] && echo yes || echo no)"

echo "--- git-hosted install: updates reach the user ---"
G="$S/hosted"; mkdir -p "$G/mkt/.claude-plugin"; cp -R "$SRC" "$G/plugin"
git -C "$G/plugin" init -q; git -C "$G/plugin" add -A; commit "$G/plugin" v1
printf '{"name":"smoke","owner":{"name":"t"},"plugins":[{"name":"llm-wiki-plugin","source":{"source":"url","url":"file://%s"}}]}\n' \
  "$G/plugin" > "$G/mkt/.claude-plugin/marketplace.json"
claude plugin marketplace add "$G/mkt" >/dev/null 2>&1
claude plugin install llm-wiki-plugin@smoke >/dev/null 2>&1; check "hosted install" "0" "$?"
C="$CLAUDE_CONFIG_DIR/plugins/cache/smoke/llm-wiki-plugin"
echo change > "$G/plugin/SMOKE"; git -C "$G/plugin" add -A; commit "$G/plugin" v2
claude plugin update llm-wiki-plugin@smoke >/dev/null 2>&1
check "a new commit is delivered" "1" "$(ls "$C"/*/SMOKE 2>/dev/null | wc -l | tr -d ' ')"
if python3 -c 'import json,sys; sys.exit("version" in json.load(open(sys.argv[1])))' \
     "$ROOT/.claude-plugin/plugin.json"; then
  ok "the Claude manifest carries no version (commit is the version)"
else
  bad "the Claude manifest sets a version: bump it on every shipped change or updates stall"
fi

echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
[ "$fail" -eq 0 ]
