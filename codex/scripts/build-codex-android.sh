#!/usr/bin/env bash
# Build the Codex Android CLI and code-mode host through the shared state graph.
# The Codex checkout is intentionally kept isolated under ./codex.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../ci/scripts/env.sh"

CODEX_SRC="${CODEX_SRC:-$REPO_ROOT/codex/src}"
CODEX_TARGET_DIR="${CODEX_TARGET_DIR:-$WORK_DIR/codex-target}"
CODEX_OUT="${CODEX_OUT:-$ARTIFACT_DIR/codex-android}"
CODEX_HOST_OUT="${CODEX_HOST_OUT:-$ARTIFACT_DIR/codex-code-mode-host}"
CODEX_SANDBOX_OUT="${CODEX_SANDBOX_OUT:-$ARTIFACT_DIR/codex-linux-sandbox}"

incremental_exec codex \
    --input "$SCRIPT_DIR/build-codex-android.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
    --input "$CODEX_SRC/codex-rs" \
    --value "ANDROID_API=$ANDROID_API" \
    --value "ANDROID_NDK_VERSION=$ANDROID_NDK_VERSION" \
    --value "CODEX_TARGET_DIR=$CODEX_TARGET_DIR" \
    --value "RUSTY_V8_ARCHIVE=${RUSTY_V8_ARCHIVE:-}" \
    --value "RUSTY_V8_SRC_BINDING_PATH=${RUSTY_V8_SRC_BINDING_PATH:-}" \
    --output "$CODEX_OUT" --output "$CODEX_HOST_OUT"

if [ ! -f "$CODEX_SRC/codex-rs/Cargo.toml" ]; then
    echo "ERROR: Codex checkout not found at $CODEX_SRC"
    echo "       Work on Codex only inside the ./codex directory."
    exit 1
fi

if [ ! -x "$ANDROID_CC" ]; then
    echo "ERROR: Android compiler not found: $ANDROID_CC"
    echo "       Set ANDROID_NDK_HOME to the installed NDK."
    exit 1
fi

# The code-mode host embeds Rusty V8. Requiring its pinned CI artifact here
# prevents Cargo from silently downloading/building a second, incompatible V8.
if [ -z "${RUSTY_V8_ARCHIVE:-}" ] || [ -z "${RUSTY_V8_SRC_BINDING_PATH:-}" ]; then
    echo "ERROR: Codex code-mode host requires RUSTY_V8_ARCHIVE and RUSTY_V8_SRC_BINDING_PATH."
    echo "       Produce the pinned Rusty V8 artifact first (see .github/workflows/build-rusty-v8-android.yml)."
    exit 1
fi

export CARGO_TARGET_DIR="$CODEX_TARGET_DIR"
export CARGO_BUILD_TARGET="$ANDROID_TRIPLE"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$ANDROID_CC"
export CC_aarch64_linux_android="$ANDROID_CC"
export CXX_aarch64_linux_android="$ANDROID_CXX"
export AR_aarch64_linux_android="$ANDROID_AR"
export RANLIB_aarch64_linux_android="$ANDROID_RANLIB"
export RUSTY_V8_ARCHIVE RUSTY_V8_SRC_BINDING_PATH

# V8's Android arm64 CPU code calls compiler-rt's __clear_cache. The NDK
# linker does not add that archive when Cargo invokes the target clang, so
# append it through a linker wrapper. Using target-specific RUSTFLAGS would
# replace the upstream .cargo/config.toml flags; the wrapper preserves them
# and appends the archive after all objects and libraries. This checkout is
# cloned externally in CI, so the fix belongs in this port script.
CLANG_RT_BUILTINS="$(find "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang" \
    -type f -name 'libclang_rt.builtins-aarch64-android.a' -print -quit)"
if [ -z "$CLANG_RT_BUILTINS" ] || [ ! -s "$CLANG_RT_BUILTINS" ]; then
    echo "ERROR: Android compiler runtime not found under ${ANDROID_NDK_HOME}" >&2
    exit 1
fi
LINKER_WRAPPER="$CODEX_TARGET_DIR/android-linker"
mkdir -p "$CODEX_TARGET_DIR"
cat > "$LINKER_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$ANDROID_CC" "\$@" "$CLANG_RT_BUILTINS"
EOF
chmod 0755 "$LINKER_WRAPPER"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$LINKER_WRAPPER"
echo "Android compiler runtime: $CLANG_RT_BUILTINS"

cd "$CODEX_SRC/codex-rs"
CORE_MANIFEST="$CODEX_SRC/codex-rs/core/Cargo.toml"
if ! grep -qF '[target.aarch64-linux-android.dependencies]' "$CORE_MANIFEST"; then
    cat >> "$CORE_MANIFEST" <<'EOF'

# Build OpenSSL from source for Android cross-compilation.
[target.aarch64-linux-android.dependencies]
openssl-sys = { workspace = true, features = ["vendored"] }
EOF
fi

cargo build --locked --release --target "$ANDROID_TRIPLE" \
    --package codex-cli --package codex-code-mode-host

install -m 0755 "$CODEX_TARGET_DIR/$ANDROID_TRIPLE/release/codex" "$CODEX_OUT"
install -m 0755 "$CODEX_TARGET_DIR/$ANDROID_TRIPLE/release/codex-code-mode-host" "$CODEX_HOST_OUT"
install -m 0755 "$SCRIPT_DIR/codex-linux-sandbox" "$CODEX_SANDBOX_OUT"
echo "Codex outputs: $CODEX_OUT and $CODEX_HOST_OUT"
