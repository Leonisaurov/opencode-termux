#!/usr/bin/env bash
# Run Bun 1.2.13 against workspaces whose catalog is nested under workspaces.
set -euo pipefail

ROOT="${1:?workspace root is required}"
shift
MANIFEST="$ROOT/package.json"
HOST_BUN="${HOST_BUN:-bun}"

test -f "$MANIFEST"
test "$("$HOST_BUN" --version)" = "1.2.13"

: "${TMPDIR:=/data/data/com.termux/files/usr/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
test -d "$TMPDIR" && test -w "$TMPDIR"

BACKUP="$(mktemp "$TMPDIR/bun13-package.XXXXXX")"
restore_manifest() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$MANIFEST"
        rm -f "$BACKUP"
    fi
}
trap restore_manifest EXIT
cp "$MANIFEST" "$BACKUP"

python3 - "$MANIFEST" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    package = json.load(stream)

workspaces = package.get("workspaces")
if isinstance(workspaces, dict) and "catalog" in workspaces and "catalog" not in package:
    package["catalog"] = workspaces.pop("catalog")
if isinstance(workspaces, dict) and "catalogs" in workspaces and "catalogs" not in package:
    package["catalogs"] = workspaces.pop("catalogs")

with open(path, "w", encoding="utf-8") as stream:
    json.dump(package, stream, indent=2)
    stream.write("\n")
PY

"$HOST_BUN" install --frozen-lockfile "$@"
