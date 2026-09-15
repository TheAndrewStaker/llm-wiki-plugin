#!/usr/bin/env python3
"""Shared helpers for the wiki hooks: root resolution, config load, git file listing,
frontmatter parsing. Every hook imports this so per-wiki settings live in one place
(wiki.config.json at the wiki root) instead of being hardcoded in each script.

Root resolution order:
  1. explicit argv path (a script's optional [WIKI_ROOT] argument)
  2. $CLAUDE_PLUGIN_OPTION_WIKI_ROOT  (set by the plugin's userConfig)
  3. $WIKI_ROOT                       (plain env override, e.g. for tests)
  4. ~/wiki                           (default)
"""
import json
import os
import re
import subprocess
import sys

# Defaults are the out-of-the-box wiki shape. wiki.config.json overrides any key.
DEFAULTS = {
    # content page-type dirs (Karpathy page types + work overlay)
    "content_dirs": [
        "entities/", "concepts/", "notes/", "analyses/",
        "initiatives/", "decisions/", "open-asks/", "reference/",
    ],
    # dirs whose pages hold prose that can mention other pages (missed-link scan)
    "prose_dirs": [
        "entities/", "concepts/", "notes/", "initiatives/",
        "decisions/", "analyses/", "reference/", "open-asks/",
    ],
    # dirs that define canonical entity/concept pages (missed-link term source)
    "entity_dirs": ["entities/", "concepts/"],
    # top-level landmark singletons: exempt from type: and orphan checks
    "landmark_files": ["CLAUDE.md", "STATE.md", "KNOWLEDGE.md", "ROADMAP.md", "README.md"],
    # extra basenames the user wants orphan-exempt (e.g. a people roster)
    "orphan_exempt_extra": [],
    # path prefixes exempt from the orphan check (parallel to the hardcoded archive/sources/
    # commands/ prefixes): a dated-log directory nothing links TO by design, e.g. "journal/"
    "orphan_exempt_dirs": [],
    # path prefixes exempt from the stale-timestamp check: a dated-log directory whose files
    # are expected to age past stale_days by design, e.g. "journal/"
    "stale_exempt_dirs": [],
    "wanted_exempt_dirs": [],
    # extra basenames exempt from the type: frontmatter requirement
    "type_exempt_extra": [],
    # path prefixes that are not wiki pages: the raw layer, plus agent tooling that sits
    # beside the wiki when its root is also the agent config dir. Excluded from the graph
    # and from search so tooling never outranks knowledge. Memory dirs drop out too via
    # is_memory() -- a separate store with its own index.
    "corpus_exclude": ["sources/", "commands/", "skills/", "hooks/"],
    # lowercased terms too generic to require a canonical link to (missed-link stoplist)
    "missed_link_stop": [],
    # lowercased titles/aliases allowed on more than one page (collision advisory exemptions)
    "collision_exempt": [],
    # per-type required frontmatter fields (advisory MISSING-FIELD; Wikidata-style hints).
    # Keys are type: values; values are lists of frontmatter keys that type should carry.
    "type_requirements": {
        "notes": ["synthesized_from"],
        "analysis": ["synthesized_from"],
        "entity": ["description"],
        "external-pointer": ["remote_url", "remote_path", "audience"],
    },
    # description length at which the retrieval line has stopped being a scannable line.
    # An outlier guard, deliberately above the natural spread: a description is indexed at
    # 2x weight, so trimming one to fit a threshold deletes ranked terms.
    "desc_max_chars": 400,
    # advisory "consider re-confirming" age for timestamp:
    "stale_days": 120,
    # a wiki with fewer than this many content pages is "young" (capture, don't query)
    "young_wiki_pages": 20,
    # Inbox soft-cap advisory (STATE.md's `## Inbox` section): 0 disables each check.
    "inbox_soft_max_items": 0,
    "inbox_soft_max_words": 0,
    "inbox_soft_max_item_words": 0,
    # timestamp-drift advisory: flag a page whose last real git edit is more than this
    # many days newer than its declared reviewed:/timestamp:. 0 disables the check.
    "timestamp_drift_days": 0,
    # commit subjects matching this (case-insensitive) regex are ignored when computing
    # a page's last-edit date for the drift check (routine autosave commits aren't edits).
    "drift_exempt_commit_pattern": "session auto-save",
    # maintenance nudge: warn at session start if analyses/reflection-*.md is older than this
    # many days (or never run). 0 disables the check.
    "reflect_nudge_days": 0,
    # search rank multiplier applied to superseded/archived pages' BM25 score.
    # 1.0 disables the down-rank; 0.0 would drop them from ranked results entirely.
    "superseded_downrank": 0.4,
    # lifecycle mutations are explicit and independently configurable
    "auto_commit": True,
    "auto_push": False,
    "topology": "hub-and-spokes",
    "advisory_budgets": {},
}


