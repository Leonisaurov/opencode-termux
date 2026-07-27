#!/usr/bin/env bash
# Clone upstream repos and apply Android patches
#
# Usage: ./scripts/apply-patches.sh
#
# This script:
# 1. Clones oven-sh/bun at the pinned tag
# 2. Clones oven-sh/WebKit at the pinned commit
# 3. Applies patches from patches/
# 4. The Zig vendor patch is applied later by build-bun.sh after Bun's
#    build system downloads Zig

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Applying Patches ==="

# --- Clone Bun ---
if [ ! -d "$BUN_SRC/.git" ]; then
    echo ">>> Cloning Bun v${BUN_VERSION}..."
    git clone --depth 1 --branch "${BUN_TAG}" https://github.com/oven-sh/bun.git "$BUN_SRC"
else
    echo ">>> Bun source already exists at $BUN_SRC"
fi

# Apply Bun patches
echo ">>> Bun android-support.patch SKIPPED - all 3 hunks are already in Bun 1.3.14 upstream"
echo "    (Verified against commit 0d9b296af33f2b851fcbf4df3e9ec89751734ba4)"
# cd "$BUN_SRC"
# git checkout -- . 2>/dev/null || true  # Reset any previous patches
# git apply --stat "$REPO_ROOT/patches/bun/android-support.patch"
# git apply "$REPO_ROOT/patches/bun/android-support.patch"
# echo "    Bun android-support patch applied"

# Apply build.zig compatibility fix for Zig 0.15.2 (no_link_obj removed)
echo ">>> Applying build.zig compatibility fix for Zig 0.15.2..."
cd "$BUN_SRC"
if grep -q "no_link_obj" build.zig; then
    python3 -c "
import re
with open('build.zig', 'r') as f:
    content = f.read()
old = '    obj.no_link_obj = opts.os != .windows and !opts.no_llvm;'
new = '''    if (@hasField(@TypeOf(obj.*), \"no_link_obj\")) {
        obj.no_link_obj = opts.os != .windows and !opts.no_llvm;
    }'''
content = content.replace(old, new, 1)
with open('build.zig', 'w') as f:
    f.write(content)
"
    echo "    build.zig no_link_obj fix applied"
else
    echo "    build.zig no_link_obj fix already applied or not needed"
fi

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
fi

# Apply WebKit patch
echo ">>> Applying WebKit Android patches..."
cd "$WEBKIT_SRC"
git checkout -- . 2>/dev/null || true  # Reset any previous patches
git apply --stat "$REPO_ROOT/patches/webkit/android-support.patch"
git apply "$REPO_ROOT/patches/webkit/android-support.patch"
echo "    WebKit patches applied successfully"

echo ""
echo "=== Patches Applied ==="
echo "Bun source:    $BUN_SRC"
echo "WebKit source: $WEBKIT_SRC"
echo ""
echo "NOTE: The Zig vendor patch (patches/zig/posix-android-sigaction.patch)"
echo "      will be applied by build-bun.sh after Zig is downloaded by the"
echo "      Bun build system."
