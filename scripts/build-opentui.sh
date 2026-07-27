#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# Strategy:
#   Build with Zig's aarch64-linux-musl target (Zig bundles musl libc natively,
#   no libc provision issues). Then patch the .so with patchelf to add
#   NEEDED libc.so so Android's dlopen() can resolve symbols like getauxval.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ZIG_BIN="${ZIG_BIN:-zig}"

echo "=== Building libopentui.so for Android aarch64 ==="

# Clone opentui if needed
if [ ! -d "$OPENTUI_SRC/.git" ]; then
    echo ">>> Cloning opentui..."
    git clone --depth 1 https://github.com/anomalyco/opentui.git "$OPENTUI_SRC"
else
    echo ">>> opentui source exists at $OPENTUI_SRC"
fi

OPENTUI_ZIG_DIR="$OPENTUI_SRC/packages/core/src/zig"

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

# Build with Zig's native musl target (Zig provides musl libc with no
# Android/bionic provision issues). We use aarch64-linux-musl which is
# explicitly listed in opentui's SUPPORTED_TARGETS.
echo ">>> Building with Zig (target: aarch64-linux-musl)..."
cd "$OPENTUI_ZIG_DIR"

"$ZIG_BIN" build \
    -Dtarget=aarch64-linux-musl \
    -Doptimize=ReleaseSafe \
    --prefix . 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir.  With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above: packages/core/src/lib/aarch64-linux-musl/
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/aarch64-linux-musl/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $LIBOPENTUI"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

# Ensure patchelf is available for NEEDED patching
echo ">>> Ensuring patchelf is available..."
if ! command -v patchelf &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq patchelf
fi

# The musl build produces a .so without NEEDED libc.so (musl is statically
# linked). Android's dlopen() requires libc.so to be a DT_NEEDED entry so it
# can resolve symbols. Add it with patchelf.
echo ">>> Patching DT_NEEDED for Android compatibility..."
CURRENT_NEEDED=$(readelf -d "$LIBOPENTUI" 2>/dev/null | grep NEEDED)

# Remove glibc-style libdl, libpthread, librt (musl bundles into libc)
for lib in libdl.so.2 libpthread.so.0 librt.so.1; do
    if echo "$CURRENT_NEEDED" | grep -q "$lib"; then
        echo "    Removing NEEDED $lib"
        patchelf --remove-needed "$lib" "$LIBOPENTUI"
    fi
done

# Add NEEDED libc.so if not already present
if ! echo "$CURRENT_NEEDED" | grep -q "libc.so"; then
    echo "    Adding NEEDED libc.so"
    patchelf --add-needed "libc.so" "$LIBOPENTUI"
fi

echo ""
echo "=== libopentui.so build complete ==="
echo "Output: $LIBOPENTUI"
echo "Size: $(du -h "$LIBOPENTUI" | cut -f1)"
file "$LIBOPENTUI"
echo ""
echo "DT_NEEDED entries:"
readelf -d "$LIBOPENTUI" 2>/dev/null | grep NEEDED

# Verify the .so has NEEDED: libc.so (required for Android dlopen)
if readelf -d "$LIBOPENTUI" 2>/dev/null | grep -q "NEEDED.*libc.so"; then
    echo "OK: libopentui.so has NEEDED: libc.so (required for Android)"
else
    echo "ERROR: libopentui.so is missing NEEDED: libc.so dependency"
    echo "       Android dlopen() will fail without this."
    readelf -d "$LIBOPENTUI" 2>/dev/null | grep NEEDED || echo "       (no NEEDED entries found)"
    exit 1
fi
