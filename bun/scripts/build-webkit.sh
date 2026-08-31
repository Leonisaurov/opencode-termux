#!/usr/bin/env bash
# Cross-compile WebKit/JavaScriptCore for Android aarch64
#
# Usage: ./scripts/build-webkit.sh
#
# This builds the JSCOnly port of WebKit, producing static libraries
# and headers in the layout that Bun's CMake expects.
#
# Requires ICU to be built first (scripts/build-icu.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

incremental_exec webkit \
    --input "$SCRIPT_DIR/build-webkit.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
    --input "$REPO_ROOT/bun/cmake/webkit-android-toolchain.cmake" \
    --input "$REPO_ROOT/ci/external-sources.lock" \
    --input "$REPO_ROOT/bun/webkit" --input "$WEBKIT_SRC" \
    --value "WEBKIT_COMMIT=$WEBKIT_COMMIT" --value "ANDROID_API=$ANDROID_API" \
    --value "ANDROID_NDK_VERSION=$ANDROID_NDK_VERSION" \
    --dep "$BUN_STATE_DIR/nodes/icu.json" \
    --output "$WEBKIT_OUTPUT"

TOOLCHAIN="$REPO_ROOT/bun/cmake/webkit-android-toolchain.cmake"
ANDROID_COMPAT_HEADER="$REPO_ROOT/bun/cmake/webkit-android-compat.h"
test -f "$ANDROID_COMPAT_HEADER"
test -d "$WEBKIT_SOURCE_OVERLAY"
test -n "$(find "$WEBKIT_SOURCE_OVERLAY" -type f -print -quit)"

# Compiler flags matching oven-sh/WebKit's Dockerfile
DEFAULT_CFLAGS="-fno-omit-frame-pointer -ffunction-sections -fdata-sections -faddrsig -DU_STATIC_IMPLEMENTATION=1"
RELEASE_FLAGS="-O3 -DNDEBUG=1"

echo "=== Building WebKit/JSC for Android aarch64 ==="
echo "WebKit source: $WEBKIT_SRC"
echo "Build dir:     $WEBKIT_BUILD"
echo "Output dir:    $WEBKIT_OUTPUT"
echo "ICU prefix:    $DEPS_PREFIX"
echo "Toolchain:     $TOOLCHAIN"
echo ""

# The resumable cache intentionally preserves the source checkout after the
# monorepo overlay was materialized. Restore that generated checkout to its
# committed tree before validating it and materializing the overlay again.
# This only touches the disposable build workspace, never a repository source
# tree in the monorepo.
if [ -d "$WEBKIT_SRC/.git" ]; then
    git -C "$WEBKIT_SRC" reset --hard HEAD >/dev/null
    git -C "$WEBKIT_SRC" clean -fd >/dev/null
fi

ensure_external_checkout \
    "$WEBKIT_SRC" \
    "https://github.com/oven-sh/WebKit.git" \
    "$WEBKIT_COMMIT" \
    "WebKit"

# The complete WebKit checkout is fetched into the build workspace. The
# Android changes live in the monorepo and are copied into that checkout as
# source files, so the build never applies a patch or relies on a dirty source
# repository.
while IFS= read -r source_file; do
    relative_path="${source_file#"$WEBKIT_SOURCE_OVERLAY"/}"
    target_file="$WEBKIT_SRC/$relative_path"
    mkdir -p "$(dirname "$target_file")"
    cp "$source_file" "$target_file"
done < <(find "$WEBKIT_SOURCE_OVERLAY" -type f -print)

# Verify ICU is built
if [ ! -f "$DEPS_PREFIX/lib/libicuuc.a" ]; then
    echo "ERROR: ICU not built. Run scripts/build-icu.sh first."
    exit 1
fi

