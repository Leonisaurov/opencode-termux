#!/usr/bin/env bash
set -euo pipefail

# Keep argument handling and transaction logic in a testable Python module.  This
# wrapper intentionally has no temporary path of its own.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/ci/scripts/installer.py" "$@"
