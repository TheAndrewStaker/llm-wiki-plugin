#!/usr/bin/env python3
"""Vendored-engine integrity. A wiki carries its own copy of the deterministic engine so a
bare clone works with no plugin installed; nothing kept the copy honest.

Three failures, each of which has happened:

  VENDOR-MISSING   a file the manifest promises is absent. lint.sh then calls a script that
                   is not there, and the summary prints "?" for its counter rather than
                   failing, so a check silently does nothing.
  VENDOR-MODIFIED  a vendored file differs from the manifest hash. Either a local edit worth
                   upstreaming, or a partial refresh.
  VENDOR-STALE     the manifest records an older plugin version than the installed plugin.
                   Advisory: a wiki is allowed to lag, but not silently.

No manifest at all is not an error. A wiki predating vendoring, or one that deliberately
runs the plugin directly, has nothing to check.

Advisory, always exits 0. Standalone: python3 hooks/vendor-check.py [WIKI_ROOT]
Ends with: VENDOR=<missing>/<modified>/<stale|ok|->
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wikilib

KB = wikilib.resolve_root(sys.argv[1] if len(sys.argv) > 1 else None)
path = os.path.join(KB, "hooks", "VENDOR.manifest")
if not os.path.isfile(path):
    print("VENDOR=-")
    sys.exit(0)


def sha(p):
    h = hashlib.sha256()
    try:
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


declared_version = "0"
entries = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line.startswith("#") or not line:
            continue
        if line.startswith("version "):
            declared_version = line.split(None, 1)[1]
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            entries.append((parts[0], parts[1].strip()))

missing = modified = 0
for want_hash, rel in entries:
    got = sha(os.path.join(KB, rel))
    if got is None:
        print(f"  VENDOR-MISSING {rel} (the manifest promises it; a checker that calls it "
              f"will report '?' instead of failing)")
        missing += 1
    elif got != want_hash:
        print(f"  VENDOR-MODIFIED {rel}")
        modified += 1

# The plugin is only reachable when installed. A bare clone skips this half.
stale = False
plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
if plugin_root:
    pj = os.path.join(os.path.expanduser(plugin_root), ".claude-plugin", "plugin.json")
    try:
        with open(pj, encoding="utf-8") as fh:
            live = json.load(fh).get("version", "0")
        if live != declared_version:
            print(f"  VENDOR-STALE vendored from {declared_version}, plugin is {live} "
                  f"(refresh: bin/wiki-vendor --install {KB})")
            stale = True
    except (OSError, ValueError):
        pass

state = "stale" if stale else ("ok" if not (missing or modified) else "drift")
print(f"VENDOR={missing}/{modified}/{state}")
