#!/usr/bin/env bash
# Append one line to today's journal/YYYY-MM-DD.md, creating it with frontmatter on first
# write. mkdir-based lock (portable: flock isn't on macOS by default, and this plugin runs
# there), mirroring auto-commit.sh's stale-owner-aware lock. Two sessions appending in the
# same second must not lose either line to a whole-file-Write race, so journal entries are
# never written via the Write/Edit tools -- always through this script.
#
# Usage: journal-append.sh [WIKI_ROOT] "HH:MM · slug · text"
set -uo pipefail

if [ $# -eq 2 ]; then
  KB="$1"; LINE="$2"
else
  KB="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-${WIKI_ROOT:-$HOME/wiki}}"; LINE="${1:-}"
fi
KB="${KB/#\~/$HOME}"
[ -n "$LINE" ] || { echo "journal-append: no line given" >&2; exit 2; }
# A relative or missing root would create a stray journal/ wherever the caller stands.
case "$KB" in
  /*) ;;
  *) echo "journal-append: wiki root must be an absolute path, got '$KB' (usage: journal-append.sh [WIKI_ROOT] LINE)" >&2; exit 2 ;;
esac
[ -d "$KB" ] || { echo "journal-append: wiki root '$KB' does not exist" >&2; exit 2; }

DIR="$KB/journal"
mkdir -p "$DIR"
DATE="$(date +%Y-%m-%d)"
FILE="$DIR/$DATE.md"
LOCK="$DIR/.append.lock"

acquired=0
for _ in $(seq 1 100); do
  if mkdir "$LOCK" 2>/dev/null; then
    acquired=1
    break
  fi
  owner=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    rm -f "$LOCK/pid" 2>/dev/null
    rmdir "$LOCK" 2>/dev/null
    continue
  fi
  sleep 0.05
done
if [ "$acquired" -ne 1 ]; then
  echo "journal-append: could not acquire $LOCK after 5s" >&2
  exit 1
fi
printf '%s\n' "$$" > "$LOCK/pid"
cleanup_lock() {
  rm -f "$LOCK/pid" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

new_day=0
if [ ! -s "$FILE" ]; then
  printf -- '---\ntype: journal\ntimestamp: %s\n---\n\n' "$DATE" > "$FILE"
  new_day=1
fi
printf -- '- %s\n' "$LINE" >> "$FILE"

# journal/index.md links every day, newest first, so day pages are reachable in the link graph.
INDEX="$DIR/index.md"
if [ "$new_day" -eq 1 ] || [ ! -f "$INDEX" ]; then
  {
    printf -- '---\ntype: index\ntitle: Journal\n---\n\n# Journal\n\n'
    for f in $(ls "$DIR" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' | sort -r); do
      printf -- '- [%s](%s)\n' "${f%.md}" "$f"
    done
  } > "$INDEX.tmp.$$" && mv "$INDEX.tmp.$$" "$INDEX"
fi
