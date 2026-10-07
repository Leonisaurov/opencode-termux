#!/usr/bin/env python3
"""Verify (and where needed restore) the string guard in @opentui/core's
bundled-file resolution.

History: `@opentui/core@0.4.5` shipped a bun-path `resolveBundledFilePath`
that called `normalizeLoadedFilePath((await loadBundledFile()).default, ...)`
without checking the value was a string. In the Android standalone build a
bundled `type: "file"` import can resolve to a module whose `default` is not
a path, crashing the TUI with `undefined is not an object (evaluating
'loadedPath.startsWith')`.

As of `@opentui/core@0.5.14` upstream ships the guard itself, in the exact
form below, so this script became a verifier: it asserts every published
runtime chunk contains the guarded sequence, still patches the known-unguarded
0.4.5 layout (so a downgrade or an unguarded re-vendor is fixed rather than
silently accepted), and fails on any third layout so CI forces a review
instead of shipping an unguarded runtime. The remaining unguarded
`normalizeLoadedFilePath` call inside `loadBundledFilePath` (node path) is
wrapped in try/catch upstream and degrades to the fallback path, so it is not
a patch target.

Usage: patch-opentui-core-runtime.py --root <opencode source root>
"""
from __future__ import annotations

import argparse
import pathlib
import sys

GUARDED = """  const loaded = (await loadBundledFile()).default;
  if (typeof loaded !== "string") {
    return resolveFallbackFilePath(fallbackPath, metaUrl);
  }
  return normalizeLoadedFilePath(loaded, metaUrl);
}
"""

UNGUARDED = """  if (!bun) {
    const path = resolveFallbackFilePath(fallbackPath, metaUrl);
    if (existsSync(path)) {
      return path;
    }
    return await loadBundledFilePath(loadBundledFile, metaUrl, options.loadBundledFileFallback ?? false) ?? path;
  }
  return normalizeLoadedFilePath((await loadBundledFile()).default, metaUrl);
}
"""


def patch_text(text: str) -> tuple[str, str]:
    """Return (text, status) for one chunk: verified | patched | irrelevant | unexpected."""
    has_runtime = "resolveBundledFilePath" in text or "normalizeLoadedFilePath" in text
    if GUARDED in text:
        return text, "verified"
    if UNGUARDED in text:
        patched = text.replace(UNGUARDED, GUARDED, 1)
        return patched, "patched"
    if has_runtime:
        return text, "unexpected"
    return text, "irrelevant"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)

    candidates = sorted(args.root.rglob("node_modules/@opentui/core/chunk-bun-*.js"))
    candidates += sorted(args.root.rglob("node_modules/@opentui/core/chunk-node-*.js"))
    if not candidates:
        print("[patch-opentui-core-runtime] no @opentui/core chunk files found", file=sys.stderr)
        return 1

    counts = {"verified": 0, "patched": 0, "irrelevant": 0, "unexpected": 0}
    for path in candidates:
        text, status = patch_text(path.read_text(encoding="utf-8"))
        counts[status] += 1
        if status == "patched":
            path.write_text(text, encoding="utf-8")
            print(f"[patch-opentui-core-runtime] patched {path}")
        elif status == "verified":
            print(f"[patch-opentui-core-runtime] guard verified in {path}")
        elif status == "unexpected":
            print(f"[patch-opentui-core-runtime] ERROR: unrecognised bundled-file layout in {path}", file=sys.stderr)

    if counts["unexpected"]:
        print("[patch-opentui-core-runtime] refusing to continue with unverifiable runtimes", file=sys.stderr)
        return 1
    if counts["verified"] + counts["patched"] == 0:
        print("[patch-opentui-core-runtime] ERROR: no chunk carried the bundled-file runtime", file=sys.stderr)
        return 1
    print(
        "[patch-opentui-core-runtime] "
        f"verified={counts['verified']} patched={counts['patched']} irrelevant={counts['irrelevant']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
