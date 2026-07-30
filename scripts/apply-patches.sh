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

# Apply default backend symlink fix for Android/Termux
echo ">>> Applying default backend symlink fix for Android..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-default-backend.patch"
git apply "$REPO_ROOT/patches/bun/android-default-backend.patch"
echo "    Default backend symlink fix applied"

# Apply Android global bin wrapper (create shell script instead of symlink)
echo ">>> Applying Android global bin wrapper patch..."
cd "$BUN_SRC"
echo "    Android global bin wrapper patch applied"
cd "$REPO_ROOT"

# Apply PR #31198 fix (CouldntReadCurrentDirectory on Android/Termux)
echo ">>> Applying PR #31198 fix for CouldntReadCurrentDirectory..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/pr31198.diff"
git apply "$REPO_ROOT/patches/bun/pr31198.diff"
echo "    PR #31198 fix applied"

# Apply Android standalone raw-append patch (inject() corrupts ELF on Android)
echo ">>> Applying Android standalone raw-append patch..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-standalone-raw-append.patch"
git apply "$REPO_ROOT/patches/bun/android-standalone-raw-append.patch"
echo "    Android standalone raw-append patch applied"

# Apply global shebang fix (replace node → bun in shebangs for global installs)
echo ">>> Applying Android global shebang fix..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-global-shebang-fix.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
git apply "$REPO_ROOT/patches/bun/android-global-shebang-fix.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
echo "    Android global shebang fix applied"

# Apply global transitive deps fix (ensure transitive deps in global node_modules)
echo ">>> Applying Android global transitive deps fix..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-global-transitive-deps.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
git apply "$REPO_ROOT/patches/bun/android-global-transitive-deps.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
echo "    Android global transitive deps fix applied"

# Apply global path reconstruction (fix module resolution for global installs)
echo ">>> Applying Android global path reconstruction fix..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-global-path-reconstruction.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
git apply "$REPO_ROOT/patches/bun/android-global-path-reconstruction.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
echo "    Android global path reconstruction fix applied"

# Apply global resolve fallback (fix transitive dep resolution for global packages)
echo ">>> Applying Android global resolve fallback fix..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-global-resolve-fallback.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
git apply "$REPO_ROOT/patches/bun/android-global-resolve-fallback.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"

# Apply platform fallback (android-arm64 → linux-arm64 for bindings)
echo ">>> Applying Android platform fallback fix..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-platform-fallback.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
git apply "$REPO_ROOT/patches/bun/android-platform-fallback.patch" 2>/dev/null || echo "    ⚠️  Skipped (already applied?)"
    echo "    Android platform fallback fix applied"
    echo "    Android global resolve fallback fix applied"

# Apply TinyCC configuration changes for Android
echo ">>> Applying TinyCC Android configuration..."
cd "$BUN_SRC"
git apply --stat "$REPO_ROOT/patches/bun/android-config-tinycc.patch" 2>/dev/null || true
git apply "$REPO_ROOT/patches/bun/android-config-tinycc.patch" 2>/dev/null || true
echo "    TinyCC Android config applied"



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
