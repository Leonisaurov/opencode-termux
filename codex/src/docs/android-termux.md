# Android/Termux Port Notes

This checkout is the Codex source tree used by the Android/Termux port. Keep
source changes here, under `codex-rs/`; do not edit generated binaries or
cached copies as a substitute for source changes.

## Target and toolchain

The supported target is `aarch64-linux-android` with Android API 24. The Rust
target configuration is in `codex-rs/.cargo/config.toml` and expects the NDK
tools `aarch64-linux-android-clang` and `llvm-ar` on `PATH`. The code-mode host
also needs Bionic/Clang runtime stubs supplied by the Android build workflow
through `CODEX_BIONIC_STUBS_O` and `CODEX_CLANG_RT_BUILTINS`.

Build and test commands are run from `codex/` unless noted:

```sh
cd codex
just fmt
just test -p codex-cli
```

Use the crate-specific test after changing a crate. Do not run a full
workspace test casually on a device; cross-compilation is resource-intensive
and the Android target cannot execute on an x86_64 build host.

## Sandbox limitation

Android does not provide the Linux sandbox primitives expected by the upstream
CLI. The Android runtime uses the separately supplied `codex-linux-sandbox`
wrapper, which invokes Termux `proot` for filesystem isolation. It is a
convenience boundary only: it does not provide network namespaces or strong
anti-exfiltration guarantees. The native `codex-rs/linux-sandbox` executable
must not be described as a working Android sandbox.

## Termux rules

Use `TMPDIR` for temporary files and validate it before builds. In Termux the
canonical fallback is `/data/data/com.termux/files/usr/tmp`; do not introduce
`/tmp` or `/data/local/tmp` into Android scripts. Keep NDK, Cargo, target, and
sccache directories outside the source checkout when the surrounding build
workflow specifies them.
