#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64
#
# Usage: ./scripts/build-bun.sh
#
# This configures and builds Bun using CMake + Ninja with the Android NDK.
# Requires WebKit to be built first (scripts/build-webkit.sh).
#
# Bun is vendored directly in this monorepo. Native source changes are tracked
# in the root repository; this script never mutates the source before compiling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

incremental_exec bun \
    --input "$SCRIPT_DIR/build-bun.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
    --input "$REPO_ROOT/ci/source-manifest.json" --input "$BUN_SRC" \
    --value "BUN_VERSION=$BUN_VERSION" --value "ANDROID_API=$ANDROID_API" \
    --value "ANDROID_NDK_VERSION=$ANDROID_NDK_VERSION" \
    --dep "$BUN_STATE_DIR/nodes/webkit.json" \
    --output "$BUN_BUILD/bun"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

# Verify prerequisites
if [ ! -d "$BUN_SRC" ]; then
    echo "ERROR: Bun source not found in the vendored monorepo tree."
    exit 1
fi
validate_source_checkout "$BUN_SRC" "$BUN_SOURCE_COMMIT" "Bun"

if [ ! -d "$WEBKIT_OUTPUT/lib" ]; then
    echo "ERROR: WebKit not built. Run scripts/build-webkit.sh first."
    exit 1
fi

# Zig cache directory setup.
#
# Zig uses two cache locations:
#   1. --cache-dir (explicit): $BUN_BUILD/cache/zig/local (set by CMake)
#   2. .zig-cache (implicit): $BUN_SRC/.zig-cache (Zig's default CWD-local cache)
#
# On successful builds, Zig hardlinks files between them. The translate-c step
# writes c-headers-for-zig.zig to one location, and build-obj looks it up from
# the other. If they're separate directories and one is missing/stale, we get
# "file_hash FileNotFound" errors.
#
# Fix: Symlink .zig-cache -> the explicit cache dir so both paths resolve to
# the same physical location. Preserve this cache across normal retries; it is
# The cache is retained between retries so generated modules can be reused.
echo ">>> Setting up Zig cache directories..."
ZIG_CACHE_ROOT="$BUN_BUILD/cache/zig"
ZIG_CACHE_LOCAL="$ZIG_CACHE_ROOT/local"
ZIG_CACHE_GLOBAL="$ZIG_CACHE_ROOT/global"

mkdir -p "$ZIG_CACHE_LOCAL" "$ZIG_CACHE_GLOBAL"
ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
echo "    Symlinked $BUN_SRC/.zig-cache -> $BUN_BUILD/cache/zig/local"

# Create build directory
mkdir -p "$BUN_BUILD"

# CMake toolchain is inside the versioned Bun source
BUN_TOOLCHAIN="$BUN_SRC/cmake/toolchains/android-aarch64.cmake"
if [ ! -f "$BUN_TOOLCHAIN" ]; then
    echo "ERROR: Android toolchain not found at $BUN_TOOLCHAIN"
    echo "       The pinned Bun source is incomplete."
    exit 1
fi

# Configure
echo ">>> Configuring Bun..."
cd "$BUN_BUILD"

cmake \
    -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_TOOLCHAIN_FILE="$BUN_TOOLCHAIN" \
    -DANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_LTO=OFF \
    -DBUN_LINK_ONLY=OFF \
    -DWEBKIT_LOCAL=ON \
    -DWEBKIT_PATH="$WEBKIT_OUTPUT" \
    "$BUN_SRC"

echo ""
echo ">>> Configure complete."

# Download Bun's pinned Zig vendor before the full build.
echo ">>> Downloading Zig vendor (clone-zig target)..."
cd "$BUN_BUILD"
ninja clone-zig || true  # May not exist as a standalone target in all versions

# Build
echo ">>> Building Bun (this will take 30-45 minutes)..."
echo "    .zig-cache -> $(readlink -f "$BUN_SRC/.zig-cache" 2>/dev/null || echo 'NOT A SYMLINK')"
cd "$BUN_BUILD"
ninja -j"$JOBS"

# Verify output
BUN_BINARY="$BUN_BUILD/bun"
if [ ! -f "$BUN_BINARY" ]; then
    # Try bun-profile (unstripped)
    BUN_BINARY="$BUN_BUILD/bun-profile"
fi

if [ ! -f "$BUN_BINARY" ]; then
    echo "ERROR: Bun binary not found after build"
    exit 1
fi

echo ""
echo "=== Bun build complete ==="
echo "Binary: $BUN_BINARY"
echo "Size: $(du -h "$BUN_BINARY" | cut -f1)"
file "$BUN_BINARY"
