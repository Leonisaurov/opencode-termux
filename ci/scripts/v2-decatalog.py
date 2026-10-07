#!/usr/bin/env python3
"""Replace workspace "catalog:" specs with their concrete catalog versions.

Bun 1.2.13 does not understand `workspaces.catalog` (introduced upstream in
1.3.x), so probing the v2 tree with the pinned Zig-era Bun requires rewriting
every `catalog:` specifier in the vendored package.json files to the exact
version the root catalog declares. This is a probe-only utility: the release
pipeline uses Bun 1.4.2 and keeps the catalogs intact.

Usage: v2-decatalog.py <workspace-root>
"""
from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    root = pathlib.Path(sys.argv[1])
    catalog = json.loads((root / "package.json").read_text())["workspaces"]["catalog"]
    rewritten = 0
    for path in sorted(root.rglob("package.json")):
        if "node_modules" in path.parts:
            continue
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        changed = False
        for section in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
            for name, spec in (data.get(section) or {}).items():
                if spec == "catalog:":
                    data[section][name] = catalog[name]
                    changed = True
        for name, spec in (data.get("overrides") or {}).items():
            if spec == "catalog:":
                data["overrides"][name] = catalog[name]
                changed = True
        if changed:
            path.write_text(json.dumps(data, indent=2) + "\n")
            rewritten += 1
    print(f"v2-decatalog: {rewritten} package.json reescritos")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
