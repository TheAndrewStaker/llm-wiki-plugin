#!/usr/bin/env bash
# Self-contained test harness. Builds a throwaway fixture wiki (with git history so stale-source
# can be exercised), runs the deterministic stack, and asserts golden results. Exits nonzero on
# any failure. Usage: tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/hooks"
# Invoke the interpreter explicitly: the `#!/usr/bin/env python3` shebang is not exec-able on
# every host (some Python launchers cannot be run through MSYS `env`), so never rely on it.
Q="python3 $ROOT/bin/wiki-query"
W="$(mktemp -d)/wiki"
mkdir -p "$W"/{entities,concepts,notes,analyses,sources}
export WIKI_ROOT="$W"

pass=0; fail=0
assert() { # assert "<label>" <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi
}
assert_contains() { # assert_contains "<label>" "<needle>" "<haystack>"
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); printf 'PASS  %s\n' "$1"
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

echo "--- query: superseded/archived pages are down-ranked, not just equally-matched ---"
DR="$(mktemp -d)/wiki"
mkdir -p "$DR"/{concepts,archive}
git -C "$DR" init -q
git -C "$DR" config user.name test
git -C "$DR" config user.email test@example.invalid
cat > "$DR/concepts/live.md" <<'EOF'
---
type: concept
title: Zephyr Calibration Notes
---
This page covers the zephyr calibration approach we use today across every
downstream deployment and keep current going forward without exception.
EOF
cat > "$DR/concepts/old.md" <<'EOF'
---
type: concept
title: Old Zephyr Notes
superseded_by: concepts/live.md
---
zephyr calibration zephyr calibration zephyr calibration zephyr calibration
zephyr calibration
EOF
cat > "$DR/archive/ancient.md" <<'EOF'
---
type: concept
title: Ancient Zephyr Notes
---
zephyr calibration zephyr calibration zephyr calibration
EOF
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" commit -qm seed
drout=$($Q --root "$DR" --limit 10 zephyr calibration)
drtop=$(printf '%s\n' "$drout" | head -1 | awk '{print $2}')
assert "the live page outranks the superseded page by default" "concepts/live.md" "$drtop"
assert_contains "the superseded page is tagged in output" "[superseded]" "$drout"
assert_contains "the archived page is tagged in output" "[archive]" "$drout"
printf '{"superseded_downrank": 1.0}\n' > "$DR/wiki.config.json"
puredr=$($Q --root "$DR" --limit 10 zephyr calibration)
puretop=$(printf '%s\n' "$puredr" | head -1 | awk '{print $2}')
assert "superseded_downrank: 1.0 restores pure BM25 order" "concepts/old.md" "$puretop"
rm -rf "$(dirname "$DR")"

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

echo "--- graph-check.py does not crash on a backticked whitespace-only link target ---"
# graph-check.py did NOT strip inline code / fenced blocks like lint-core.py, so a page merely
# documenting the bad-link syntax inside backticks still hit `.split()[0]` on a whitespace-only
# target and raised IndexError, which made lint.sh's summary print "islands:?".
printf -- '---\ntype: notes\ntitle: syntax doc\n---\nBad-link example: `[x](  )`. See [alpha](../entities/alpha.md).\n' > "$W/notes/syntaxdoc.md"
git -C "$W" add -A >/dev/null 2>&1
graph=$(python3 "$H/graph-check.py" "$W" 2>&1); rc=$?
assert "graph-check.py does not crash (exit 0)" "0" "$rc"
assert_contains "graph-check.py still reports COMPONENTS" "COMPONENTS=" "$graph"
lint_out=$(bash "$H/lint.sh" "$W" 2>&1)
assert "lint.sh summary no longer shows islands:?" "0" "$(printf '%s\n' "$lint_out" | grep -c 'islands:?')"
git -C "$W" rm -qf notes/syntaxdoc.md >/dev/null 2>&1

echo "--- reflect-scope caps + runs ---"
scope=$(python3 "$H/reflect-scope.py" "$W")
assert_contains "reflect-scope emits a count" "SCOPE_COUNT=" "$scope"

echo "--- reflect-scope includes a freshly committed contradiction-pair page ---"
# Seeded-contradiction self-test (pin #1 of 3): a page only becomes eligible for the
# reflect pass once it is actually committed to the fixture, mirroring how a real ingest
# lands. This does not judge the contradiction itself (that needs a subagent, see
# evals/reflect-contradiction.example.md); it only pins that reflect-scope.py's candidate
# list picks up the newly committed page via the oldest-timestamp lane.
cp "$ROOT/tests/fixtures/contradiction-a.md" "$W/entities/relay-node.md"
cp "$ROOT/tests/fixtures/contradiction-b.md" "$W/concepts/relay-node-defaults.md"
git -C "$W" add -A >/dev/null 2>&1
git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add relay-node contradiction pair" >/dev/null 2>&1
pair_scope=$(python3 "$H/reflect-scope.py" "$W")
assert_contains "reflect-scope includes the committed contradiction page" \
  "entities/relay-node.md" "$pair_scope"
git -C "$W" rm -qf entities/relay-node.md concepts/relay-node-defaults.md >/dev/null 2>&1
git -C "$W" -c user.name=t -c user.email=t@t commit -qm "remove relay-node contradiction pair" >/dev/null 2>&1

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
mkdir -p "$W/journal"
printf -- '---\ntype: notes\ntitle: Log\n---\nShipped the [[image marker]] change.\n' > "$W/journal/2020-01-02.md"
git -C "$W" add -A >/dev/null 2>&1
assert_contains "a wikilink in a log is wanted by default" "WANTED [[image marker]]" "$(python3 "$H/wanted-pages.py" "$W")"
printf '{"wanted_exempt_dirs": ["journal/"]}' > "$W/wiki.config.json"
wanted_ex=$(python3 "$H/wanted-pages.py" "$W")
assert "wanted_exempt_dirs skips that directory" "0" "$(printf '%s\n' "$wanted_ex" | grep -c 'image marker')"
assert_contains "exemption does not suppress other directories" "WANTED [[gadget spec]]" "$wanted_ex"
rm -f "$W/wiki.config.json"
git -C "$W" rm -qf journal/2020-01-02.md >/dev/null 2>&1
git -C "$W" rm -qf notes/wishlist.md >/dev/null 2>&1

echo "--- shared alias parsing + fenced supersede example (review fixes) ---"
cat > "$W/concepts/gizmo.md" <<'EOF'
---
type: concept
title: Gizmo Framework
aliases:
  - The Gizmo
  - gizmo-fw
---
Outgoing: [alpha](../entities/alpha.md).
EOF
cat > "$W/notes/gizmo-note.md" <<'EOF'
---
type: notes
title: Gizmo note
synthesized_from: ../sources/beta-src.md
---
Mentions [[The Gizmo|the framework]] and [[gizmo-fw]] and [[Missing Thing]].
Links [alpha](../entities/alpha.md).
EOF
git -C "$W" add -A >/dev/null 2>&1
wanted=$(python3 "$H/wanted-pages.py" "$W")
assert "block alias resolves a display wikilink" "0" "$(printf '%s\n' "$wanted" | grep -c 'the gizmo')"
assert "block alias resolves a plain wikilink" "0" "$(printf '%s\n' "$wanted" | grep -c 'gizmo fw')"
assert_contains "unknown name still wanted" "WANTED [[missing thing]]" "$wanted"
cat > "$W/concepts/gizmo2.md" <<'EOF'
---
type: concept
title: Gizmo Two
aliases: [Gizmo Framework]
---
Body. [alpha](../entities/alpha.md).
EOF
cat > "$W/notes/docsup.md" <<'EOF'
---
type: notes
title: Supersede convention doc
synthesized_from: ../sources/beta-src.md
---
The convention, as an example:
```
Status: Superseded
```
See [alpha](../entities/alpha.md).
EOF
cat > "$W/notes/docsup-linker.md" <<'EOF'
---
type: notes
title: Linker note
synthesized_from: ../sources/beta-src.md
---
Cites the [convention doc](docsup.md).
EOF
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "alias-vs-title collision flagged" 'COLLISION "Gizmo Framework"' "$core"
assert "fenced supersede example is not a superseded page" "0" "$(printf '%s\n' "$core" | grep -c 'STALE-POINTER notes/docsup-linker.md')"
git -C "$W" rm -qf concepts/gizmo.md concepts/gizmo2.md notes/gizmo-note.md notes/docsup.md notes/docsup-linker.md >/dev/null 2>&1

echo "--- inbox soft-cap advisory (disabled by default) ---"
inbox=$(python3 "$H/inbox-check.py" "$W")
assert "inbox check disabled by default (no config)" "INBOX=-" "$inbox"

echo "--- inbox soft-cap advisory: under cap is OK ---"
cat >> "$W/STATE.md" <<'EOF'

## Inbox
- [2026-01-01 · test] first item
- [2026-01-01 · test] second item
EOF
echo '{"inbox_soft_max_items": 5, "inbox_soft_max_words": 200}' > "$W/wiki.config.json"
inbox=$(python3 "$H/inbox-check.py" "$W")
assert "inbox under both caps is OK" "INBOX=OK" "$inbox"

echo "--- inbox soft-cap advisory: over the item cap is OVER ---"
echo '{"inbox_soft_max_items": 1, "inbox_soft_max_words": 200}' > "$W/wiki.config.json"
inbox=$(python3 "$H/inbox-check.py" "$W")
assert_contains "inbox over item cap flagged OVER" "INBOX=OVER" "$inbox"
assert_contains "inbox advisory line names STATE.md" "INBOX-OVER STATE.md" "$inbox"
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "inbox soft-cap stays advisory (gate passes)" "0" "$rc"

echo "--- inbox soft-cap advisory: over the word cap alone is also OVER ---"
echo '{"inbox_soft_max_items": 50, "inbox_soft_max_words": 3}' > "$W/wiki.config.json"
inbox=$(python3 "$H/inbox-check.py" "$W")
assert_contains "inbox over word cap flagged OVER" "INBOX=OVER" "$inbox"
rm "$W/wiki.config.json"
git -C "$W" checkout -q -- STATE.md   # restore the fixture STATE.md (no Inbox section)

echo "--- timestamp-drift advisory (disabled by default) ---"
cat > "$W/notes/drifted.md" <<'EOF'
---
type: notes
title: Drifted page
timestamp: 2020-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-06-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-06-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add drifted page" >/dev/null 2>&1
drift=$(python3 "$H/timestamp-drift.py" "$W")
assert "timestamp-drift disabled by default" "DRIFT=0" "$drift"

echo "--- timestamp-drift advisory: a drifted page is flagged when enabled ---"
echo '{"timestamp_drift_days": 7}' > "$W/wiki.config.json"
drift=$(python3 "$H/timestamp-drift.py" "$W")
assert_contains "drifted page flagged" "DRIFT notes/drifted.md" "$drift"
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "timestamp-drift stays advisory (gate passes)" "0" "$rc"

echo "--- timestamp-drift advisory: exempt-only commits after baseline are ignored ---"
cat > "$W/notes/exempt-example.md" <<'EOF'
---
type: notes
title: Exempt example page
timestamp: 2026-01-05
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-05 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-05 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add exempt example page" >/dev/null 2>&1
echo "trailing autosave edit" >> "$W/notes/exempt-example.md"
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "session auto-save: bump" >/dev/null 2>&1
drift=$(python3 "$H/timestamp-drift.py" "$W")
assert "exempt-only-edited page is not flagged" "0" "$(printf '%s\n' "$drift" | grep -c 'DRIFT notes/exempt-example.md')"
rm "$W/wiki.config.json"
git -C "$W" rm -qf notes/drifted.md notes/exempt-example.md >/dev/null 2>&1

