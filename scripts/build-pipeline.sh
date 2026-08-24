#!/usr/bin/env bash
# Run the complete Android/OpenCode pipeline through the incremental node graph.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

BUILD_KILO="${BUILD_KILO:-0}"
BUILD_CODEX="${BUILD_CODEX:-0}"

echo "=== Incremental Android build pipeline ==="
echo "State: $BUILD_STATE_DIR"

"$SCRIPT_DIR/build-icu.sh"
"$SCRIPT_DIR/build-webkit.sh"
"$SCRIPT_DIR/build-tinycc.sh"
"$SCRIPT_DIR/build-bun.sh"
"$SCRIPT_DIR/build-opentui.sh"
"$SCRIPT_DIR/build-opencode.sh"
"$SCRIPT_DIR/make-packages.sh"

if [ "$BUILD_KILO" = "1" ]; then
  "$REPO_ROOT/kilocode_build.sh"
fi

if [ "$BUILD_CODEX" = "1" ]; then
  "$SCRIPT_DIR/build-codex-android.sh"
fi

echo "=== Incremental pipeline complete ==="
python3 "$REPO_ROOT/scripts/build-state.py" check \
  --root "$REPO_ROOT" --state-dir "$BUILD_STATE_DIR" --node packages \
  --input scripts/make-packages.sh --input scripts/env.sh \
  --input "$WORK_DIR/packages" --input "$DIST_DIR/opencode" \
  --value "OPENCODE_VERSION=$OPENCODE_VERSION" \
  --dep "$BUILD_STATE_DIR/nodes/opencode.json" \
  --output "$WORK_DIR/packages"
