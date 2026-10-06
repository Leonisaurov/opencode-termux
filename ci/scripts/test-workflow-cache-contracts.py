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

    # The value parity above compares option *names*, so two workflows can share
    # a contract and still compute different digests: cache-contract.py embeds
    # env ZIG_VERSION, and OpenTUI 0.5.14 pins its own compiler in build.zig
    # while Bun/core keep the previous one. Zig is therefore a per-product
    # toolchain, and the consumer must recompute each product with the literal
    # version its producer runs, or the restore key never matches.
    def zig_versions(name: str) -> dict[str, str]:
        text = (WORKFLOWS / name).read_text(encoding="utf-8")
        return dict(re.findall(r"^\s*((?:BUN_)?ZIG_VERSION):\s*['\"]([\w.]+)['\"]", text, re.MULTILINE))

    opentui_zig = zig_versions("build-opentui.yml")["ZIG_VERSION"]
    assert zig_versions("build-opencode.yml")["ZIG_VERSION"] == opentui_zig, \
        "build-opencode.yml: OpenTUI consumed with a different Zig than its producer"
    bun_zig = zig_versions("build-core.yml")["ZIG_VERSION"]
    assert zig_versions("build-bun.yml")["ZIG_VERSION"] == bun_zig, "core and bun Zig diverged"
    assert zig_versions("build-opencode.yml")["BUN_ZIG_VERSION"] == bun_zig, \
        "build-opencode.yml: BUN_ZIG_VERSION does not match the bun producers"
    assert bun_zig != opentui_zig, "Bun and OpenTUI must pin distinct Zig versions"
    # The consumer overrides the env only for the products rebuilt by Bun/core.
    assert 'ZIG_VERSION="$BUN_ZIG_VERSION" python3 ci/scripts/cache-contract.py' in (
        WORKFLOWS / "build-opencode.yml").read_text(encoding="utf-8"), "core/bun keys: no Zig override"
    assert 'UPSTREAM_COMMIT="$OPENTUI_COMMIT" python3 ci/scripts/cache-contract.py' in (
        WORKFLOWS / "build-opencode.yml").read_text(encoding="utf-8"), "opentui_key: unexpected Zig override"

    # OpenTUI 0.5.14 moved its native tree to packages/native; the older
    # checkout still built for Kilo keeps packages/core. The stack that publishes
    # libopentui.so must reference only the new layout.
    for name in ("build-opentui.yml", "build-opencode.yml"):
        text = (WORKFLOWS / name).read_text(encoding="utf-8")
        assert "packages/native/lib" in text, f"{name}: native lib layout missing"
        assert "packages/core/src/lib" not in text, f"{name}: stale OpenTUI lib layout"
    consumer = (ROOT / "opencode/scripts/build-opencode.sh").read_text(encoding="utf-8")
    assert "packages/native/lib" in consumer and "packages/core/src/lib" not in consumer

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

    # Codex and its Rusty V8 dependency are not products of this repository:
    # they build in Leonisaurov/codex-termux. Keeping them out here is an
    # invariant, so re-adding either producer must fail this check.
    for retired in ("build-codex.yml", "build-rusty-v8-android.yml"):
        assert not (WORKFLOWS / retired).exists(), f"{retired}: Codex producer in this repository"

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

    # The orchestrator wires the four stack products and nothing else.
    android = (WORKFLOWS / "build-android.yml").read_text(encoding="utf-8")
    assert "rusty_v8" not in android, "build-android.yml: Rusty V8 re-wired into the stack"
    assert "codex" not in android, "build-android.yml: Codex re-wired into the stack"
    assert "for product in core opentui bun opencode kilo; do" in android
    assert "needs: [detect, bun, opentui, opencode, kilo]" in android


if __name__ == "__main__":
    main()
