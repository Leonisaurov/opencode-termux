#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# Strategy:
#   Build with Zig's aarch64-linux-android.24 target and the pinned Android libc
#   source port. The generated android-libc.txt points Zig at the NDK Bionic
#   headers/CRT, so the final ELF is linked for Android without post-link hacks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

OPENTUI_TARGET="${OPENTUI_TARGET:-aarch64-linux-android.24}"
ANDROID_NDK_LIB_DIR="${ANDROID_NDK_LIB_DIR:-${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/${ANDROID_API}}"
ZIG_LIBC_FILE="${ZIG_LIBC_FILE:-${WORK_DIR}/android-libc.txt}"
export OPENTUI_TARGET ANDROID_NDK_LIB_DIR

if [ ! -f "$ZIG_LIBC_FILE" ] && [ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot" ]; then
    mkdir -p "$(dirname "$ZIG_LIBC_FILE")"
    cat > "$ZIG_LIBC_FILE" <<EOF
include_dir=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
sys_include_dir=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android
crt_dir=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/$ANDROID_API
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF
fi

incremental_exec opentui \
    --input "$SCRIPT_DIR/build-opentui.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
    --input "$REPO_ROOT/opentui/patches" --input "$OPENTUI_SRC" \
    --value "ZIG_VERSION=$ZIG_VERSION" --value "ANDROID_API=$ANDROID_API" \
    --value "OPENTUI_TARGET=$OPENTUI_TARGET" --value "ANDROID_NDK_LIB_DIR=$ANDROID_NDK_LIB_DIR" \
    --value "ZIG_LIBC_FILE=$ZIG_LIBC_FILE" \
    --output "$OPENTUI_SRC/packages/core/src/lib/$OPENTUI_TARGET/libopentui.so"

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

# Apply the repository-owned Android libc patch to the pinned upstream source.
# Cached source may already contain it; reject a different partial application.
OPENTUI_PATCH="$REPO_ROOT/opentui/patches/opentui/android-libc-link.patch"
OPENTUI_PORT_PATCH="$REPO_ROOT/opentui/patches/opentui/android-termux-port.patch"
cd "$OPENTUI_SRC"
if git apply --check "$OPENTUI_PATCH" >/dev/null 2>&1; then
    git apply "$OPENTUI_PATCH"
elif git apply --reverse --check "$OPENTUI_PATCH" >/dev/null 2>&1; then
    echo ">>> OpenTUI Android libc patch already applied"
else
    echo "ERROR: OpenTUI Android libc patch does not apply cleanly" >&2
    exit 1
fi

# Apply the repository-owned Android/Termux source port after the linker patch.
# This is the same source state validated in the local pinned checkout; CI must
# never silently build the unpatched upstream renderer.
if git apply --check "$OPENTUI_PORT_PATCH" >/dev/null 2>&1; then
    git apply "$OPENTUI_PORT_PATCH"
elif git apply --reverse --check "$OPENTUI_PORT_PATCH" >/dev/null 2>&1; then
    echo ">>> OpenTUI Android/Termux source port already applied"
else
    echo "ERROR: OpenTUI Android/Termux source port does not apply cleanly" >&2
    exit 1
fi

if [ ! -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_ZIG_DIR"
    exit 1
fi

# Build against Android/Bionic using the NDK libc path supplied above.
echo ">>> Building with Zig (target: $OPENTUI_TARGET)..."
cd "$OPENTUI_ZIG_DIR"

LIBC_ARGS=()
if [ -f "$ZIG_LIBC_FILE" ]; then
    LIBC_ARGS=(--libc "$ZIG_LIBC_FILE")
fi

"$ZIG_BIN" build \
    -Dtarget="$OPENTUI_TARGET" \
    -Doptimize=ReleaseSafe \
    --prefix . "${LIBC_ARGS[@]}" 2>&1

# The build.zig installs to dest_dir="../lib/{output_name}" relative to
# the --prefix dir. With --prefix=. (= OPENTUI_ZIG_DIR), the .so ends
# up one directory above under packages/core/src/lib/$OPENTUI_TARGET/.
LIBOPENTUI="$OPENTUI_ZIG_DIR/../lib/$OPENTUI_TARGET/libopentui.so"
if [ ! -f "$LIBOPENTUI" ]; then
    echo "ERROR: libopentui.so not found"
    echo "  Expected at: $LIBOPENTUI"
    echo "  Searching for any libopentui.so under opentui-src..."
    find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== libopentui.so Android build complete ==="
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
