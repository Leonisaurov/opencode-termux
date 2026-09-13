#!/usr/bin/env python3
"""Contract tests for the @opentui/core runtime patch (no network/builds)."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "patch_opentui_core_runtime", ROOT / "ci/scripts/patch-opentui-core-runtime.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OpentuiRuntimePatchTests(unittest.TestCase):
    def test_old_block_is_patched(self):
        text, changed = MODULE.patch_text(MODULE.OLD)
        self.assertTrue(changed)
        self.assertIn(MODULE.NEW, text)
        self.assertNotIn(MODULE.OLD, text)

    def test_patch_is_idempotent(self):
        patched, _ = MODULE.patch_text(MODULE.OLD)
        again, changed = MODULE.patch_text(patched)
        self.assertFalse(changed)
        self.assertEqual(again, patched)

    def test_unexpected_layout_is_left_alone(self):
        text, changed = MODULE.patch_text("const unrelated = true\n")
        self.assertFalse(changed)
        self.assertEqual(text, "const unrelated = true\n")


if __name__ == "__main__":
    unittest.main()