def resolve_root(argv_root=None):
    if argv_root:
        return os.path.expanduser(argv_root)
    env = os.environ.get("CLAUDE_PLUGIN_OPTION_WIKI_ROOT") or os.environ.get("WIKI_ROOT")
    if env:
        return os.path.expanduser(env)
    return os.path.expanduser("~/wiki")


def load_config(kb):
    cfg = dict(DEFAULTS)
    path = os.path.join(kb, "wiki.config.json")
    try:
        with open(path, encoding="utf-8") as fh:
            user = json.load(fh)
        if isinstance(user, dict):
            cfg.update(user)
    except FileNotFoundError:
        pass
    except (ValueError, OSError) as exc:
        print(f"# wiki.config.json ignored ({exc})", file=sys.stderr)
    return cfg


def git_files(kb, pattern="*.md"):
    out = subprocess.run(
        ["git", "ls-files", pattern],
        cwd=kb, capture_output=True, text=True,
    ).stdout
    return [f for f in out.splitlines() if f]


def corpus_files(kb, cfg=None, pattern="*.md"):
    """Git-tracked pages that are actual wiki knowledge.

    The one definition of "the corpus", shared by the graph check and by search, so those
    two never disagree about what counts as a page. Drops corpus_exclude prefixes and the
    memory store.
    """
    cfg = cfg if cfg is not None else load_config(kb)
    skip = tuple(cfg.get("corpus_exclude") or ())
    return [f for f in git_files(kb, pattern)
            if not (skip and f.startswith(skip)) and not is_memory(f)]


