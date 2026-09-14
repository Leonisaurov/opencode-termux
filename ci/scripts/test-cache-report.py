#!/usr/bin/env python3
"""Tests for the cache usage report (no network)."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci/scripts/cache-report.py"
SPEC = importlib.util.spec_from_file_location("cache_report", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CacheReportTests(unittest.TestCase):
    def test_parse_paginated_json_objects(self):
        pages = (
            '{"total_count": 2, "actions_caches": [{"key": "a", "size_in_bytes": 1}]}'
            '{"total_count": 2, "actions_caches": [{"key": "b", "size_in_bytes": 2}]}'
        )
        entries = MODULE.parse_pages(pages)
        self.assertEqual([entry["key"] for entry in entries], ["a", "b"])

    def test_reports_duplicates_and_total(self):
        entries = [
            {"key": "ci-cache-v2-toolchain-ndk", "size_in_bytes": 100},
            {"key": "ci-cache-v2-toolchain-ndk", "size_in_bytes": 300},
            {"key": "ci-cache-v2-bun", "size_in_bytes": 50},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "caches.json"
            path.write_text(json.dumps({"actions_caches": entries}))
            result = subprocess.run(
                ["python3", str(SCRIPT), "--input", str(path)],
                text=True,
                capture_output=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("entries=3", result.stdout)
        self.assertIn("duplicate keys", result.stdout)
        self.assertIn("x2", result.stdout)
        self.assertIn("ci-cache-v2-toolchain-ndk", result.stdout)


if __name__ == "__main__":
    unittest.main()
