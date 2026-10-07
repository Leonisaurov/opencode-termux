#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OPENCODE_BUNDLER = ROOT / "opencode/scripts/build-opencode-android.ts"
KILO_BUNDLER = ROOT / "kilo/scripts/build-kilo-android.ts"
OPENCODE_BUILD = ROOT / "opencode/scripts/build-opencode.sh"
MODULE_GRAPH_PATCH = ROOT / "ci/scripts/module-graph-patch.ts"
BUNDLE_VALIDATOR = ROOT / "ci/scripts/validate-android-bundle.py"
KILO_BUILD = ROOT / "kilo/scripts/build.sh"
KILO_ZIG_MANIFEST = ROOT / "opentui/src/kilo/packages/core/src/zig/build.zig.zon"
OPENCODE_WORKER = ROOT / "opencode/src/packages/opencode/src/cli/tui/worker.ts"
OPENCODE_ENTRY = ROOT / "opencode/src/packages/cli/src/index.ts"
KILO_WORKER = ROOT / "kilo/src/packages/opencode/src/cli/tui/worker.ts"
UUCODE_PACKAGE = ROOT / (
    "opentui/src/kilo/packages/core/src/zig/zig-pkg/"
    "uucode-0.1.0-ZZjBPtA_TQCWp5PIKmfm5tu1WOkKWFmBGFEMxircPfkA"
)


def main() -> None:
    opencode = OPENCODE_BUNDLER.read_text(encoding="utf-8")
    kilo = KILO_BUNDLER.read_text(encoding="utf-8")
    opencode_build = OPENCODE_BUILD.read_text(encoding="utf-8")
    kilo_build = KILO_BUILD.read_text(encoding="utf-8")
    module_graph_patch = MODULE_GRAPH_PATCH.read_text(encoding="utf-8")
    bundle_validator = BUNDLE_VALIDATOR.read_text(encoding="utf-8")
    manifest = KILO_ZIG_MANIFEST.read_text(encoding="utf-8")

    assert MODULE_GRAPH_PATCH.is_file()
    assert BUNDLE_VALIDATOR.is_file()
    assert 'conditions: ["bun", "node"]' in opencode
    assert 'conditions: ["browser"]' not in opencode
    assert 'patchAndroidModuleGraph' in opencode
    assert 'validateAndroidStandalone' in opencode
    assert 'patchAndroidModuleGraph' in kilo
    assert 'validateAndroidStandalone' in kilo
    assert 'const workerPath = "./src/cli/tui/worker.ts"' in kilo

    # OpenCode v2: the CLI entrypoint is the only graph entrypoint; the worker,
    # migration and models-snapshot defines of the 1.18 pipeline must not come
    # back, and the Bionic-incompatible native bindings are stubbed.
    assert 'entrypoints: ["./src/index.ts"]' in opencode
    assert "workerPath" not in opencode
    assert "OPENCODE_WORKER_PATH" not in opencode
    assert "OTUI_TREE_SITTER_WORKER_PATH" not in opencode
    assert "OPENCODE_MIGRATIONS" not in opencode
    assert "models-snapshot" not in opencode
    assert 'virtual:opencode-app-assets' in opencode
    assert 'export default undefined' in opencode
    assert 'persistent-pty' in opencode
    assert '"process.env.OPENTUI_LIBC"' in opencode
    assert OPENCODE_ENTRY.is_file()
    assert not OPENCODE_WORKER.exists()
    assert KILO_WORKER.is_file()

    restore = 'if [ -n "$BUILT_SO" ] && [ -f "$BUILT_SO" ]; then'
    fallback = 'elif [ ! -f "$TARGET_SO" ]; then'
    assert restore in kilo_build
    assert fallback in kilo_build
    assert kilo_build.index(restore) < kilo_build.index(fallback)
    assert 'ci/scripts/module-graph-patch.ts' in opencode_build
    assert 'ci/scripts/module-graph-patch.ts' in kilo_build
    assert 'OPENCODE_PKG="$OPENCODE_SRC/packages/cli"' in opencode_build
    assert '--os="*" --cpu="*"' in opencode_build
    assert "@opentui/core-linux-arm64/libopentui.so" in opencode_build
    assert 'module graph still contains' in module_graph_patch
    assert 'total_byte_count does not match file size' in module_graph_patch
    assert 'module graph contains vulnerable' in bundle_validator
    assert 'python3 ci/scripts/validate-android-bundle.py' in (ROOT / ".github/workflows/build-opencode.yml").read_text(encoding="utf-8")
    assert 'python3 ci/scripts/validate-android-bundle.py' in (ROOT / ".github/workflows/build-kilo.yml").read_text(encoding="utf-8")
    for workflow in ("build-bun.yml", "build-bun-target.yml", "build-opencode.yml"):
        workflow_text = (ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8")
        assert "ci/scripts/test-android-heap-tagging.py" in workflow_text

    assert '.path = "zig-pkg/uucode-0.1.0-ZZjBPtA_TQCWp5PIKmfm5tu1WOkKWFmBGFEMxircPfkA"' in manifest
    assert ".url = \"file://" not in manifest
    assert "/data/data/" not in manifest
    assert UUCODE_PACKAGE.is_dir()


if __name__ == "__main__":
    main()
