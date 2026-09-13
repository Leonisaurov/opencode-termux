#!/usr/bin/env python3
"""Restore the non-string bundled-file guard in the published @opentui/core.

The published `@opentui/core@0.4.5` chunk calls `normalizeLoadedFilePath` on
`(await loadBundledFile()).default` without checking that the value is a
string. In the Android standalone build a bundled `type: "file"` import can
resolve to a module whose `default` is not a path, which crashes the TUI with
`undefined is not an object (evaluating 'loadedPath.startsWith')`.

The matching fix already exists in the vendored OpenTUI source
(`opentui/src/opencode/packages/core/src/platform/runtime.ts`), so this script
brings the published chunk in line with that pinned source instead of patching
behaviour at runtime.

Usage: patch-opentui-core-runtime.py --root <opencode source root>
"""
from __future__ import annotations

import argparse
import pathlib
import sys

OLD = """  if (!bun) {
    const path = resolveFallbackFilePath(fallbackPath, metaUrl);
    if (existsSync(path)) {
      return path;
    }
    return await loadBundledFilePath(loadBundledFile, metaUrl, options.loadBundledFileFallback ?? false) ?? path;
  }
  return normalizeLoadedFilePath((await loadBundledFile()).default, metaUrl);
}
"""

NEW = """  if (!bun) {
    const path = resolveFallbackFilePath(fallbackPath, metaUrl);
    if (existsSync(path)) {
      return path;
    }
    return await loadBundledFilePath(loadBundledFile, metaUrl, options.loadBundledFileFallback ?? false) ?? path;
  }
  const loaded = (await loadBundledFile()).default;
  if (typeof loaded !== "string") {
    return resolveFallbackFilePath(fallbackPath, metaUrl);
  }
  return normalizeLoadedFilePath(loaded, metaUrl);
}
"""


def patch_text(text: str) -> tuple[str, bool]:
    """Return the patched text and whether it changed."""
    if NEW in text:
        return text, False
    if OLD not in text:
        return text, False
    return text.replace(OLD, NEW, 1), True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    args = parser.parse_args()

    candidates = sorted(args.root.rglob("node_modules/@opentui/core/chunk-bun-*.js"))
    candidates += sorted(args.root.rglob("node_modules/@opentui/core/chunk-node-*.js"))
    if not candidates:
        print("[patch-opentui-core-runtime] no @opentui/core chunk files found", file=sys.stderr)
        return 0

    changed = 0
    unexpected = 0
    for path in candidates:
        text, did_change = patch_text(path.read_text(encoding="utf-8"))
        if did_change:
            path.write_text(text, encoding="utf-8")
            changed += 1
            print(f"[patch-opentui-core-runtime] patched {path}")
        elif OLD in text:
            unexpected += 1
            print(f"[patch-opentui-core-runtime] WARNING: unexpected layout in {path}", file=sys.stderr)

    if unexpected:
        print("[patch-opentui-core-runtime] refusing to continue with unpatched runtimes", file=sys.stderr)
        return 1
    if changed == 0:
        print("[patch-opentui-core-runtime] already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
