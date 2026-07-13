#!/usr/bin/env bash
# Deterministic knowledge-base lint (fast, single-pass Python). Pre-commit-gated + run on demand.
# Hard-fails on broken links or unresolved commit-gate tokens; orphans / islands / missed-links /
# no-type / stale / collisions / unindexed / inbox soft-cap / timestamp-drift are advisory.
# Source-freshness (stale-source.py) is a separate triggered tool.
set -uo pipefail

KB="${1:-${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-${WIKI_ROOT:-$HOME/wiki}}}"
KB="${KB/#\~/$HOME}"
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$KB" ]; then echo "lint: wiki root not found: $KB" >&2; exit 2; fi
if ! command -v python3 >/dev/null 2>&1; then echo "lint: python3 required" >&2; exit 2; fi

if [ -t 1 ]; then C=$'\033[36m'; R=$'\033[31m'; G=$'\033[32m'; Z=$'\033[0m'; else C=""; R=""; G=""; Z=""; fi

# lint-core is the GATE (broken links + unresolved tokens). If it crashes we cannot trust the
# counts, so FAIL CLOSED (show the error, exit 2) instead of silently passing. graph/missed are
# advisory: a crash there warns but never blocks.
core_err=$(mktemp)
core=$(python3 "$H/lint-core.py" "$KB" 2>"$core_err")
core_rc=$?
graph=$(python3 "$H/graph-check.py" "$KB" 2>/dev/null || true)
missed=$(python3 "$H/missed-links.py" "$KB" 2>/dev/null || true)
wanted=$(python3 "$H/wanted-pages.py" "$KB" 2>/dev/null || true)
inbox=$(python3 "$H/inbox-check.py" "$KB" 2>/dev/null || true)
drift=$(python3 "$H/timestamp-drift.py" "$KB" 2>/dev/null || true)

echo "${C}== knowledge-base lint ==${Z}"
if [ "$core_rc" -ne 0 ]; then
  echo "${R}FAIL${Z} (lint-core crashed; failing closed rather than passing blind):" >&2
  cat "$core_err" >&2
  rm -f "$core_err"; exit 2
fi
rm -f "$core_err"
printf '%s\n' "$core"   | grep -vE '^CORE ' || true
printf '%s\n' "$graph"  | grep '^  ISLAND' || true
printf '%s\n' "$missed" | grep '^  MISSED-LINK' || true
printf '%s\n' "$wanted" | grep '^  WANTED' || true
printf '%s\n' "$inbox"  | grep '^  INBOX-OVER' || true
printf '%s\n' "$drift"  | grep '^  DRIFT' || true

b=$(printf '%s\n'  "$core"   | sed -n 's/^CORE broken=\([0-9]*\).*/\1/p')
u=$(printf '%s\n'  "$core"   | sed -n 's/^CORE [^ ]* unresolved=\([0-9]*\).*/\1/p')
by=$(printf '%s\n' "$core"   | sed -n 's/.* badyaml=\([0-9]*\).*/\1/p')
nt=$(printf '%s\n' "$core"   | sed -n 's/.* notype=\([0-9]*\).*/\1/p')
st=$(printf '%s\n' "$core"   | sed -n 's/.* stale=\([0-9]*\).*/\1/p')
orp=$(printf '%s\n' "$core"  | sed -n 's/.* orphan=\([0-9]*\).*/\1/p')
col=$(printf '%s\n' "$core"  | sed -n 's/.* collision=\([0-9]*\).*/\1/p')
unx=$(printf '%s\n' "$core"  | sed -n 's/.* unindexed=\([0-9]*\).*/\1/p')
mf=$(printf '%s\n' "$core"   | sed -n 's/.* missingfield=\([0-9]*\).*/\1/p')
de=$(printf '%s\n' "$core"   | sed -n 's/.* deadend=\([0-9]*\).*/\1/p')
sp=$(printf '%s\n' "$core"   | sed -n 's/.* staleptr=\([0-9]*\).*/\1/p')
ch=$(printf '%s\n' "$core"   | sed -n 's/.* chain=\([0-9]*\)$/\1/p')
islands=$(printf '%s\n' "$graph"  | sed -n 's/^COMPONENTS=[0-9]* ISLAND_NODES=//p')
ml=$(printf '%s\n' "$missed" | sed -n 's/^MISSED_LINKS=//p')
wp=$(printf '%s\n' "$wanted" | sed -n 's/^WANTED=\([0-9]*\).*/\1/p')
ib=$(printf '%s\n' "$inbox"  | sed -n 's/^INBOX=//p')
dr=$(printf '%s\n' "$drift"  | sed -n 's/^DRIFT=\([0-9]*\).*/\1/p')

echo "${C}== summary ==${Z}  broken-links:${b:-?}  unresolved:${u:-?}  bad-yaml:${by:-?}  orphans:${orp:-?}  islands:${islands:-?}  missed-links:${ml:-?}  no-type:${nt:-?}  stale:${st:-?}  collisions:${col:-?}  unindexed:${unx:-?}  missing-fields:${mf:-?}  dead-ends:${de:-?}  stale-pointers:${sp:-?}  chains:${ch:-?}  wanted:${wp:-?}  inbox:${ib:-?}  drift:${dr:-?}"
# If the gate counters didn't parse, the CORE line is malformed -> fail closed, don't pass blind.
if [ -z "$b" ] || [ -z "$u" ] || [ -z "$by" ]; then
  echo "${R}FAIL${Z} (could not read lint-core counts; failing closed)"; exit 2
fi
if [ "$b" -gt 0 ] || [ "$u" -gt 0 ] || [ "$by" -gt 0 ]; then
  echo "${R}FAIL${Z} (broken links, unresolved tokens, or malformed YAML frontmatter)"; exit 1
fi
budget_report=$(python3 - "$KB" "${orp:--1}" "${islands:--1}" "${ml:--1}" "${col:--1}" "${unx:--1}" "${de:--1}" <<'PY'
import json, os, sys
root, values = sys.argv[1], sys.argv[2:]
names = ("orphan", "islands", "missed_links", "collision", "unindexed", "deadend")
try:
    cfg = json.load(open(os.path.join(root, "wiki.config.json"), encoding="utf-8"))
except (FileNotFoundError, ValueError, OSError):
    cfg = {}
limits = cfg.get("advisory_budgets", {})
over = []
for name, raw in zip(names, values):
    limit = limits.get(name)
    if isinstance(limit, int) and limit >= 0 and raw.isdigit() and int(raw) > limit:
        over.append(f"  BUDGET {name}={raw} limit={limit}")
print("\n".join(over))
sys.exit(1 if over else 0)
PY
)
budget_rc=$?
if [ "$budget_rc" -ne 0 ]; then
  printf '%s\n' "$budget_report"
  echo "${R}FAIL${Z} (configured advisory budget exceeded)"; exit 1
fi
echo "${G}OK${Z} (hard checks clean; warnings advisory)"; exit 0
