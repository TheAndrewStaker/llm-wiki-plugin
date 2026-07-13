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

echo "--- template scaffold lints clean + pre-commit gate blocks ---"
# wiki-setup's deterministic core: templates/tree + the wiki's own hook copies must yield a
# lint-green wiki whose pre-commit rejects a broken link and passes a clean commit.
T="$(mktemp -d)/fresh"
mkdir -p "$T"
cp -R "$ROOT/templates/tree/." "$T/"
mv "$T/gitignore" "$T/.gitignore"
mkdir -p "$T/hooks"
for f in lint.sh lint-core.py graph-check.py missed-links.py stale-source.py reflect-scope.py rewrite-links.py wanted-pages.py inbox-check.py timestamp-drift.py wikilib.py pre-commit; do
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

echo "--- OKF interchange export and validation ---"
OKF_TMP="$(mktemp -d)"
OKF_WIKI="$OKF_TMP/wiki"
OKF_OUT="$OKF_TMP/export"
cp -R "$ROOT/templates/tree" "$OKF_WIKI"
mkdir -p "$OKF_WIKI/sources"
printf 'private raw source\n' > "$OKF_WIKI/sources/private.md"
printf '%s\n' '---' 'type: concept' 'title: Exported concept' '---' 'Body.' > "$OKF_WIKI/concepts/exported.md"
"$ROOT/bin/wiki-okf" export "$OKF_WIKI" "$OKF_OUT" >/dev/null; rc=$?
assert "OKF export succeeds" "0" "$rc"
"$ROOT/bin/wiki-okf" validate "$OKF_OUT" >/dev/null; rc=$?
assert "OKF exported bundle validates" "0" "$rc"
assert "OKF root index has no frontmatter" "0" "$(head -1 "$OKF_OUT/index.md" | grep -c '^---$')"
assert "OKF per-dir index has no frontmatter" "0" "$(head -1 "$OKF_OUT/concepts/index.md" | grep -c '^---$')"
assert "OKF export excludes raw sources" "no" "$([ -e "$OKF_OUT/sources/private.md" ] && echo yes || echo no)"
printf '%s\n' '---' 'type: index' '---' 'invalid reserved file' > "$OKF_OUT/concepts/index.md"
"$ROOT/bin/wiki-okf" validate "$OKF_OUT" >/dev/null; rc=$?
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
rm -rf "$AUTO_TMP"

echo
echo "======================================"
echo "  PASS=$pass  FAIL=$fail"
echo "======================================"
rm -rf "$(dirname "$W")"
[ "$fail" -eq 0 ]
