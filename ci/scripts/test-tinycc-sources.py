#!/usr/bin/env python3
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bun/scripts/build-tinycc.sh"
TINYCC = ROOT / "bun/tinycc"
LOCK = ROOT / "ci/external-sources.lock"
TCC_ZIG = ROOT / "bun/src/src/deps/tcc.zig"
BUN_TINYCC_COMMIT = "29985a3b59898861442fa3b43f663fc1af2591d7"


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
    # libtcc must embed tccdefs_.h; otherwise the Android runtime tries to read
    # tccdefs.h from CONFIG_TCCDIR and fails inside the standalone binary.
    assert "#define CONFIG_TCC_PREDEFS 1" in script
    assert '"$HOST_CC" -DC2STR "$TINYCC_SRC/conftest.c" -o "$C2STR_BIN"' in script
    assert '"$C2STR_BIN" "$TINYCC_SRC/include/tccdefs.h" "$TCCDEFS_H"' in script

    # The vendored TinyCC must match the commit Bun 1.2.13 pins (see
    # cmake/targets/BuildTinyCC.cmake) and keep the two-argument
    # tcc_relocate(TCCState*, void*) ABI used by bun/src/src/deps/tcc.zig.
    # A newer TinyCC changed it to one argument and aborts with exit(-1) when
    # Bun performs the size query followed by the relocation.
    lock = LOCK.read_text(encoding="utf-8")
    assert BUN_TINYCC_COMMIT in lock
    libtcc_h = (TINYCC / "libtcc.h").read_text(encoding="utf-8")
    assert "LIBTCCAPI int tcc_relocate(TCCState *s1, void *ptr);" in libtcc_h
    tccrun_c = (TINYCC / "tccrun.c").read_text(encoding="utf-8")
    assert "twice is no longer supported" not in tccrun_c
    tcc_zig = TCC_ZIG.read_text(encoding="utf-8")
    assert "fn tcc_relocate(s1: *NativeState, ptr: ?*anyopaque) c_int;" in tcc_zig


if __name__ == "__main__":
    main()
