#!/usr/bin/env bash
# Build OpenCode standalone binary for Android aarch64
#
# Usage: ./scripts/build-opencode.sh
#
# This script consumes the versioned OpenCode v2 checkout, swaps the Linux
# ARM64 OpenTUI runtime for the Android build, and cross-compiles the
# standalone from packages/cli with `bun build --compile --target=`. The base
# ELF embedded by the compiler is the patched Android runtime, so no module
# graph is appended to the EOF.
#
# Requires:
# - Host Bun 1.4.2 installed (the emitter; pinned in ci/external-sources.lock)
# - Android Bun base materialized (ci/scripts/materialize-bun-base.sh, run here)
# - libopentui.so built (scripts/build-opentui.sh)
# - Network access to the Leonisaurov/bun-android release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

# La base parcheada es un input del estado de build: se materializa antes de
# registrar el nodo para que la ruta exista cuando build-state la resume.
OPENCODE_BUN_BASE="$(bash "$REPO_ROOT/ci/scripts/materialize-bun-base.sh")"
export OPENCODE_BUN_BASE
echo ">>> Bun Android base: $OPENCODE_BUN_BASE"

incremental_exec opencode \
    --input "$SCRIPT_DIR/build-opencode.sh" --input "$SCRIPT_DIR/build-opencode-android.ts" \
    --input "$REPO_ROOT/ci/scripts/materialize-bun-base.sh" \
    --input "$REPO_ROOT/ci/scripts/patch-opentui-core-runtime.py" \
    --input "$REPO_ROOT/ci/external-sources.lock" \
    --input "$REPO_ROOT/ci/scripts/env.sh" --input "$OPENCODE_SRC" \
    --input "$OPENCODE_BUN_BASE" \
    --input "$OPENTUI_SRC/packages/native/lib/aarch64-linux-android.24/libopentui.so" \
    --value "OPENCODE_VERSION=$OPENCODE_VERSION" \
    --value "HOST_BUN_VERSION=$HOST_BUN_VERSION" \
    --value "BUN_ANDROID_PIN=$BUN_ANDROID_SHA256" \
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

# Verify the base carried the whole way here (materialize already gated it).
if [ ! -f "$OPENCODE_BUN_BASE" ]; then
    echo "ERROR: Bun Android base not found at $OPENCODE_BUN_BASE"
    echo "       Run ci/scripts/materialize-bun-base.sh first."
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

# Swap the Android libopentui.so into the package the bundler embeds. Under
# --target=bun-linux-arm64-android the bundler specializes process.platform/arch
# and the plugin maps android onto the linux/arm64 asset descriptor (sonda B7 D2:
# run 38115779161), so the module graph carries only the core-linux-arm64 bytes
# and the phone loads those. The host glibc x64 asset never enters the graph.
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
}
trap restore_opentui_swap EXIT

if [ -n "$OPENTUI_NODE_MODULE" ]; then
    echo ">>> Swapping @opentui/core-linux-arm64 libopentui.so with the Android build..."
    BACKUP_FILE="${OPENTUI_NODE_MODULE}.host.bak"
    cp "$OPENTUI_NODE_MODULE" "$BACKUP_FILE"
    cp "$ARM64_LIBOPENTUI" "$OPENTUI_NODE_MODULE"
    echo "    Backed up to $BACKUP_FILE"
else
    echo "ERROR: Could not find @opentui/core-linux-arm64 libopentui.so in node_modules"
    echo "       The build would embed the host library; refusing to continue."
    exit 1
fi

# Create dist directory
mkdir -p "$DIST_DIR"

# Run the TypeScript build script
# Copy it into the OpenCode tree so Bun can resolve @opentui/solid/bun-plugin
# from node_modules (Bun resolves bare imports relative to the script file's location)
echo ">>> Building OpenCode standalone binary..."
BUILD_SCRIPT="$SCRIPT_DIR/build-opencode-android.ts"
BUILD_SCRIPT_LOCAL="$OPENCODE_PKG/build-opencode-android.ts"
cp "$BUILD_SCRIPT" "$BUILD_SCRIPT_LOCAL"
cd "$OPENCODE_PKG"

OPENCODE_VERSION="$OPENCODE_VERSION" \
    OPENCODE_BUN_BASE="$OPENCODE_BUN_BASE" \
    OPENCODE_BUN_REVISION_MARKER="$BUN_ANDROID_REVISION_MARKER" \
    OPENCODE_LIBOPENTUI="$ARM64_LIBOPENTUI" \
    OPENCODE_BUN_TARGET="bun-linux-arm64-android" \
    OUTPUT_DIR="$DIST_DIR" \
    OPENCODE_DIR="$OPENCODE_PKG" \
    "$HOST_BUN" run "$BUILD_SCRIPT_LOCAL"

rm -f "$BUILD_SCRIPT_LOCAL"

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
