# Patches Android/Termux para openai/codex

Modificaciones Android del checkout `codex/` convertidas en parches reproducibles para CI.
Se aplican sobre un checkout limpio de **openai/codex** en el commit pinneado.

## Pin (commit base)

```
50ef7395faee1d0e2d01730f9636aa06091c7be3  Report I/O subtypes for session config import failures (#37723)
```

Generado desde el checkout local (`git -C codex diff HEAD`) en la rama `main` de openai/codex.

## Parches y orden de aplicación

Orden **numérico** estricto (01 → 32). Cada parche toca exactamente un archivo (requisito de `scripts/build-codex-ci.sh`); los parches que crean archivos quedan como untracked `??` tras `git apply` — `verify_patched_state` acepta ` M ` y `??`):

| # | Archivo | Propósito |
|---|---------|-----------|
| 01 | `codex-rs/.cargo/config.toml` | Sección `[target.aarch64-linux-android]` (linker NDK, ar llvm-ar, rustflags: `target-feature=-crt-static`, `split-debuginfo=off`, `debuginfo=line-tables-only`, `force-frame-pointers=yes`, `--build-id=none`, `-fuse-ld=lld`). **`link-self-contained=no` NO se usa** (flag no soportado en targets `*-linux-android` con rustc 1.95.0 → error al linkear bins) |
| 02 | `codex-rs/sandboxing/src/lib.rs` | Extiende cfg `target_os = "linux"` → `any(linux, android)` para bwrap y `system_bwrap_warning` |
| 03 | `codex-rs/sandboxing/src/manager.rs` | `get_platform_sandbox`: **android cae en `LinuxSeccomp`** igual que linux — la rama `cfg!(target_os = "linux")` pasa a `cfg!(any(target_os = "linux", target_os = "android"))` (el `else { None }` final de android NO serviría). Combinado con el 19, el runtime de codex spawna `codex-linux-sandbox --sandbox-policy-cwd … --permission-profile … -- <cmd>` y el wrapper proot aplica el aislamiento de filesystem |
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
| 17 | `codex-rs/code-mode-host/Cargo.toml` | `openssl-sys = { workspace = true, features = ["vendored"] }` en `[target.aarch64-linux-android.dependencies]` del **package manifest de code-mode-host** — necesario para builds parciales como solo code-mode-host. NO puede ir en el workspace root: es un virtual manifest (solo `[workspace]`) y cargo rechaza secciones `[target.*]` ahí (`error: this virtual manifest specifies a target section, which is not allowed`). El grafo de code-mode-host no contiene openssl-sys (solo `core` lo arrastra, vía codex-cli); la sección unifica la feature vendored cuando el build combina este crate con crates que sí lo traen |
| 18 | `codex-rs/code-mode-host/src/main.rs` | Stub TLS asm (`.tdata` `.p2align 6`) en el bin del host: bionic ARM64 exige el PT_TLS con `p_align >= 64` y `p_vaddr % 64 == 0` (skew 0); V8 trae `thread_local` con alineación 8 y sin el stub el segmento TLS nace con skew != 0 y el linker64 aborta (`"executable's TLS segment is underaligned"`). Rust stable NO puede emitir `.tdata` nativo en android (`thread_local!` → emutls), de ahí `core::arch::global_asm!` con `.fill 64, 1, 0x2a` + ancla `#[used]` (evita que el linker descarte el stub) |
| 19 | `codex-rs/arg0/src/lib.rs` | Activa el **sandbox de codex en Android** vía `codex_linux_sandbox_exe`: en la rama `target_os = "android"` resuelve el exe del sandbox desde la env `CODEX_LINUX_SANDBOX_EXE` (si está seteada y es un archivo) o buscando `codex-linux-sandbox` en los dirs de `PATH` (búsqueda manual con `split_paths`, sin `which`); si no lo encuentra → `None` (comportamiento previo). La rama linux queda intacta. El exe resuelto es el wrapper bash `scripts/codex-linux-sandbox` del port (instalado en `$PREFIX/bin` por `install.sh`), que ejecuta las tools bajo proot |
| 20 | `codex-rs/execpolicy/src/amend.rs` | Omite `File::lock()` al persistir reglas aprobadas en Android/bionic (`default.rules`), cuyo `flock` devuelve `ErrorKind::Unsupported`; conserva el lock advisory en otros sistemas. |
| 21 | `codex-rs/tui/Cargo.toml` | Añade `axum` al TUI para el API HTTP opcional. |
| 22 | `codex-rs/tui/src/lib.rs` | Registra el módulo de API sin activarlo por defecto. |
| 23 | `codex-rs/tui/src/app.rs` | Arranca el API solo con `CODEX_APPROVAL_API=1`. |
| 24 | `codex-rs/tui/src/app_command.rs` | Añade el comando interno de steer remoto. |
| 25 | `codex-rs/tui/src/app_event_sender.rs` | Enruta steer y decisiones remotas por el canal normal de la TUI. |
| 26 | `codex-rs/tui/src/app/thread_routing.rs` | Ejecuta steer contra el turno activo. |
| 27 | `codex-rs/tui/src/chatwidget/tool_requests.rs` | Publica solicitudes de comandos/cambios al API opcional y autoacepta prefijos de sesión. |
| 28 | `codex-rs/tui/src/approval_api.rs` | API autenticada `/v1/state`, `/v1/approvals/:id` y `/v1/steer`; reglas en memoria, sin tocar `default.rules`. |
| 29 | `codex-rs/tui/src/app/app_server_requests.rs` | Elimina del estado remoto las aprobaciones resueltas localmente desde la TUI. |
| 30 | `codex-rs/arg0/src/lib.rs` | Omite `try_lock` en Android para los directorios temporales de aliases; bionic no soporta advisory file locks, pero el descriptor permanece abierto para conservar el guard. |
| 31 | `codex-rs/sandboxing/src/bwrap.rs` | Suprime en Android el aviso de bubblewrap: el port usa `codex-linux-sandbox`/proot y no requiere el prerrequisito Linux de desktop. |
| 32 | `codex-rs/Cargo.toml` | Embebe la versión del port (`0.134.0-alpha.3`) en lugar de `0.0.0`, para que `codex --version` y `doctor` reporten correctamente la versión instalada. |

## Comando de aplicación

```bash
# $CODEX_SRC = checkout limpio de openai/codex en el pin 50ef7395
git -C "$CODEX_SRC" apply --check patches/codex/*.patch
git -C "$CODEX_SRC" apply patches/codex/*.patch
```

Los paths de los parches son relativos a la raíz del repo openai/codex (`codex-rs/...`),
por lo que `git apply` (p1 implícito) funciona sin ajustes.

## API opcional y plugin ntfy

La TUI expone el API únicamente cuando `CODEX_APPROVAL_API=1` y
`CODEX_APPROVAL_API_TOKEN` está configurado. El consumidor externo es
`scripts/codex-ntfy-plugin.ts`; la TUI continúa siendo la fuente de verdad y
ntfy solo es un canal remoto adicional. Ver `scripts/codex-ntfy-plugin.md`.

## Validación

- `git apply --check` individual: 32/32 OK sobre worktree limpio en `50ef7395`.
- `git apply --check` conjunto (wildcard 01-20): OK.
- `git apply` 01-20 en orden sobre worktree limpio: OK.
- Aplicados todos sobre el worktree limpio: el diff resultante es **byte-idéntico**
  al diff del checkout modificado (`git -C codex diff HEAD`).
- Sintaxis de los archivos tocados por los parches 05 y 10-15 validada con `rustfmt --check` (stable, exit OK).