# Update toolchain with current paths
# The toolchain file has hardcoded paths that need to be parameterized
# We create a temporary toolchain with correct paths
TOOLCHAIN_TMP="$WORK_DIR/webkit-android-toolchain.cmake"
sed \
    -e "s|/home/guy/Android/Sdk/ndk/28.1.13356709|${ANDROID_NDK_HOME}|g" \
    -e "s|/home/guy/opencode-termux/deps-android/prefix|${DEPS_PREFIX}|g" \
    "$TOOLCHAIN" > "$TOOLCHAIN_TMP"

# Create build directory
mkdir -p "$WEBKIT_BUILD"

# Configure
echo ">>> Configuring WebKit/JSC..."
cd "$WEBKIT_BUILD"

# WebKit's Android logging implementation uses __android_log_print.
cmake \
    -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_TMP" \
    -DPORT=JSCOnly \
    -DENABLE_STATIC_JSC=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_THIN_ARCHIVES=OFF \
    -DUSE_BUN_JSC_ADDITIONS=ON \
    -DUSE_BUN_EVENT_LOOP=ON \
    -DENABLE_BUN_SKIP_FAILING_ASSERTIONS=ON \
    -DENABLE_FTL_JIT=ON \
    -DENABLE_REMOTE_INSPECTOR=ON \
    -DALLOW_LINE_AND_COLUMN_NUMBER_IN_BUILTINS=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_FLAGS="$DEFAULT_CFLAGS -include $ANDROID_COMPAT_HEADER" \
    -DCMAKE_CXX_FLAGS="$DEFAULT_CFLAGS -include $ANDROID_COMPAT_HEADER -fno-exceptions -fno-c++-static-destructors" \
    -DCMAKE_C_FLAGS_RELEASE="$RELEASE_FLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$RELEASE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -llog" \
    -DICU_ROOT="$DEPS_PREFIX" \
    -DICU_INCLUDE_DIRS="$DEPS_PREFIX/include" \
    "$WEBKIT_SRC"

echo ""
echo ">>> Configure complete. Building..."

# Build JSC target
cmake --build "$WEBKIT_BUILD" --config Release --target jsc -- -j"$JOBS"

# Build private headers
echo ">>> Building private headers..."
ninja -C "$WEBKIT_BUILD" JavaScriptCore_CopyPrivateHeaders 2>/dev/null || true

echo ""
echo ">>> Build complete. Installing to $WEBKIT_OUTPUT..."

# Install to output directory
mkdir -p "$WEBKIT_OUTPUT"/{lib,include/JavaScriptCore,include/wtf,include/bmalloc,include/unicode}

