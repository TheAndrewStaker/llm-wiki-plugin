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
    # Stop-hook log guard: block a stop once when work events (commits, PRs) happened with no
    # wiki log write since. Off unless `enabled` is true. Keys: work_commands, log_commands,
    # log_dirs, work_writes (count file writes outside the wiki as work), min_work.
    "log_guard": {},
    # standing aims: {"file": "ROADMAP.md", "heading": "Standing aims"}; empty disables.
    "aims": {},
}

LOG_GUARD_DEFAULTS = {
    "enabled": False,
    "work_commands": ["git commit", "gh pr create", "gh pr merge"],
    "log_commands": ["wiki-fm set", "journal-append"],
    "log_dirs": ["initiatives/", "journal/"],
    "work_writes": False,
    "ignore_write_prefixes": ["/tmp/", "/private/tmp/", "/var/folders/"],
    "min_work": 1,
}


def log_guard_config(cfg):
    out = dict(LOG_GUARD_DEFAULTS)
    user = cfg.get("log_guard") or {}
    if isinstance(user, dict):
        out.update(user)
    return out


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


_INDEX_TEXTS = None


def index_texts(kb):
    """{rel: text} for every tracked .md blob in the index (GIT_INDEX_FILE honoured), read
    in one cat-file batch. Cached per process."""
    global _INDEX_TEXTS
    if _INDEX_TEXTS is not None and _INDEX_TEXTS[0] == kb:
        return _INDEX_TEXTS[1]
    ls = subprocess.run(["git", "ls-files", "-s", "--", "*.md"], cwd=kb,
                        capture_output=True, text=True).stdout
    shas = {}
    for line in ls.splitlines():
        meta, _, path = line.partition("\t")
        parts = meta.split()
        if len(parts) >= 2 and path:
            shas[path] = parts[1]
    texts = {}
    if shas:
        out = subprocess.run(["git", "cat-file", "--batch"], cwd=kb,
                             input=("\n".join(shas.values()) + "\n").encode(),
                             capture_output=True).stdout
        by_sha, pos = {}, 0
        while pos < len(out):
            nl = out.find(b"\n", pos)
            if nl < 0:
                break
            header = out[pos:nl].decode("utf-8", "replace").split()
            if len(header) < 3 or header[1] != "blob":
                pos = nl + 1
                continue
            size = int(header[2])
            by_sha[header[0]] = out[nl + 1:nl + 1 + size].decode("utf-8", "replace")
            pos = nl + 1 + size + 1
        texts = {p: by_sha[s] for p, s in shas.items() if s in by_sha}
    _INDEX_TEXTS = (kb, texts)
    return texts