echo "--- rubber-stamp advisory: a bare forward timestamp bump is flagged ---"
cat > "$W/notes/rs-flagged.md" <<'EOF'
---
type: notes
title: RS flagged page
timestamp: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-flagged page" >/dev/null 2>&1
sed -i.bak 's/^timestamp: 2026-01-01/timestamp: 2026-07-01/' "$W/notes/rs-flagged.md"
rm -f "$W/notes/rs-flagged.md.bak"
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "bump timestamp" >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert_contains "bare forward bump flagged" "RUBBER-STAMP notes/rs-flagged.md" "$rs"
bash "$H/lint.sh" "$W" >/dev/null 2>&1; rc=$?
assert "rubber-stamp stays advisory (gate passes)" "0" "$rc"

echo "--- rubber-stamp advisory: a timestamp bump WITH a content edit is not flagged ---"
cat > "$W/notes/rs-content.md" <<'EOF'
---
type: notes
title: RS content page
timestamp: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end. Original body.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-content page" >/dev/null 2>&1
cat > "$W/notes/rs-content.md" <<'EOF'
---
type: notes
title: RS content page
timestamp: 2026-07-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end. Revised body.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "revise rs-content page" >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert "content-edit bump is not flagged" "0" \
  "$(printf '%s\n' "$rs" | grep -c 'RUBBER-STAMP notes/rs-content.md')"

echo "--- rubber-stamp advisory: a reviewed:-only bump is not flagged ---"
cat > "$W/notes/rs-reviewed.md" <<'EOF'
---
type: notes
title: RS reviewed page
timestamp: 2026-01-01
reviewed: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-reviewed page" >/dev/null 2>&1
sed -i.bak 's/^reviewed: 2026-01-01/reviewed: 2026-07-01/' "$W/notes/rs-reviewed.md"
rm -f "$W/notes/rs-reviewed.md.bak"
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "re-verify rs-reviewed page" >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert "reviewed:-only bump is not flagged" "0" \
  "$(printf '%s\n' "$rs" | grep -c 'RUBBER-STAMP notes/rs-reviewed.md')"

echo "--- rubber-stamp advisory: a backward correction to match git history is not flagged ---"
cat > "$W/notes/rs-backward.md" <<'EOF'
---
type: notes
title: RS backward page
timestamp: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-backward page" >/dev/null 2>&1
sed -i.bak 's/^timestamp: 2026-01-01/timestamp: 2026-09-01/' "$W/notes/rs-backward.md"
rm -f "$W/notes/rs-backward.md.bak"
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-02-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-02-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "erroneously stamp ahead" >/dev/null 2>&1
sed -i.bak 's/^timestamp: 2026-09-01/timestamp: 2026-01-15/' "$W/notes/rs-backward.md"
rm -f "$W/notes/rs-backward.md.bak"
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-03-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-03-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "correct timestamp to match history" >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert "backward correction is not flagged" "0" \
  "$(printf '%s\n' "$rs" | grep -c 'RUBBER-STAMP notes/rs-backward.md')"

echo "--- rubber-stamp advisory: staged (uncommitted) forward bump is flagged too ---"
cat > "$W/notes/rs-staged.md" <<'EOF'
---
type: notes
title: RS staged page
timestamp: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-staged page" >/dev/null 2>&1
sed -i.bak 's/^timestamp: 2026-01-01/timestamp: 2026-07-01/' "$W/notes/rs-staged.md"
rm -f "$W/notes/rs-staged.md.bak"
git -C "$W" add -A >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert_contains "staged forward bump flagged" "RUBBER-STAMP notes/rs-staged.md" "$rs"
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "bump timestamp (staged test)" >/dev/null 2>&1

echo "--- rubber-stamp advisory: reordered frontmatter cannot hide the bump ---"
cat > "$W/notes/rs-reorder.md" <<'EOF'
---
type: notes
title: RS reorder page
timestamp: 2026-01-01
reviewed: 2026-01-02
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-reorder page" >/dev/null 2>&1
cat > "$W/notes/rs-reorder.md" <<'EOF'
---
type: notes
title: RS reorder page
reviewed: 2026-01-02
timestamp: 2026-07-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "bump with reordered keys" >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert_contains "reordered-key bump flagged" "RUBBER-STAMP notes/rs-reorder.md" "$rs"

echo "--- rubber-stamp advisory: an inserted blank line cannot hide the bump ---"
cat > "$W/notes/rs-blank.md" <<'EOF'
---
type: notes
title: RS blank page
timestamp: 2026-01-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-01-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-01-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "add rs-blank page" >/dev/null 2>&1
cat > "$W/notes/rs-blank.md" <<'EOF'
---
type: notes
title: RS blank page

timestamp: 2026-07-01
synthesized_from: ../sources/beta-src.md
---
Links [alpha](../entities/alpha.md) so it is not a dead end.
EOF
git -C "$W" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="2026-07-01 12:00:00 +0000" GIT_COMMITTER_DATE="2026-07-01 12:00:00 +0000" \
  git -C "$W" -c user.name=t -c user.email=t@t commit -qm "bump with inserted blank" >/dev/null 2>&1
rs=$(python3 "$H/rubber-stamp.py" "$W")
assert_contains "blank-line bump flagged" "RUBBER-STAMP notes/rs-blank.md" "$rs"

echo "--- rubber-stamp advisory: advisory_budgets.rubber_stamp gates it ---"
printf '{"advisory_budgets":{"rubber_stamp":0}}\n' > "$W/wiki.config.json"
budget_out=$(bash "$H/lint.sh" "$W" 2>&1); rc=$?
assert "the just-committed rubber-stamp bump busts a 0 budget" "1" "$rc"
assert_contains "budget failure names rubber_stamp" "BUDGET rubber_stamp=" "$budget_out"
rm "$W/wiki.config.json"
git -C "$W" rm -qf notes/rs-flagged.md notes/rs-content.md notes/rs-reviewed.md \
  notes/rs-backward.md notes/rs-staged.md notes/rs-reorder.md notes/rs-blank.md \
  >/dev/null 2>&1
git -C "$W" -c user.name=t -c user.email=t@t commit -qm "clean up rubber-stamp fixtures" \
  >/dev/null 2>&1

echo "--- template scaffold lints clean + pre-commit gate blocks ---"
# wiki-setup's deterministic core: templates/tree + the wiki's own hook copies must yield a
# lint-green wiki whose pre-commit rejects a broken link and passes a clean commit.
T="$(mktemp -d)/fresh"
mkdir -p "$T"
cp -R "$ROOT/templates/tree/." "$T/"
mv "$T/gitignore" "$T/.gitignore"
python3 "$ROOT/bin/wiki-vendor" --install "$T" >/dev/null
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

echo "--- meeting media transcription wrapper ---"
MEDIA_TMP="$(mktemp -d)"
mkdir -p "$MEDIA_TMP/bin" "$MEDIA_TMP/out"
touch "$MEDIA_TMP/meeting.mp4"
cat > "$MEDIA_TMP/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$MEDIA_TMP/bin/mlx_whisper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TRANSCRIBE_ARGS"
out=; name=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir) out=$2; shift 2 ;;
    --output-name) name=$2; shift 2 ;;
    *) shift ;;
  esac
done
for extension in txt vtt srt tsv json; do printf 'fixture\n' > "$out/$name.$extension"; done
EOF
chmod +x "$MEDIA_TMP/bin/ffmpeg" "$MEDIA_TMP/bin/mlx_whisper"
TRANSCRIBE_ARGS="$MEDIA_TMP/args" PATH="$MEDIA_TMP/bin:$PATH" \
  WIKI_TRANSCRIPTION_MODEL=/models/test WIKI_TRANSCRIPTION_LANGUAGE=en \
  WIKI_TRANSCRIPTION_ORIGIN=https://example.com/recordings/42 \
  bash "$ROOT/skills/meeting-notes/scripts/transcribe-media.sh" \
  "$MEDIA_TMP/meeting.mp4" "$MEDIA_TMP/out" >/dev/null
assert_contains "transcriber receives configured model" "/models/test" "$(cat "$MEDIA_TMP/args")"
assert_contains "transcriber requests word timestamps" "--word-timestamps" "$(cat "$MEDIA_TMP/args")"
assert "transcriber emits wiki-ready VTT" "yes" "$([ -s "$MEDIA_TMP/out/meeting.vtt" ] && echo yes || echo no)"
assert "transcriber emits timestamp JSON" "yes" "$([ -s "$MEDIA_TMP/out/meeting.json" ] && echo yes || echo no)"
assert_contains "transcriber stamps source-media provenance" "source-media: meeting.mp4" "$(cat "$MEDIA_TMP/out/meeting.vtt")"
assert_contains "transcriber stamps source-path provenance" "source-path: $MEDIA_TMP/meeting.mp4" "$(cat "$MEDIA_TMP/out/meeting.vtt")"
assert_contains "transcriber stamps source-origin when given" "source-origin: https://example.com/recordings/42" "$(cat "$MEDIA_TMP/out/meeting.vtt")"
rm -rf "$MEDIA_TMP"

echo "--- companion-source extraction ---"
COMP_TMP="$(mktemp -d)"
python3 - "$COMP_TMP" <<'PYEOF'
import base64, sys
d = sys.argv[1]
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
open(d + "/local.png", "wb").write(png)
open(d + "/note.html", "w").write(
    "<div><h1>Sync</h1></div>"
    '<div><img src="data:image/png;base64,' + base64.b64encode(png).decode() + '"></div>'
    "<div>A point &amp; an entity.</div>"
    "<ul><li>one</li><li>two</li></ul>"
    '<div><img src="local.png"></div>'
    '<div><img src="https://example.com/remote.png"></div>'
    '<div><img src="gone.png"></div>')
PYEOF
out=$(python3 "$ROOT/skills/meeting-notes/scripts/extract-companion.py" \
  --html "$COMP_TMP/note.html" --out "$COMP_TMP/x" --label "9/14 Sync" 2>/dev/null)
text=$(cat "$COMP_TMP/x/9-14-sync.md")
assert_contains "extractor reports both embedded and local-file images" "images: 2" "$out"
assert "extractor slugifies the label" "yes" "$([ -f "$COMP_TMP/x/images/9-14-sync-01.png" ] && echo yes || echo no)"
assert "extractor decodes a data URI to real bytes" "yes" "$([ -s "$COMP_TMP/x/images/9-14-sync-01.png" ] && echo yes || echo no)"
assert "extractor copies a referenced local file" "yes" "$([ -s "$COMP_TMP/x/images/9-14-sync-02.png" ] && echo yes || echo no)"
assert_contains "image marker holds the position the image had in the text" "# Sync" "$text"
assert_contains "text keeps an in-place image marker" "[[image 1:" "$text"
assert_contains "remote images are named, not fetched" "remote, not fetched" "$text"
assert_contains "a missing local reference is named" "missing local file: gone.png" "$text"
assert_contains "entities are unescaped" "A point & an entity." "$text"
assert_contains "list items become one bullet per line" "- one
- two" "$text"
assert "raw markup does not reach the text" "0" "$(printf '%s' "$text" | grep -c '<div')"
python3 "$ROOT/skills/meeting-notes/scripts/extract-companion.py" \
  --html "$COMP_TMP/note.html" --out "$COMP_TMP/y" --max-px 0 >/dev/null 2>&1
