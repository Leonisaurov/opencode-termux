#!/usr/bin/env python3
"""Verify that cache contracts are complete and shared by producers/consumers.

A product's durable cache key is computed by ``ci/scripts/cache-contract.py``
from an explicit list of paths and values. If a consumer recomputes the same
product key with a different list, its restore key never matches the producer
and the cached artifact silently stops being reused. If a build input is absent
from every list, editing it does not invalidate the cache and a stale artifact
is restored.

This test parses the workflow argument arrays and enforces both invariants
without a runner.
"""
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"

ASSIGN = re.compile(r"(\w+)=\((.+?)\)\n", re.DOTALL)
PRODUCT = re.compile(r"--product\s+(\S+)")
PATH = re.compile(r"--path\s+(\S+)")
VALUE = re.compile(r"--value\s+\"([^\"=]+)=")


def blocks(path: pathlib.Path) -> dict[str, tuple[set[str], set[str]]]:
    """Map each ``cache-contract.py`` product to its (paths, values)."""
    result: dict[str, tuple[set[str], set[str]]] = {}
    text = path.read_text(encoding="utf-8")
    for match in ASSIGN.finditer(text):
        body = match.group(2)
        product = PRODUCT.search(body)
        if not product:
            continue
        paths = set(PATH.findall(body))
        values = set(VALUE.findall(body))
        result.setdefault(product.group(1), (paths, values))
    return result


def main() -> None:
    core = blocks(WORKFLOWS / "build-core.yml")
    bun = blocks(WORKFLOWS / "build-bun.yml")
    opencode = blocks(WORKFLOWS / "build-opencode.yml")
    opentui = blocks(WORKFLOWS / "build-opentui.yml")
    kilo = blocks(WORKFLOWS / "build-kilo.yml")
    codex = blocks(WORKFLOWS / "build-codex.yml")
    rusty = blocks(WORKFLOWS / "build-rusty-v8-android.yml")

    # Every producer of a product must use the same path and value sets as the
    # consumer, otherwise the recomputed restore key diverges.
    def same(product: str, ref: dict, others: list[dict]) -> None:
        paths, values = ref[product]
        for other in others:
            assert other[product][0] == paths, f"{product}: path contract mismatch"
            assert other[product][1] == values, f"{product}: value contract mismatch"

    same("bun-core", core, [bun, opencode])
    same("bun", bun, [opencode])
    same("opentui", opentui, [opencode])

    # The vendored source trees must be part of their product keys so a port
    # edit invalidates the artifact even when the upstream pin is unchanged.
    assert "OPENTUI_SOURCE_TREE" in opentui["opentui"][1]
    assert "OPENTUI_SOURCE_TREE" in opencode["opentui"][1]
    assert "KILO_SOURCE_TREE" in kilo["kilo"][1]
    assert "KILO_OPENTUI_SOURCE_TREE" in kilo["kilo"][1]
    opcode_paths, opcode_values = opencode["opencode"]
    assert "ci/scripts/patch-opentui-core-runtime.py" in opcode_paths
    assert "ci/scripts/module-graph-patch.ts" in opcode_paths
    assert "OPENCODE_SOURCE_COMMIT" in opcode_values
    # ci/source-manifest.json aggregates every product commit. Including it in a
    # per-product key makes an unrelated product change invalidate this cache,
    # so keys must rely on the product's own source tree/commit instead.
    for group in (core, bun, opentui, opencode, kilo):
        for product, (paths, _values) in group.items():
            assert "ci/source-manifest.json" not in paths, f"{product}: global manifest in cache key"

    # Rusty V8 and Codex are contract-driven producers too.
    assert "rusty-v8" in rusty, "rusty-v8 cache contract missing"
    assert "codex" in codex, "codex cache contract missing"
    assert "V8_VERSION" in rusty["rusty-v8"][1]
    assert "CODEX_REF" in codex["codex"][1]
    assert "V8_VERSION" in codex["codex"][1]

    # The NDK must use one shared absolute path so actions/cache (which versions
    # by path string) stores a single entry instead of one per product workspace.
    # It lives under the gitignored `.ci/` so clean-tree checks stay intact.
    shared = "${{ github.workspace }}/.ci/android-ndk"
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        for value in re.findall(r"ANDROID_NDK_HOME:\s*['\"]?(.+?)['\"]?\s*$", text, re.MULTILINE):
            assert value == shared, f"{workflow.name}: NDK path is not shared: {value}"
    assert "path: ${{ env.ANDROID_NDK_HOME }}" in (WORKFLOWS / "build-core.yml").read_text()

    # The Zig toolchain must also use one shared path; only the prefix-restored
    # intermediate Zig compiler caches stay per product.
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        assert "${{ env.WORK_DIR }}/zig-${{ env.ZIG_VERSION }}" not in text, (
            f"{workflow.name}: per-product Zig toolchain path"
        )
    setup = (ROOT / "ci/scripts/setup-runner.sh").read_text(encoding="utf-8")
    assert "${GITHUB_WORKSPACE}/.ci/zig-${ZIG_VERSION}" in setup

    # The orchestrator must wire both producers and include Codex in publish.
    android = (WORKFLOWS / "build-android.yml").read_text(encoding="utf-8")
    assert "rusty_v8: ${{ steps.changes.outputs.build_rusty_v8 }}" in android
    assert "codex: ${{ steps.changes.outputs.build_codex }}" in android
    assert "for product in core opentui bun opencode kilo rusty_v8 codex; do" in android
    assert "uses: ./.github/workflows/build-rusty-v8-android.yml" in android
    assert "uses: ./.github/workflows/build-codex.yml" in android
    assert "needs: [detect, bun, opentui, opencode, kilo, codex]" in android


if __name__ == "__main__":
    main()
