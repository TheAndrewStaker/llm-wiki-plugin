#!/usr/bin/env python3
"""Prove the commit gate refuses bad structure, by fault injection in a throwaway clone.

    python3 hooks/gate-proof.py [WIKI_ROOT] [--keep]

Clones the wiki, wires the clone's gate the way the wiki's is wired, then drives the real
commit path (wiki-commit) three times: a page with a broken link (must be refused), the same
page repaired but unlinked (must be refused where orphans or unindexed pages are gated), and
the page linked from its index (must commit). Each refusal must name the seeded page, leave
HEAD where it was and leave the edits on disk. The wiki itself is never written.
Exits 0 when every step holds, 1 otherwise.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import wikilib

ap = argparse.ArgumentParser(prog="gate-proof")
ap.add_argument("root", nargs="?")
ap.add_argument("--keep", action="store_true", help="keep the clone for inspection")
a = ap.parse_args()
SRC = str(wikilib.resolve_root(a.root))
ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=ENV)


def fail(msg, detail=""):
    print(f"FAIL  {msg}")
    if detail:
        print("\n".join("      " + l for l in detail.strip().splitlines()[-15:]))
    cleanup()
    sys.exit(1)


def ok(msg):
    print(f"ok    {msg}")


tmp = tempfile.mkdtemp(prefix="wiki-gate-proof.")
KB = os.path.join(tmp, "wiki")


def cleanup():
    if a.keep:
        print(f"clone kept at {KB}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)


if git(SRC, "rev-parse", "--git-dir").returncode:
    fail(f"{SRC} is not a git repository")
r = git(tmp, "clone", "-q", "--local", SRC, KB)
if r.returncode:
    fail("could not clone the wiki", r.stderr)
for key in ("user.name", "user.email"):
    val = git(SRC, "config", "--get", key).stdout.strip()
    if val:
        git(KB, "config", key, val)

# Wire the clone's gate exactly as the wiki's is wired; an unwired wiki fails here.
hooks_path = git(SRC, "config", "--get", "core.hooksPath").stdout.strip()
src_git = os.path.join(SRC, git(SRC, "rev-parse", "--git-dir").stdout.strip())
if hooks_path:
    real = os.path.realpath(os.path.join(SRC, os.path.expanduser(hooks_path)))
    inside = os.path.relpath(real, os.path.realpath(SRC))
    git(KB, "config", "core.hooksPath", inside if not inside.startswith("..") else real)
    wired = os.path.isfile(os.path.join(real, "pre-commit"))
else:
    hook = os.path.join(src_git, "hooks", "pre-commit")
    wired = os.path.isfile(hook)
    if wired:
        shutil.copy2(hook, os.path.join(KB, ".git", "hooks", "pre-commit"))
if not wired:
    fail(f"no pre-commit gate is wired in {SRC}: commits there are not checked")
ok(f"clone of {SRC} with its gate wired the same way")

cfg = wikilib.load_config(KB)
budgets = cfg.get("advisory_budgets") or {}
gated = [n for n in ("orphan", "unindexed") if isinstance(budgets.get(n), int) and budgets[n] >= 0]
target = None
for d in cfg.get("content_dirs") or []:
    d = d.strip("/")
    if d != "initiatives" and os.path.isfile(os.path.join(KB, d, "index.md")):
        target = d
        break
if not target:
    fail("no content directory with an index.md to seed a page into")
ptype = "note"
for name in sorted(os.listdir(os.path.join(KB, target))):
    if name.endswith(".md") and name != "index.md":
        m = re.match(r"^---\n(.*?)\n---", open(os.path.join(KB, target, name),
                                                 encoding="utf-8").read(), re.S)
        t = wikilib.frontmatter_value(m.group(1), "type") if m else None
        if t:
            ptype = t
            break

tag = str(os.getpid())
page = f"{target}/gate-proof-{tag}.md"
index = f"{target}/index.md"
today = datetime.date.today().isoformat()
head = (f"---\ntype: {ptype}\ntitle: Gate proof {tag}\ntimestamp: {today}\n---\n\n"
        f"# Gate proof {tag}\n\nSeeded by the gate proof. Listed in the [catalog](index.md).\n")
broken = head + f"\nSee [the missing page](gate-proof-missing-{tag}.md).\n"
index_before = open(os.path.join(KB, index), encoding="utf-8").read()
index_after = index_before.rstrip("\n") + f"\n- [Gate proof {tag}](gate-proof-{tag}.md): seeded by the gate proof ({today})\n"
commit_tool = os.path.join(KB, "bin", "wiki-commit")
if not os.path.isfile(commit_tool):
    commit_tool = os.path.join(os.path.dirname(HERE), "bin", "wiki-commit")


def write(rel, text):
    with open(os.path.join(KB, rel), "w", encoding="utf-8") as fh:
        fh.write(text)


def read(rel):
    return open(os.path.join(KB, rel), encoding="utf-8").read()


def commit(msg, *paths):
    r = subprocess.run([sys.executable, commit_tool, "--root", KB, "-m", msg, *paths],
                       cwd=KB, capture_output=True, text=True, env=ENV)
    return r.returncode, r.stdout + r.stderr


def head_sha():
    return git(KB, "rev-parse", "HEAD").stdout.strip()


def refused(label, tokens, paths, expect):
    base = head_sha()
    rc, out = commit(f"gate-proof: {label}", *paths)
    named = sorted({l.strip() for l in out.splitlines()
             if f"gate-proof-{tag}" in l and any(l.strip().startswith(t) for t in tokens)})
    if rc == 0:
        fail(f"{label}: the commit was accepted", out)
    if not named:
        fail(f"{label}: refused, but not for the seeded fault", out)
    if head_sha() != base:
        fail(f"{label}: HEAD moved on a refused commit")
    for rel, text in expect.items():
        if read(rel) != text:
            fail(f"{label}: the edit to {rel} was not preserved")
    ok(f"{label}: refused, HEAD unchanged, edits preserved")
    for l in named[:3]:
        print(f"        {l}")


base = head_sha()
write(page, broken)
write(index, index_after)
refused("page with a broken link", ("BROKEN",), (page, index), {page: broken, index: index_after})

write(page, head)
write(index, index_before)
if gated:
    refused("repaired page that nothing links to", ("ORPHAN", "UNINDEXED"), (page,),
            {page: head, index: index_before})
else:
    print("skip  unlinked page: this wiki does not gate orphans or unindexed pages "
          "(advisory_budgets)")

write(index, index_after)
rc, out = commit("gate-proof: linked page", page, index)
if rc != 0:
    fail("linked page: the repaired commit was refused", out)
new = head_sha()
if new == base or git(KB, "rev-parse", "HEAD~1").stdout.strip() != base:
    fail("linked page: expected exactly one new commit")
names = git(KB, "show", "--name-only", "--format=", "HEAD").stdout.split()
if page not in names or index not in names:
    fail("linked page: the commit does not carry the page and its index entry", "\n".join(names))
ok(f"linked page: committed {new[:8]} with the page and its index entry")

log = os.path.join(KB, ".git", "wiki-gate.log")
if os.path.isfile(log):
    rows = [l.rstrip("\n").split("\t") for l in open(log, encoding="utf-8")]
    want = 2 if gated else 1
    n_ref = sum(1 for r in rows if len(r) == 5 and r[2] == "refused")
    n_com = sum(1 for r in rows if len(r) == 5 and r[2] == "committed")
    if n_ref != want or n_com != 1:
        fail(f"gate log: expected {want} refusals and 1 commit, found {n_ref} and {n_com}")
    ok(f"gate log: {n_ref} refusals and 1 commit recorded")
    for r in rows:
        print(f"        {r[2]:<9} {r[3] or '-':<20} {r[4]}")
else:
    print("skip  gate log: this wiki's pre-commit hook does not write one")

proven = "broken link" + (", unlinked page" if gated else "")
print(f"PROVEN ({proven}); {SRC} was not written")
cleanup()