def read(kb, rel):
    """A page's text. With WIKI_CHECK_INDEX=1 (the commit gate) a tracked page is read from
    the index being committed, so another session's uncommitted edits never decide this
    commit's verdict; anything not in the index falls back to the working tree."""
    if os.environ.get("WIKI_CHECK_INDEX") == "1":
        texts = index_texts(kb)
        if rel in texts:
            return texts[rel]
    try:
        return open(os.path.join(kb, rel), encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def fm_block(text):
    """The bare frontmatter block of a page, or "" when it has none."""
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    return m.group(1) if m else ""


def git_text(kb, rel, ref="HEAD"):
    """Content of `rel` at `ref` (ref "" reads the index), or "" when absent there."""
    r = subprocess.run(["git", "show", f"{ref}:{rel}"], cwd=kb, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def renamed_from(kb, index=False):
    """{new_path: old_path} for renames against HEAD, staged (index=True) or in the tree."""
    args = ["git", "diff"] + (["--cached"] if index else []) + ["-M", "--name-status", "HEAD"]
    r = subprocess.run(args, cwd=kb, capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].startswith("R"):
            out[parts[2]] = parts[1]
    return out


def previous_frontmatter(kb, rel, index=False, renames=None):
    """Frontmatter of `rel` as HEAD has it, following a staged rename; "" when the page is
    new or was not a board initiative at HEAD, so entering the board counts as a
    transition. Lets a gate judge what changed rather than a state."""
    old = (renames or {}).get(rel, rel)
    fm = fm_block(git_text(kb, old))
    return fm if _board_initiative(fm) else ""


NULLISH = {"~", "null", "Null", "NULL", "''", '""'}


def present(fm, key):
    """A field's value, with YAML nulls and empty quotes read as absent."""
    v = frontmatter_value(fm, key)
    return None if v is None or v.strip() in NULLISH else v


def state_dir(kb):
    """Machine-local state beside the lint history: <git-dir>/compendium, else <wiki>/.compendium."""
    r = subprocess.run(["git", "rev-parse", "--absolute-git-dir"], cwd=kb,
                       capture_output=True, text=True)
    gd = r.stdout.strip() if r.returncode == 0 else ""
    return os.path.join(gd, "compendium") if gd else os.path.join(kb, ".compendium")


def frontmatter_value(text, key):
    # [ \t]* not \s*: \s crosses the newline, so a key with a block list below it returns
    # that list's first item (marker attached), and an empty key returns the NEXT key's value.
    # A whole page is narrowed to its frontmatter block; a bare block is read in full, so a
    # key past any fixed offset (e.g. below a long flow list) is still found.
    block = re.match(r"^---\n(.*?)\n---", text, re.S)
    scope = block.group(1) if block else text
    m = re.search(r"^" + re.escape(key) + r":[ \t]*(.+)$", scope, re.M)
    return m.group(1).strip() if m else None


_WRITE_MARKERS = re.compile(
    r"(\bsed\s+-i|\bperl\s+-[a-z]*i|\btee\b|open\([^)]*['\"][wa]|write_text|\.write\(|"
    r"\bwiki-fm\s+set\b|\bmv\s|\bcp\s)")


def bash_writes(cmd, rel):
    """True when a shell command names `rel` and visibly writes it: as a redirect target,
    or alongside an in-place edit, a file opened for writing, or wiki-fm set."""
    if rel not in cmd:
        return False
    if re.search(r">>?\s*['\"]?[^\s'\"]*" + re.escape(rel), cmd):
        return True
    return bool(_WRITE_MARKERS.search(cmd))


def queue_owner(schema):
    """(waiting_on key, display label) for the wiki owner's personal queue; the owner's
    file-level asks live at open-asks/<key>.md."""
    key = (schema or {}).get("owner", "owner")
    return key, (schema or {}).get("owner_label", key.capitalize())


QUEUE_LINE_RE = re.compile(r"^- \[( |x|X)\] (\d{4}-\d\d-\d\d) · ([^·\n]+?) · ")
QUEUE_INIT_RE = re.compile(r"\]\((?:\.\./)?initiatives/([A-Za-z0-9._-]+)\.md(?:#[^)]*)?\)")


def parse_queue(text):
    """Bullets of an owner queue file as dicts: start/end line indexes (end exclusive), raw
    text, checked, date (str or None), source (who asked, or None), initiatives (slugs linked
    after the bullet's last '→', its owners; mentions before it do not count). A bullet runs
    until the next bullet, a blank line or a heading; fenced code blocks are skipped."""
    lines = text.split("\n")
    items, i, fence = [], 0, False
    while i < len(lines):
        if lines[i].lstrip().startswith("```"):
            fence = not fence
            i += 1
            continue
        if fence or not lines[i].startswith("- "):
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j][:1] in (" ", "\t") and lines[j].strip():
            j += 1
        raw = "\n".join(lines[i:j])
        m = QUEUE_LINE_RE.match(lines[i])
        owners = raw.rsplit("→", 1)[1] if "→" in raw else ""
        items.append({
            "start": i, "end": j, "raw": raw,
            "checked": bool(m and m.group(1) in "xX"),
            "date": m.group(2) if m else None,
            "source": m.group(3).strip() if m else None,
            "initiatives": QUEUE_INIT_RE.findall(owners),
        })
        i = j
    return items


def initiative_issues(schema, fm, prev_fm=None, active_count=None):
    """Per-page initiative schema violations as (field, message) pairs. `fm` is the bare
    frontmatter block. Shared by the commit gate and the frontmatter writer so the two
    cannot disagree about what a page owes.

    Transition rules need `prev_fm`: the page's frontmatter before this change ("" for a
    new page). None skips them. `required_at_status` ({"done": ["verify"]}) fails a page
    that reaches the status without the field, or that already had it and drops it; a page
    that was already in that status without the field is grandfathered. `active_max` fails
    a page becoming `active` when `active_count` (this page included) exceeds the cap."""
    def wc(s):
        return len(s.split()) if s else 0

    get = lambda k: present(fm, k)
    kinds = set(schema.get("assignment_kind", []))
    statuses = set(schema.get("assignment_status", []))
    waiting = set(schema.get("waiting_on", []))
    kind, status, wo, ask = get("assignment_kind"), get("assignment_status"), \
        get("waiting_on") or "none", get("ask")
    out = []
    if kinds and kind not in kinds:
        out.append(("assignment_kind", f"missing or not in {sorted(kinds)}"))
    if statuses and status not in statuses:
        out.append(("assignment_status", f"missing or not in {sorted(statuses)}"))
    if get("priority") is not None and not get("priority_set"):
        out.append(("priority_set", "required because priority is set"))
    if kind == "pitch" and not get("cycle"):
        out.append(("cycle", "required because assignment_kind is pitch"))
    if waiting and wo not in waiting:
        out.append(("waiting_on", f"'{wo}' not in {sorted(waiting)}"))
    if wo != "none" and not ask:
        out.append(("ask", f"required because waiting_on is '{wo}', not 'none'"))
    for field, cap_key in (("summary", "summary_max_words"), ("next", "next_max_words"),
                           ("verify", "verify_max_words"), ("ask", "ask_max_words")):
        cap, val = schema.get(cap_key, 0), get(field)
        if cap and val and wc(val) > cap:
            out.append((field, f"{wc(val)}w > {cap}w cap"))
    for field in schema.get("list_fields", []):
        m = re.search(rf"^{re.escape(field)}:[ \t]*(.*)$", fm, re.M)
        if not m:
            continue
        val = re.sub(r"\s+#.*$", "", m.group(1)).strip()
        if val == "":
            if not re.search(rf"^{re.escape(field)}:[ \t]*\n(?:[ \t]+- .*\n?)+", fm + "\n", re.M):
                out.append((field, "must be a list: [\"a\", \"b\"] or a block of '  - ' items"))
            continue
        if not (val.startswith("[") and val.endswith("]")):
            out.append((field, f"must be a list such as [\"{val.strip(chr(34))}\"], not a bare value"))
    if prev_fm is None:
        return out
    prev_status = frontmatter_value(prev_fm, "assignment_status") if prev_fm else None
    for at_status, fields in (schema.get("required_at_status") or {}).items():
        if status != at_status:
            continue
        for field in fields:
            if get(field):
                continue
            had = bool(prev_fm) and bool(present(prev_fm, field))
            if prev_status != at_status:
                out.append((field, f"required when assignment_status becomes '{at_status}'"))
            elif had:
                out.append((field, f"cannot be removed while assignment_status is '{at_status}'"))
    cap = schema.get("active_max") or 0
    if cap and active_count is not None and status == "active" and prev_status != "active" \
            and active_count > cap:
        out.append(("assignment_status",
                    f"activating makes {active_count} active > {cap} cap "
                    f"(active_max); park another initiative first"))
    return out


def _board_initiative(fm):
    return frontmatter_value(fm, "type") == "initiative" and frontmatter_value(fm, "board") != "false"


def active_count(kb, index=False, extra=None):
    """Board initiatives whose assignment_status is `active`, read from the index when
    index=True. `extra` ({rel: fm}) supplies pages whose content is not on disk yet."""
    extra = dict(extra or {})
    n = 0
    for f in git_files(kb):
        if not f.startswith("initiatives/") or os.path.basename(f) == "index.md":
            continue
        fm = extra.pop(f, None)
        if fm is None:
            fm = fm_block(git_text(kb, f, "") if index else read(kb, f))
        if _board_initiative(fm) and frontmatter_value(fm, "assignment_status") == "active":
            n += 1
    for f, fm in extra.items():
        if f.startswith("initiatives/") and _board_initiative(fm) \
                and frontmatter_value(fm, "assignment_status") == "active":
            n += 1
    return n


AIM_LINE = re.compile(
    r"^- (?P<id>aim:[a-z0-9][a-z0-9-]*) · (?P<date>\d{4}-\d{2}-\d{2}) · (?P<text>.+?) · "
    r"carried by: (?P<carrier>none|\[[^\]]+\]\([^)\s]+\)) · reviewed: (?P<reviewed>\d{4}-\d{2}-\d{2})"
    r"(?P<superseded> · superseded \d{4}-\d{2}-\d{2})?$")


def parse_aims(kb, cfg, text=None):
    """Standing aims from the configured section. Returns (aims, errors). Each aim:
    id, date, text, carrier (wiki-relative path or None), reviewed, superseded (bool),
    carrier_status (the carrier's assignment_status, or None). Errors are strings naming
    the offending line; a duplicate live id is an error."""
    conf = cfg.get("aims") or {}
    if not conf.get("file") or not conf.get("heading"):
        return [], []
    rel = conf["file"]
    text = read(kb, rel) if text is None else text
    m = re.search(r"(?ms)^##\s+" + re.escape(conf["heading"]) + r"\s*$(.*?)(?=^## |\Z)", text)
    if not m:
        return [], [f"{rel} aims: section '## {conf['heading']}' not found"]
    aims, errors, live = [], [], set()
    import datetime
    for line in m.group(1).splitlines():
        if not line.startswith("- "):
            continue
        lm = AIM_LINE.match(line.rstrip())
        if not lm:
            errors.append(f"{rel} aims: line does not parse: {line[:70]!r}")
            continue
        try:
            datetime.date.fromisoformat(lm.group("date"))
            datetime.date.fromisoformat(lm.group("reviewed"))
        except ValueError:
            errors.append(f"{rel} aims: {lm.group('id')} has a bad date")
            continue
        carrier, carrier_status = None, None
        if lm.group("carrier") != "none":
            tgt = re.search(r"\(([^)\s]+)\)", lm.group("carrier")).group(1)
            carrier = os.path.normpath(os.path.join(os.path.dirname(rel), tgt)).replace(os.sep, "/")
            cfm = fm_block(read(kb, carrier))
            if frontmatter_value(cfm, "type") != "initiative":
                errors.append(f"{rel} aims: {lm.group('id')} carrier {carrier} is not an initiative page")
            carrier_status = frontmatter_value(cfm, "assignment_status")
        superseded = bool(lm.group("superseded"))
        if not superseded:
            if lm.group("id") in live:
                errors.append(f"{rel} aims: {lm.group('id')} appears twice without 'superseded'")
            live.add(lm.group("id"))
        aims.append({"id": lm.group("id"), "date": lm.group("date"), "text": lm.group("text"),
                     "carrier": carrier, "reviewed": lm.group("reviewed"),
                     "superseded": superseded, "carrier_status": carrier_status})
    return aims, errors


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
        yield from missed_mentions_text(index, f, read(kb, f))


def missed_mentions_text(index, f, raw):
    """missed_mentions for one page given its text, so a caller can judge another
    version of the page (HEAD's) with the same index."""
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
