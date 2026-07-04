#!/usr/bin/env bash
# Self-contained test harness. Builds a throwaway fixture wiki (with git history so stale-source
# can be exercised), runs the deterministic stack, and asserts golden results. Exits nonzero on
# any failure. Usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks"
Q="$ROOT/bin/wiki-query"
W="$(mktemp -d)/wiki"
mkdir -p "$W"/{entities,concepts,notes,analyses,sources}
export WIKI_ROOT="$W"

pass=0; fail=0
assert() { # assert "<label>" <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi
}
assert_contains() { # assert_contains "<label>" "<needle>" "<haystack>"
  if printf '%s' "$3" | grep -qF "$2"; then pass=$((pass+1)); printf 'PASS  %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (missing: %s)\n' "$1" "$2"; fi
}

# ---- fixture content (commit 1: clean, one orphan, one missed link) ----
cat > "$W/KNOWLEDGE.md" <<'EOF'
---
type: index
title: Fixture index
---
Map. [entities/index.md](entities/index.md) · [concepts/index.md](concepts/index.md)
EOF
cat > "$W/STATE.md" <<'EOF'
---
type: state
title: State
---
## Focus
- fixture
EOF
cat > "$W/entities/index.md" <<'EOF'
---
type: index
title: Entities
---
- [Alpha System](alpha.md)
EOF
cat > "$W/concepts/index.md" <<'EOF'
---
type: index
title: Concepts
---
- [Beta Concept](beta.md)
EOF
cat > "$W/entities/alpha.md" <<'EOF'
---
type: entity
title: Alpha System
timestamp: 2026-01-01
---
Alpha builds on the [Beta Concept](../concepts/beta.md).
EOF
cat > "$W/concepts/beta.md" <<'EOF'
---
type: concept
title: Beta Concept
timestamp: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
A concept used by [Alpha System](../entities/alpha.md).
EOF
# orphan (no inbound link) that MENTIONS "Beta Concept" in prose without linking it -> missed-link
cat > "$W/notes/orphan.md" <<'EOF'
---
type: notes
title: Orphan note
---
This note discusses the Beta Concept at length but never links it.
EOF
echo "original source text" > "$W/sources/beta-src.md"

git -C "$W" init -q
git -C "$W" add -A
git -C "$W" -c user.name=t -c user.email=t@t commit -qm c1

echo "--- deterministic checkers (commit 1) ---"
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "broken links: none" "broken=0" "$core"
assert_contains "orphan detected"    "ORPHAN notes/orphan.md" "$core"
missed=$(python3 "$H/missed-links.py" "$W")
assert_contains "missed-link detected" "MISSED-LINK notes/orphan.md" "$missed"

echo "--- query ---"
qout=$($Q --root "$W" beta concept)
top=$(printf '%s\n' "$qout" | head -1 | awk '{print $2}')
assert "query top hit is beta.md" "concepts/beta.md" "$top"
qtype=$($Q --root "$W" --type entity alpha | head -1 | awk '{print $2}')
assert "type filter -> alpha.md" "entities/alpha.md" "$qtype"

echo "--- config seam (missed_link_stop) ---"
before=$(printf '%s\n' "$missed" | sed -n 's/^MISSED_LINKS=//p')
echo '{"missed_link_stop": ["Beta Concept"]}' > "$W/wiki.config.json"
after=$(python3 "$H/missed-links.py" "$W" | sed -n 's/^MISSED_LINKS=//p')
assert "stoplist drops the missed link" "$((before-1))" "$after"
rm "$W/wiki.config.json"

echo "--- gate fails on a broken link ---"
cat > "$W/notes/orphan.md" <<'EOF'
---
type: notes
title: Orphan note
---
Now links a [missing page](../concepts/does-not-exist.md).
EOF
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "lint.sh exits 1 on broken link" "1" "$rc"
git -C "$W" checkout -q -- notes/orphan.md   # restore

echo "--- stale-source diff mode (source changed across commits) ---"
echo "the source text CHANGED substantively" > "$W/sources/beta-src.md"
git -C "$W" add -A
git -C "$W" -c user.name=t -c user.email=t@t commit -qm c2
stale=$(python3 "$H/stale-source.py" --range HEAD~1..HEAD "$W")
assert_contains "beta.md flagged RE-CHECK" "RE-CHECK concepts/beta.md" "$stale"

echo "--- reflect-scope caps + runs ---"
scope=$(python3 "$H/reflect-scope.py" "$W")
assert_contains "reflect-scope emits a count" "SCOPE_COUNT=" "$scope"

echo
echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
echo "======================================"
rm -rf "$(dirname "$W")"
[ "$fail" -eq 0 ]
