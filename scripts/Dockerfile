# Build with:
#   docker build -t ghcr.io/YOUR_USER/opencode-builder -f scripts/Dockerfile .
# Push to GitHub Container Registry with:
#   docker push ghcr.io/YOUR_USER/opencode-builder
#
# The GitHub Actions workflow .github/workflows/docker-image.yml
# automates this.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_NDK_HOME=/opt/android-ndk
ENV ZIG_VERSION=0.15.2
ENV WORK_DIR=/home/builder/build

RUN useradd -u 1001 -U -m -s /bin/bash builder && \
    echo "builder ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder

# ── System packages ─────────────────────────────────────────
RUN apt-get update -qq && \
    apt-get install -y -qq ninja-build python3 ruby perl git curl wget unzip \
      xz-utils zip build-essential pkg-config libxml2-dev libxslt1-dev \
      golang-go autoconf automake libtool ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ── CMake 3.28+ ─────────────────────────────────────────────
RUN CMAKE_VER="3.28.6" && \
    cd /tmp && \
    wget -q "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/cmake-${CMAKE_VER}-linux-x86_64.tar.gz" -O cmake.tar.gz && \
    tar xzf cmake.tar.gz -C /opt/ && \
    ln -sf "/opt/cmake-${CMAKE_VER}-linux-x86_64/bin/cmake" /usr/local/bin/cmake && \
    ln -sf "/opt/cmake-${CMAKE_VER}-linux-x86_64/bin/ctest" /usr/local/bin/ctest && \
    rm cmake.tar.gz

# ── Android NDK r28b ────────────────────────────────────────
RUN cd /tmp && \
    wget -q "https://dl.google.com/android/repository/android-ndk-r28b-linux.zip" -O ndk.zip && \
    mkdir -p "$ANDROID_NDK_HOME" && \
    unzip -q ndk.zip -d /tmp/ndk-extract && \
    mv /tmp/ndk-extract/android-ndk-r28b/* "$ANDROID_NDK_HOME/" && \
    rm -rf /tmp/ndk.zip /tmp/ndk-extract

ENV PATH="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}"

# ── Rust + Android target ───────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    $HOME/.cargo/bin/rustup target add aarch64-linux-android

ENV PATH="${HOME}/.cargo/bin:${PATH}"

# ── Zig ─────────────────────────────────────────────────────
RUN cd /tmp && \
    wget -q "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -O zig.tar.xz && \
    mkdir -p "${WORK_DIR}/zig-${ZIG_VERSION}" && \
    tar xf zig.tar.xz -C "${WORK_DIR}/zig-${ZIG_VERSION}" --strip-components=1 && \
    rm zig.tar.xz

ENV ZIG_BIN="${WORK_DIR}/zig-${ZIG_VERSION}/zig"
ENV PATH="${WORK_DIR}/zig-${ZIG_VERSION}:${PATH}"

# ── Bun host 1.3.2 ──────────────────────────────────────────
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.2"
ENV PATH="${HOME}/.bun/bin:${PATH}"

USER builder:builder
WORKDIR /home/builder
