#!/usr/bin/env python3
"""Report GitHub Actions cache usage for this repository.

Usage:
    python3 ci/scripts/cache-report.py                 # query with gh
    python3 ci/scripts/cache-report.py --input list.json

The GitHub cache quota is 10 GiB per repository. When exceeded, entries are
evicted by least-recent use, which turns a warm build cold without warning.
The report prints total usage, the largest entries, and keys that appear more
than once. ``actions/cache`` versions a key by the cached *path string*, so
several jobs caching the same logical key under different paths (for example one
Android NDK per product workspace) keep one large copy per path.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
from collections import defaultdict

GIB = 1024 ** 3
QUOTA_GIB = 10


def parse_pages(raw: str) -> list[dict]:
    """GitHub pagination concatenates JSON objects; parse them one by one."""
    entries: list[dict] = []
    decoder = json.JSONDecoder()
    index = 0
    while index < len(raw):
        chunk, end = decoder.raw_decode(raw, index)
        entries.extend(chunk.get("actions_caches", []))
        index = end
        while index < len(raw) and raw[index] in " \n\r\t":
            index += 1
    return entries


def load(args: argparse.Namespace) -> list[dict]:
    if args.input:
        return json.loads(args.input.read_text(encoding="utf-8"))["actions_caches"]
    raw = subprocess.check_output(
        ["gh", "api", "--paginate", f"repos/{args.repo}/actions/caches?per_page=100"],
        text=True,
    )
    return parse_pages(raw)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="Leonisaurov/opencode-termux")
    parser.add_argument("--input", type=pathlib.Path)
    parser.add_argument("--top", type=int, default=15)
    args = parser.parse_args()

    entries = load(args)
    total = sum(entry["size_in_bytes"] for entry in entries)
    print(f"entries={len(entries)} total={total / GIB:.2f} GiB quota={QUOTA_GIB} GiB")
    if total > QUOTA_GIB * GIB:
        print("WARNING: over quota; expect LRU eviction of older caches.")

    print(f"\nlargest {args.top}:")
    for entry in sorted(entries, key=lambda e: e["size_in_bytes"], reverse=True)[: args.top]:
        print(f"  {entry['size_in_bytes'] / GIB:6.2f} GiB  {entry['key']}")

    groups: dict[str, list[dict]] = defaultdict(list)
    for entry in entries:
        groups[entry["key"]].append(entry)
    duplicates = {key: items for key, items in groups.items() if len(items) > 1}
    if duplicates:
        print("\nduplicate keys (same key, multiple path versions):")
        for key, items in sorted(duplicates.items(), key=lambda kv: -sum(i["size_in_bytes"] for i in kv[1])):
            wasted = sum(i["size_in_bytes"] for i in items[1:])
            print(f"  x{len(items)} (wastes {wasted / GIB:.2f} GiB)  {key}")
    else:
        print("\nno duplicate keys")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
