# Patches Android/Termux para openai/codex

Modificaciones Android del checkout `codex/` convertidas en parches reproducibles para CI.
Se aplican sobre un checkout limpio de **openai/codex** en el commit pinneado.

## Pin (commit base)

```
50ef7395faee1d0e2d01730f9636aa06091c7be3  Report I/O subtypes for session config import failures (#37723)
```

Generado desde el checkout local (`git -C codex diff HEAD`) en la rama `main` de openai/codex.

## Parches y orden de aplicación

Orden **numérico** estricto (01 → 16). Cada parche toca exactamente un archivo (requisito de `scripts/build-codex-ci.sh`); el 16 lo CREA (nuevo, queda como untracked `??` tras `git apply` — `verify_patched_state` acepta ` M ` y `??`):

| # | Archivo | Propósito |
|---|---------|-----------|
| 01 | `codex-rs/.cargo/config.toml` | Sección `[target.aarch64-linux-android]` (linker NDK, ar llvm-ar, rustflags: `target-feature=-crt-static`, `split-debuginfo=off`, `debuginfo=line-tables-only`, `force-frame-pointers=yes`, `--build-id=none`, `-fuse-ld=lld`). **`link-self-contained=no` NO se usa** (flag no soportado en targets `*-linux-android` con rustc 1.95.0 → error al linkear bins) |
| 02 | `codex-rs/sandboxing/src/lib.rs` | Extiende cfg `target_os = "linux"` → `any(linux, android)` para bwrap y `system_bwrap_warning` |
| 03 | `codex-rs/sandboxing/src/manager.rs` | `get_platform_sandbox` en Android devuelve `None` (sin sandbox) |
| 04 | `codex-rs/cli/src/main.rs` | `HostSandboxArgs` = `LandlockCommand` y llamada a `run_command_under_landlock` en Android |
| 05 | `codex-rs/cli/src/debug_sandbox.rs` | `run_command_under_landlock` compilable en Android: cfg `any(linux, android)`, `bail!` divergente en android, y **todo el cuerpo linux envuelto en `#[cfg(target_os = "linux")] { ... }`** (sin código muerto type-checkeado en android) |
| 06 | `codex-rs/linux-sandbox/Cargo.toml` | Dependencias target `any(linux, android)` |
| 07 | `codex-rs/linux-sandbox/src/main.rs` | En Android imprime "no soportado" y exit(1) en vez de llamar `run_main()` |
| 08 | `codex-rs/code-mode-protocol/build.rs` | En Android **no** usa `protoc-bin-vendored` (binarios glibc) → fallback `protoc` de Termux (paquete `protobuf`); CI linux intacto |
| 09 | `codex-rs/core/Cargo.toml` | Activa `vendored` de openssl-sys para `[target.aarch64-linux-android.dependencies]` → openssl-src cross-compilado en CI (sin openssl del sistema); `openssl-src` ya está en Cargo.lock, `--locked` intacto |
| 10 | `codex-rs/core/src/installation_id.rs` | Salta el `file.lock()?` en Android (`#[cfg(not(target_os = "android"))]`): Rust std no soporta flock en bionic (ErrorKind::Unsupported) y rompía el arranque del app server embebido ("failed to start embedded app server") |
| 11 | `codex-rs/thread-store/src/local/writer_lock.rs` | Neutraliza los flock del thread-store en Android: `try_lock` → siempre `Ok(())` (adquirir writer y limpiar locks stale) y salta `file.lock()` del coordination lock (rompía `thread/start` en el bootstrap TUI: "failed to acquire thread writer coordination lock") |
| 12 | `codex-rs/message-history/src/lib.rs` | Neutraliza flock del historial en Android: `try_lock` en `append_entry` y `try_lock_shared` en `lookup_history_entry` → siempre adquiridos (`Ok(())`) |
| 13 | `codex-rs/rollout/src/maintenance.rs` | `try_acquire_rollout_maintenance_lock`: `try_lock` → siempre `Ok(())` en Android (mantiene compresión/migración de rollouts operativas) |
| 14 | `codex-rs/rmcp-client/src/oauth/refresh_lock.rs` | Neutraliza el flock de refresh OAuth de MCP en Android: `try_lock` en `RefreshCredentialLock::acquire_in` → siempre `Ok(())` (refresh de credenciales OAuth MCP no falla) |
| 15 | `codex-rs/rmcp-client/src/oauth/store_lock.rs` | Neutraliza el flock del store OAuth de MCP en Android: `try_lock` en `OAuthStoreLock::acquire_in` → siempre `Ok(())` (login/actualización del store OAuth MCP no falla) |
| 16 | `codex-rs/code-mode-host/build.rs` (NUEVO) | Build script del crate host que inyecta los link-args de los stubs bionic (`CODEX_BIONIC_STUBS_O`) y del compiler-rt del NDK (`CODEX_CLANG_RT_BUILTINS`) vía `cargo:rustc-link-arg` cuando las env vars están presentes (leídas de los build scripts del port). El crate v8 (use_custom_libcxx) referencia `__clear_cache`/`aligned_alloc`/`strtof_l`/`strtod_l` que bionic API 24 no exporta. Mecanismo scoped al crate, aditivo — NO usa RUSTFLAGS (reemplazaría los rustflags del config.toml) |

## Comando de aplicación

```bash
# $CODEX_SRC = checkout limpio de openai/codex en el pin 50ef7395
git -C "$CODEX_SRC" apply --check patches/codex/*.patch
git -C "$CODEX_SRC" apply patches/codex/*.patch
```

Los paths de los parches son relativos a la raíz del repo openai/codex (`codex-rs/...`),
por lo que `git apply` (p1 implícito) funciona sin ajustes.

## Validación

- `git apply --check` individual: 16/16 OK sobre worktree limpio en `50ef7395`.
- `git apply --check` conjunto (wildcard 01-16): OK.
- `git apply` 01-16 en orden sobre worktree limpio: OK.
- Aplicados todos sobre el worktree limpio: el diff resultante es **byte-idéntico**
  al diff del checkout modificado (`git -C codex diff HEAD`).
- Sintaxis de los archivos tocados por los parches 05 y 10-15 validada con `rustfmt --check` (stable, exit OK).
