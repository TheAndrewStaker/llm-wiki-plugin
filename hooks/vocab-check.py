#!/usr/bin/env python3
"""Frontmatter vocabulary advisories. Advisory only, always exits 0; lint.sh decides the
gate through advisory_budgets (unknown_type, uncheckable_sources_added).

  UNKNOWN-TYPE        a page's `type:` is not in config `types` (no check when unset).
  UNCHECKABLE-ADDED   a `synthesized_from` entry that is free text (not a path or URL) and
                      was not on the page before this change: staged against HEAD under
                      WIKI_CHECK_INDEX=1, else the working tree against HEAD. Entries are
                      compared as a parsed set, so reordering or reformatting a list adds
                      nothing, and neither does splitting or rewording an existing prose
                      entry (most of its words already appear in the page's old frontmatter);
                      a renamed page is compared with its old path.

Standalone: python3 hooks/vocab-check.py [WIKI_ROOT]
Ends with: VOCAB unknown_type=<n> uncheckable_added=<n>
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
cfg = wikilib.load_config(KB)
os.chdir(KB)
files = wikilib.corpus_files(KB, cfg)
TYPE = re.compile(r"(?m)^type:[ \t]*(.*?)[ \t]*$")


def fm(text):
    m = re.match(r"^---\n(.*?)\n---", text or "", re.S)
    return m.group(1) if m else None


def norm(entry):
    return re.sub(r"\s+", " ", entry).strip()


def words(text):
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def reworded(entry, old_words):
    w = words(entry)
    return bool(w) and len(w & old_words) / len(w) >= 0.6


unknown = 0
types = cfg.get("types")
if isinstance(types, list) and types:
    allowed = {str(t) for t in types}
    for f in files:
        block = fm(wikilib.read(KB, f))
        if block is None:
            continue
        m = TYPE.search(block)
        value = m.group(1).strip().strip("'\"") if m else ""
        if value and value not in allowed:
            print(f"  UNKNOWN-TYPE {f} ({value!r} is not in config types)")
            unknown += 1

index_mode = os.environ.get("WIKI_CHECK_INDEX") == "1"
diff = ["git", "diff"] + (["--cached"] if index_mode else []) + ["--name-only", "HEAD", "--", "*.md"]
changed = subprocess.run(diff, cwd=KB, capture_output=True, text=True).stdout.split()
if not index_mode:
    changed += subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "*.md"],
                              cwd=KB, capture_output=True, text=True).stdout.split()
renames = wikilib.renamed_from(KB, index=index_mode)
corpus = set(files) | set(changed)
skip = tuple(cfg.get("corpus_exclude") or ())
added = 0
for f in sorted(set(changed)):
    if f not in corpus or (skip and f.startswith(skip)) or wikilib.is_memory(f):
        continue
    new_text = wikilib.git_text(KB, f, "") if index_mode else wikilib.read(KB, f)
    block = fm(new_text)
    if block is None:
        continue
    old_block = fm(wikilib.git_text(KB, renames.get(f, f), "HEAD"))
    before = {norm(e) for e in wikilib.fm_sources(old_block)} if old_block else set()
    old_words = words(old_block or "")
    gained = [e for e in wikilib.fm_sources(block) if wikilib.citation_kind(e) == "freetext"
              and norm(e) not in before and not reworded(e, old_words)]
    if gained:
        print(f"  UNCHECKABLE-ADDED {f} ({len(gained)}: {'; '.join(gained)[:80]}) cite a path or URL")
        added += 1

print(f"VOCAB unknown_type={unknown} uncheckable_added={added}")
