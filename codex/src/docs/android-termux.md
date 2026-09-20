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

## File locks

Rust's `std::fs::File::lock`, `try_lock`, `lock_shared` and `try_lock_shared`
return `ErrorKind::Unsupported` ("lock() not supported") on
`aarch64-linux-android`: std only implements flock for a target list that does
not include Android (checked against 1.95 through 1.98). Any unpatched call site
fails at runtime, which previously broke startup (curated plugins sync,
app-server control socket), the network-proxy CA cache, history paging, and the
`rules/default.rules` write behind "don't ask again".

Every such site carries a `CODEX-TERMUX-ANDROID-PATCH` marker and skips the
advisory flock under `#[cfg(target_os = "android")]`, because the Termux runtime
is single-user. A new upstream lock site will regress silently, so validate a
built binary with:

```sh
bash codex/test/lock-regression/run.sh /path/to/codex-android
```

The harness boots the real app-server against a scripted Responses API stand-in,
answers a command approval with an execpolicy amendment, and fails if the
binary reports `lock() not supported`, if no `allow` rule lands in
`<CODEX_HOME>/rules/default.rules`, or if the approved command does not run.

## Termux rules

Use `TMPDIR` for temporary files and validate it before builds. In Termux the
canonical fallback is `/data/data/com.termux/files/usr/tmp`; do not introduce
`/tmp` or `/data/local/tmp` into Android scripts. Keep NDK, Cargo, target, and
sccache directories outside the source checkout when the surrounding build
workflow specifies them.
