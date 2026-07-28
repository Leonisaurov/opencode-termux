#!/usr/bin/env bash
# Helper to run the docker build locally (for testing)
set -e

DOCKER_IMAGE="${DOCKER_IMAGE:-termux/termux-docker:aarch64}"
BUN_BINARY="${BUN_BINARY:-./build/bun-build/bun}"

if [ ! -f "$BUN_BINARY" ]; then
  echo "Error: Bun binary not found at $BUN_BINARY"
  echo "Set BUN_BINARY env var or build bun first"
  exit 1
fi

docker run --rm --platform linux/arm64 \
  -v "$(dirname "$BUN_BINARY"):/bun" \
  -v "$PWD:/workspace" \
  "$DOCKER_IMAGE" \
  bash -c '
    set -e
    cp /bun/$(basename $BUN_BINARY) /data/data/com.termux/files/usr/bin/bun 2>/dev/null || \
      cp /bun/bun /data/data/com.termux/files/usr/bin/bun
    chmod +x /data/data/com.termux/files/usr/bin/bun
    bun --version
    echo "Ready!"
  '
