#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64 using zig build (Bun 1.3.14+)
#
# Usage: ./scripts/build-bun.sh
#
# Bun 1.3.14 replaced CMake+Ninja with a build.zig-based system.
# This script:
#   1. Runs host bun's configure to generate codegen files
#   2. Runs zig build to produce the Bun Zig object file
#
# Prerequisites:
#   - Android NDK installed (ANDROID_NDK_HOME)
#   - Zig 0.15.2+ in PATH or ZIG_BIN set
#   - WebKit pre-built in WEBKIT_OUTPUT (scripts/build-webkit.sh)
#   - Host bun installed (for codegen)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"
HOST_BUN="${HOST_BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"
NDK_SYSROOT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

if [ ! -d "$BUN_SRC" ]; then
    echo "ERROR: Bun source not found. Run scripts/apply-patches.sh first."
    exit 1
fi
if [ ! -f "$ZIG_BIN" ]; then
    echo "ERROR: Zig binary not found at $ZIG_BIN."
    exit 1
fi
if [ ! -x "$HOST_BUN" ]; then
    echo "ERROR: Host bun not found."
    exit 1
fi

echo "    Zig:      $("$ZIG_BIN" version 2>/dev/null)"
echo "    Host bun: $($HOST_BUN --version 2>/dev/null)"

# Set up Zig cache
rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
mkdir -p "$BUN_BUILD/cache/zig/local" "$BUN_BUILD/cache/zig/global"
ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
mkdir -p "$BUN_BUILD"

cd "$BUN_SRC"

# Symlink Zig binary for Bun's toolchain
mkdir -p vendor/zig
ln -sf "$ZIG_BIN" vendor/zig/zig

# Symlink WebKit source for configure step
mkdir -p vendor
ln -sfn "$WEBKIT_SRC" vendor/WebKit

# Step 1: Generate build.ninja via configure-only
echo ">>> Running configure step..."
"$HOST_BUN" run scripts/build.ts --configure-only \
    --profile=release \
    --os=linux --arch=aarch64 --abi=android \
    --buildDir="$BUN_BUILD" \
    --webkit=local \
    --mode=full \
    --androidNdk="$ANDROID_NDK_HOME" \
    2>&1

# Step 2: Run codegen targets with ninja
echo ">>> Running codegen targets with ninja..."
NINJA_BUILD_DIR="$BUN_BUILD/release"
if [ -f "$NINJA_BUILD_DIR/build.ninja" ]; then
    NINJA_DIR="$NINJA_BUILD_DIR"
elif [ -f "$BUN_BUILD/build.ninja" ]; then
    NINJA_DIR="$BUN_BUILD"
else
    NINJA_DIR=""
fi

if [ -n "$NINJA_DIR" ]; then
    echo "    Found build.ninja in $NINJA_DIR"
    ninja -C "$NINJA_DIR" \
        -j"${JOBS:-2}" \
        codegen \
        2>&1
else
    echo "WARNING: build.ninja not found in $BUN_BUILD/release or $BUN_BUILD, searching..."
    find "$BUN_BUILD" -name "build.ninja" 2>/dev/null | head -5
fi

# Step 3: Build Zig object using zig build
CODEGEN_DIR=$(find "$BUN_BUILD" -name "ZigGeneratedClasses.zig" -exec dirname {} \; 2>/dev/null | head -1)
if [ -z "$CODEGEN_DIR" ]; then
    echo "ERROR: ZigGeneratedClasses.zig not found after codegen step"
    exit 1
fi

echo ">>> Codegen dir: $CODEGEN_DIR"
echo ">>> Building Bun Zig object..."
"$ZIG_BIN" build obj \
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
echo ">>> Zig build complete."

# Find artifact
BUN_ARTIFACT=""
for candidate in "$BUN_BUILD/bin/bun" "$BUN_BUILD/bun" \
    "$BUN_BUILD/lib/bun-zig.o" "$BUN_BUILD/lib/bun.o" \
    "$BUN_SRC/zig-out/bun" "$BUN_SRC/zig-out/lib/bun-zig.o"; do
    if [ -f "$candidate" ]; then
        BUN_ARTIFACT="$candidate"
        break
    fi
done

if [ -z "$BUN_ARTIFACT" ]; then
    echo "WARNING: Artifact not found in expected locations."
    find "$BUN_BUILD" "$BUN_SRC/zig-out" -type f 2>/dev/null | head -20 || true
    BUN_ARTIFACT="$(find "$BUN_BUILD" "$BUN_SRC/zig-out" -type f 2>/dev/null | head -1)"
fi

if [ -z "$BUN_ARTIFACT" ]; then
    echo "ERROR: No artifact found"
    exit 1
fi

mkdir -p "$WORK_DIR/bun-build"
cp "$BUN_ARTIFACT" "$WORK_DIR/bun-build/bun"

echo ""
echo "=== Bun build complete ==="
echo "Artifact: $BUN_ARTIFACT"
echo "Binary:   $WORK_DIR/bun-build/bun"
echo "Size:     $(du -h "$WORK_DIR/bun-build/bun" | cut -f1)"
file "$WORK_DIR/bun-build/bun"
