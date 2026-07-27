#!/usr/bin/env bash
# Cross-compile Bun for Android aarch64 using Bun's build.ts (Bun 1.3.14+)
#
# Usage: ./scripts/build-bun.sh
#
# Bun 1.3.14 replaced CMake+Ninja with a build.zig + scripts/build.ts system.
# This script uses the host bun to run scripts/build.ts which handles:
#   1. Code generation (ZigGeneratedClasses.zig, etc.)
#   2. Zig compilation via build.zig
#   3. C++ compilation via NDK clang
#   4. Final linking into the bun binary
#
# Prerequisites:
#   - Android NDK installed (ANDROID_NDK_HOME)
#   - Zig 0.15.2+ in PATH or ZIG_BIN set
#   - WebKit pre-built in WEBKIT_OUTPUT (scripts/build-webkit.sh)
#   - Host bun installed (for running scripts/build.ts)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"
HOST_BUN="${HOST_BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}"
NDK_SYSROOT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

echo "=== Building Bun v${BUN_VERSION} for Android aarch64 ==="

# Verify prerequisites
if [ ! -d "$BUN_SRC" ]; then
    echo "ERROR: Bun source not found. Run scripts/apply-patches.sh first."
    exit 1
fi

if [ ! -f "$ZIG_BIN" ]; then
    echo "ERROR: Zig binary not found at $ZIG_BIN. Set ZIG_BIN or install Zig."
    exit 1
fi

if [ ! -x "$HOST_BUN" ]; then
    echo "ERROR: Host bun not found. Set HOST_BUN or install bun."
    exit 1
fi

if [ ! -d "$WEBKIT_OUTPUT/lib" ]; then
    echo "ERROR: WebKit not built. Run scripts/build-webkit.sh first."
    exit 1
fi

echo "    Zig:      $("$ZIG_BIN" version 2>/dev/null)"
echo "    Host bun: $($HOST_BUN --version 2>/dev/null)"

# Set up Zig cache directories
echo ">>> Setting up Zig cache directories..."
rm -rf "$BUN_BUILD/cache/zig" "$BUN_SRC/.zig-cache"
mkdir -p "$BUN_BUILD/cache/zig/local" "$BUN_BUILD/cache/zig/global"
ln -sfn "$BUN_BUILD/cache/zig/local" "$BUN_SRC/.zig-cache"
echo "    Symlinked $BUN_SRC/.zig-cache -> $BUN_BUILD/cache/zig/local"

mkdir -p "$BUN_BUILD"

cd "$BUN_SRC"

# Bun's build.ts expects zig at vendor/zig/zig — symlink our zig there
echo ">>> Setting up Zig binary for Bun's build system..."
mkdir -p "$BUN_SRC/vendor/zig"
ln -sf "$ZIG_BIN" "$BUN_SRC/vendor/zig/zig"
echo "    Symlinked $ZIG_BIN -> $BUN_SRC/vendor/zig/zig"

# Bun's build.ts expects WebKit source at vendor/WebKit/ or $BUN_WEBKIT_PATH
echo ">>> Setting up WebKit source for build system..."
mkdir -p "$BUN_SRC/vendor"
ln -sfn "$WEBKIT_SRC" "$BUN_SRC/vendor/WebKit"
echo "    Symlinked $WEBKIT_SRC -> $BUN_SRC/vendor/WebKit"

# Build using Bun's build.ts — this generates codegen, compiles Zig and C++,
# and links the final binary.
echo ">>> Building Bun for Android using build.ts..."
echo "    This will generate codegen, compile Zig + C++, and link."
echo ""

"$HOST_BUN" run scripts/build.ts \
    --profile=release \
    --os=linux \
    --arch=aarch64 \
    --abi=android \
    --buildDir="$BUN_BUILD" \
    --webkit=local \
    --mode=full \
    --androidNdk="$ANDROID_NDK_HOME" \
    -j"$JOBS" \
    2>&1

echo ""
echo ">>> Build step complete. Checking for binary..."

# The built binary is at $BUN_BUILD/bun or $BUN_BUILD/bun-profile
BUN_BINARY=""
for candidate in "$BUN_BUILD/bun" "$BUN_BUILD/bun-profile"; do
    if [ -f "$candidate" ]; then
        BUN_BINARY="$candidate"
        break
    fi
done

if [ -z "$BUN_BINARY" ]; then
    echo "ERROR: Bun binary not found after build"
    find "$BUN_BUILD" -maxdepth 2 -type f -executable 2>/dev/null | head -20
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
