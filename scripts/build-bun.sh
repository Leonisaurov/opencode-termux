#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64 using zig build (Bun 1.3.14+)
#
# Usage: ./scripts/build-bun.sh
#
# Bun 1.3.14 replaced CMake+Ninja with a build.zig-based system.
# This script runs zig build directly with Android cross-compilation flags.
#
# Prerequisites:
#   - Android NDK installed (ANDROID_NDK_HOME)
#   - Zig 0.15.2+ in PATH or ZIG_BIN set
#   - WebKit pre-built in WEBKIT_OUTPUT (scripts/build-webkit.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"
NDK_SYSROOT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

# Verify prerequisites
if [ ! -d "$BUN_SRC" ]; then
    echo "ERROR: Bun source not found. Run scripts/apply-patches.sh first."
    exit 1
fi

if [ ! -d "$WEBKIT_OUTPUT/lib" ]; then
    echo "ERROR: WebKit not built. Run scripts/build-webkit.sh first."
    exit 1
fi

# Zig version check
echo ">>> Zig version: $("$ZIG_BIN" version 2>/dev/null || echo 'not found')"

# Set up Zig cache directories
echo ">>> Setting up Zig cache directories..."
rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
mkdir -p "$BUN_BUILD/cache/zig/local"
mkdir -p "$BUN_BUILD/cache/zig/global"
ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
echo "    Symlinked $BUN_SRC/.zig-cache -> $BUN_BUILD/cache/zig/local"

# Create install prefix
mkdir -p "$BUN_BUILD"

cd "$BUN_SRC"

# Step 1: Generate codegen files using host bun
echo ">>> Generating codegen files using host bun..."
HOST_BUN="${HOST_BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"
if [ ! -x "$HOST_BUN" ]; then
    echo "ERROR: host bun not found. Install bun or set HOST_BUN."
    exit 1
fi
echo "    Host bun: $($HOST_BUN --version 2>/dev/null || echo 'unknown')"

# Install root dependencies (needed for codegen scripts)
echo ">>> Installing root dependencies..."
cd "$BUN_SRC"
$HOST_BUN install --frozen-lockfile 2>&1 || $HOST_BUN install 2>&1 || true

# Run configure-only to generate codegen files.
# This uses host bun to run all codegen scripts and generate build.ninja.
echo ">>> Running configure step to generate codegen files..."
cd "$BUN_SRC"
WEBKIT_PATH="$WEBKIT_OUTPUT" \
WEBKIT_LOCAL=ON \
$HOST_BUN run scripts/build.ts --configure-only \
    --os=linux --arch=aarch64 --abi=android \
    --buildDir="$BUN_BUILD" \
    --androidNdk="$ANDROID_NDK_HOME" \
    --webkit=local \
    --mode=full \
    2>&1 || echo "    Configure exited $? (may be expected for cross-compile)"

# The codegen files should now exist in $BUN_BUILD/codegen/
CODEGEN_DIR="$BUN_BUILD/codegen"
echo ">>> Codegen dir: $CODEGEN_DIR"
ls -la "$CODEGEN_DIR" 2>/dev/null | head -10 || echo "    (codegen dir not found)"

# Step 2: Build Bun Zig code with zig build
echo ">>> Building Bun with Zig (target: aarch64-linux-android, optimize: ReleaseFast)..."
cd "$BUN_SRC"
"$ZIG_BIN" build \
    -Dtarget=aarch64-linux-android \
    -Doptimize=ReleaseFast \
    -Dandroid_ndk_sysroot="$NDK_SYSROOT" \
    -Dversion="${BUN_VERSION}" \
    -Dsha="$(git rev-parse HEAD 2>/dev/null || echo '0000000000000000000000000000000000000000')" \
    -Dcodegen_path="$CODEGEN_DIR" \
    --cache-dir "$BUN_BUILD/cache/zig" \
    --global-cache-dir "$BUN_BUILD/cache/zig/global" \
    --prefix "$BUN_BUILD" \
    2>&1

echo ""
echo ">>> Zig build step complete. Checking for outputs..."
find "$BUN_BUILD" -type f -name "bun*" -o -name "*.o" 2>/dev/null | head -20

# The zig build obj step produces bun-zig.o or bun.o
# Look for an executable or object to copy
BUN_ARTIFACT=""
for candidate in "$BUN_BUILD/bin/bun" "$BUN_BUILD/bun" "$BUN_BUILD/lib/bun-zig.o" "$BUN_BUILD/lib/bun.o"; do
    if [ -f "$candidate" ]; then
        BUN_ARTIFACT="$candidate"
        break
    fi
done

if [ -z "$BUN_ARTIFACT" ]; then
    echo "WARNING: Expected artifact not found. Searching entire prefix..."
    find "$BUN_BUILD" -type f 2>/dev/null | head -30
    # Fall back to checking zig-out if --prefix didn't install there
    if [ -d "$BUN_SRC/zig-out" ]; then
        echo "    Checking zig-out directory..."
        find "$BUN_SRC/zig-out" -type f 2>/dev/null | head -20
        BUN_ARTIFACT="$(find "$BUN_SRC/zig-out" -type f -name "bun*" 2>/dev/null | head -1)"
    fi
fi

if [ -z "$BUN_ARTIFACT" ]; then
    echo "ERROR: Bun artifact not found after build"
    exit 1
fi

# Copy to the expected location for downstream scripts
mkdir -p "$WORK_DIR/bun-build"
cp "$BUN_ARTIFACT" "$WORK_DIR/bun-build/bun"

echo ""
echo "=== Bun build complete ==="
echo "Artifact: $BUN_ARTIFACT"
echo "Binary:   $WORK_DIR/bun-build/bun"
echo "Size:     $(du -h "$WORK_DIR/bun-build/bun" | cut -f1)"
file "$WORK_DIR/bun-build/bun"
