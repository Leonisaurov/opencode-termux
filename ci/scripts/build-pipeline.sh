#!/usr/bin/env bash
# Run the complete Android/OpenCode pipeline through the incremental node graph.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

BUILD_KILO="${BUILD_KILO:-0}"
BUILD_CODEX="${BUILD_CODEX:-0}"

echo "=== Incremental Android build pipeline ==="
echo "State: $BUILD_STATE_DIR"

run_product() {
  local product="$1" script="$2"
  env PRODUCT="$product" PRODUCT_ROOT="$REPO_ROOT/$product" \
    WORK_DIR="$REPO_ROOT/$product/build" \
    BUILD_STATE_DIR="$REPO_ROOT/$product/build/state" \
    "$script"
}

run_product bun "$REPO_ROOT/bun/scripts/build-icu.sh"
run_product bun "$REPO_ROOT/bun/scripts/build-webkit.sh"
run_product bun "$REPO_ROOT/bun/scripts/build-tinycc.sh"
run_product bun "$REPO_ROOT/bun/scripts/build-bun.sh"
run_product opentui "$REPO_ROOT/opentui/scripts/build-opentui.sh"
run_product opencode "$REPO_ROOT/opencode/scripts/build-opencode.sh"
run_product opencode "$REPO_ROOT/opencode/scripts/make-packages.sh"

if [ "$BUILD_KILO" = "1" ]; then
  run_product kilo "$REPO_ROOT/kilo/scripts/build.sh"
fi

if [ "$BUILD_CODEX" = "1" ]; then
  run_product codex "$REPO_ROOT/codex/scripts/build-codex-android.sh"
fi

echo "=== Incremental pipeline complete ==="
python3 "$REPO_ROOT/ci/scripts/build-state.py" check \
  --root "$REPO_ROOT" --state-dir "$BUILD_STATE_DIR" --node packages \
  --input "$REPO_ROOT/opencode/scripts/make-packages.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
  --input "$WORK_DIR/packages" --input "$DIST_DIR/opencode" \
  --value "OPENCODE_VERSION=$OPENCODE_VERSION" \
  --dep "$BUILD_STATE_DIR/nodes/opencode.json" \
  --output "$WORK_DIR/packages"
