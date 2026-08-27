#!/usr/bin/env python3
"""Fast regression tests for the content-addressed build state helper."""

import json
import os
import subprocess
import tempfile
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "scripts" / "build-state.py"
CACHE_CONTRACT = ROOT / "scripts" / "cache-contract.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["python3", str(STATE), *args], cwd=ROOT, text=True, capture_output=True)


def main() -> None:
    os.environ.setdefault("TMPDIR", "/data/data/com.termux/files/usr/tmp")
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
        root = Path(directory)
        source = root / "source.txt"
        output = root / "output.txt"
        source.write_text("one\n", encoding="utf-8")
        command = ["python3", "-c", "from pathlib import Path; Path('output.txt').write_text(Path('source.txt').read_text())"]
        base = ["run", "--root", str(root), "--state-dir", "state", "--node", "demo", "--input", "source.txt", "--output", "output.txt", "--"] + command
        first = subprocess.run(["python3", str(STATE), *base], cwd=root, text=True, capture_output=True)
        assert "BUILD_STATE=miss" in first.stdout, first.stderr
        second = subprocess.run(["python3", str(STATE), *base], cwd=root, text=True, capture_output=True)
        assert "BUILD_STATE=hit" in second.stdout, second.stderr
        source.write_text("two\n", encoding="utf-8")
        third = subprocess.run(["python3", str(STATE), *base], cwd=root, text=True, capture_output=True)
        assert "BUILD_STATE=miss" in third.stdout, third.stderr
        manifest = json.loads((root / "state/nodes/demo.json").read_text(encoding="utf-8"))
        assert manifest["status"] == "valid"
        assert manifest["outputs"]

        child = [
            "run", "--root", str(root), "--state-dir", "state", "--node", "child",
            "--dep", "state/nodes/demo.json", "--output", "child.txt", "--",
            "python3", "-c", "from pathlib import Path; Path('child.txt').write_text('child')",
        ]
        child_first = subprocess.run(["python3", str(STATE), *child], cwd=root, text=True, capture_output=True)
        assert "BUILD_STATE=miss" in child_first.stdout, child_first.stderr
        source.write_text("three\n", encoding="utf-8")
        subprocess.run(["python3", str(STATE), *base], cwd=root, check=True, capture_output=True, text=True)
        child_second = subprocess.run(["python3", str(STATE), *child], cwd=root, text=True, capture_output=True)
        assert "BUILD_STATE=miss" in child_second.stdout, child_second.stderr
        status = subprocess.run(["python3", str(STATE), "status", "--root", str(root), "--state-dir", "state"], cwd=root, text=True, capture_output=True)
        assert "demo: valid" in status.stdout and "child: valid" in status.stdout, status.stderr
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
        root = Path(directory)
        source = root / "input.txt"
        output = root / "output.bin"
        source.write_text("contract\n", encoding="utf-8")
        output.write_bytes(b"artifact\n")
        base = ["--root", str(root), "--product", "demo", "--path", "input.txt", "--value", "ANDROID_API=24"]
        key = subprocess.run([sys.executable, str(CACHE_CONTRACT), "key", *base], text=True, capture_output=True, check=True)
        assert key.stdout.startswith("ci-cache-v1-demo-")
        manifest = "state/cache.json"
        output_args = ["--output", "output.bin"]
        subprocess.run([sys.executable, str(CACHE_CONTRACT), "write", *base, *output_args, "--manifest", manifest], check=True)
        valid = subprocess.run([sys.executable, str(CACHE_CONTRACT), "validate", *base, *output_args, "--manifest", manifest], text=True, capture_output=True)
        assert valid.returncode == 0 and "CACHE_CONTRACT=valid" in valid.stdout
        output.write_bytes(b"corrupt\n")
        corrupt = subprocess.run([sys.executable, str(CACHE_CONTRACT), "validate", *base, *output_args, "--manifest", manifest], text=True, capture_output=True)
        assert corrupt.returncode != 0 and "output-mismatch" in corrupt.stderr
        source.write_text("changed\n", encoding="utf-8")
        invalid = subprocess.run([sys.executable, str(CACHE_CONTRACT), "validate", *base, *output_args, "--manifest", manifest], text=True, capture_output=True)
        assert invalid.returncode != 0 and "key-mismatch" in invalid.stderr
    print("build-state tests: OK")


if __name__ == "__main__":
    main()