def read(kb, rel):
    try:
        return open(os.path.join(kb, rel), encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def frontmatter_value(text, key):
    # [ \t]* not \s*: \s crosses the newline, so a key with a block list below it returns
    # that list's first item (marker attached), and an empty key returns the NEXT key's value.
    m = re.search(r"^" + re.escape(key) + r":[ \t]*(.+)$", text[:1200], re.M)
    return m.group(1).strip() if m else None


def fm_list(fm_text, key):
    """Every value under `key` — inline flow ([a, b]), single scalar, or block list.

    Use for any key that may carry more than one value. Reading such a key with
    frontmatter_value sees at most the first entry, which silently narrows whatever
    the caller does with it.
    """
    m = re.search(r"^" + re.escape(key) + r":[ \t]*(.*)$", fm_text, re.M)
    if not m:
        return []
    val = m.group(1).strip()
    if val.startswith("["):
        return [a.strip().strip("'\"") for a in val.strip("[]").split(",") if a.strip()]
    if val:
        return [val.strip("'\"")]
    out = []
    for line in fm_text[m.end():].lstrip("\n").split("\n"):
        item = re.match(r"^\s*-\s+(.+)$", line)
        if not item:
            break
        out.append(item.group(1).strip().strip("'\""))
    return out


def fm_aliases(fm_text):
    """Names a page answers to. Shared by lint-core (collisions) and wanted-pages
    (resolution) so the two can never disagree."""
    return fm_list(fm_text, "aliases")


def frontmatter_values(text, key):
    """fm_list against a whole page, frontmatter block located for you."""
    block = re.match(r"^---\n(.*?)\n---", text, re.S)
    return fm_list(block.group(1), key) if block else []


def is_memory(f):
    return f.startswith("projects/") and "/memory/" in f


def supersede_marker(text):
    """True if a page carries the supersede token: a `Status: Superseded` line, or
    `superseded_by:` in its real frontmatter block. Fences and inline code are
    stripped first so a page that merely DOCUMENTS the convention is not itself
    marked superseded. Shared by lint-core (chain/stale-pointer checks) and
    wiki-query (rank down-weighting) so the two never disagree about the token.
    """
    stripped = re.sub(r"(?s)(```|~~~).*?(\1|\Z)", "", text)
    stripped = re.sub(r"`[^`]*`", "", stripped)
    if re.search(r"(?im)^\s*Status:\s*Superseded", stripped):
        return True
    fmblock = re.match(r"^---\n(.*?)\n---", text, re.S)
    return bool(fmblock and re.search(r"^superseded_by:\s*\S", fmblock.group(1), re.M))


def mention_index(kb, cfg, files):
    """Linkable page titles, lowercased title -> (display title, path).

    Shared by the missed-link advisory and the linker that fixes it, so the two can
    never disagree about what counts as a mention. Titles under 6 chars and configured
    stopwords over-fire, so both are dropped.
    """
    stop = {s.lower() for s in cfg["missed_link_stop"]}
    entity_dirs = tuple(cfg["entity_dirs"])
    out = {}
    for f in files:
        if not f.startswith(entity_dirs) or os.path.basename(f) == "index.md":
            continue
        head = read(kb, f)[:1000]
        m = re.search(r"^title:\s*(.+)$", head, re.M)
        if m:
            t = m.group(1).strip()
            if len(t) >= 6 and t.lower() not in stop:
                out.setdefault(t.lower(), (t, f))
    return out


def strip_markup(t):
    """Body prose with frontmatter, code and existing links removed, so a term already
    linked (or merely quoted in code) never reads as a missed mention."""
    t = re.sub(r"^---\n.*?\n---\n", "", t, flags=re.S)
    t = re.sub(r"```.*?```", "", t, flags=re.S)
    t = re.sub(r"`[^`]*`", "", t)
    t = re.sub(r"\[\[[^\]]*\]\]", "", t)
    return re.sub(r"\[[^\]]*\]\([^)]*\)", "", t)


def linked_targets(page, raw):
    """Wiki-root-relative paths that `page` already links to."""
    out = set()
    for tgt in re.findall(r"\]\(([^)#\s]+)", raw):
        p = (tgt if tgt.startswith("/")
             else os.path.normpath(os.path.join(os.path.dirname(page), tgt)).replace(os.sep, "/"))
        out.add(p.lstrip("/"))
    return out


def mention_re(term):
    # Case-SENSITIVE. Page titles are proper nouns, and a lowercase occurrence usually is
    # not the entity: "a tableau annotation" names a Kubernetes resource, not the product.
    # Matching loosely here would have the linker rewrite those.
    return re.compile(r"(?<![\w-])" + re.escape(term) + r"(?![\w-])")


def missed_mentions(kb, cfg, files):
    """Yield (prose_page, display_title, target_page, raw_text) once per target a page
    names in prose but never links. One link per page satisfies it, so a page already
    linking the target is skipped no matter how often it names it."""
    index = mention_index(kb, cfg, files)
    prose_dirs = tuple(cfg["prose_dirs"])
    for f in files:
        if not f.startswith(prose_dirs) or os.path.basename(f) == "index.md":
            continue
        if f.endswith(".base"):
            continue
        raw = read(kb, f)
        plain = strip_markup(raw)
        linked = linked_targets(f, raw)
        seen = set()
        for term, (disp, page) in index.items():
            if f == page or page in seen or page in linked:
                continue
            # match on the display title: the index key is lowercased for dedup only
            if not mention_re(disp).search(plain):
                continue
            seen.add(page)
            yield f, disp, page, raw
