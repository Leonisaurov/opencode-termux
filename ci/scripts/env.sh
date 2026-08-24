#!/usr/bin/env bash
# Shared environment for the product workspaces.
# Product scripts source this file; each product owns its WORK_DIR and state.

set -euo pipefail

# Termux owns the process temporary directory. Validate it before any build
# helper or compiler is allowed to create temporary files.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  : "${TMPDIR:=${RUNNER_TEMP:-${REPO_ROOT:-.}/build/tmp}}"
else
  : "${TMPDIR:=/data/data/com.termux/files/usr/tmp}"
fi
export TMPDIR
mkdir -p "$TMPDIR"
test -d "$TMPDIR" && test -w "$TMPDIR"

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PRODUCT="${PRODUCT:-opencode}"
export PRODUCT_ROOT="${PRODUCT_ROOT:-$REPO_ROOT/$PRODUCT}"

# Versions
export BUN_VERSION="${BUN_VERSION:-1.2.13}"
export BUN_TAG="bun-v${BUN_VERSION}"
export WEBKIT_COMMIT="${WEBKIT_COMMIT:-017930ebf915121f8f593bef61cbbca82d78132d}"
export ICU_VERSION="${ICU_VERSION:-75.1}"
export ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
export OPENCODE_VERSION="${OPENCODE_VERSION:-1.3.13}"
export ANDROID_API="${ANDROID_API:-24}"
export ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.1.13356709}"

# Android NDK
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-/opt/android-ndk}"
export ANDROID_ABI=arm64-v8a
export ANDROID_ARCH=aarch64
export ANDROID_TRIPLE="aarch64-linux-android"
export ANDROID_TRIPLE_API="${ANDROID_TRIPLE}${ANDROID_API}"

# NDK toolchain paths
export NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
export NDK_SYSROOT="${NDK_TOOLCHAIN}/sysroot"
export ANDROID_CC="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang"
export ANDROID_CXX="${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang++"
export ANDROID_AR="${NDK_TOOLCHAIN}/bin/llvm-ar"
export ANDROID_RANLIB="${NDK_TOOLCHAIN}/bin/llvm-ranlib"
export ANDROID_STRIP="${NDK_TOOLCHAIN}/bin/llvm-strip"
export ANDROID_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
export ANDROID_LD="${NDK_TOOLCHAIN}/bin/ld.lld"

# Source checkouts are canonical and never generated inside another product.
export BUN_BUILD_ROOT="${BUN_BUILD_ROOT:-${REPO_ROOT}/bun/build}"
export BUN_SRC="${BUN_SRC:-${REPO_ROOT}/bun/src}"
export WEBKIT_SRC="${WEBKIT_SRC:-${BUN_BUILD_ROOT}/webkit-src}"
export OPENTUI_SRC="${OPENTUI_SRC:-${REPO_ROOT}/opentui/src/opencode}"
export OPENCODE_SRC="${OPENCODE_SRC:-${REPO_ROOT}/opencode/src}"
export ICU_SRC="${ICU_SRC:-${BUN_BUILD_ROOT}/icu-src}"

# Each product receives an isolated generated area and state graph.
export WORK_DIR="${WORK_DIR:-${PRODUCT_ROOT}/build}"

export DEPS_PREFIX="${DEPS_PREFIX:-${BUN_BUILD_ROOT}/deps-android/prefix}"
export WEBKIT_BUILD="${WEBKIT_BUILD:-${BUN_BUILD_ROOT}/webkit-build}"
export WEBKIT_OUTPUT="${WEBKIT_OUTPUT:-${BUN_BUILD_ROOT}/webkit-android}"
export BUN_BUILD="${BUN_BUILD:-${BUN_BUILD_ROOT}/bun-build}"
export DIST_DIR="${WORK_DIR}/dist"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-${WORK_DIR}/state}"
export ARTIFACT_DIR="${ARTIFACT_DIR:-${PRODUCT_ROOT}/artifacts}"
export BUN_STATE_DIR="${BUN_STATE_DIR:-${BUN_BUILD_ROOT}/state}"
export OPENTUI_STATE_DIR="${OPENTUI_STATE_DIR:-${REPO_ROOT}/opentui/build/state}"
export OPENCODE_STATE_DIR="${OPENCODE_STATE_DIR:-${REPO_ROOT}/opencode/build/state}"

# Number of parallel jobs (can be overridden for low-RAM machines)
export JOBS="${JOBS:-$(nproc)}"

echo "=== Android Build Environment (${PRODUCT}) ==="
echo "Repo root:     ${REPO_ROOT}"
echo "Work dir:      ${WORK_DIR}"
echo "NDK:           ${ANDROID_NDK_HOME}"
echo "API Level:     ${ANDROID_API}"
echo "Target:        ${ANDROID_TRIPLE}"
echo "Bun version:   ${BUN_VERSION}"
echo "WebKit commit: ${WEBKIT_COMMIT}"
echo "OpenCode ver:  ${OPENCODE_VERSION}"
echo "Jobs:          ${JOBS}"
echo "==========================================="

# Run a legacy build script through the shared content-addressed state engine.
# Each caller supplies the node metadata and this function appends the caller
# script as the command. The guard is re-entrant so the actual script body runs
# exactly once after a cache miss.
incremental_exec() {
  if [ "${BUILD_STATE_ACTIVE:-0}" = "1" ]; then
    return 0
  fi
  local node="$1"
  shift
  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  exec env BUILD_STATE_ACTIVE=1 python3 "$REPO_ROOT/ci/scripts/build-state.py" run \
    --root "$REPO_ROOT" --state-dir "$BUILD_STATE_DIR" --node "$node" \
    --input "$REPO_ROOT/ci/scripts/build-state.py" "$@" -- "$script_path"
}
