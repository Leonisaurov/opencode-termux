#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "bun/webkit/Source/bmalloc/libpas/src/libpas/pas_probabilistic_guard_malloc_allocator.c"


def main() -> None:
    text = SOURCE.read_text(encoding="utf-8")
    condition = next(
        line for line in text.splitlines()
        if line.startswith("#if ") and "__ANDROID_API__ >= 33" in line
    )
    assert "defined(__ANDROID__)" in condition
    assert "PAS_OS(ANDROID)" not in condition
    assert "size_t backtrace(void** buffer, size_t size)" in text


if __name__ == "__main__":
    main()
