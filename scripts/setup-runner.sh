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
echo "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin" >> "$GITHUB_PATH"
echo "NDK: $(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android"*clang 2>/dev/null | head -1)"

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
  echo "=== Installing Bun host v1.3.2 ==="
  curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.2"
fi
echo "$HOME/.bun/bin" >> "$GITHUB_PATH"
export PATH="$HOME/.bun/bin:$PATH"
echo "Bun host: $(bun --version 2>/dev/null || echo 'not found')"

echo "=== Setup complete ==="
df -h .
