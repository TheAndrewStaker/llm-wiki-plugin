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

echo "--- gate does NOT fail OPEN on content that used to crash lint-core ---"
# whitespace-only link target [x](  ) once raised IndexError -> lint.sh printed OK/exit 0 while a
# real broken link on the same page slipped through. Must now exit nonzero, not 0.
printf -- '---\ntype: notes\ntitle: crashy\n---\nWhitespace [x](  ) and a real broken [y](nope.md).\n' > "$W/notes/crashy.md"
git -C "$W" add -A >/dev/null 2>&1
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "crashy+broken content does not pass (nonzero exit)" "yes" "$([ "$rc" -ne 0 ] && echo yes || echo no)"
# a non-UTF-8 byte in a tracked page must not crash the gate open either
printf -- '---\ntype: notes\ntitle: bin\n---\nok \xff\xfe done\n' > "$W/notes/binbyte.md"
git -C "$W" add -A >/dev/null 2>&1
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc2=$?
assert "non-utf8 page does not crash the gate open" "yes" "$([ "$rc2" -ne 0 ] && echo yes || echo no)"
git -C "$W" rm -qf notes/crashy.md notes/binbyte.md >/dev/null 2>&1

echo "--- reflect-scope caps + runs ---"
scope=$(python3 "$H/reflect-scope.py" "$W")
assert_contains "reflect-scope emits a count" "SCOPE_COUNT=" "$scope"

echo "--- search health check (deterministic index-size tripwire) ---"
h=$($Q --root "$W" --health)
assert_contains "health emits a verdict" "verdict:" "$h"
assert_contains "health scopes itself to the size tripwire" "recall tripwire" "$h"

echo "--- malformed-YAML frontmatter is caught + fails the gate ---"
# a `related:` markdown link opens a flow sequence YAML can't parse (breaks Obsidian + any parser)
printf -- '---\ntype: notes\ntitle: bad fm\nrelated: [Widget](../entities/widget.md)\n---\nbody\n' > "$W/notes/badfm.md"
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "malformed frontmatter flagged" "BADYAML notes/badfm.md" "$core"
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "gate fails on malformed frontmatter" "1" "$rc"
# a VALID flow sequence must NOT be flagged
printf -- '---\ntype: notes\ntitle: good fm\ntags: [a, b, c]\n---\nbody\n' > "$W/notes/goodfm.md"
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert "valid flow sequence not flagged" "0" "$(printf '%s\n' "$core" | grep -c 'BADYAML notes/goodfm.md')"
git -C "$W" rm -qf notes/badfm.md notes/goodfm.md >/dev/null 2>&1

echo "--- catalog + neighbors ---"
cout=$($Q --root "$W" --catalog)
assert_contains "catalog reports page count" "catalog.tsv" "$cout"
assert_contains "catalog lists beta.md" "concepts/beta.md" "$(cat "$W/catalog.tsv")"
nout=$($Q --root "$W" --neighbors beta concept)
assert_contains "neighbors surfaces a 1-hop link" "entities/alpha.md" "$nout"

echo "--- collision + index-drift advisories ---"
cat > "$W/concepts/beta-dup.md" <<'EOF'
---
type: concept
title: Beta Concept
---
A second page claiming the name "Beta Concept".
EOF
cat > "$W/concepts/gamma.md" <<'EOF'
---
type: concept
title: Gamma Concept
---
A page the concepts index does not list.
EOF
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "duplicate title flagged" 'COLLISION "Beta Concept"' "$core"
assert_contains "collision names the duplicate page" "concepts/beta-dup.md" "$core"
assert_contains "unindexed page flagged" "UNINDEXED concepts/gamma.md" "$core"
assert "indexed page not flagged" "0" "$(printf '%s\n' "$core" | grep -c 'UNINDEXED concepts/beta.md')"
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "collision/unindexed stay advisory (gate passes)" "0" "$rc"
echo '{"collision_exempt": ["beta concept"]}' > "$W/wiki.config.json"
core=$(python3 "$H/lint-core.py" "$W")
assert "collision_exempt drops the collision" "0" "$(printf '%s\n' "$core" | grep -c 'COLLISION')"
rm "$W/wiki.config.json"
git -C "$W" rm -qf concepts/beta-dup.md concepts/gamma.md >/dev/null 2>&1

echo "--- rewrite-links: dry-run plans, apply repoints, lint stays green ---"
git -C "$W" mv concepts/beta.md concepts/beta-renamed.md
dry=$(python3 "$H/rewrite-links.py" concepts/beta.md concepts/beta-renamed.md "$W")
assert_contains "dry-run plans the alpha rewrite" "REWRITE entities/alpha.md" "$dry"
assert_contains "dry-run leaves files untouched" "(../concepts/beta.md)" "$(cat "$W/entities/alpha.md")"
python3 "$H/rewrite-links.py" concepts/beta.md concepts/beta-renamed.md "$W" --apply >/dev/null
assert_contains "apply repoints alpha's link" "(../concepts/beta-renamed.md)" "$(cat "$W/entities/alpha.md")"
assert_contains "apply repoints the index link" "(beta-renamed.md)" "$(cat "$W/concepts/index.md")"
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "no broken links after rename+rewrite" "broken=0" "$core"
git -C "$W" -c user.name=t -c user.email=t@t commit -qm c3

