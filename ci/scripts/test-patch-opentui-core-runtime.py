#!/usr/bin/env python3
"""Contract tests for the @opentui/core runtime guard verifier (no network/builds).

Fixtures are taken verbatim from the published @opentui/core@0.5.14 chunks
(chunk-bun-sjw2d9bq.js / chunk-node-80p7e6t6.js) and from the archived 0.4.5
unguarded layout, so the verifier is pinned to the real published text.
"""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "patch_opentui_core_runtime", ROOT / "ci/scripts/patch-opentui-core-runtime.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

# Extracto literal del runtime 0.5.14: preambulo !bun + secuencia protegida.
V0514_RUNTIME = """async function resolveBundledFilePath2(key, loadBundledFile, fallbackPath, metaUrl, options = {}) {
  if (options.useAssetRoot ?? true) {
    const configuredPath = resolveAssetRootPath(key);
    if (configuredPath !== undefined) {
      return configuredPath;
    }
  }
  if (!bun) {
    const path = resolveFallbackFilePath(fallbackPath, metaUrl);
    if (existsSync(path)) {
      return path;
    }
    return await loadBundledFilePath(loadBundledFile, metaUrl, options.loadBundledFileFallback ?? false) ?? path;
  }
  const loaded = (await loadBundledFile()).default;
  if (typeof loaded !== "string") {
    return resolveFallbackFilePath(fallbackPath, metaUrl);
  }
  return normalizeLoadedFilePath(loaded, metaUrl);
}
"""

# Extracto del layout 0.4.5 publicado (sin guard) — debe parchearse.
V045_RUNTIME = """  if (!bun) {
    const path = resolveFallbackFilePath(fallbackPath, metaUrl);
    if (existsSync(path)) {
      return path;
    }
    return await loadBundledFilePath(loadBundledFile, metaUrl, options.loadBundledFileFallback ?? false) ?? path;
  }
  return normalizeLoadedFilePath((await loadBundledFile()).default, metaUrl);
}
"""


class OpentuiRuntimeGuardTests(unittest.TestCase):
    def test_0514_chunk_is_verified_without_change(self):
        text, status = MODULE.patch_text(V0514_RUNTIME)
        self.assertEqual(status, "verified")
        self.assertEqual(text, V0514_RUNTIME)

    def test_0514_guarded_sequence_matches_upstream(self):
        # El GUARDED del verificador es el texto real publicado por upstream.
        self.assertIn(MODULE.GUARDED, V0514_RUNTIME)

    def test_045_unguarded_layout_is_patched(self):
        text, status = MODULE.patch_text(V045_RUNTIME)
        self.assertEqual(status, "patched")
        self.assertIn(MODULE.GUARDED, text)
        self.assertNotIn(MODULE.UNGUARDED, text)

    def test_patch_is_idempotent(self):
        patched, _ = MODULE.patch_text(V045_RUNTIME)
        again, status = MODULE.patch_text(patched)
        self.assertEqual(status, "verified")
        self.assertEqual(again, patched)

    def test_unknown_runtime_layout_is_unexpected(self):
        text, status = MODULE.patch_text("function resolveBundledFilePath() { return 1 }\n")
        self.assertEqual(status, "unexpected")
        self.assertEqual(text, "function resolveBundledFilePath() { return 1 }\n")

    def test_irrelevant_chunk_is_skipped(self):
        text, status = MODULE.patch_text("const unrelated = true\n")
        self.assertEqual(status, "irrelevant")
        self.assertEqual(text, "const unrelated = true\n")

    def test_main_succeeds_on_0514_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            core = pathlib.Path(tmp) / "node_modules" / "@opentui" / "core"
            core.mkdir(parents=True)
            (core / "chunk-bun-abc123.js").write_text(V0514_RUNTIME, encoding="utf-8")
            (core / "chunk-node-def456.js").write_text(V0514_RUNTIME, encoding="utf-8")
            (core / "chunk-bun-j2z63cdy.js").write_text("const unrelated = true\n", encoding="utf-8")
            rc = MODULE.main(["--root", tmp])
            self.assertEqual(rc, 0)

    def test_main_patches_045_tree_in_place(self):
        with tempfile.TemporaryDirectory() as tmp:
            core = pathlib.Path(tmp) / "node_modules" / "@opentui" / "core"
            core.mkdir(parents=True)
            target = core / "chunk-bun-old000.js"
            target.write_text(V045_RUNTIME, encoding="utf-8")
            rc = MODULE.main(["--root", tmp])
            self.assertEqual(rc, 0)
            self.assertIn(MODULE.GUARDED, target.read_text(encoding="utf-8"))

    def test_main_fails_on_unrecognised_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            core = pathlib.Path(tmp) / "node_modules" / "@opentui" / "core"
            core.mkdir(parents=True)
            (core / "chunk-bun-new999.js").write_text(
                "async function resolveBundledFilePath(key) { await loadBundledFile() }\n",
                encoding="utf-8",
            )
            self.assertEqual(MODULE.main(["--root", tmp]), 1)

    def test_main_fails_without_chunks(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(MODULE.main(["--root", tmp]), 1)


if __name__ == "__main__":
    unittest.main()
