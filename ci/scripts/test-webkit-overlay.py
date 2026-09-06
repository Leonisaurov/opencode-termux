#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "bun/scripts/build-webkit.sh"
OVERLAY = ROOT / "bun/webkit"


def main() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    lines = script.splitlines()
    assert '--input "$WEBKIT_SRC"' not in script
    assert '--value "WEBKIT_COMMIT=$WEBKIT_COMMIT"' in script
    start = lines.index("done <<'EOF'") + 1
    end = lines.index("EOF", start)
    applied = [line for line in lines[start:end] if line]
    assert len(applied) == len(set(applied))
    available = sorted(path.relative_to(OVERLAY).as_posix() for path in OVERLAY.rglob("*") if path.is_file())
    assert applied == available
    assert all((OVERLAY / relative_path).is_file() for relative_path in applied)

    expected = {
        "Source/JavaScriptCore/HandleSet.h",
        "Source/JavaScriptCore/runtime/InitializeThreading.cpp",
        "Source/bmalloc/bmalloc/DebugHeap.cpp",
        "Source/bmalloc/libpas/src/libpas/pas_min_heap.h",
        "Source/bmalloc/libpas/src/libpas/pas_probabilistic_guard_malloc_allocator.c",
        "Source/bmalloc/libpas/src/libpas/pas_thread_local_cache.c",
    }
    assert set(applied) == expected

    initialize = (OVERLAY / "Source/JavaScriptCore/runtime/InitializeThreading.cpp").read_text(encoding="utf-8")
    assert "Options::usePollingTraps() = true;" in initialize
    assert "Options::useWasmFaultSignalHandler() = false;" in initialize
    assert "Options::useWasmFastMemory() = false;" in initialize

    debug_heap = (OVERLAY / "Source/bmalloc/bmalloc/DebugHeap.cpp").read_text(encoding="utf-8")
    assert "posix_memalign" in debug_heap

    min_heap = (OVERLAY / "Source/bmalloc/libpas/src/libpas/pas_min_heap.h").read_text(encoding="utf-8")
    assert '#include "pas_zero_memory.h"' not in min_heap
    assert "memcmp(" in min_heap

    thread_cache = (OVERLAY / "Source/bmalloc/libpas/src/libpas/pas_thread_local_cache.c").read_text(encoding="utf-8")
    assert '#include "pas_process.h"' not in thread_cache
    assert '#include "pas_system_heap.h"' not in thread_cache
    assert '#include "pas_thread_suspender.h"' not in thread_cache
    assert "getname_result = -1;" in thread_cache

    allocator = (OVERLAY / "Source/bmalloc/libpas/src/libpas/pas_probabilistic_guard_malloc_allocator.c").read_text(encoding="utf-8")
    assert '#include "pas_mte.h"' not in allocator
    assert "(!defined(__ANDROID__) || __ANDROID_API__ >= 33)" in allocator


if __name__ == "__main__":
    main()
