#!/usr/bin/env bash
# Shared environment for the product workspaces.
# Product scripts source this file; each product owns its WORK_DIR and state.

set -euo pipefail

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Termux owns the process temporary directory. GitHub Actions supplies its
# runner-managed equivalent; otherwise use the canonical Termux directory.
# Validate it before any build helper or compiler is allowed to create files.
if [ -n "${GITHUB_ACTIONS:-}" ] && [ -z "${TMPDIR:-}" ] && [ -n "${RUNNER_TEMP:-}" ]; then
  TMPDIR="$RUNNER_TEMP"
fi
: "${TMPDIR:=/data/data/com.termux/files/usr/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
test -d "$TMPDIR" && test -w "$TMPDIR"

export PRODUCT="${PRODUCT:-opencode}"
export PRODUCT_ROOT="${PRODUCT_ROOT:-$REPO_ROOT/$PRODUCT}"

# Versions
export BUN_VERSION="${BUN_VERSION:-1.2.13}"
export BUN_TAG="bun-v${BUN_VERSION}"
export ICU_VERSION="${ICU_VERSION:-75.1}"
export ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
export OPENCODE_VERSION="${OPENCODE_VERSION:-2.0.24}"
export ANDROID_API="${ANDROID_API:-24}"
export ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.1.13356709}"
export WEBKIT_COMMIT="${WEBKIT_COMMIT:-017930ebf915121f8f593bef61cbbca82d78132d}"

# Bun 1.4.2 para el lane nativo de OpenCode. These are external published
# sources, so ci/external-sources.lock is their only home; nothing here may
# restate them as a default or the workflow would be able to disagree with the
# lock. BUN_VERSION above stays 1.2.13 for the vendored bun/ product and Kilo.
EXTERNAL_SOURCES_LOCK="${EXTERNAL_SOURCES_LOCK:-$REPO_ROOT/ci/external-sources.lock}"
external_source_pin() {
  python3 - "$EXTERNAL_SOURCES_LOCK" "$1" "$2" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
print(lock["sources"][sys.argv[2]][sys.argv[3]])
PY
}
export BUN_ANDROID_RELEASE="$(external_source_pin bun-android-release release)"
export BUN_ANDROID_ASSET="$(external_source_pin bun-android-release asset)"
export BUN_ANDROID_VERSION="$(external_source_pin bun-android-release version)"
export BUN_ANDROID_SHA256="$(external_source_pin bun-android-release sha256)"
export BUN_ANDROID_PORT_COMMIT="$(external_source_pin bun-android-release port_commit)"
export BUN_ANDROID_UPSTREAM_COMMIT="$(external_source_pin bun-android-release upstream_commit)"
export BUN_ANDROID_REVISION_MARKER="$(external_source_pin bun-android-release revision_marker)"
export BUN_ANDROID_MIN_API="$(external_source_pin bun-android-release min_android_api)"
export BUN_BASE_CACHE_NAME="$(external_source_pin bun-android-release fetch_cache_name)"
export BUN_ANDROID_URL="https://github.com/Leonisaurov/bun-android/releases/download/${BUN_ANDROID_RELEASE}/${BUN_ANDROID_ASSET}"
export HOST_BUN_VERSION="$(external_source_pin bun-host-emitter version)"
export HOST_BUN_SHA256="$(external_source_pin bun-host-emitter sha256)"
export HOST_BUN_URL="$(external_source_pin bun-host-emitter url)"
test "$HOST_BUN_VERSION" = "$BUN_ANDROID_VERSION" || {
  echo "ERROR: emitter ${HOST_BUN_VERSION} y base ${BUN_ANDROID_VERSION} divergen en el lock" >&2
  exit 1
}

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

# Source commits are part of the repository contract. The values deliberately
# name commits, not branches or dirty working trees, so a cache cannot hide a
# different source tree.
export BUN_SOURCE_COMMIT="${BUN_SOURCE_COMMIT:-d7b539a544a36e457eab6c7a8a050fba1d4ac6d6}"
export OPENCODE_SOURCE_COMMIT="${OPENCODE_SOURCE_COMMIT:-e7a34f09bfd9134dfade5a8ddb843f7030bc9a69}"
export KILO_SOURCE_COMMIT="${KILO_SOURCE_COMMIT:-ea7ea9f91eacd2539929d53da9376828ca277aa2}"
export OPENTUI_OPENCODE_SOURCE_COMMIT="${OPENTUI_OPENCODE_SOURCE_COMMIT:-31a93fbe66992298d6d0f27481fa781f43d0c1e2}"
export OPENTUI_KILO_SOURCE_COMMIT="${OPENTUI_KILO_SOURCE_COMMIT:-5b3d520550e118fd436f682bd67242b95a05318b}"

