#!/usr/bin/env bash
# Build libopentui.so for Android aarch64
#
# Usage: ./scripts/build-opentui.sh
#
# Strategy:
#   Build with Zig's aarch64-linux-android.24 target and the versioned Android
#   source port. The generated android-libc.txt points Zig at the NDK Bionic
#   headers/CRT, so the final ELF is linked for Android without post-link hacks.
#
#   OpenTUI >= 0.5.2 keeps the native build in packages/native and requires the
#   Zig version named by packages/native/build.zig (SUPPORTED_ZIG_VERSIONS);
#   the compiler is pinned per product by the workflows that call this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

OPENTUI_TARGET="${OPENTUI_TARGET:-aarch64-linux-android.24}"
ANDROID_NDK_LIB_DIR="${ANDROID_NDK_LIB_DIR:-${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/${ANDROID_API}}"
ZIG_LIBC_FILE="${ZIG_LIBC_FILE:-${WORK_DIR}/android-libc.txt}"
OPENTUI_NATIVE_DIR="$OPENTUI_SRC/packages/native"
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

export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-${WORK_DIR}/cache/zig-opentui}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${WORK_DIR}/cache/zig-global}"
mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

incremental_exec opentui \
    --input "$SCRIPT_DIR/build-opentui.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
    --input "$OPENTUI_SRC" \
    --value "ZIG_VERSION=$ZIG_VERSION" --value "ANDROID_API=$ANDROID_API" \
    --value "OPENTUI_TARGET=$OPENTUI_TARGET" --value "ANDROID_NDK_LIB_DIR=$ANDROID_NDK_LIB_DIR" \
    --value "ZIG_LIBC_FILE=$ZIG_LIBC_FILE" \
    --output "$OPENTUI_NATIVE_DIR/lib/$OPENTUI_TARGET/libopentui.so"

ZIG_BIN="${ZIG_BIN:-zig}"

echo "=== Building libopentui.so for Android aarch64 ==="

validate_source_checkout "$OPENTUI_SRC" "$OPENTUI_OPENCODE_SOURCE_COMMIT" "OpenTUI"
echo ">>> OpenTUI source exists at $OPENTUI_SRC"

if [ ! -f "$OPENTUI_NATIVE_DIR/build.zig" ]; then
    echo "ERROR: build.zig not found at $OPENTUI_NATIVE_DIR"
    exit 1
fi

# The native Zig graph reads its dependencies from the ignored zig-deps
# directory, which the tree ships as a deterministic archive.
sh "$OPENTUI_NATIVE_DIR/scripts/prepare-zig-deps.sh"

# Build against Android/Bionic using the NDK libc path supplied above.
# -Dlibrary-target accepts a custom target and names its output directory after
# the target string, so the artifact lands in packages/native/lib/<target>/.
echo ">>> Building with Zig (target: $OPENTUI_TARGET)..."
cd "$OPENTUI_NATIVE_DIR"

LIBC_ARGS=()
if [ -f "$ZIG_LIBC_FILE" ]; then
    LIBC_ARGS=(--libc "$ZIG_LIBC_FILE")
fi

# Zig's translate-c steps do not read --libc, so they get the same directories
# parsed out of the libc file: header search and link configuration must not be
# able to drift apart. Missing directories are fatal because translate-c would
# otherwise fail later inside clang with an error that hides this cause.
BUILD_ARGS=("${LIBC_ARGS[@]}")
BUILD_ARGS+=("-Dbionic-api-level=${ANDROID_API}")
for key in include_dir sys_include_dir; do
    case "$key" in
        include_dir) option=-Dbionic-include-dir ;;
        sys_include_dir) option=-Dbionic-sys-include-dir ;;
    esac
    value="$(sed -n "s/^[[:space:]]*${key}=[[:space:]]*//p" "$ZIG_LIBC_FILE" 2>/dev/null \
        | tail -n 1 | sed -e 's/[[:space:]]*$//')"
    if [ -z "$value" ] || [ ! -d "$value" ]; then
        echo "ERROR: $ZIG_LIBC_FILE does not resolve a usable $key, so translate-c would compile against no Bionic headers" >&2
        exit 1
    fi
    BUILD_ARGS+=("${option}=${value}")
done

"$ZIG_BIN" build "build-$OPENTUI_TARGET" \
    -Dlibrary-target="$OPENTUI_TARGET" \
    -Doptimize=ReleaseSafe \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    "${BUILD_ARGS[@]}" 2>&1

LIBOPENTUI="$OPENTUI_NATIVE_DIR/lib/$OPENTUI_TARGET/libopentui.so"
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
