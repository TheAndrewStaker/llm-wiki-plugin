#!/usr/bin/env python3
"""Archive owner-queue bullets that no longer need the owner, without asking.

Rules (open-asks/<owner>.md, bullets shaped '- [ ] YYYY-MM-DD · <source> · text'):
  - a checked bullet ('- [x]') is archived;
  - a bullet from someone else is archived only when it links initiatives and every one is done;
  - a bullet whose source is the configured self label is archived when every linked initiative
    is done or parked, or when it has not been touched for `queue_self_expire_days`
    (its own date is when it was last touched; an agent re-dates a bullet it renews).
Undated bullets are never touched. Archived bullets go to archive/<YYYY-MM>.md under an
"Expired from the queue" heading with the reason, and one journal line names them, so the
change is visible and a git revert restores it.

Usage: queue-expire.py [WIKI_ROOT] [--dry-run] [--commit]
  --commit  commit the touched files on their own; skipped (exit 3) when the queue, this
            month's archive or today's journal already has uncommitted edits, and rolled back
            (exit 1) when the commit is refused, so another session's work is never swept in
Prints one line per archived bullet; exit 0 when the run completed.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib


def git(kb, *args):
    return subprocess.run(["git", "-C", kb, *args], capture_output=True, text=True)


def initiative_status(kb, slug):
    fm = wikilib.fm_block(wikilib.read(kb, f"initiatives/{slug}.md"))
    return wikilib.frontmatter_value(fm, "assignment_status") if fm else None


def decide(kb, rel, it, schema, today):
    if not it["date"]:
        return None
    if it["checked"]:
        return "checked off"
    statuses = [initiative_status(kb, s) for s in it["initiatives"]]
    statuses = [s for s in statuses if s]
    self_label = schema.get("queue_self_label", "self")
    if it["source"] != self_label:
        if statuses and all(s == "done" for s in statuses):
            return "linked initiative done"
        return None
    if statuses and all(s in ("done", "parked") for s in statuses):
        return "linked initiative " + "/".join(sorted(set(statuses)))
    days = schema.get("queue_self_expire_days")
    if not days:
        return None
    touched = wikilib_date(it["date"])
    if touched and (today - touched).days > int(days):
        return f"untouched {(today - touched).days}d"
    return None


def wikilib_date(v):
    try:
        return datetime.date.fromisoformat(v)
    except (TypeError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--commit", action="store_true")
    args = ap.parse_args()
    kb = wikilib.resolve_root(args.root)
    cfg = wikilib.load_config(kb)
    schema = cfg.get("initiative_schema") or {}
    if not schema.get("queue_dated"):
        return 0
    owner, _ = wikilib.queue_owner(schema)
    rel = f"open-asks/{owner}.md"
    path = os.path.join(kb, rel)
    if not os.path.isfile(path):
        return 0
    today = datetime.date.today()
    arel = f"archive/{today:%Y-%m}.md"
    jrel = f"journal/{today}.md"
    if args.commit:
        r = git(kb, "status", "--porcelain", "--", rel, arel, jrel)
        if r.returncode != 0 or r.stdout.strip():
            return 3
    text = wikilib.read(kb, rel)
    expired = []
    for it in wikilib.parse_queue(text):
        why = decide(kb, rel, it, schema, today)
        if why:
            expired.append((it, why))
    if not expired:
        return 0
    for it, why in expired:
        print(f"{why}: {it['raw'].splitlines()[0][:100]}")
    if args.dry_run:
        return 0

    lines = text.split("\n")
    drop = set()
    for it, _ in expired:
        drop.update(range(it["start"], it["end"]))
    kept = [l for n, l in enumerate(lines) if n not in drop]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(re.sub(r"\n{3,}", "\n\n", "\n".join(kept)))

    apath = os.path.join(kb, arel)
    os.makedirs(os.path.dirname(apath), exist_ok=True)
    existing = wikilib.read(kb, arel)
    if not existing:
        existing = (f"---\ntype: archive\ntitle: Archive {today:%Y-%m}\ntimestamp: {today}\n---\n\n"
                    f"# Archive {today:%Y-%m}\n")
    block = f"\n## Expired from the queue ({today})\n\n"
    for it, why in expired:
        block += f"{it['raw']}\n  _Archived: {why}._\n"
    with open(apath, "w", encoding="utf-8") as fh:
        fh.write(existing.rstrip("\n") + "\n" + block)

    note = f"{datetime.datetime.now():%H:%M} · queue · archived {len(expired)} from {rel}: " + "; ".join(
        f"{(it['raw'].splitlines()[0][6:].split(' · ', 2)[-1])[:50]} ({why})" for it, why in expired)
    journal = os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal-append.sh")
    subprocess.run(["bash", journal, kb, note], capture_output=True)

    if args.commit:
        paths = [rel, arel] + ([jrel] if os.path.isfile(os.path.join(kb, jrel)) else [])
        wc = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "wiki-commit")
        r = subprocess.run([sys.executable, wc, "--root", kb, "-m",
                            f"Archive {len(expired)} expired queue item(s)", *paths],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"queue-expire: commit refused, rolled back: {(r.stderr or r.stdout).strip()[:300]}",
                  file=sys.stderr)
            tracked = [p for p in paths if git(kb, "cat-file", "-e", f"HEAD:{p}").returncode == 0]
            if tracked:
                git(kb, "checkout", "HEAD", "--", *tracked)
            for p in paths:
                if p not in tracked and os.path.isfile(os.path.join(kb, p)):
                    os.remove(os.path.join(kb, p))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