assert "--max-px 0 writes no readable copy" "0" "$(ls "$COMP_TMP/y/images" | grep -c '\.view\.')"
python3 "$ROOT/skills/meeting-notes/scripts/extract-companion.py" --html "$COMP_TMP/none.html" \
  --out "$COMP_TMP/z" >/dev/null 2>&1; rc=$?
assert "a missing source file is a usage error" "2" "$rc"
printf '<p>text only</p>' > "$COMP_TMP/plain.html"
python3 "$ROOT/skills/meeting-notes/scripts/extract-companion.py" --html "$COMP_TMP/plain.html" \
  --out "$COMP_TMP/p" >/dev/null 2>&1
assert "no images means no images directory" "no" "$([ -d "$COMP_TMP/p/images" ] && echo yes || echo no)"
rm -rf "$COMP_TMP"

echo "--- OKF interchange export and validation ---"
OKF_TMP="$(mktemp -d)"
OKF_WIKI="$OKF_TMP/wiki"
OKF_OUT="$OKF_TMP/export"
cp -R "$ROOT/templates/tree" "$OKF_WIKI"
mkdir -p "$OKF_WIKI/sources"
printf 'private raw source\n' > "$OKF_WIKI/sources/private.md"
printf '%s\n' '---' 'type: concept' 'title: Exported concept' '---' 'Body.' > "$OKF_WIKI/concepts/exported.md"
python3 "$ROOT/bin/wiki-okf" export "$OKF_WIKI" "$OKF_OUT" >/dev/null; rc=$?
assert "OKF export succeeds" "0" "$rc"
python3 "$ROOT/bin/wiki-okf" validate "$OKF_OUT" >/dev/null; rc=$?
assert "OKF exported bundle validates" "0" "$rc"
assert_contains "OKF root index declares okf_version" 'okf_version: "0.1"' "$(head -3 "$OKF_OUT/index.md")"
assert "OKF per-dir index has no frontmatter" "0" "$(head -1 "$OKF_OUT/concepts/index.md" | grep -c '^---$')"
assert_contains "OKF exporter generates navigation section" "# concepts" "$(cat "$OKF_OUT/concepts/index.md")"
assert "OKF export excludes raw sources" "no" "$([ -e "$OKF_OUT/sources/private.md" ] && echo yes || echo no)"
printf '%s\n' '---' 'type: [broken' '---' 'invalid YAML' > "$OKF_OUT/concepts/invalid.md"
okf_invalid=$(python3 "$ROOT/bin/wiki-okf" validate "$OKF_OUT" 2>&1); rc=$?
assert "OKF validator rejects unparseable YAML" "1" "$rc"
assert_contains "OKF validator names invalid YAML" "INVALID_YAML concepts/invalid.md" "$okf_invalid"
rm "$OKF_OUT/concepts/invalid.md"
printf '%s\n' '---' '- not' '- a mapping' '---' 'list frontmatter' > "$OKF_OUT/concepts/listfm.md"
okf_listfm=$(python3 "$ROOT/bin/wiki-okf" validate "$OKF_OUT" 2>&1); rc=$?
assert "OKF validator rejects non-mapping frontmatter" "1" "$rc"
assert_contains "OKF validator names non-mapping page" "INVALID_YAML concepts/listfm.md" "$okf_listfm"
rm "$OKF_OUT/concepts/listfm.md"
printf '%s\n' '---' 'type: index' '---' 'invalid reserved file' > "$OKF_OUT/concepts/index.md"
python3 "$ROOT/bin/wiki-okf" validate "$OKF_OUT" >/dev/null; rc=$?
assert "OKF validator rejects reserved frontmatter" "1" "$rc"
rm -rf "$OKF_TMP"

echo "--- immutable source staging and provenance ledger ---"
STAGE_TMP="$(mktemp -d)"
mkdir -p "$STAGE_TMP/wiki"
printf 'trusted bytes, untrusted prose\n' > "$STAGE_TMP/input.txt"
python3 "$H/stage-source.py" --root "$STAGE_TMP/wiki" --source "$STAGE_TMP/input.txt" \
  --destination sources/2026-07-13-input.txt --source-ref fixture >/dev/null; rc=$?
assert "source staging succeeds" "0" "$rc"
expected_hash=$(shasum -a 256 "$STAGE_TMP/input.txt" | awk '{print $1}')
assert_contains "ledger records SHA-256" "$expected_hash" "$(cat "$STAGE_TMP/wiki/.compendium/ingest-ledger.jsonl")"
python3 "$H/stage-source.py" --root "$STAGE_TMP/wiki" --source "$STAGE_TMP/input.txt" \
  --destination sources/2026-07-13-input.txt --source-ref fixture >/dev/null; rc=$?
assert "identical restaging is idempotent" "0" "$rc"
assert "idempotent staging writes one ledger row" "1" "$(wc -l < "$STAGE_TMP/wiki/.compendium/ingest-ledger.jsonl" | tr -d ' ')"
printf 'different bytes\n' > "$STAGE_TMP/input.txt"
python3 "$H/stage-source.py" --root "$STAGE_TMP/wiki" --source "$STAGE_TMP/input.txt" \
  --destination sources/2026-07-13-input.txt >/dev/null 2>&1; rc=$?
assert "immutable staged path rejects replacement" "2" "$rc"
assert_contains "staged bytes remain unchanged" "trusted bytes" "$(cat "$STAGE_TMP/wiki/sources/2026-07-13-input.txt")"
rm -rf "$STAGE_TMP"

echo "--- model-neutral CLI, spoke pointers, and advisory budgets ---"
cli_query=$(python3 "$ROOT/bin/wiki" --root "$W" query beta concept | head -1)
assert_contains "unified CLI delegates deterministic query" "concepts/beta-renamed.md" "$cli_query"
CLI_TMP="$(mktemp -d)"
mkdir -p "$CLI_TMP/reference"
printf '{"topology":"hub-and-spokes","auto_commit":false,"auto_push":false}\n' > "$CLI_TMP/wiki.config.json"
python3 "$ROOT/bin/wiki" --root "$CLI_TMP" pointer --title "Team handbook" \
  --url https://example.invalid/handbook --remote-path docs/handbook.md --audience team \
  --destination reference/team-handbook.md >/dev/null; rc=$?
assert "pointer creation succeeds" "0" "$rc"
assert_contains "pointer records canonical remote URL" "remote_url: \"https://example.invalid/handbook\"" "$(cat "$CLI_TMP/reference/team-handbook.md")"
assert_contains "pointer records audience" "audience: \"team\"" "$(cat "$CLI_TMP/reference/team-handbook.md")"
cli_status=$(python3 "$ROOT/bin/wiki" --root "$CLI_TMP" status)
assert_contains "unified status reports topology" "topology: hub-and-spokes" "$cli_status"
rm -rf "$CLI_TMP"
printf '{"advisory_budgets":{"orphan":0}}\n' > "$W/wiki.config.json"
budget_out=$(bash "$H/lint.sh" "$W" 2>&1); rc=$?
assert "configured advisory budget fails lint" "1" "$rc"
assert_contains "budget failure names exceeded metric" "BUDGET orphan=" "$budget_out"
rm "$W/wiki.config.json"

echo "--- labeled retrieval evaluation ---"
EVAL_CASES="$(mktemp)"
printf '%s\n' '[{"id":"hit","query":"beta concept","expected":["concepts/beta-renamed.md"]},{"id":"miss","query":"term absent everywhere","expected":["concepts/missing.md"]}]' > "$EVAL_CASES"
eval_out=$(python3 "$ROOT/bin/wiki" --root "$W" eval --cases "$EVAL_CASES" --k 5 --min-recall 0.5); rc=$?
assert "retrieval eval accepts met recall threshold" "0" "$rc"
assert_contains "retrieval eval reports recall" "recall@5=0.500" "$eval_out"
python3 "$ROOT/bin/wiki" --root "$W" eval --cases "$EVAL_CASES" --k 5 --min-recall 0.75 >/dev/null; rc=$?
assert "retrieval eval gates a missed threshold" "1" "$rc"
rm "$EVAL_CASES"

echo "--- frontmatter portability lint ---"
PORT_W="$(mktemp -d)/wiki"
mkdir -p "$PORT_W/concepts"
printf '%s\n' '---' 'type: concept' 'title: Bad' 'title: Dup' '	tabbed: x' 'publish: no' \
  'tag: [a]' 'cssclass: wide' 'tags:' '' '- listed' 'description: >-' '  folded away' '---' 'body' \
  > "$PORT_W/concepts/bad.md"
printf '%s\n' '---' 'type: concept' 'title: Good' \
  'description: "quoted: safe # not a comment"' 'tags: [a, b]' '---' 'body' \
  > "$PORT_W/concepts/good.md"
git -C "$PORT_W" init -q && git -C "$PORT_W" add -A
port=$(python3 "$H/frontmatter-portability.py" "$PORT_W")
port_machine=$(printf '%s\n' "$port" | tail -1)
assert_contains "portability flags duplicate key" "PORT-DUPKEY" "$port"
assert_contains "portability flags tab indentation" "PORT-TAB" "$port"
assert_contains "portability flags Norway-problem scalar" "PORT-AMBIG" "$port"
assert_contains "singular tag advises the real plural" "use plural 'tags:'" "$port"
assert_contains "singular cssclass advises cssclasses" "use plural 'cssclasses:'" "$port"
assert_contains "folded description flagged" "PORT-DESC" "$port"
assert_contains "machine line counts the dup key" "dupkey=1" "$port_machine"
assert_contains "quoted colon-hash value is not TITLECOLON" "titlecolon=0" "$port_machine"
assert_contains "blank line before block list is a valid list" "nonlist=0" "$port_machine"
bash "$H/lint.sh" "$PORT_W" >/dev/null 2>&1; rc=$?
assert "dup-key/tab hard gate fails lint" "1" "$rc"

echo "--- description length is an outlier guard, not a house style ---"
# The description is indexed at 2x weight, so a threshold set inside a healthy corpus's
# spread pushes authors to truncate, which deletes ranked terms. Default sits above it.
DESC_W="$(mktemp -d)/wiki"
mkdir -p "$DESC_W/concepts"
mid=$(python3 -c "print('word ' * 50)")          # ~250 chars: normal for a dense page
huge=$(python3 -c "print('word ' * 120)")        # ~600 chars: a pasted paragraph
printf -- '---\ntype: concept\ntitle: Mid\ndescription: %s\n---\nbody\n' "$mid" > "$DESC_W/concepts/mid.md"
git -C "$DESC_W" init -q && git -C "$DESC_W" add -A
assert_contains "a 250-char description is not flagged" "desc=0" \
  "$(python3 "$H/frontmatter-portability.py" "$DESC_W" | tail -1)"
printf -- '---\ntype: concept\ntitle: Huge\ndescription: %s\n---\nbody\n' "$huge" > "$DESC_W/concepts/huge.md"
git -C "$DESC_W" add -A
huge_out=$(python3 "$H/frontmatter-portability.py" "$DESC_W")
assert_contains "a 600-char description is flagged" "desc=1" "$(printf '%s\n' "$huge_out" | tail -1)"
assert_contains "the advice is to rewrite, not truncate" "do not truncate" "$huge_out"
printf '{"desc_max_chars": 200}\n' > "$DESC_W/wiki.config.json"
assert_contains "the threshold is per-wiki configurable" "desc=2" \
  "$(python3 "$H/frontmatter-portability.py" "$DESC_W" | tail -1)"
printf '{"desc_max_chars": 0}\n' > "$DESC_W/wiki.config.json"
assert_contains "0 disables the length check" "desc=0" \
  "$(python3 "$H/frontmatter-portability.py" "$DESC_W" | tail -1)"
