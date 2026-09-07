#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "bun/src/src/main.zig"


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    assert 'extern "c" fn mallopt' not in source
    assert 'bun.sys.dlsymImpl(null, "mallopt")' in source
    assert "const M_BIONIC_SET_HEAP_TAGGING_LEVEL: c_int = -204;" in source
    assert "const M_HEAP_TAGGING_LEVEL_NONE: c_int = 0;" in source
    assert "const Mallopt = *const fn" in source
    assert "export const android_heap_tagging_ctor" in source
    assert "linksection(\".init_array\")" in source
    assert source.count("android_disable_heap_tagging();") == 1


if __name__ == "__main__":
    main()
