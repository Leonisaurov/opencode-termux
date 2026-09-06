#!/usr/bin/env python3
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bun/scripts/build-tinycc.sh"
TINYCC = ROOT / "bun/tinycc"


def main() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"SOURCES=\(\n(.*?)\n\)", script, re.DOTALL)
    assert match is not None
    sources = re.findall(r"^\s+([A-Za-z0-9_.-]+\.c)\s*$", match.group(1), re.MULTILINE)
    assert len(sources) == len(set(sources))
    assert "tccdbg.c" in sources
    assert all((TINYCC / source).is_file() for source in sources)
    assert '--output "$TINYCC_BUILD/libtcc.a"' in script
    assert 'ln -s "$TINYCC_LINK_TARGET" "$TINYCC_LINK"' in script


if __name__ == "__main__":
    main()