# Source checkouts are canonical and never generated inside another product.
export BUN_BUILD_ROOT="${BUN_BUILD_ROOT:-${REPO_ROOT}/bun/build}"
export BUN_SRC="${BUN_SRC:-${REPO_ROOT}/bun/src}"
export WEBKIT_SRC="${WEBKIT_SRC:-${BUN_BUILD_ROOT}/webkit-src}"
export WEBKIT_SOURCE_OVERLAY="${WEBKIT_SOURCE_OVERLAY:-${REPO_ROOT}/bun/webkit}"
export TINYCC_SRC="${TINYCC_SRC:-${REPO_ROOT}/bun/tinycc}"
export TINYCC_BUILD="${TINYCC_BUILD:-${BUN_BUILD_ROOT}/tinycc-build-android}"
export OPENTUI_SRC="${OPENTUI_SRC:-${REPO_ROOT}/opentui/src/opencode}"
export OPENCODE_SRC="${OPENCODE_SRC:-${REPO_ROOT}/opencode/src}"
export ICU_SRC="${ICU_SRC:-${BUN_BUILD_ROOT}/icu-src}"

# OpenCode's Android runtime is the published 1.4.2 base, stripped by
# ci/scripts/materialize-bun-base.sh; the vendored bun/ build is not consumed
# by this lane anymore.
export OPENCODE_BUN_BASE_DIR="${OPENCODE_BUN_BASE_DIR:-${PRODUCT_ROOT}/build/bun-android-base}"
export OPENCODE_BUN_BASE="${OPENCODE_BUN_BASE:-${OPENCODE_BUN_BASE_DIR}/${BUN_ANDROID_ASSET}-stripped}"

# Each product receives an isolated generated area and state graph.
export WORK_DIR="${WORK_DIR:-${PRODUCT_ROOT}/build}"

export DEPS_PREFIX="${DEPS_PREFIX:-${BUN_BUILD_ROOT}/deps-android/prefix}"
export WEBKIT_BUILD="${WEBKIT_BUILD:-${BUN_BUILD_ROOT}/webkit-build}"
export WEBKIT_OUTPUT="${WEBKIT_OUTPUT:-${BUN_BUILD_ROOT}/webkit-android}"
export BUN_BUILD="${BUN_BUILD:-${BUN_BUILD_ROOT}/bun-build}"
export DIST_DIR="${WORK_DIR}/dist"
export BUILD_STATE_DIR="${BUILD_STATE_DIR:-${WORK_DIR}/state}"
export ARTIFACT_DIR="${ARTIFACT_DIR:-${PRODUCT_ROOT}/artifacts}"
export BUN_INSTALL_CACHE="${BUN_INSTALL_CACHE:-${HOME}/.bun/install/cache}"
export BUN_INSTALL_CACHE_DIR="$BUN_INSTALL_CACHE"
export CCACHE_DIR="${CCACHE_DIR:-${WORK_DIR}/cache/ccache}"
export SCCACHE_DIR="${SCCACHE_DIR:-${WORK_DIR}/cache/sccache}"
export CARGO_HOME="${CARGO_HOME:-${WORK_DIR}/cache/cargo}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${WORK_DIR}/target}"
export ZIG_CACHE_DIR="${ZIG_CACHE_DIR:-${WORK_DIR}/cache/zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${WORK_DIR}/cache/zig-global}"
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
echo "Bun 142 base:  ${BUN_ANDROID_RELEASE} (${BUN_ANDROID_ASSET}, api>=${BUN_ANDROID_MIN_API})"
echo "Bun 142 pin:   ${BUN_ANDROID_SHA256}"
echo "Bun 142 base at: ${OPENCODE_BUN_BASE}"
echo "Bun emitter:   ${HOST_BUN_VERSION}"
echo "WebKit source: ${WEBKIT_COMMIT} + monorepo overlay"
echo "OpenCode ver:  ${OPENCODE_VERSION}"
echo "Cache schema:  ci-cache-v2"
echo "Jobs:          ${JOBS}"
echo "==========================================="

validate_source_checkout() {
  local source_dir="$1"
  local expected="$2"
  local label="$3"
  test -d "$source_dir" || { echo "ERROR: missing vendored $label source at $source_dir" >&2; return 1; }
  test ! -e "$source_dir/.git" || {
    echo "ERROR: $label source still contains nested git metadata: $source_dir" >&2
    return 1
  }
  test -n "$expected" # Keep the origin revision in the build contract.
}

ensure_external_checkout() {
  local source_dir="$1"
  local remote="$2"
  local expected="$3"
  local label="$4"
  local actual
  if [ ! -d "$source_dir/.git" ]; then
    mkdir -p "$source_dir"
    git -C "$source_dir" init -q
    git -C "$source_dir" remote add origin "$remote"
    git -C "$source_dir" fetch -q --depth=1 origin "$expected"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
  fi
  actual="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
  test "$actual" = "$expected" || {
    echo "ERROR: $label source is $actual; expected $expected" >&2
    return 1
  }
  test -z "$(git -C "$source_dir" status --porcelain --untracked-files=all)" || {
    echo "ERROR: $label source checkout is dirty: $source_dir" >&2
    return 1
  }
}

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
