# Patches Android/Termux para openai/codex

Modificaciones Android del checkout `codex/` convertidas en parches reproducibles para CI.
Se aplican sobre un checkout limpio de **openai/codex** en el commit pinneado.

## Pin (commit base)

```
50ef7395faee1d0e2d01730f9636aa06091c7be3  Report I/O subtypes for session config import failures (#37723)
```

Generado desde el checkout local (`git -C codex diff HEAD`) en la rama `main` de openai/codex.

## Parches y orden de aplicación

Orden **numérico** estricto (01 → 09). Cada parche toca un único archivo:

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

## Comando de aplicación

```bash
# $CODEX_SRC = checkout limpio de openai/codex en el pin 50ef7395
git -C "$CODEX_SRC" apply --check patches/codex/*.patch
git -C "$CODEX_SRC" apply patches/codex/*.patch
```

Los paths de los parches son relativos a la raíz del repo openai/codex (`codex-rs/...`),
por lo que `git apply` (p1 implícito) funciona sin ajustes.

## Validación

- `git apply --check` individual: 8/8 OK sobre worktree limpio en `50ef7395`.
- `git apply --check` conjunto (wildcard 01-09): OK.
- `git apply` 01-09 en orden sobre worktree limpio: OK.
- Aplicados todos sobre el worktree limpio: el diff resultante es **byte-idéntico**
  al diff del checkout modificado (`git -C codex diff HEAD`).
- Sintaxis del archivo tocado por el parche 05 validada con `rustfmt --check` (stable, exit OK).
