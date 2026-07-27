#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64 using Bun's native build.ts
#
# Bun 1.3.14+ has built-in Android profiles in scripts/build.ts.
# We use --configure-only to generate build.ninja, then ninja to build.
#
# Usage: ./scripts/build-bun.sh
#
# Prerequisites:
#   - Android NDK (ANDROID_NDK_HOME)
#   - Host bun (HOST_BUN) for running build.ts
#   - ninja (from system packages)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

HOST_BUN="${HOST_BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"
BUILD_DIR="${BUN_BUILD:-$WORK_DIR/bun-build}"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

if [ ! -d "$BUN_SRC/.git" ]; then
    echo "ERROR: Bun source not found. Run scripts/apply-patches.sh first."
    exit 1
fi
if [ ! -x "$HOST_BUN" ]; then
    echo "ERROR: Host bun not found at $HOST_BUN"
    exit 1
fi

echo "    Host bun: $($HOST_BUN --version 2>/dev/null)"
echo "    Target:   aarch64-linux-android"

cd "$BUN_SRC"

# ── Step 1: Configure-only ──────────────────────────────────────
echo ">>> Step 1: Generating build.ninja via build.ts..."
mkdir -p "$BUILD_DIR"

"$HOST_BUN" run scripts/build.ts \
    --profile=android-release \
    --configure-only \
    --androidNdk="$ANDROID_NDK_HOME" \
    --buildDir="$BUILD_DIR" \
    --webkit=prebuilt \
    -j"${JOBS:-2}" \
    2>&1

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    echo "ERROR: build.ninja not generated in $BUILD_DIR"
    find "$BUILD_DIR" -name "build.ninja" 2>/dev/null | head -3
    exit 1
fi
echo "    build.ninja generated in $BUILD_DIR ($(wc -l < "$BUILD_DIR/build.ninja") rules)"

# ── Step 2: Build with ninja ────────────────────────────────────
echo ">>> Step 2: Building Bun with ninja..."
ln -sf "$BUN_SRC/build.zig" "$BUILD_DIR/build.zig"
ninja -C "$BUILD_DIR" \
    -j"${JOBS:-2}" \
    bun \
    2>&1

# ── Step 3: Locate artifact ─────────────────────────────────────
echo ">>> Step 3: Locating Bun binary..."
BUN_BINARY=""
for candidate in "$BUILD_DIR/bun" "$BUILD_DIR/release/bun" "$BUILD_DIR/android-release/bun"; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        BUN_BINARY="$candidate"
        break
    fi
done

if [ -z "$BUN_BINARY" ]; then
    echo "WARNING: Bun binary not found in expected locations."
    find "$BUILD_DIR" -name "bun" -type f -executable 2>/dev/null | head -5
    exit 1
fi

# Copy to expected location
mkdir -p "$WORK_DIR/bun-build"
cp "$BUN_BINARY" "$WORK_DIR/bun-build/bun"

echo ""
echo "=== Bun build complete ==="
echo "Binary: $WORK_DIR/bun-build/bun"
echo "Size:   $(du -h "$WORK_DIR/bun-build/bun" | cut -f1)"
file "$WORK_DIR/bun-build/bun"
readelf -h "$WORK_DIR/bun-build/bun" 2>/dev/null | grep -E "Machine|Class" || true