# a folded description is a real break and stays flagged whatever the length setting is
printf -- '---\ntype: concept\ntitle: Folded\ndescription: >-\n  folded away\n---\nbody\n' \
  > "$DESC_W/concepts/folded.md"
git -C "$DESC_W" add -A
assert_contains "a folded description is still a defect with length off" "desc=1" \
  "$(python3 "$H/frontmatter-portability.py" "$DESC_W" | tail -1)"
rm -rf "$(dirname "$DESC_W")"

echo "--- neighbor-scope reconcile nudge ---"
NB_W="$(mktemp -d)/wiki"
mkdir -p "$NB_W/concepts"
printf '%s\n' '---' 'type: concept' 'title: A' '---' 'links [B](b.md)' > "$NB_W/concepts/a.md"
printf '%s\n' '---' 'type: concept' 'title: B' '---' 'body' > "$NB_W/concepts/b.md"
git -C "$NB_W" init -q && git -C "$NB_W" add -A \
  && git -C "$NB_W" -c user.email=t@test -c user.name=t commit -qm base
printf 'edited\n' >> "$NB_W/concepts/b.md"
git -C "$NB_W" add concepts/b.md
nb=$(python3 "$H/neighbor-scope.py" "$NB_W")
assert_contains "neighbor lists the unedited inbound linker" "NEIGHBOR concepts/a.md links concepts/b.md" "$nb"
assert_contains "neighbor machine line counts one" "NEIGHBORS=1" "$nb"
python3 "$H/neighbor-scope.py" --range >/dev/null 2>&1; rc=$?
assert "dangling --range is a usage error" "2" "$rc"

echo "--- session-status.sh: a stalled pull is bounded, not a session-start hang ---"
# A stalled remote must not hang session start. Fake `git` on PATH so the `pull` subcommand
# sleeps far past the timeout while every other git call passes through untouched, then confirm
# session-status.sh still returns promptly and warns instead of blocking.
FAKEBIN="$(mktemp -d)"
REAL_GIT="$(command -v git)"
cat > "$FAKEBIN/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "pull" ]; then sleep 10; touch "$FAKEBIN/pull-completed"; exit 0; fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAKEBIN/git"
br=$(git -C "$W" rev-parse --abbrev-ref HEAD)
git -C "$W" remote add origin file:///nonexistent-origin-for-test >/dev/null 2>&1
git -C "$W" update-ref "refs/remotes/origin/$br" "$(git -C "$W" rev-parse HEAD)" >/dev/null 2>&1
git -C "$W" branch --set-upstream-to="origin/$br" "$br" >/dev/null 2>&1
start=$(date +%s)
out=$(WIKI_ROOT="$W" WIKI_PULL_TIMEOUT=2 PATH="$FAKEBIN:$PATH" bash "$H/session-status.sh" 2>&1)
elapsed=$(( $(date +%s) - start ))
assert "session-status returns well before the stalled pull would finish" "yes" "$([ "$elapsed" -le 8 ] && echo yes || echo no)"
assert_contains "session-status warns about the stalled pull" "exceeded" "$out"
sleep 1
assert "timed-out pull cannot later mutate the wiki" "no" "$([ -e "$FAKEBIN/pull-completed" ] && echo yes || echo no)"
git -C "$W" remote remove origin >/dev/null 2>&1
rm -rf "$FAKEBIN"

echo "--- auto-commit policy and lifecycle lock ---"
AUTO_TMP="$(mktemp -d)"
git -C "$AUTO_TMP" init -q
git -C "$AUTO_TMP" config user.name test
git -C "$AUTO_TMP" config user.email test@example.invalid
printf 'initial\n' > "$AUTO_TMP/page.md"
git -C "$AUTO_TMP" add page.md
git -C "$AUTO_TMP" commit -qm initial
printf '{"auto_commit": false, "auto_push": false}\n' > "$AUTO_TMP/wiki.config.json"
printf 'changed\n' >> "$AUTO_TMP/page.md"
before=$(git -C "$AUTO_TMP" rev-parse HEAD)
printf '{}\n' | WIKI_ROOT="$AUTO_TMP" bash "$H/auto-commit.sh" >/dev/null 2>&1; rc=$?
assert "disabled auto-commit is a clean no-op" "0" "$rc"
assert "disabled auto-commit creates no commit" "$before" "$(git -C "$AUTO_TMP" rev-parse HEAD)"
printf '{"auto_commit": true, "auto_push": false}\n' > "$AUTO_TMP/wiki.config.json"
mkdir "$AUTO_TMP/.git/wiki-auto-commit.lock"
printf '%s\n' "$$" > "$AUTO_TMP/.git/wiki-auto-commit.lock/pid"
printf '{}\n' | WIKI_ROOT="$AUTO_TMP" bash "$H/auto-commit.sh" >/dev/null 2>&1; rc=$?
assert "live lifecycle lock makes concurrent hook a no-op" "0" "$rc"
assert "lifecycle lock prevents concurrent commit" "$before" "$(git -C "$AUTO_TMP" rev-parse HEAD)"
rm "$AUTO_TMP/.git/wiki-auto-commit.lock/pid"
rmdir "$AUTO_TMP/.git/wiki-auto-commit.lock"
printf '{}\n' | WIKI_ROOT="$AUTO_TMP" bash "$H/auto-commit.sh" >/dev/null 2>&1; rc=$?
assert "enabled auto-commit succeeds" "0" "$rc"
assert "enabled auto-commit records changes" "yes" "$([ "$(git -C "$AUTO_TMP" rev-parse HEAD)" != "$before" ] && echo yes || echo no)"
printf 'stale failure\n' > "$AUTO_TMP/.auto-commit-failed"
printf '{}\n' | WIKI_ROOT="$AUTO_TMP" bash "$H/auto-commit.sh" >/dev/null 2>&1
assert "clean tree clears a resolved-by-hand failure breadcrumb" "no" \
  "$([ -e "$AUTO_TMP/.auto-commit-failed" ] && echo yes || echo no)"

# A dirty tree that stages to nothing: another committer took the same changes, or the
# difference was stat-only. `git commit` calls that a failure, and a Stop hook that passes
# the verdict on tells the author their session broke when nothing did.
printf 'racing\n' >> "$AUTO_TMP/page.md"
git -C "$AUTO_TMP" add -A
git -C "$AUTO_TMP" commit -qm "another committer got there first"
before=$(git -C "$AUTO_TMP" rev-parse HEAD)
touch "$AUTO_TMP/page.md"
printf '{}\n' | WIKI_ROOT="$AUTO_TMP" bash "$H/auto-commit.sh" >/dev/null 2>&1; rc=$?
assert "a tree that stages to nothing is a no-op, not a failure" "0" "$rc"
assert "staging to nothing writes no breadcrumb" "no" \
  "$([ -e "$AUTO_TMP/.auto-commit-failed" ] && echo yes || echo no)"
assert "staging to nothing creates no commit" "$before" "$(git -C "$AUTO_TMP" rev-parse HEAD)"

# A blocked commit still has to be loud, or the branch above would swallow the gate.
mkdir -p "$AUTO_TMP/.git/hooks"
cat > "$AUTO_TMP/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
echo "lint says no" >&2
exit 1
HOOK
chmod +x "$AUTO_TMP/.git/hooks/pre-commit"
printf 'a real change\n' >> "$AUTO_TMP/page.md"
printf '{}\n' | WIKI_ROOT="$AUTO_TMP" bash "$H/auto-commit.sh" >/dev/null 2>&1; rc=$?
assert "a blocked commit still fails loudly" "1" "$rc"
assert "a blocked commit leaves the breadcrumb" "yes" \
  "$([ -e "$AUTO_TMP/.auto-commit-failed" ] && echo yes || echo no)"
rm -rf "$AUTO_TMP"

echo "--- pre-commit stages what its lint writes, so a commit leaves a clean tree ---"
# The lint is stubbed to the one behaviour under test: it appends to the history file the
# way lint.sh does, and passes. An unstaged write there leaves the tree dirty the moment
# the commit ends, which is what turns one edit into a commit per turn forever.
PC_TMP="$(mktemp -d)"
git -C "$PC_TMP" init -q
git -C "$PC_TMP" config user.name test
git -C "$PC_TMP" config user.email test@example.invalid
mkdir -p "$PC_TMP/hooks"
cp "$H/pre-commit" "$PC_TMP/hooks/pre-commit"
cat > "$PC_TMP/hooks/lint.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$1/.compendium"
printf 'ran\n' >> "$1/.compendium/lint-history.tsv"
exit 0
STUB
chmod +x "$PC_TMP/hooks/pre-commit" "$PC_TMP/hooks/lint.sh"
printf 'page\n' > "$PC_TMP/page.md"
git -C "$PC_TMP" add -A
git -C "$PC_TMP" -c core.hooksPath=hooks commit -qm first >/dev/null 2>&1
assert "the commit carries the lint line its own run wrote" "yes" \
  "$(git -C "$PC_TMP" ls-tree -r --name-only HEAD | grep -q 'lint-history' && echo yes || echo no)"
assert "and the tree is clean afterwards" "" "$(git -C "$PC_TMP" status --porcelain)"
rm -rf "$PC_TMP"

echo "--- vendored engine: the manifest is current, and drift is visible ---"
assert "the committed manifest matches the tree" "0" \
  "$(python3 "$ROOT/bin/wiki-vendor" --check >/dev/null 2>&1; echo $?)"
VD="$(mktemp -d)/w"
mkdir -p "$VD"/{entities,concepts,notes,analyses,sources}
printf -- '---\ntype: notes\ntitle: t\n---\nbody\n' > "$VD/notes/a.md"
git -C "$VD" init -q 2>/dev/null || (mkdir -p "$VD" && git -C "$VD" init -q)
git -C "$VD" add -A
git -C "$VD" -c user.name=t -c user.email=t@t commit -qm c1
python3 "$ROOT/bin/wiki-vendor" --install "$VD" >/dev/null
assert "a fresh install reports no drift" "VENDOR=0/0/ok" \
  "$(python3 "$VD/hooks/vendor-check.py" "$VD" | tail -1)"
assert "wiki-links is vendored too" "yes" \
  "$([ -f "$VD/bin/wiki-links" ] && echo yes || echo no)"
# the partial-copy case: a checker the manifest promises is simply absent
rm "$VD/hooks/graph-check.py"
vc=$(python3 "$VD/hooks/vendor-check.py" "$VD")
assert_contains "a missing vendored file is named" "VENDOR-MISSING hooks/graph-check.py" "$vc"
assert "and counted" "VENDOR=1/0/drift" "$(printf '%s\n' "$vc" | tail -1)"
bash "$VD/hooks/lint.sh" "$VD" >/dev/null 2>&1
assert "lint refuses to run rather than printing a '?' counter" "2" "$?"
python3 "$ROOT/bin/wiki-vendor" --install "$VD" >/dev/null
printf '\n# local edit\n' >> "$VD/hooks/wikilib.py"
assert "a locally edited vendored file is flagged" "VENDOR=0/1/drift" \
  "$(python3 "$VD/hooks/vendor-check.py" "$VD" | tail -1)"
assert "a wiki with no manifest is not an error" "VENDOR=-" \
  "$(rm "$VD/hooks/VENDOR.manifest"; python3 "$VD/hooks/vendor-check.py" "$VD" | tail -1)"
rm -rf "$(dirname "$VD")"

