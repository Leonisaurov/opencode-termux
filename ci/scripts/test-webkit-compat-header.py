#!/usr/bin/env python3
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "bun/cmake/webkit-android-compat.h"


def main() -> None:
    source = "#include <stddef.h>\nint main(void) { return 0; }\n"
    compiler = shutil.which("clang") or shutil.which("cc")
    assert compiler, "a C compiler is required to validate the compatibility header"
    result = subprocess.run(
        [
            compiler,
            "-fsyntax-only",
            "-D__ANDROID__",
            "-D__ANDROID_API__=24",
            "-include",
            str(HEADER),
            "-x",
            "c",
            "-",
        ],
        input=source,
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    main()
