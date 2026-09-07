#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OPENCODE_BUNDLER = ROOT / "opencode/scripts/build-opencode-android.ts"
KILO_BUNDLER = ROOT / "kilo/scripts/build-kilo-android.ts"
KILO_ZIG_MANIFEST = ROOT / "opentui/src/kilo/packages/core/src/zig/build.zig.zon"
OPENCODE_WORKER = ROOT / "opencode/src/packages/opencode/src/cli/tui/worker.ts"
KILO_WORKER = ROOT / "kilo/src/packages/opencode/src/cli/tui/worker.ts"
UUCODE_PACKAGE = ROOT / (
    "opentui/src/kilo/packages/core/src/zig/zig-pkg/"
    "uucode-0.1.0-ZZjBPtA_TQCWp5PIKmfm5tu1WOkKWFmBGFEMxircPfkA"
)


def main() -> None:
    opencode = OPENCODE_BUNDLER.read_text(encoding="utf-8")
    kilo = KILO_BUNDLER.read_text(encoding="utf-8")
    manifest = KILO_ZIG_MANIFEST.read_text(encoding="utf-8")

    assert 'const workerPath = "./src/cli/tui/worker.ts"' in opencode
    assert "./src/cli/cmd/tui/worker.ts" not in opencode
    assert 'const workerPath = "./src/cli/tui/worker.ts"' in kilo
    assert OPENCODE_WORKER.is_file()
    assert KILO_WORKER.is_file()

    assert '.path = "zig-pkg/uucode-0.1.0-ZZjBPtA_TQCWp5PIKmfm5tu1WOkKWFmBGFEMxircPfkA"' in manifest
    assert ".url = \"file://" not in manifest
    assert "/data/data/" not in manifest
    assert UUCODE_PACKAGE.is_dir()


if __name__ == "__main__":
    main()