echo "--- neighbor-scope: cosmetic edits stay silent, and each nudge says why ---"
NS="$(mktemp -d)/wiki"
mkdir -p "$NS"/{entities,analyses,sources}
printf -- '---\ntype: entity\ntitle: Widget Platform\ndescription: d\n---\nIt processes 4.19B rates.\n' \
  > "$NS/entities/widget-platform.md"
printf -- '---\ntype: analysis\ntitle: Restater\ntimestamp: 2026-01-01\nsynthesized_from: ../sources/s.md\n---\nThe [platform](../entities/widget-platform.md) reports 4.19B rates.\n' \
  > "$NS/analyses/restater.md"
printf -- '---\ntype: analysis\ntitle: Synth\ntimestamp: 2026-01-01\nsynthesized_from: ../entities/widget-platform.md\n---\nBuilt from the [platform](../entities/widget-platform.md).\n' \
  > "$NS/analyses/synth.md"
printf -- '---\ntype: analysis\ntitle: Pointer\ntimestamp: 2026-01-01\nsynthesized_from: ../sources/s.md\n---\nSee the [platform](../entities/widget-platform.md).\n' \
  > "$NS/analyses/pointer.md"
printf 'src\n' > "$NS/sources/s.md"
git -C "$NS" init -q
git -C "$NS" add -A
git -C "$NS" -c user.name=t -c user.email=t@t commit -qm c1

# frontmatter-only change is not a claim change
python3 - "$NS" <<'PYEOF'
import sys
p = sys.argv[1] + "/entities/widget-platform.md"
s = open(p).read().replace("type: entity", "type: entity\ntags: [x]", 1)
open(p, "w").write(s)
PYEOF
git -C "$NS" add -A
assert "a frontmatter-only edit does not nudge" "NEIGHBORS=0" \
  "$(python3 "$H/neighbor-scope.py" "$NS" | tail -1)"
git -C "$NS" checkout -- . ; git -C "$NS" reset -q

# whitespace-only change is not a claim change
printf '\n\n' >> "$NS/entities/widget-platform.md"
git -C "$NS" add -A
assert "a whitespace-only edit does not nudge" "NEIGHBORS=0" \
  "$(python3 "$H/neighbor-scope.py" "$NS" | tail -1)"
git -C "$NS" checkout -- . ; git -C "$NS" reset -q

# a changed figure is a claim change, and the reasons are graded
python3 - "$NS" <<'PYEOF'
import sys
p = sys.argv[1] + "/entities/widget-platform.md"
open(p, "w").write(open(p).read().replace("4.19B", "9.99B"))
PYEOF
git -C "$NS" add -A
out=$(python3 "$H/neighbor-scope.py" "$NS")
assert "a changed figure nudges all three linkers" "NEIGHBORS=3" "$(printf '%s\n' "$out" | tail -1)"
assert_contains "the page repeating the figure is RESTATES" "analyses/restater.md links entities/widget-platform.md (RESTATES 4.19B)" "$out"
assert_contains "the page built from it is SYNTHESIS" "analyses/synth.md links entities/widget-platform.md (SYNTHESIS" "$out"
assert_contains "the see-also page is only MENTIONS" "analyses/pointer.md links entities/widget-platform.md (MENTIONS)" "$out"
assert "RESTATES is ranked first so the cap keeps it" "analyses/restater.md" \
  "$(printf '%s\n' "$out" | head -1 | awk '{print $2}')"
# a bare year is on nearly every page; admitting it would mark the whole wiki as restating
printf -- '---\ntype: analysis\ntitle: Yearly\ntimestamp: 2026-01-01\nsynthesized_from: ../sources/s.md\n---\nIn 2026 the [platform](../entities/widget-platform.md) shipped.\n' \
  > "$NS/analyses/yearly.md"
python3 - "$NS" <<'PYEOF'
import sys
p = sys.argv[1] + "/entities/widget-platform.md"
open(p, "w").write(open(p).read().replace("It processes", "In 2026 it processes"))
PYEOF
git -C "$NS" add -A
yr=$(python3 "$H/neighbor-scope.py" "$NS")
assert "a bare year is not treated as a restated value" "0" \
  "$(printf '%s\n' "$yr" | grep -c 'RESTATES 2026')"
rm -rf "$(dirname "$NS")"

echo "--- wiki-links: the backlink direction markdown does not give you ---"
WL="$(mktemp -d)/wiki"
mkdir -p "$WL"/{entities,concepts,analyses}
printf -- '---\ntype: entity\ntitle: Widget Platform\ndescription: d\n---\nSee [Gadget](../concepts/gadget.md).\n' > "$WL/entities/widget-platform.md"
printf -- '---\ntype: concept\ntitle: Gadget\n---\nA gadget.\n' > "$WL/concepts/gadget.md"
printf -- '---\ntype: analysis\ntitle: Report\n---\nOn [Widget Platform](../entities/widget-platform.md).\n' > "$WL/analyses/report.md"
printf -- '---\ntype: analysis\ntitle: Second\n---\nCiting [Report](report.md).\n' > "$WL/analyses/second.md"
git -C "$WL" init -q
git -C "$WL" add -A
git -C "$WL" -c user.name=t -c user.email=t@t commit -qm c1
Q2="python3 $ROOT/bin/wiki-links"
one=$($Q2 --root "$WL" widget-platform)
assert_contains "an inbound link is reported" "<- analyses/report.md" "$one"
assert_contains "an outbound link is reported" "-> concepts/gadget.md" "$one"
assert "depth 1 finds exactly the two neighbours" "LINKS=2" "$(printf '%s\n' "$one" | tail -1)"
two=$($Q2 --root "$WL" widget-platform --depth 2)
assert_contains "depth 2 reaches the second-hop citer" "analyses/second.md" "$two"
assert "an --in scan drops the outbound side" "LINKS=1" \
  "$($Q2 --root "$WL" widget-platform --in | tail -1)"
assert "a --type filter narrows the result" "LINKS=1" \
  "$($Q2 --root "$WL" widget-platform --type concept | tail -1)"
assert "a bare name resolves to the page" "LINKS=2" \
  "$($Q2 --root "$WL" entities/widget-platform.md | tail -1)"
assert "an unknown page is an error, not an empty answer" "2" \
  "$($Q2 --root "$WL" nope >/dev/null 2>&1; echo $?)"
assert_contains "--json carries the direction" '"direction": "in"' "$($Q2 --root "$WL" widget-platform --json)"
rm -rf "$(dirname "$WL")"

echo "--- the raw layer is not link-gated ---"
# a captured web page carries origin-relative asset paths that do not exist here, and the
# staging contract forbids editing it, so gating those would be an unfixable hard failure.
printf -- '# Captured\n\n![slide](/images/talks/x/slide-01.webp?123)\n[more](/assets/deck.pdf)\n' \
  > "$W/sources/captured.md"
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "raw-layer links do not break the gate" "broken=0" "$core"
assert "no BROKEN LINK is reported against sources/" "0" \
  "$(printf '%s\n' "$core" | grep -c 'BROKEN LINK sources/')"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "the gate still passes with a captured page present" "0" "$?"
# a real page with the same bad link must still fail
printf -- '---\ntype: notes\ntitle: n\n---\n[slide](/images/talks/x/slide-01.webp)\n' > "$W/notes/badlink.md"
git -C "$W" add -A >/dev/null 2>&1
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "a wiki page with the same broken link still fails" "1" "$?"
git -C "$W" rm -qf notes/badlink.md sources/captured.md >/dev/null 2>&1

echo "--- links that leave the wiki are counted, never gated ---"
# The target belongs to another repo, so whether it resolves depends on that repo's
# checked-out branch, or on whether this machine cloned it at all. A gate that reads it
# gives the same commit different verdicts on different machines.
SIB="$(dirname "$W")/sibling"
printf -- '---\ntype: notes\ntitle: ext\n---\nSee [the sibling doc](../../sibling/doc.md).\n' \
  > "$W/notes/extlink.md"
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "an absent cross-repo target is not a broken link" "broken=0" "$core"
assert_contains "it is counted as a link leaving the wiki" "external=1" "$core"
assert_contains "and as one this filesystem cannot answer for" "extmissing=1" "$core"
assert_contains "the advisory names the target" \
  "EXTERNAL notes/extlink.md -> ../../sibling/doc.md" "$core"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "the gate passes with the sibling absent" "0" "$?"
# the raw layer stays out of the count entirely, as it does for broken links
printf -- '# Captured\n\n[up and out](../../elsewhere/x.md)\n' > "$W/sources/escaping.md"
git -C "$W" add -A >/dev/null 2>&1
assert_contains "a raw-layer page adds no external count" "external=1" \
  "$(python3 "$H/lint-core.py" "$W")"
git -C "$W" rm -qf sources/escaping.md >/dev/null 2>&1

mkdir -p "$SIB"; printf 'doc\n' > "$SIB/doc.md"
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "the count is the same once the sibling exists" "external=1" "$core"
assert_contains "and nothing is reported unverifiable" "extmissing=0" "$core"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "the gate passes with the sibling present" "0" "$?"
rm -rf "$SIB"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "the verdict does not move when the sibling disappears" "0" "$?"

# a wiki whose siblings are always present can opt the gate back in
printf '{"advisory_budgets":{"external_missing":0}}\n' > "$W/wiki.config.json"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "advisory_budgets.external_missing re-arms the gate" "1" "$?"
rm "$W/wiki.config.json"

# and the gate on the wiki's own links is untouched
printf -- '---\ntype: notes\ntitle: n\n---\n[gone](../concepts/missing.md)\n' > "$W/notes/badlink.md"
git -C "$W" add -A >/dev/null 2>&1
assert_contains "a link inside the wiki still breaks the gate" "broken=1" \
  "$(python3 "$H/lint-core.py" "$W")"
git -C "$W" rm -qf notes/badlink.md notes/extlink.md >/dev/null 2>&1

echo "--- a target git is set to ignore is not a target the wiki has ---"
# The mirror image of the case above: present in the author's working tree, absent from every
# clone, and invisible to search and the graph, both of which are built from git ls-files.
mkdir -p "$W/teamdocs"
printf -- '---\ntype: notes\ntitle: local only\n---\nlocal\n' > "$W/teamdocs/local.md"
printf -- '---\ntype: notes\ntitle: cites\n---\nSee [the local doc](../teamdocs/local.md).\n' \
  > "$W/notes/cites-ignored.md"
git -C "$W" add -A notes >/dev/null 2>&1
# a target that is merely NEW is not the defect: the next commit picks it up
assert_contains "a target that is only uncommitted is not reported" "ignored=0" \
  "$(python3 "$H/lint-core.py" "$W")"
printf 'teamdocs/\n' >> "$W/.gitignore"
git -C "$W" add -A >/dev/null 2>&1
core=$(python3 "$H/lint-core.py" "$W")
assert_contains "an ignored target is not counted as broken" "broken=0" "$core"
assert_contains "it is counted as an ignored target" "ignored=1" "$core"
assert_contains "the advisory names the link" \
  "IGNORED-TARGET notes/cites-ignored.md -> ../teamdocs/local.md" "$core"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "ignored targets stay advisory by default" "0" "$?"
printf '{"advisory_budgets":{"ignored_targets":0}}\n' > "$W/wiki.config.json"
bash "$H/lint.sh" "$W" >/dev/null 2>&1
assert "advisory_budgets.ignored_targets gates it" "1" "$?"
rm "$W/wiki.config.json"
# un-ignoring the target clears it, which is the whole remedy
git -C "$W" rm -qf --cached .gitignore >/dev/null 2>&1; rm -f "$W/.gitignore"
git -C "$W" add -A >/dev/null 2>&1
assert_contains "un-ignoring the target clears the finding" "ignored=0" \
  "$(python3 "$H/lint-core.py" "$W")"
