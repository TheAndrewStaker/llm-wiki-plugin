#!/usr/bin/env python3
"""Immutably stage a local source and append its provenance to the ingest ledger."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


def digest(path):
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
            size += len(block)
    return sha.hexdigest(), size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("WIKI_ROOT", "~/wiki"))
    parser.add_argument("--source", required=True, help="local file to copy or register")
    parser.add_argument("--destination", required=True, help="path under sources/ in the wiki")
    parser.add_argument("--source-ref", help="non-secret URL or label; defaults to input basename")
    args = parser.parse_args()
    root = Path(args.root).expanduser().resolve()
    source = Path(args.source).expanduser().resolve()
    destination = (root / args.destination).resolve()
    sources = (root / "sources").resolve()
    if not source.is_file():
        parser.error(f"source is not a file: {source}")
    if sources != destination.parent and sources not in destination.parents:
        parser.error("destination must be below sources/")

    source_hash, source_size = digest(source)
    if destination.exists():
        existing_hash, existing_size = digest(destination)
        if (existing_hash, existing_size) != (source_hash, source_size):
            parser.error(f"immutable destination already exists with different bytes: {destination}")
        disposition = "already-staged"
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
        disposition = "staged"
        try:
            shutil.copyfile(source, temporary)
            if digest(temporary) != (source_hash, source_size):
                raise OSError("copy verification failed")
            try:
                os.link(temporary, destination)
            except FileExistsError:
                if digest(destination) != (source_hash, source_size):
                    parser.error(
                        f"immutable destination appeared concurrently with different bytes: {destination}"
                    )
                disposition = "already-staged"
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    ledger = root / ".compendium" / "ingest-ledger.jsonl"
    ledger.parent.mkdir(parents=True, exist_ok=True)
    relative = destination.relative_to(root).as_posix()
    record = {
        "bytes": source_size,
        "destination": relative,
        "sha256": source_hash,
        "source_ref": args.source_ref or source.name,
        "staged_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
    }
    previous = set()
    if ledger.exists():
        for line in ledger.read_text(encoding="utf-8").splitlines():
            try:
                item = json.loads(line)
                previous.add((item.get("destination"), item.get("sha256")))
            except json.JSONDecodeError:
                print(f"stage-source: malformed ledger line in {ledger}", file=sys.stderr)
                return 2
    if (relative, source_hash) not in previous:
        with ledger.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
    print(json.dumps({**record, "disposition": disposition}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