echo "--- per-type required fields + dead ends + supersede hygiene ---"
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "notes page missing synthesized_from flagged" "MISSING-FIELD notes/orphan.md" "$core"
assert_contains "entity missing description flagged" "MISSING-FIELD entities/alpha.md" "$core"
assert_contains "linkless page is a dead end" "DEADEND notes/orphan.md" "$core"
assert "linked page is not a dead end" "0" "$(printf '%s\n' "$core" | grep -c 'DEADEND entities/alpha.md')"
echo '{"type_requirements": {}}' > "$W/wiki.config.json"
core=$(python3 "$H/lint-core.py" "$W")
assert "type_requirements config seam empties the check" "0" "$(printf '%s\n' "$core" | grep -c 'MISSING-FIELD')"
rm "$W/wiki.config.json"
mkdir -p "$W/archive"
cat > "$W/archive/older-widget.md" <<'EOF'
---
type: archive
title: Older widget notes
---
Status: Superseded
Superseded by [old widget notes](old-widget.md).
EOF
cat > "$W/archive/old-widget.md" <<'EOF'
---
type: archive
title: Old widget notes
---
Status: Superseded
Superseded by [Beta Concept](../concepts/beta-renamed.md); see also [older](older-widget.md).
EOF
cat > "$W/notes/pointer.md" <<'EOF'
---
type: notes
title: Pointer note
synthesized_from: ../sources/beta-src.md
---
Still cites [old widget notes](../archive/old-widget.md).
EOF
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "live link to superseded page flagged" "STALE-POINTER notes/pointer.md" "$core"
assert_contains "superseded chain flagged" "CHAIN archive/old-widget.md -> archive/older-widget.md" "$core"
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "new checks stay advisory (gate passes)" "0" "$rc"
git -C "$W" rm -qf archive/older-widget.md archive/old-widget.md notes/pointer.md >/dev/null 2>&1

echo "--- wanted-pages red-link ranking ---"
cat > "$W/notes/wishlist.md" <<'EOF'
---
type: notes
title: Wishlist note
synthesized_from: ../sources/beta-src.md
---
We keep citing [[Gadget Spec]] and again [[Gadget Spec]], plus [[Alpha System]].
Links [Beta Concept](../concepts/beta-renamed.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
wanted=$(python3 "$H/wanted-pages.py" "$W")
assert_contains "unresolved wikilink ranked with count" "WANTED [[gadget spec]] (2 mentions" "$wanted"
assert "wikilink matching an existing title is resolved" "0" "$(printf '%s\n' "$wanted" | grep -c 'alpha system')"
git -C "$W" rm -qf notes/wishlist.md >/dev/null 2>&1

echo "--- template scaffold lints clean + pre-commit gate blocks ---"
# wiki-setup's deterministic core: templates/tree + the wiki's own hook copies must yield a
# lint-green wiki whose pre-commit rejects a broken link and passes a clean commit.
T="$(mktemp -d)/fresh"
mkdir -p "$T"
cp -R "$ROOT/templates/tree/." "$T/"
mv "$T/gitignore" "$T/.gitignore"
mkdir -p "$T/hooks"
for f in lint.sh lint-core.py graph-check.py missed-links.py stale-source.py reflect-scope.py rewrite-links.py wanted-pages.py wikilib.py pre-commit; do
  cp "$ROOT/hooks/$f" "$T/hooks/"
done
git -C "$T" init -q
git -C "$T" config core.hooksPath hooks
git -C "$T" add -A
git -C "$T" -c user.name=t -c user.email=t@t commit -qm scaffold >/dev/null 2>&1; rc=$?
assert "fresh scaffold commits through the gate" "0" "$rc"
bash "$T/hooks/lint.sh" "$T" >/dev/null 2>&1; rc=$?
assert "fresh scaffold lints clean" "0" "$rc"
printf -- '---\ntype: notes\ntitle: bad\n---\n[broken](../nope/missing.md)\n' > "$T/notes/bad.md"
git -C "$T" add -A
git -C "$T" -c user.name=t -c user.email=t@t commit -qm bad >/dev/null 2>&1; rc=$?
assert "pre-commit blocks a broken-link commit" "yes" "$([ "$rc" -ne 0 ] && echo yes || echo no)"
rm -rf "$(dirname "$T")"

echo "--- org-residue scan (scanner ships; terms live in a gitignored denylist) ---"
bash "$ROOT/scripts/check-no-org.sh" >/dev/null 2>&1; rc=$?
assert "org-residue scan passes on tracked repo" "0" "$rc"

echo
echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
echo "======================================"
rm -rf "$(dirname "$W")"
[ "$fail" -eq 0 ]