git -C "$W" rm -qrf notes/cites-ignored.md teamdocs >/dev/null 2>&1

echo "--- link-mentions: fixes what missed-links reports, and leaves quotes alone ---"
LM="$(mktemp -d)/wiki"
mkdir -p "$LM"/{entities,analyses,sources}
printf -- '---\ntype: entity\ntitle: Widget Platform\ndescription: a platform\n---\nThe platform.\n' \
  > "$LM/entities/widget-platform.md"
cat > "$LM/analyses/mentions.md" <<'EOF'
---
type: analysis
title: Mentions
timestamp: 2026-01-01
synthesized_from: ../sources/s.md
---

## Widget Platform in a heading must not be linked

> A quote naming Widget Platform verbatim must survive untouched.

Prose naming Widget Platform once, then Widget Platform again.

`Widget Platform` in code is not a mention, and neither is:

```
Widget Platform in a fence
```

An [existing link](../entities/widget-platform.md) is a different case.
EOF
printf 'src\n' > "$LM/sources/s.md"
git -C "$LM" init -q
git -C "$LM" add -A
git -C "$LM" -c user.name=t -c user.email=t@t commit -qm c1

# the existing link means this page is NOT a missed mention at all
assert "a page that already links the target reports nothing" "MISSED_LINKS=0" \
  "$(python3 "$H/missed-links.py" "$LM" | tail -1)"

# drop the existing link so the page becomes a genuine miss
sed -i.bak 's|An \[existing link\](../entities/widget-platform.md) is a different case.|A trailing sentence.|' "$LM/analyses/mentions.md"
rm -f "$LM/analyses/mentions.md.bak"
assert "now it is reported once" "MISSED_LINKS=1" "$(python3 "$H/missed-links.py" "$LM" | tail -1)"

dry=$(python3 "$H/link-mentions.py" "$LM")
assert_contains "dry-run plans the insertion" "LINK analyses/mentions.md" "$dry"
assert "dry-run writes nothing" "MISSED_LINKS=1" "$(python3 "$H/missed-links.py" "$LM" | tail -1)"

python3 "$H/link-mentions.py" "$LM" --apply >/dev/null
assert "apply clears the advisory" "MISSED_LINKS=0" "$(python3 "$H/missed-links.py" "$LM" | tail -1)"
body=$(cat "$LM/analyses/mentions.md")
assert "the blockquote is untouched" "1" \
  "$(printf '%s\n' "$body" | grep -c '^> A quote naming Widget Platform verbatim must survive untouched.$')"
assert "the heading is untouched" "1" \
  "$(printf '%s\n' "$body" | grep -c '^## Widget Platform in a heading must not be linked$')"
assert "the inline code span is untouched" "1" \
  "$(printf '%s\n' "$body" | grep -c '^`Widget Platform` in code')"
assert "the fenced line is untouched" "1" \
  "$(printf '%s\n' "$body" | grep -c '^Widget Platform in a fence$')"
assert "exactly one link was inserted" "1" \
  "$(printf '%s\n' "$body" | grep -c 'Widget Platform\](../entities/widget-platform.md)')"
assert "the second prose mention stays plain" "1" \
  "$(printf '%s\n' "$body" | grep -c 'then Widget Platform again')"
assert "apply is idempotent" "LINKED=0" "$(python3 "$H/link-mentions.py" "$LM" --apply | tail -1 | grep -o 'LINKED=0')"
rm -rf "$(dirname "$LM")"

echo "--- multi-source provenance is read whole, not just its first entry ---"
MS="$(mktemp -d)/wiki"
mkdir -p "$MS"/{analyses,sources}
printf 'one\n' > "$MS/sources/a.md"
printf 'two\n' > "$MS/sources/b.md"
printf -- '---\ntype: analysis\ntitle: Multi\ntimestamp: 2026-01-01\nsynthesized_from:\n  - ../sources/a.md\n  - ../sources/b.md\ntags: [x]\n---\nbody\n' > "$MS/analyses/multi.md"
git -C "$MS" init -q
git -C "$MS" add -A
git -C "$MS" -c user.name=t -c user.email=t@t commit -qm c1
# a block list must not be misreported as free-text
first=$(python3 "$H/stale-source.py" --standing "$MS" 2>&1)
assert "a block list is not called free-text" "0" "$(printf '%s\n' "$first" | grep -c 'is free-text')"
# change only the SECOND source: the first-entry-only bug would miss this entirely
printf 'two CHANGED substantively\n' > "$MS/sources/b.md"
git -C "$MS" add -A
git -C "$MS" -c user.name=t -c user.email=t@t commit -qm c2
second=$(python3 "$H/stale-source.py" --range HEAD~1..HEAD "$MS" 2>&1)
assert_contains "a change to the SECOND source is caught" "RE-CHECK analyses/multi.md" "$second"
assert_contains "the triggering source is named" "sources/b.md" "$second"
rm -rf "$(dirname "$MS")"

echo "--- frontmatter_value does not cross a newline ---"
fv=$(python3 - "$H" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import wikilib
page = "---\ntype: analysis\nsynthesized_from:\n  - ../sources/a.md\ntimestamp: 2026-01-01\n---\n"
print("scalar:", wikilib.frontmatter_value(page, "timestamp"))
print("blocklist-scalar:", wikilib.frontmatter_value(page, "synthesized_from"))
print("blocklist-values:", ",".join(wikilib.frontmatter_values(page, "synthesized_from")))
PYEOF
)
assert_contains "a scalar key still reads" "scalar: 2026-01-01" "$fv"
assert_contains "a block-list key yields no scalar" "blocklist-scalar: None" "$fv"
assert_contains "a block-list key yields its items" "blocklist-values: ../sources/a.md" "$fv"

echo "--- inbox: one fat item is distinct from many small ones ---"
IB="$(mktemp -d)"
git -C "$IB" init -q
printf '{"inbox_soft_max_items": 15, "inbox_soft_max_words": 800, "inbox_soft_max_item_words": 40}\n' > "$IB/wiki.config.json"
{ printf -- '---\ntype: state\ntitle: s\n---\n## Inbox\n'
  printf -- '- short entry one\n- short entry two\n'
  printf -- '## Next\n'; } > "$IB/STATE.md"
ok=$(python3 "$H/inbox-check.py" "$IB")
assert "small entries stay OK" "INBOX=OK" "$(printf '%s\n' "$ok" | tail -1)"
{ printf -- '---\ntype: state\ntitle: s\n---\n## Inbox\n'
  printf -- '- short entry one\n'
  printf -- '- fat entry'; for i in $(seq 60); do printf -- ' word'; done; printf -- '\n'
  printf -- '## Next\n'; } > "$IB/STATE.md"
fatout=$(python3 "$H/inbox-check.py" "$IB")
assert "one fat item trips the advisory" "INBOX=OVER" "$(printf '%s\n' "$fatout" | tail -1)"
assert_contains "the fat item is named" "INBOX-FAT" "$fatout"
# The totals line names which cap was breached, so printing it when only a per-item cap
# fired puts in-range numbers next to the word OVER and reads as a false positive.
assert "under-cap totals do not report as over" "0" "$(printf '%s\n' "$fatout" | grep -c 'INBOX-OVER')"
printf '{"inbox_soft_max_items": 15, "inbox_soft_max_words": 800}\n' > "$IB/wiki.config.json"
assert "item cap off means no INBOX-FAT" "0" "$(python3 "$H/inbox-check.py" "$IB" | grep -c 'INBOX-FAT')"

echo "--- inbox: trailing prose belongs to the section, not to the last item ---"
# A blank line ends the item's block. Without that boundary the last bullet absorbs every
# trailing paragraph (a triage note, a format reminder) and is reported as fat.
printf '{"inbox_soft_max_items": 15, "inbox_soft_max_words": 800, "inbox_soft_max_item_words": 40}\n' > "$IB/wiki.config.json"
{ printf -- '---\ntype: state\ntitle: s\n---\n## Inbox\n'
  printf -- '- short entry one\n'
  printf -- '- short entry two\n\n'
  printf -- '_Triaged today:'; for i in $(seq 80); do printf -- ' word'; done; printf -- '._\n'
  printf -- '## Next\n'; } > "$IB/STATE.md"
trail=$(python3 "$H/inbox-check.py" "$IB")
assert "trailing prose does not make the last item fat" "0" "$(printf '%s\n' "$trail" | grep -c 'INBOX-FAT')"
assert "a section of small items stays OK" "INBOX=OK" "$(printf '%s\n' "$trail" | tail -1)"
{ printf -- '---\ntype: state\ntitle: s\n---\n## Inbox\n'
  printf -- '- wrapped entry\n'
  printf -- '  continues here'; for i in $(seq 60); do printf -- ' word'; done; printf -- '\n'
  printf -- '## Next\n'; } > "$IB/STATE.md"
wrapped=$(python3 "$H/inbox-check.py" "$IB")
assert_contains "an indented continuation counts toward its item" "INBOX-FAT" "$wrapped"

echo "--- inbox: an entry appended to the end of the FILE is not in the Inbox ---"
# "append one line to STATE.md" resolves to "append at the end" for an agent that never
# located the heading, so entries land in whatever section is last. The size caps cannot
# see it: the section they measure stays small and reads clean while the handoff grows.
{ printf -- '---\ntype: state\ntitle: s\n---\n## Inbox\n'
  printf -- '- [2026-01-02 · session] a properly filed pointer\n'
  printf -- '## Anchors\n'
  printf -- '- a stable pointer that is not an inbox entry\n'
  printf -- '- [2026-01-03 · session] a find appended to the end of the file\n'; } > "$IB/STATE.md"
mis=$(python3 "$H/inbox-check.py" "$IB")
assert "a misfiled entry trips the advisory" "INBOX=OVER" "$(printf '%s\n' "$mis" | tail -1)"
assert_contains "it names the section it landed in" "under: Anchors" "$mis"
assert_contains "it says where the entry should have gone" "not at the end of the file" "$mis"
assert_contains "it quotes the misfiled entry" "a find appended to the end of the file" "$mis"
assert "an undated bullet elsewhere is not an inbox entry" "0" \
  "$(printf '%s\n' "$mis" | grep -c 'a stable pointer')"
assert "the entry inside the Inbox is not counted" "0" \
  "$(printf '%s\n' "$mis" | grep -c 'a properly filed pointer')"
# no size cap is breached, so the caps alone would call this file clean
assert "the size caps see nothing wrong" "0" "$(printf '%s\n' "$mis" | grep -c 'INBOX-OVER')"
{ printf -- '---\ntype: state\ntitle: s\n---\n## Inbox\n'
  printf -- '- [2026-01-02 · session] a properly filed pointer\n'
  printf -- '## Anchors\n- a stable pointer\n'; } > "$IB/STATE.md"
assert "everything in its place stays OK" "INBOX=OK" \
  "$(python3 "$H/inbox-check.py" "$IB" | tail -1)"
rm -rf "$IB"

echo "--- one corpus definition for the graph and for search ---"
CORP="$(mktemp -d)"
git -C "$CORP" init -q
git -C "$CORP" config user.name test
git -C "$CORP" config user.email test@example.invalid
mkdir -p "$CORP/concepts" "$CORP/skills/tooling" "$CORP/projects/repo/memory"
printf -- '---\ntype: concept\ntitle: Widget Calibration\n---\nwidget calibration procedure\n' \
  > "$CORP/concepts/widget.md"
printf -- '# SKILL\nwidget calibration widget calibration widget calibration\n' \
  > "$CORP/skills/tooling/SKILL.md"
