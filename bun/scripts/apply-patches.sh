#!/usr/bin/env bash
# Clone upstream repos and apply Android patches
#
# Usage: ./scripts/apply-patches.sh
#
# This script:
# 1. Clones oven-sh/bun at the pinned tag
# 2. Clones oven-sh/WebKit at the pinned commit
# 3. Applies patches from patches/ (with strict preflight checks)
# 4. The Zig vendor patch is applied later by build-bun.sh after Bun's
#    build system downloads Zig

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

echo "=== Applying Patches ==="

ensure_revision() {
    local source_dir="$1"
    local revision="$2"
    local label="$3"
    local current expected

    current="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
    expected="$(git -C "$source_dir" rev-parse "${revision}^{commit}" 2>/dev/null || true)"
    if [ -z "$expected" ]; then
        git -C "$source_dir" fetch --depth=1 origin "$revision"
        expected="$(git -C "$source_dir" rev-parse FETCH_HEAD)"
    fi
    if [ "$current" = "$expected" ]; then
        return 0
    fi

    if [ -n "$(git -C "$source_dir" status --porcelain --untracked-files=all)" ]; then
        echo "ERROR: $label checkout is at $current, expected $expected, and has local changes." >&2
        echo "       Refusing to reset it; convert or preserve those changes before changing revisions." >&2
        return 1
    fi
    echo ">>> Switching $label to pinned revision $expected..."
    git -C "$source_dir" checkout --detach "$expected"
}

apply_repo_patch() {
    local patch_file="$1"
    if git apply --check "$patch_file" >/dev/null 2>&1; then
        git apply "$patch_file"
    elif git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        echo ">>> Patch already applied: $(basename "$patch_file")"
    else
        echo "ERROR: patch does not apply cleanly: $patch_file" >&2
        return 1
    fi
}

# --- Clone Bun ---
if [ ! -d "$BUN_SRC/.git" ]; then
    echo ">>> Cloning Bun v${BUN_VERSION}..."
    git clone --depth 1 --branch "${BUN_TAG}" https://github.com/oven-sh/bun.git "$BUN_SRC"
else
    echo ">>> Bun source already exists at $BUN_SRC"
    ensure_revision "$BUN_SRC" "$BUN_TAG" "Bun"
fi

# Apply Bun patches in dependency order. The heap-tagging patch is based on
# the source tree after android-support.patch, so check and apply it only
# after the support patch has changed the checkout.
echo ">>> Applying Bun Android patches..."
cd "$BUN_SRC"
ANDROID_SUPPORT_PATCH="$REPO_ROOT/bun/patches/bun/android-support.patch"
ANDROID_HEAP_TAGGING_PATCH="$REPO_ROOT/bun/patches/bun/android-heap-tagging.patch"
apply_repo_patch "$ANDROID_SUPPORT_PATCH"
apply_repo_patch "$ANDROID_HEAP_TAGGING_PATCH"
echo "    Bun patches applied successfully"

# --- Clone WebKit ---
if [ ! -d "$WEBKIT_SRC/.git" ]; then
    echo ">>> Cloning WebKit at commit ${WEBKIT_COMMIT}..."
    mkdir -p "$WEBKIT_SRC"
    cd "$WEBKIT_SRC"
    git init
    git remote add origin https://github.com/oven-sh/WebKit.git
    git fetch --depth=1 origin "${WEBKIT_COMMIT}"
    git checkout FETCH_HEAD
else
    echo ">>> WebKit source already exists at $WEBKIT_SRC"
    ensure_revision "$WEBKIT_SRC" "$WEBKIT_COMMIT" "WebKit"
fi

# Apply WebKit patch
echo ">>> Applying WebKit Android patches..."
cd "$WEBKIT_SRC"
WEBKIT_ANDROID_PATCH="$REPO_ROOT/bun/patches/webkit/android-support.patch"
apply_repo_patch "$WEBKIT_ANDROID_PATCH"
echo "    WebKit patches applied successfully"

echo ""
echo "=== Patches Applied ==="
echo "Bun source:    $BUN_SRC"
echo "WebKit source: $WEBKIT_SRC"
echo ""
echo "NOTE: The Zig vendor patch (bun/patches/zig/posix-android-sigaction.patch)"
echo "      will be applied by build-bun.sh after Zig is downloaded by the"
echo "      Bun build system."
