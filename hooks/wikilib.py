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
    # extra basenames exempt from the type: frontmatter requirement
    "type_exempt_extra": [],
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
    },
    # advisory "consider re-confirming" age for timestamp:
    "stale_days": 120,
    # a wiki with fewer than this many content pages is "young" (capture, don't query)
    "young_wiki_pages": 20,
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


def read(kb, rel):
    try:
        return open(os.path.join(kb, rel), encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def frontmatter_value(text, key):
    m = re.search(r"^" + re.escape(key) + r":\s*(.+)$", text[:1200], re.M)
    return m.group(1).strip() if m else None


def is_memory(f):
    return f.startswith("projects/") and "/memory/" in f