printf -- '# memory\nwidget calibration widget calibration widget calibration\n' \
  > "$CORP/projects/repo/memory/widget.md"
git -C "$CORP" add -A >/dev/null 2>&1
git -C "$CORP" commit -qm seed
top=$($Q --root "$CORP" --limit 1 widget calibration | awk '{print $2}')
assert "search ranks the wiki page over tooling and memory" "concepts/widget.md" "$top"
noise=$($Q --root "$CORP" --limit 10 widget calibration | grep -c 'skills/\|/memory/')
assert "tooling and memory are absent from search results" "0" "$noise"
cgraph=$(python3 "$H/graph-check.py" "$CORP" 2>&1)
assert "tooling is not an island in the wiki graph" "0" \
  "$(printf '%s\n' "$cgraph" | grep -c 'ISLAND skills/')"
printf '{"corpus_exclude": []}\n' > "$CORP/wiki.config.json"
optin=$($Q --root "$CORP" --limit 10 widget calibration | grep -c 'skills/')
assert "an empty corpus_exclude opts tooling back in" "1" "$optin"
rm -rf "$CORP"

echo "--- lint.sh: appends a lint-history.tsv line every run ---"
RN="$(mktemp -d)/wiki"
mkdir -p "$RN"/{entities,concepts,analyses}
cat > "$RN/KNOWLEDGE.md" <<'EOF'
---
type: index
title: Index
---
[e](entities/index.md)
EOF
cat > "$RN/entities/index.md" <<'EOF'
---
type: index
title: Entities
---
EOF
cat > "$RN/STATE.md" <<'EOF'
---
type: state
title: State
---
## Focus
- fixture
EOF
git -C "$RN" init -q
git -C "$RN" -c user.name=t -c user.email=t@t add -A
git -C "$RN" -c user.name=t -c user.email=t@t commit -qm base >/dev/null
bash "$H/lint.sh" "$RN" >/dev/null 2>&1
assert "lint-history.tsv is created on first run" "1" \
  "$([ -f "$RN/.compendium/lint-history.tsv" ] && echo 1 || echo 0)"
assert "lint-history.tsv has one line after one run" "1" \
  "$(wc -l < "$RN/.compendium/lint-history.tsv" | tr -d ' ')"
mkdir -p "$RN/notes"
cat > "$RN/notes/orphan.md" <<'EOF'
---
type: notes
title: Orphan
---
lonely
EOF
git -C "$RN" add -A
bash "$H/lint.sh" "$RN" >/dev/null 2>&1
assert "lint-history.tsv gets a second line on a second run" "2" \
  "$(wc -l < "$RN/.compendium/lint-history.tsv" | tr -d ' ')"

echo "--- lint.sh: lint-history.tsv keeps only the newest 200 lines ---"
: > "$RN/.compendium/lint-history.tsv"
for i in $(seq 205); do printf '2020-01-01T00:00:00Z\tfiller %d\n' "$i" >> "$RN/.compendium/lint-history.tsv"; done
bash "$H/lint.sh" "$RN" >/dev/null 2>&1
assert "history is capped at 200 lines" "200" \
  "$(wc -l < "$RN/.compendium/lint-history.tsv" | tr -d ' ')"
assert "the oldest filler lines are dropped, not the newest" "0" \
  "$(grep -c 'filler 1$' "$RN/.compendium/lint-history.tsv")"

echo "--- session-status.sh: reflect maintenance nudge (disabled by default) ---"
rm -f "$RN/wiki.config.json"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert "no reflect nudge when reflect_nudge_days is unset" "0" "$(printf '%s' "$out" | grep -c 'maintenance: reflect')"

echo "--- session-status.sh: reflect maintenance nudge (never run) ---"
printf '{"reflect_nudge_days": 21}\n' > "$RN/wiki.config.json"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert_contains "nudge fires when reflect has never run" "maintenance: reflect has never run (cap 21d)" "$out"

echo "--- session-status.sh: reflect maintenance nudge (fresh reflection silences it) ---"
touch "$RN/analyses/reflection-$(date -u +%Y-%m-%d).md"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert "no nudge with a fresh reflection file" "0" "$(printf '%s' "$out" | grep -c 'maintenance: reflect')"

echo "--- session-status.sh: reflect maintenance nudge (stale reflection fires) ---"
rm -f "$RN/analyses/reflection-"*.md
touch "$RN/analyses/reflection-2020-01-01.md"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert_contains "nudge fires when the newest reflection is older than the cap" \
  "cap 21d" "$out"
assert_contains "nudge names how long ago reflect last ran" "maintenance: reflect last ran" "$out"
rm -f "$RN/analyses/reflection-"*.md

echo "--- session-status.sh: lint-history delta line ---"
: > "$RN/.compendium/lint-history.tsv"
printf '2026-01-01T00:00:00Z\tbroken-links:0  orphans:0  islands:1\n' >> "$RN/.compendium/lint-history.tsv"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert "no delta line with only one history entry" "0" \
  "$(printf '%s' "$out" | grep -c 'advisories since last lint')"
printf '2026-01-02T00:00:00Z\tbroken-links:0  orphans:1  islands:2\n' >> "$RN/.compendium/lint-history.tsv"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert_contains "delta line lists changed counters" \
  "advisories since last lint: orphans 0->1, islands 1->2" "$out"
assert "delta line omits unchanged counters" "0" \
  "$(printf '%s' "$out" | grep -o 'advisories since last lint:[^|]*' | grep -c 'broken-links')"

echo "--- session-status.sh: a counter flipping to ? is reported as a checker failure ---"
printf '2026-01-03T00:00:00Z\tbroken-links:0  orphans:?  islands:2\n' >> "$RN/.compendium/lint-history.tsv"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert_contains "numeric-to-? transition is reported, not dropped" \
  "orphans 1->? (checker failed)" "$out"

echo "--- session-status.sh: a non-integer reflect_nudge_days is ignored loudly ---"
printf '{"reflect_nudge_days": "5.5"}\n' > "$RN/wiki.config.json"
out=$(WIKI_ROOT="$RN" bash "$H/session-status.sh" 2>&1)
assert_contains "invalid nudge value is named in a warning" \
  "reflect_nudge_days is not a whole number" "$out"
assert "invalid nudge value emits no stderr integer error" "0" \
  "$(printf '%s' "$out" | grep -c 'integer expression expected')"
rm -rf "$(dirname "$RN")"

