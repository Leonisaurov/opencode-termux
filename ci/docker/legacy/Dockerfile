FROM termux/termux-docker:aarch64

# Install base tools
RUN apt update && apt install -y git tar xz-utils binutils patchelf

# Copy and setup our Android Bun
# (bun binary will be mounted at runtime or copied during CI)
