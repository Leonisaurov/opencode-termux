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

## Reported client version

The backend gates models by their `minimal_client_version` (`gpt-5.6-sol`,
`gpt-5.6-terra` and `gpt-5.6-luna` need 0.144.0, `gpt-6-astra` needs 0.153.0), so
a build pinned to an older upstream release only receives the models its version
satisfies and every newer model fails with "requires a newer version of Codex".

`codex-protocol`'s `client_version` module lets a build report another version
through `CODEX_REPORTED_CLIENT_VERSION`, which feeds the HTTP User-Agent (both
the prefix and the app-server identity suffix) and the models endpoint's
`client_version` parameter. It is unset by default.

Measured on 2026-09-21 with a 0.134.0-alpha.3 build:

- the models endpoint honours the override: with `0.155.1` the account catalog
  returns `gpt-reserve`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`;
- a turn for `gpt-5.6-luna` still fails with
  `400 ... requires a newer version of Codex`, also with `9.9.9`, with the
  first-party originators `codex_cli_rs` / `codex-tui`, and with a fresh
  `installation_id`.

The inference gate is therefore evaluated server-side against the authenticated
account/session, not against anything the client sends, so raising the reported
version cannot unlock newer models. Re-vendoring upstream is the only supported
path; keep the override for catalog/diagnostic work only.

## Termux rules

Use `TMPDIR` for temporary files and validate it before builds. In Termux the
canonical fallback is `/data/data/com.termux/files/usr/tmp`; do not introduce
`/tmp` or `/data/local/tmp` into Android scripts. Keep NDK, Cargo, target, and
sccache directories outside the source checkout when the surrounding build
workflow specifies them.