# ==== STATE port: initiative-check.py, board.py, journal-append.sh, pre-commit board regen ====
IW="$(mktemp -d)/wiki"
mkdir -p "$IW"/{initiatives,open-asks,journal,hooks}
cp "$H"/* "$IW/hooks/" 2>/dev/null
chmod +x "$IW"/hooks/*.sh "$IW"/hooks/*.py "$IW/hooks/pre-commit" 2>/dev/null
cat > "$IW/wiki.config.json" <<'EOF'
{
  "current_cycle": 17,
  "cycle_ends": "2026-09-25",
  "initiative_schema": {
    "assignment_kind": ["pitch", "assigned", "self"],
    "assignment_status": ["planning", "active", "review", "parked", "done"],
    "waiting_on": ["none", "andrew", "data"],
    "summary_max_words": 5, "next_max_words": 5, "ask_max_words": 5,
    "queue_max": 2, "state_word_budget": 40
  },
  "orphan_exempt_dirs": ["journal/"],
  "stale_exempt_dirs": ["journal/"]
}
EOF
cat > "$IW/initiatives/index.md" <<'EOF'
---
type: index
title: Initiatives
timestamp: 2026-08-26
---
- [Pitch A](pitch-a.md)
EOF
cat > "$IW/initiatives/pitch-a.md" <<'EOF'
---
type: initiative
title: Pitch A
timestamp: 2026-08-26
assignment_kind: pitch
assignment_status: active
cycle: 17
next: ship it
waiting_on: none
---
body [i](index.md)
EOF
cat > "$IW/initiatives/self-b.md" <<'EOF'
---
type: initiative
title: Self B
timestamp: 2026-08-20
assignment_kind: self
assignment_status: active
priority: 4
priority_set: 2026-01-01
next: do it
waiting_on: andrew
ask: merge or close
---
body [i](index.md)
EOF
cat > "$IW/initiatives/shipped.md" <<'EOF'
---
type: initiative
title: Shipped
timestamp: 2026-08-19
assignment_kind: assigned
assignment_status: done
next: n/a
---
body [i](index.md)
EOF
cat > "$IW/initiatives/off-board.md" <<'EOF'
---
type: initiative
title: Off Board
timestamp: 2026-08-01
board: false
---
plan/synthesis doc, exempt from schema [i](index.md)
EOF
cat > "$IW/open-asks/andrew.md" <<'EOF'
---
type: index
title: Open asks
timestamp: 2026-08-26
---
- one file-level ask
EOF
cat > "$IW/STATE.md" <<'EOF'
---
type: state
title: STATE
---
<!-- board:begin (generated by hooks/board.py from initiative frontmatter; do not edit) -->
placeholder
<!-- board:end -->

## Inbox (retired)
Migrated.
EOF
git -C "$IW" init -q 2>/dev/null
git -C "$IW" config core.hooksPath hooks
git -C "$IW" add -A && git -C "$IW" commit -qm init >/dev/null

echo "--- initiative-check.py: a clean wiki passes ---"
out=$(python3 "$H/initiative-check.py" "$IW")
assert "no INIT-FAIL on a schema-compliant wiki" "0" "$(printf '%s' "$out" | grep -c 'INIT-FAIL ')"
assert_contains "still prints the machine count line" "INIT-FAIL=0" "$out"

echo "--- initiative-check.py: off-board page (board: false) is exempt from every rule ---"
assert "off-board.md's missing assignment_kind is not flagged" "" \
  "$(printf '%s' "$out" | grep 'off-board.md')"

echo "--- initiative-check.py: bad kind/status/missing priority_set/missing cycle ---"
cat > "$IW/initiatives/bad.md" <<'EOF'
---
type: initiative
title: Bad
timestamp: 2026-08-26
assignment_kind: nonsense
priority: 3
---
body [i](index.md)
EOF
git -C "$IW" add -A >/dev/null 2>&1
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "flags an out-of-enum assignment_kind" "assignment_kind: missing or not in" "$out"
assert_contains "flags missing assignment_status" "assignment_status: missing or not in" "$out"
assert_contains "flags priority set with no priority_set" "priority_set: required" "$out"
rm -f "$IW/initiatives/bad.md"
git -C "$IW" add -A >/dev/null 2>&1

echo "--- initiative-check.py: pitch with no cycle fails, cycle satisfies it ---"
cat > "$IW/initiatives/pitch-no-cycle.md" <<'EOF'
---
type: initiative
title: Pitch No Cycle
timestamp: 2026-08-26
assignment_kind: pitch
assignment_status: active
next: x
waiting_on: none
---
body [i](index.md)
EOF
git -C "$IW" add -A >/dev/null 2>&1
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "a pitch with no cycle: fails" "cycle: required" "$out"
rm -f "$IW/initiatives/pitch-no-cycle.md"
git -C "$IW" add -A >/dev/null 2>&1

echo "--- initiative-check.py: waiting_on set with no ask fails ---"
cat > "$IW/initiatives/no-ask.md" <<'EOF'
---
type: initiative
title: No Ask
timestamp: 2026-08-26
assignment_kind: self
assignment_status: active
next: x
waiting_on: data
---
body [i](index.md)
EOF
git -C "$IW" add -A >/dev/null 2>&1
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "waiting_on without ask fails" "ask: required" "$out"
rm -f "$IW/initiatives/no-ask.md"
git -C "$IW" add -A >/dev/null 2>&1

echo "--- initiative-check.py: word caps (configured at 5 words in this fixture) ---"
cat > "$IW/initiatives/long-next.md" <<'EOF'
---
type: initiative
title: Long Next
timestamp: 2026-08-26
assignment_kind: self
assignment_status: active
next: this next action has way more than five words in it
waiting_on: none
---
body [i](index.md)
EOF
git -C "$IW" add -A >/dev/null 2>&1
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "an over-cap next: is flagged" "next: " "$out"
assert_contains "the flag names the word count" "w > 5w cap" "$out"
rm -f "$IW/initiatives/long-next.md"
git -C "$IW" add -A >/dev/null 2>&1

echo "--- initiative-check.py: waiting-on-Andrew queue cap (configured at 2) ---"
cp "$IW/initiatives/self-b.md" "$IW/initiatives/self-c.md"
sed -i.bak 's/Self B/Self C/' "$IW/initiatives/self-c.md" && rm -f "$IW/initiatives/self-c.md.bak"
git -C "$IW" add -A >/dev/null 2>&1
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "queue over cap is flagged" "queue: 3 items > 2 cap" "$out"
rm -f "$IW/initiatives/self-c.md"
git -C "$IW" add -A >/dev/null 2>&1

echo "--- initiative-check.py: a bullet under the STATE.md Inbox tombstone is hard-rejected ---"
printf -- '- 2026-08-26 · an agent wrote a bullet anyway\n' >> "$IW/STATE.md"
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "an Inbox bullet fails" "Inbox: bullet found under the tombstone" "$out"
git -C "$IW" checkout -q -- STATE.md

echo "--- initiative-check.py: STATE.md hand-written word budget (configured at 40) ---"
python3 -c "
import re
t = open('$IW/STATE.md').read()
pad = ' '.join(['word'] * 60)
t = t.replace('## Inbox (retired)', pad + '\n\n## Inbox (retired)')
open('$IW/STATE.md', 'w').write(t)
"
out=$(python3 "$H/initiative-check.py" "$IW")
assert_contains "an over-budget STATE.md is flagged" "hand-written: " "$out"
assert_contains "the flag names the cap" "w > 40w cap" "$out"
git -C "$IW" checkout -q -- STATE.md

echo "--- initiative-caps.py: reports a breach at the edit, not at the commit ---"
cat > "$IW/initiatives/long-next.md" <<'EOF'
---
type: initiative
title: Long Next
timestamp: 2026-08-26
assignment_kind: self
assignment_status: active
next: this next action has way more than five words in it
waiting_on: none
---
body [i](index.md)
EOF
out=$(python3 "$H/initiative-caps.py" "$IW/initiatives/long-next.md" "$IW" 2>&1); rc=$?
assert "an over-cap field exits 2, which is what reaches the agent" "2" "$rc"
assert_contains "it names the field and both numbers" "next: 11 words > 5 cap" "$out"
assert_contains "it says what the breach will cost" "hard-fail the commit" "$out"

out=$(python3 "$H/initiative-caps.py" "$IW/initiatives/pitch-a.md" "$IW" 2>&1); rc=$?
assert "a compliant page says nothing" "" "$out"
assert "and exits 0" "0" "$rc"

python3 "$H/initiative-caps.py" "$IW/initiatives/off-board.md" "$IW" >/dev/null 2>&1
assert "board: false is exempt here as well" "0" "$?"

python3 "$H/initiative-caps.py" "$IW/STATE.md" "$IW" >/dev/null 2>&1
assert "a file outside initiatives/ is ignored" "0" "$?"

python3 "$H/initiative-caps.py" "$IW/initiatives/index.md" "$IW" >/dev/null 2>&1
assert "the initiatives index is ignored" "0" "$?"

printf '{"tool_input":{"file_path":"%s"}}' "$IW/initiatives/long-next.md" \
  | WIKI_ROOT="$IW" python3 "$H/initiative-caps.py" >/dev/null 2>&1
assert "the stdin hook payload carries the same verdict" "2" "$?"

printf 'not json' | WIKI_ROOT="$IW" python3 "$H/initiative-caps.py" >/dev/null 2>&1
assert "a malformed payload never fails the edit" "0" "$?"
rm -f "$IW/initiatives/long-next.md"

echo "--- board.py: rank ordering, defaults, waiting skip, repo filter, stale-rank marker ---"
board=$(python3 "$H/board.py" "$IW" --repo demo-repo)
assert_contains "current-cycle pitch defaults to rank 1" "1. [pitch" "$board"
assert_contains "Self B (explicit priority 4) is ranked, not defaulted" "4. [self" "$board"
assert_contains "Self B's old priority_set reads as stale" "stale, set 2026-01-01" "$board"
assert_contains "shipped (done) initiative appears under Shipped, not Now/Next" "Shipped: shipped" "$board"
assert "done initiative does not appear as a ranked row" "0" \
  "$(printf '%s' "$board" | grep -c '\[assigned·done\]')"
assert_contains "waiting-on-Andrew queue lists Self B's ask" "self-b · merge or close" "$board"
assert_contains "waiting-on-Andrew queue also lists the open-asks/andrew.md item" \
  "(open-asks/andrew) one file-level ask" "$board"
assert_contains "actionable-now pointer skips the row waiting on Andrew" \
  "Where demo-repo stands: #1 Pitch A" "$board"
assert "off-board.md never appears on the board" "0" "$(printf '%s' "$board" | grep -c 'Off Board')"

echo "--- board.py --write replaces only the marked block, idempotently ---"
python3 "$H/board.py" "$IW" --write
first=$(cat "$IW/STATE.md")
python3 "$H/board.py" "$IW" --write
second=$(cat "$IW/STATE.md")
assert "STATE.md still has exactly one Inbox tombstone heading after two writes" "1" \
  "$(printf '%s' "$second" | grep -c '## Inbox')"
assert_contains "the board block was actually replaced (no leftover placeholder)" \
  "1. [pitch" "$first"
assert "the placeholder is gone" "0" "$(printf '%s' "$first" | grep -c 'placeholder')"
assert "re-running --write with no frontmatter change is idempotent" "yes" \
  "$([ "$(printf '%s' "$first" | grep -c 'Pitch A')" = "$(printf '%s' "$second" | grep -c 'Pitch A')" ] && echo yes || echo no)"
git -C "$IW" checkout -q -- STATE.md

echo "--- board.py: overflow beyond the row cap prints a +N more line ---"
BW="$(mktemp -d)/wiki"; mkdir -p "$BW/initiatives"
for i in $(seq 1 15); do
  cat > "$BW/initiatives/p$i.md" <<EOF
---
type: initiative
title: P$i
timestamp: 2026-08-26
assignment_kind: self
assignment_status: active
next: x
waiting_on: none
---
body
EOF
done
git -C "$BW" init -q 2>/dev/null; git -C "$BW" add -A >/dev/null 2>&1
board=$(python3 "$H/board.py" "$BW")
assert_contains "more than 12 active rows print an overflow line" "more" "$board"
rm -rf "$(dirname "$BW")"

echo "--- pre-commit: regenerates the board before linting, on a clean and a failing tree ---"
git -C "$IW" checkout -q -- STATE.md
sed -i.bak 's/placeholder/still-placeholder-until-regen/' "$IW/STATE.md" 2>/dev/null || true
rm -f "$IW/STATE.md.bak"
( cd "$IW" && ./hooks/pre-commit >/tmp/precommit-out.$$ 2>&1 ); pc_rc=$?
assert "pre-commit exits 0 on a schema-clean tree" "0" "$pc_rc"
assert_contains "pre-commit regenerated STATE.md's board (real row present)" \
  "1. [pitch" "$(cat "$IW/STATE.md")"
assert "pre-commit regenerated STATE.md's board (placeholder gone)" "0" \
  "$(grep -c 'placeholder' "$IW/STATE.md")"
git -C "$IW" checkout -q -- STATE.md
rm -f "/tmp/precommit-out.$$"

cat > "$IW/initiatives/bad2.md" <<'EOF'
---
type: initiative
title: Bad2
timestamp: 2026-08-26
assignment_kind: nonsense
---
body [i](index.md)
EOF
git -C "$IW" add -A >/dev/null 2>&1
( cd "$IW" && ./hooks/pre-commit >/tmp/precommit-out2.$$ 2>&1 ); pc_rc=$?
assert "pre-commit exits nonzero when a page violates the schema" "yes" \
  "$([ "$pc_rc" -ne 0 ] && echo yes || echo no)"
rm -f "$IW/initiatives/bad2.md" "/tmp/precommit-out2.$$"

echo "--- journal-append.sh: creates the day's file with frontmatter, appends lines ---"
JW="$(mktemp -d)/wiki"; mkdir -p "$JW"
"$H/journal-append.sh" "$JW" "09:00 · demo · first entry"
"$H/journal-append.sh" "$JW" "09:05 · demo · second entry"
today="$(date +%Y-%m-%d)"
assert "exactly one journal file for today" "1" "$(ls "$JW/journal/$today.md" 2>/dev/null | wc -l | tr -d ' ')"
assert_contains "it carries type: journal frontmatter" "type: journal" "$(cat "$JW/journal/$today.md")"
assert "both lines landed" "2" "$(grep -c '^- ' "$JW/journal/$today.md")"

echo "--- journal-append.sh: 20 concurrent writers, no line lost, lock released ---"
CW="$(mktemp -d)/wiki"; mkdir -p "$CW"
for i in $(seq 1 20); do
  "$H/journal-append.sh" "$CW" "12:00 · concurrent · line $i" &
done
wait
assert "all 20 concurrent appends landed" "20" "$(grep -c '^- ' "$CW/journal/$today.md" 2>/dev/null)"
assert "the lock directory is cleaned up" "0" "$([ -d "$CW/journal/.append.lock" ] && echo 1 || echo 0)"
rm -rf "$(dirname "$JW")" "$(dirname "$CW")"

echo "--- lint-core.py: journal/ is exempt from STALE and ORPHAN, other dirs are not ---"
EW="$(mktemp -d)/wiki"; mkdir -p "$EW/journal" "$EW/notes"
printf '{"stale_days": 5, "orphan_exempt_dirs": ["journal/"], "stale_exempt_dirs": ["journal/"]}\n' \
  > "$EW/wiki.config.json"
cat > "$EW/journal/2020-01-01.md" <<'EOF'
---
type: journal
timestamp: 2020-01-01
---
- old
EOF
cat > "$EW/notes/old.md" <<'EOF'
---
type: notes
timestamp: 2020-01-01
synthesized_from: x
---
old, unlinked
EOF
git -C "$EW" init -q 2>/dev/null; git -C "$EW" add -A >/dev/null 2>&1
out=$(python3 "$H/lint-core.py" "$EW")
assert "journal/ file is not flagged STALE" "0" "$(printf '%s' "$out" | grep -c 'STALE journal/')"
assert "journal/ file is not flagged ORPHAN" "0" "$(printf '%s' "$out" | grep -c 'ORPHAN journal/')"
assert_contains "a non-exempt dir with the same age is still flagged STALE" "STALE notes/old.md" "$out"
assert_contains "a non-exempt dir is still flagged ORPHAN" "ORPHAN notes/old.md" "$out"
rm -rf "$(dirname "$EW")"

rm -rf "$(dirname "$IW")"

echo
echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
echo "======================================"
rm -rf "$(dirname "$W")"
[ "$fail" -eq 0 ]