# Copy static libraries
cp "$WEBKIT_BUILD"/lib/*.a "$WEBKIT_OUTPUT/lib/" 2>/dev/null || true

# Copy ICU libraries
cp "$DEPS_PREFIX/lib/libicudata.a" "$WEBKIT_OUTPUT/lib/"
cp "$DEPS_PREFIX/lib/libicui18n.a" "$WEBKIT_OUTPUT/lib/"
cp "$DEPS_PREFIX/lib/libicuuc.a" "$WEBKIT_OUTPUT/lib/"

# Copy cmakeconfig.h
cp "$WEBKIT_BUILD/cmakeconfig.h" "$WEBKIT_OUTPUT/include/"

# Copy headers
find "$WEBKIT_BUILD/JavaScriptCore/DerivedSources/" -name "*.h" -exec cp {} "$WEBKIT_OUTPUT/include/JavaScriptCore/" \;
find "$WEBKIT_BUILD/JavaScriptCore/Headers/JavaScriptCore/" -name "*.h" -exec cp {} "$WEBKIT_OUTPUT/include/JavaScriptCore/" \; 2>/dev/null || true
find "$WEBKIT_BUILD/JavaScriptCore/PrivateHeaders/JavaScriptCore/" -name "*.h" -exec cp {} "$WEBKIT_OUTPUT/include/JavaScriptCore/" \; 2>/dev/null || true

# Copy WTF headers
cp -r "$WEBKIT_BUILD/WTF/Headers/wtf/"* "$WEBKIT_OUTPUT/include/wtf/" 2>/dev/null || true

# Copy bmalloc headers
cp -r "$WEBKIT_BUILD/bmalloc/Headers/bmalloc/"* "$WEBKIT_OUTPUT/include/bmalloc/" 2>/dev/null || true

# Copy ICU unicode headers
cp -r "$DEPS_PREFIX/include/unicode/"* "$WEBKIT_OUTPUT/include/unicode/"

# Create cmakeconfig.h at root of WEBKIT_OUTPUT (needed by SetupWebKit.cmake)
cp "$WEBKIT_BUILD/cmakeconfig.h" "$WEBKIT_OUTPUT/"
if grep -q '^#define BUN_WEBKIT_VERSION ' "$WEBKIT_OUTPUT/cmakeconfig.h"; then
    sed -i "s|^#define BUN_WEBKIT_VERSION .*|#define BUN_WEBKIT_VERSION \"current\"|" \
        "$WEBKIT_OUTPUT/cmakeconfig.h"
else
    echo '#define BUN_WEBKIT_VERSION "current"' >> "$WEBKIT_OUTPUT/cmakeconfig.h"
fi

# Set up directory structure that SetupWebKit.cmake expects for WEBKIT_LOCAL
mkdir -p "$WEBKIT_OUTPUT/JavaScriptCore/Headers/JavaScriptCore"
mkdir -p "$WEBKIT_OUTPUT/JavaScriptCore/PrivateHeaders/JavaScriptCore"
mkdir -p "$WEBKIT_OUTPUT/JavaScriptCore/DerivedSources/inspector"
mkdir -p "$WEBKIT_OUTPUT/bmalloc/Headers"
mkdir -p "$WEBKIT_OUTPUT/WTF/Headers"

# Copy headers into the WEBKIT_LOCAL layout
cp -r "$WEBKIT_OUTPUT/include/JavaScriptCore/"* "$WEBKIT_OUTPUT/JavaScriptCore/Headers/JavaScriptCore/" 2>/dev/null || true
cp -r "$WEBKIT_OUTPUT/include/JavaScriptCore/"* "$WEBKIT_OUTPUT/JavaScriptCore/PrivateHeaders/JavaScriptCore/" 2>/dev/null || true
# Bun includes this JSC heap header directly, but some WebKit builds do not
# expose it through JavaScriptCore_CopyPrivateHeaders. Export it from the
# checked-out WebKit source into the same versioned local layout.
HANDLE_SET_HEADER="$(find "$WEBKIT_SRC/Source/JavaScriptCore" -type f -name HandleSet.h -print -quit)"
test -n "$HANDLE_SET_HEADER" || {
    echo "ERROR: WebKit source does not contain JavaScriptCore/HandleSet.h" >&2
    exit 1
}
cp "$HANDLE_SET_HEADER" "$WEBKIT_OUTPUT/include/JavaScriptCore/HandleSet.h"
cp "$HANDLE_SET_HEADER" "$WEBKIT_OUTPUT/JavaScriptCore/Headers/JavaScriptCore/HandleSet.h"
cp "$HANDLE_SET_HEADER" "$WEBKIT_OUTPUT/JavaScriptCore/PrivateHeaders/JavaScriptCore/HandleSet.h"
find "$WEBKIT_BUILD/JavaScriptCore/DerivedSources/" -name "*.json" -exec cp {} "$WEBKIT_OUTPUT/JavaScriptCore/DerivedSources/inspector/" \; 2>/dev/null || true
cp -r "$WEBKIT_OUTPUT/include/bmalloc" "$WEBKIT_OUTPUT/bmalloc/Headers/" 2>/dev/null || true
cp -r "$WEBKIT_OUTPUT/include/wtf" "$WEBKIT_OUTPUT/WTF/Headers/" 2>/dev/null || true

echo ""
echo "=== WebKit/JSC build complete ==="
echo "Libraries:"
ls -la "$WEBKIT_OUTPUT/lib/"
echo ""
echo "Headers:"
find "$WEBKIT_OUTPUT/include" -maxdepth 2 -type d
