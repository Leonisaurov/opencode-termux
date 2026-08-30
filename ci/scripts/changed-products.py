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
GRAPH_PRODUCTS = ("core", "opentui", "bun", "opencode", "kilo", "rusty_v8", "codex")


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


def affected_products(changed: set[str]) -> set[str]:
    """Expand direct changes into the same-run producer dependency graph.

    The orchestrator passes artifacts between jobs in one run. A consumer
    therefore cannot run alone when one of its producers is selected: the
    producer must be selected as well. This is deliberately conservative for
    Bun and OpenTUI because both runtimes are embedded into standalone outputs.
    """
    if not changed:
        return set()
    if set(PRODUCTS).issubset(changed):
        return set(GRAPH_PRODUCTS)

    affected: set[str] = set()
    if "bun" in changed:
        # OpenCode always consumes an OpenTUI artifact from this run, even
        # when the OpenTUI source itself did not change. Selecting the
        # producer avoids a skipped `needs` edge; its exact cache normally
        # makes this a no-op.
        affected.update({"core", "bun", "opentui", "opencode", "kilo"})
    if "opentui" in changed:
        affected.update({"core", "bun", "opentui", "opencode", "kilo"})
    if "opencode" in changed:
        affected.update({"core", "bun", "opentui", "opencode"})
    if "kilo" in changed:
        affected.update({"core", "bun", "kilo"})
    if "codex" in changed:
        affected.update({"rusty_v8", "codex"})
    return affected


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
    parser.add_argument(
        "--graph",
        action="store_true",
        help="emit producer/consumer closure for the Android workflow DAG",
    )
    args = parser.parse_args()
    direct = classify(changed_paths(args.root, args.base, args.head))
    products = sorted(affected_products(direct) if args.graph else direct)
    value = ",".join(products)
    if args.format == "github":
        print(f"changed_products={value}")
        prefix = "build_" if args.graph else "changed_"
        names = GRAPH_PRODUCTS if args.graph else PRODUCTS
        for product in names:
            print(f"{prefix}{product}={'true' if product in products else 'false'}")
    else:
        print(value or "none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
