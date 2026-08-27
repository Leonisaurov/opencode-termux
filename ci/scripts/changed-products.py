#!/usr/bin/env python3
"""Classify changed paths into the Android build products they can affect.

This is intentionally conservative: shared CI code and workflow changes
invalidate every product. The result is a planning hint, never permission to
skip a producer whose validated output is unavailable.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import PurePosixPath

PRODUCTS = ("bun", "opentui", "opencode", "kilo", "codex")


def classify(paths: list[str]) -> set[str]:
    changed = set()
    for raw in paths:
        path = PurePosixPath(raw)
        parts = path.parts
        if not parts:
            continue
        if parts[0] in {"ci", ".github", "releases"}:
            return set(PRODUCTS)
        if parts[0] in PRODUCTS:
            changed.add(parts[0])
    return changed


def changed_paths(root: str, base: str, head: str) -> list[str]:
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=ACMRTUXB", base, head],
            cwd=root, text=True, capture_output=True, check=True,
        )
    except subprocess.CalledProcessError:
        # Shallow or initial checkouts may not have the requested base. Treat
        # that as an all-products change so a missing comparison can never
        # suppress a required producer.
        return ["ci"]
    return [line for line in result.stdout.splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--base", default="HEAD^")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--format", choices=["plain", "github"], default="plain")
    args = parser.parse_args()
    products = sorted(classify(changed_paths(args.root, args.base, args.head)))
    value = ",".join(products)
    if args.format == "github":
        print(f"changed_products={value}")
        for product in PRODUCTS:
            print(f"changed_{product}={'true' if product in products else 'false'}")
    else:
        print(value or "none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
