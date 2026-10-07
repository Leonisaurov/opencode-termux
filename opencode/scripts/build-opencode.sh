#!/usr/bin/env bash
# Build OpenCode standalone binary for Android aarch64
#
# Usage: ./scripts/build-opencode.sh
#
# This script consumes the versioned OpenCode v2 checkout, swaps the Linux
# ARM64 OpenTUI runtime for the Android build, and creates the standalone
# binary from packages/cli.
#
# Requires:
# - Android Bun binary built (scripts/build-bun.sh)
# - libopentui.so built (scripts/build-opentui.sh)
# - Host Bun installed (for bundling)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

incremental_exec opencode \
    --input "$SCRIPT_DIR/build-opencode.sh" --input "$SCRIPT_DIR/build-opencode-android.ts" \
    --input "$REPO_ROOT/ci/scripts/module-graph-patch.ts" \
    --input "$REPO_ROOT/ci/scripts/patch-opentui-core-runtime.py" \
    --input "$REPO_ROOT/ci/scripts/env.sh" --input "$OPENCODE_SRC" \
    --input "$BUN_BUILD/bun" \
    --input "$OPENTUI_SRC/packages/native/lib/aarch64-linux-android.24/libopentui.so" \
    --value "OPENCODE_VERSION=$OPENCODE_VERSION" --value "BUN_VERSION=$BUN_VERSION" \
    --output "$DIST_DIR/opencode"

HOST_BUN="${HOST_BUN:-bun}"

echo "=== Building OpenCode v${OPENCODE_VERSION} for Android aarch64 ==="

validate_source_checkout "$OPENCODE_SRC" "$OPENCODE_SOURCE_COMMIT" "OpenCode"
echo ">>> OpenCode source exists at $OPENCODE_SRC"

OPENCODE_PKG="$OPENCODE_SRC/packages/cli"

# Install OpenCode dependencies
echo ">>> Installing OpenCode dependencies..."
cd "$OPENCODE_SRC"
"$HOST_BUN" install

