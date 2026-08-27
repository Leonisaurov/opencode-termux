#!/usr/bin/env python3
"""Regression tests for conservative product change classification."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("changed_products", ROOT / "scripts/changed-products.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def main() -> None:
    assert MODULE.classify(["bun/src/file.cc"]) == {"bun"}
    assert MODULE.classify(["opentui/patches/android.patch"]) == {"opentui"}
    assert MODULE.classify(["opencode/src/index.ts", "kilo/scripts/build.sh"]) == {"opencode", "kilo"}
    assert MODULE.classify(["codex/src/codex-rs/Cargo.lock"]) == {"codex"}
    assert MODULE.classify(["ci/scripts/env.sh"]) == set(MODULE.PRODUCTS)
    assert MODULE.classify([".github/workflows/build-bun.yml"]) == set(MODULE.PRODUCTS)
    assert MODULE.classify(["README.md"]) == set()
    print("changed-products tests: OK")


if __name__ == "__main__":
    main()
