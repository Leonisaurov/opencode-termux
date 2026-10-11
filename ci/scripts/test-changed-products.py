#!/usr/bin/env python3
"""Regression tests for conservative product change classification."""

import importlib.util
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("changed_products", ROOT / "scripts/changed-products.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def main() -> None:
    assert MODULE.classify(["bun/src/file.cc"]) == {"bun"}
    assert MODULE.classify(["opentui/src/opencode/packages/native/src/renderer.zig"]) == {"opentui"}
    assert MODULE.classify(["opentui/src/kilo/packages/core/src/zig/renderer.zig"]) == {"opentui"}
    assert MODULE.classify(["ci/source-manifest.json"]) == set(MODULE.PRODUCTS)
    assert MODULE.classify(["opencode/src/index.ts", "kilo/scripts/build.sh"]) == {"opencode", "kilo"}
    assert MODULE.classify(["ci/scripts/env.sh"]) == set(MODULE.PRODUCTS)
    assert MODULE.classify([".github/workflows/build-bun.yml"]) == set(MODULE.PRODUCTS)
    assert MODULE.classify(["README.md"]) == set()
    # Una ruta fuera del grafo de productos no selecciona nada: es lo que protege
    # de que un producto jubilado o ajeno vuelva a colarse en el DAG del stack.
    assert MODULE.classify(["retired/src/crate/Cargo.lock"]) == set()
    assert MODULE.affected_products({"bun"}) == {"core", "bun", "opentui", "kilo"}
    # Un cambio en Bun ya no arrastra a OpenCode: este lane consume el runtime
    # publicado y fijado en el lock externo, así que la única arista que necesita
    # viva en el DAG es la del .so de OpenTUI.
    assert MODULE.affected_products({"opencode"}) == {"opentui", "opencode"}
    assert MODULE.affected_products({"opentui"}) == {"core", "bun", "opentui", "opencode", "kilo"}
    assert MODULE.affected_products(set(MODULE.PRODUCTS)) == set(MODULE.GRAPH_PRODUCTS)
    android = yaml.safe_load((ROOT.parent / ".github/workflows/build-android.yml").read_text(encoding="utf-8"))
    jobs = android["jobs"]
    # OpenCode ya no tiene arista con el job bun: consume el runtime publicado
    # del lock externo. Kilo conserva la suya.
    assert jobs["opencode"]["needs"] == ["detect", "opentui"], "opencode: unexpected DAG producers"
    assert "bun_version" not in jobs["opencode"]["with"], "opencode: era-Zig Bun input still wired"
    assert "bun" in jobs["kilo"]["needs"], "kilo: lost its Bun producer edge"
    print("changed-products tests: OK")


if __name__ == "__main__":
    main()