# Mirror upstream's packages/cli/script/build.ts: fetch every platform's
# optional native package so the literal dynamic imports in @opentui/core and
# the parcel-watcher binding resolve at bundle time.
echo ">>> Installing all-platform native dependencies..."
NATIVE_SPECS=$(cd "$OPENCODE_SRC" && "$HOST_BUN" -e '
const cli = await Bun.file("packages/cli/package.json").json()
const root = await Bun.file("package.json").json()
const catalog = root.workspaces?.catalog ?? root.catalog ?? {}
const spec = (name) => {
  const v = cli.dependencies[name]
  return v === "catalog:" ? `${name}@${catalog[name]}` : `${name}@${v}`
}
console.log([spec("@opentui/core"), spec("@opencode-ai/pty")].join(" "))
')
(cd "$OPENCODE_PKG" && "$HOST_BUN" install --os="*" --cpu="*" $NATIVE_SPECS)

# The published @opentui/core chunk predates the vendored source guard for
# non-string bundled-file defaults, which crashes the Android TUI. Bring it in
# line with the pinned OpenTUI source before bundling.
echo ">>> Patching @opentui/core runtime for Android..."
python3 "$REPO_ROOT/ci/scripts/patch-opentui-core-runtime.py" --root "$OPENCODE_SRC"

# Find the Android bun binary
ANDROID_BUN="$BUN_BUILD/bun"
if [ ! -f "$ANDROID_BUN" ]; then
    echo "ERROR: Android bun binary not found at $ANDROID_BUN"
    echo "       Run scripts/build-bun.sh first."
    exit 1
fi

# Find ARM64 libopentui.so
# OpenTUI >= 0.5.2 installs the native library under packages/native/lib.
ARM64_LIBOPENTUI="$OPENTUI_SRC/packages/native/lib/aarch64-linux-android.24/libopentui.so"
if [ ! -f "$ARM64_LIBOPENTUI" ]; then
    echo "ERROR: ARM64 libopentui.so not found at $ARM64_LIBOPENTUI"
    echo "       Run scripts/build-opentui.sh first."
    exit 1
fi

# Swap the Android libopentui.so into the package the device will resolve.
# OpenTUI 0.5.x picks @opentui/core-<platform>-<arch> from process.platform/
# arch (OPENTUI_LIBC is defined to glibc, so not the -musl package); on the
# phone that branch is @opentui/core-linux-arm64.
OPENTUI_NODE_MODULE=""
for candidate in \
    "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64/libopentui.so" \
    "$OPENCODE_PKG/node_modules/@opentui/core-linux-arm64/libopentui.so" \
    "$OPENCODE_SRC/node_modules/.bun/@opentui+core-linux-arm64@*/node_modules/@opentui/core-linux-arm64/libopentui.so"
do
    # Handle glob
    for f in $candidate; do
        if [ -f "$f" ]; then
            OPENTUI_NODE_MODULE="$f"
            break 2
        fi
    done
done

BACKUP_FILE=""
BUILD_SCRIPT_LOCAL=""
PATCH_SCRIPT_LOCAL=""

restore_opentui_swap() {
    # If bundling aborts after the swap, never leave the cached dependency
    # polluted with the Android library. This also makes a retry deterministic.
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        rm -f "$OPENTUI_NODE_MODULE"
        mv "$BACKUP_FILE" "$OPENTUI_NODE_MODULE"
    fi
    if [ -n "$BUILD_SCRIPT_LOCAL" ]; then
        rm -f "$BUILD_SCRIPT_LOCAL"
    fi
    if [ -n "$PATCH_SCRIPT_LOCAL" ]; then
        rm -f "$PATCH_SCRIPT_LOCAL"
    fi
}
trap restore_opentui_swap EXIT

if [ -n "$OPENTUI_NODE_MODULE" ]; then
    echo ">>> Swapping @opentui/core-linux-arm64 libopentui.so with the Android build..."
    BACKUP_FILE="${OPENTUI_NODE_MODULE}.host.bak"
    cp "$OPENTUI_NODE_MODULE" "$BACKUP_FILE"
    cp "$ARM64_LIBOPENTUI" "$OPENTUI_NODE_MODULE"
    echo "    Backed up to $BACKUP_FILE"
else
    echo "WARNING: Could not find @opentui/core-linux-arm64 libopentui.so in node_modules"
    echo "         The build may embed the wrong architecture"
fi

# Create dist directory
mkdir -p "$DIST_DIR"

# Run the TypeScript build script
# Copy it into the OpenCode tree so Bun can resolve @opentui/solid/bun-plugin
# from node_modules (Bun resolves bare imports relative to the script file's location)
echo ">>> Building OpenCode standalone binary..."
BUILD_SCRIPT="$SCRIPT_DIR/build-opencode-android.ts"
BUILD_SCRIPT_LOCAL="$OPENCODE_PKG/build-opencode-android.ts"
PATCH_SCRIPT_LOCAL="$OPENCODE_PKG/module-graph-patch.ts"
cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
cp "$REPO_ROOT/ci/scripts/module-graph-patch.ts" "$PATCH_SCRIPT_LOCAL"
cd "$OPENCODE_PKG"

OPENCODE_VERSION="$OPENCODE_VERSION" \
    ANDROID_BUN="$ANDROID_BUN" \
    OUTPUT_DIR="$DIST_DIR" \
    OPENCODE_DIR="$OPENCODE_PKG" \
    "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL"

# Clean up copied scripts
rm -f "$BUILD_SCRIPT_LOCAL" "$PATCH_SCRIPT_LOCAL"

# Restore original libopentui.so
if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo ">>> Restoring original host libopentui.so..."
    mv "$BACKUP_FILE" "$OPENTUI_NODE_MODULE"
fi

# Verify output
OPENCODE_BINARY="$DIST_DIR/opencode"
if [ ! -f "$OPENCODE_BINARY" ]; then
    echo "ERROR: OpenCode binary not found at $OPENCODE_BINARY"
    exit 1
fi

echo ""
echo "=== OpenCode build complete ==="
echo "Binary: $OPENCODE_BINARY"
echo "Size: $(du -h "$OPENCODE_BINARY" | cut -f1)"
file "$OPENCODE_BINARY"
