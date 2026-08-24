#!/usr/bin/env python3
"""Fast regression tests for the content-addressed build state helper."""

import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "scripts" / "build-state.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["python3", str(STATE), *args], cwd=ROOT, text=True, capture_output=True)


def main() -> None:
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
    print("build-state tests: OK")


if __name__ == "__main__":
    main()
