#!/bin/bash
# setup-runner.sh — Install all build dependencies on a GitHub Actions runner.
# Must be sourced (source scripts/setup-runner.sh) or run as script.
# Expects env vars: ANDROID_NDK_HOME, WORK_DIR, ZIG_VERSION

set -euo pipefail

# ── Free disk space ────────────────────────────────────────────
echo "=== Freeing disk space ==="
sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/share/boost /opt/hostedtoolcache 2>/dev/null || true
df -h .

# ── System packages ─────────────────────────────────────────────
echo "=== Installing system packages ==="
sudo apt-get update -qq
sudo apt-get install -y -qq ninja-build python3 ruby perl git curl wget unzip \
  xz-utils zip build-essential pkg-config libxml2-dev libxslt1-dev \
  golang-go autoconf automake libtool 2>&1 | tail -5

# ── LLVM/Clang 21 (required by Bun 1.3.14 configure) ────────────
echo "=== Installing LLVM/Clang 21 ==="
if ! command -v clang-21 &>/dev/null; then
  wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh
  chmod +x /tmp/llvm.sh
  sudo /tmp/llvm.sh 21 all -qq 2>&1 | tail -3 || true
  rm -f /tmp/llvm.sh
fi
echo "clang-21: $(clang-21 --version 2>/dev/null | head -1 || echo 'not found')"

# Symlink NDK compiler-rt into clang-21's resource dir for Android linking
echo "=== Setting up NDK compiler-rt symlinks for clang-21 ==="
NDK_CLANG_VER="19"  # NDK r28 ships clang 19
ANDROID_TRIPLE_DIR="aarch64-unknown-linux-android28"
LLVM_CLANG_DIR="/usr/lib/llvm-21/lib/clang/21"
LLVM_LIB_LINUX="${LLVM_CLANG_DIR}/lib/linux"
LLVM_LIB_TRIPLE="${LLVM_CLANG_DIR}/lib/${ANDROID_TRIPLE_DIR}"
NDK_PREBUILT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
NDK_CLANG_LIB="${NDK_PREBUILT}/lib/clang/${NDK_CLANG_VER}/lib/linux"

if [ -d "$NDK_CLANG_LIB" ]; then
  sudo mkdir -p "$LLVM_LIB_TRIPLE" "${LLVM_LIB_LINUX}/aarch64"
  sudo ln -sf "${NDK_CLANG_LIB}/libclang_rt.builtins-aarch64-android.a" "${LLVM_LIB_TRIPLE}/libclang_rt.builtins.a"
  sudo ln -sf "${NDK_CLANG_LIB}/aarch64/libunwind.a" "${LLVM_LIB_TRIPLE}/libunwind.a"
  sudo ln -sf "${NDK_CLANG_LIB}/libclang_rt.builtins-aarch64-android.a" "${LLVM_LIB_LINUX}/libclang_rt.builtins-aarch64-android.a"
  sudo ln -sf "${NDK_CLANG_LIB}/aarch64/libunwind.a" "${LLVM_LIB_LINUX}/aarch64/libunwind.a"
  echo "    NDK compiler-rt symlinks created"
else
  echo "    WARNING: NDK runtime dir not found at $NDK_CLANG_LIB"
fi

# ── CMake 3.28+ ─────────────────────────────────────────────────
if ! cmake --version 2>/dev/null | grep -q "3\.2[89]\|3\.[3-9]"; then
  echo "=== Installing CMake 3.28.6 ==="
  CMAKE_VER="3.28.6"
  cd /tmp
  wget -q "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/cmake-${CMAKE_VER}-linux-x86_64.tar.gz" -O cmake.tar.gz
  sudo tar xzf cmake.tar.gz -C /opt/
  sudo ln -sf "/opt/cmake-${CMAKE_VER}-linux-x86_64/bin/cmake" /usr/local/bin/cmake
  sudo ln -sf "/opt/cmake-${CMAKE_VER}-linux-x86_64/bin/ctest" /usr/local/bin/ctest
  sudo ln -sf "/opt/cmake-${CMAKE_VER}-linux-x86_64/bin/cpack" /usr/local/bin/cpack
  rm cmake.tar.gz
fi
echo "CMake: $(cmake --version | head -1)"

# ── Android NDK ─────────────────────────────────────────────────
if [ ! -d "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64" ]; then
  echo "=== Installing Android NDK r28b ==="
  cd /tmp
  wget -q "https://dl.google.com/android/repository/android-ndk-r28b-linux.zip" -O ndk.zip
  mkdir -p "$ANDROID_NDK_HOME"
  unzip -q ndk.zip -d /tmp/ndk-extract
  mv /tmp/ndk-extract/android-ndk-r28b/* "$ANDROID_NDK_HOME/"
  rm -rf /tmp/ndk.zip /tmp/ndk-extract

fi

# ── Bionic stubs (dl, pthread, rt, util están en libc.so en Android) ──
echo "=== Creating Bionic library stubs ==="
SYSROOT_LIB="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"
for lib in libdl.so libpthread.so librt.so libutil.so; do
  if [ ! -f "${SYSROOT_LIB}/${lib}" ]; then
    echo 'INPUT(-lc)' > "${SYSROOT_LIB}/${lib}"
    echo "  Created stub: ${SYSROOT_LIB}/${lib}"
  fi
done
for lib in libdl.a libpthread.a librt.a libutil.a; do
  if [ ! -f "${SYSROOT_LIB}/${lib}" ]; then
    echo 'INPUT(-lc)' > "${SYSROOT_LIB}/${lib}"
    echo "  Created stub: ${SYSROOT_LIB}/${lib}"
  fi
done
echo "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin" >> "$GITHUB_PATH"
echo "NDK: $(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android"*clang 2>/dev/null | head -1)"
echo "ANDROID_NDK_ROOT=${ANDROID_NDK_HOME}" >> "$GITHUB_ENV"

# ── Rust + Android target ───────────────────────────────────────
if ! command -v rustup &>/dev/null; then
  echo "=== Installing Rust ==="
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
  export PATH="$HOME/.cargo/bin:$PATH"
fi
rustup target add aarch64-linux-android
echo "Rust: $(rustc --version)"

# ── Zig ─────────────────────────────────────────────────────────
if [ ! -f "${WORK_DIR}/zig-${ZIG_VERSION}/zig" ]; then
  echo "=== Installing Zig ${ZIG_VERSION} ==="
  mkdir -p "${WORK_DIR}"
  cd /tmp
  wget -q "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -O zig.tar.xz
  mkdir -p "${WORK_DIR}/zig-${ZIG_VERSION}"
  tar xf zig.tar.xz -C "${WORK_DIR}/zig-${ZIG_VERSION}" --strip-components=1
  rm zig.tar.xz
fi
echo "ZIG_BIN=${WORK_DIR}/zig-${ZIG_VERSION}/zig" >> "$GITHUB_ENV"
echo "${WORK_DIR}/zig-${ZIG_VERSION}" >> "$GITHUB_PATH"
echo "Zig: $(${WORK_DIR}/zig-${ZIG_VERSION}/zig version 2>/dev/null)"

# ── Bun host ────────────────────────────────────────────────────
if [ ! -f "$HOME/.bun/bin/bun" ]; then
  echo "=== Installing Bun host v1.3.14 ==="
  curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14"
fi
echo "$HOME/.bun/bin" >> "$GITHUB_PATH"
export PATH="$HOME/.bun/bin:$PATH"
echo "Bun host: $(bun --version 2>/dev/null || echo 'not found')"

echo "=== Setup complete ==="
df -h .
