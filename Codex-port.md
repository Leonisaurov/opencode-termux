# Codex-port.md — Port de Codex CLI a Termux / bionic / aarch64

## 1. Objetivo

Compilar y ejecutar **OpenAI Codex CLI** (`codex-rs`) en **Termux** (Android), target **aarch64-linux-android**, contra **bionic** y sin depender de `rustup`.

## 2. Entorno objetivo

- **OS**: Android / Termux
- **Arquitectura**: aarch64
- **libc**: bionic (`aarch64-linux-android.24`)
- **Toolchain Rust**: paquete Termux (`rustc`/`cargo`), **sin `rustup`**
- **NDK**: r29 (`29.0.14033849` o `r29-termux`)
- **Clang**: `aarch64-linux-android-clang` 21.1.8
- **Restricción**: `tcr` puede estar en `~/.local/bin`; no asumir que está en `PATH`

## 3. Estado actual

### 3.1 Cambios aplicados en `codex/codex-rs/`

| Archivo | Cambio |
|---|---|
| `.cargo/config.toml` | Se agregó `[target.aarch64-linux-android]` con linker `aarch64-linux-android-clang`, `ar = "llvm-ar"` y `rustflags` para bionic/NDK. |
| `sandboxing/src/lib.rs` | `cfg(target_os = "linux")` ampliado a `cfg(any(target_os = "linux", target_os = "android"))` para `mod bwrap` y sus `pub use`. Stub `system_bwrap_warning` ahora cubre `not(any(linux, android))`. |
| `sandboxing/src/manager.rs` | `get_platform_sandbox()` devuelve `None` en Android. |
| `cli/src/main.rs` | `HostSandboxArgs` usa `LandlockCommand` en Android. Rama `Subcommand::Sandbox` compila para Android y queda deshabilitada por `debug_sandbox.rs`. |
| `cli/src/debug_sandbox.rs` | `run_command_under_landlock` compila en Android; hace `bail!` temprano con mensaje “no soportado en Android/Termux”. |
| `linux-sandbox/Cargo.toml` | Dependencies y dev-dependencies condicionales extendidas a `android`. |
| `linux-sandbox/src/main.rs` | `main` compila en Android; imprime mensaje de no soporte y hace `exit(1)` en lugar de panic. |

### 3.2 Script de build

- **Archivo**: `./codex_build.sh`
- **Características**:
  - Sin `rustup`. Usa `cargo`/`rustc` del sistema.
  - Detecta `tcr` en `~/.local/bin` y lo agrega al `PATH` si existe.
  - Detecta NDK automáticamente en `ANDROID_NDK_HOME`, `$HOME/Android/Sdk/ndk/*`, `$PREFIX/opt/android-ndk`, `/opt/android-ndk`, `$HOME/android-ndk`.
  - Fingerprint incremental en `build/.markers/build-fingerprint-codex`.
  - Compila `codex-cli`, `codex-tui` y `codex-linux-sandbox` para `aarch64-linux-android`.
  - Copia el binario final a `./codex-android`.

## 4. Decisiones técnicas

1. **Sandboxing en Android**: No hay `bubblewrap`/`landlock`/`seccomp` útil en Termux. Se mantiene la compilación, pero el flujo de `codex sandbox` falla temprano con mensaje claro.
2. **IDE IPC**: ya usa `SO_PEERCRED` en Android (`tui/src/ide_context/ipc.rs`); se preserva sin cambios.
3. **Clipboard**: `arboard` ya está excluido en Android (`tui/Cargo.toml`). Se mantiene el fallback OSC 52 / tmux.
4. **Certificados**: `network-proxy/src/native_certs.rs` ya incluye la ruta Termux `/data/data/com.termux/files/usr/etc/tls/cert.pem`.
5. **Target Rust**: `aarch64-linux-android` ya está instalado en Termux (`/data/data/com.termux/files/usr/lib/rustlib/aarch64-linux-android/`). No hace falta `rustup target add`.
6. **`.cargo/config.toml`**: Se usa `linker = "aarch64-linux-android-clang"` y `ar = "llvm-ar"`. No se fuerza `crt-static` ni `link-self-contained` para usar la libc del sistema.
7. **`debuginfo=trace-args` inválido**: corregido a `debuginfo=line-tables-only` porque `trace-args` no es un valor válido en esta toolchain.

## 5. Próximos pasos

1. Ejecutar `./codex_build.sh` en Termux y verificar que `./codex-android` se genere.
2. Correr `./codex-android --version` para sanity-check del binario.
3. Probar TUI real en pty de Termux; verificar que `ratatui` + `crossterm` funcionen contra el backend de terminal.
4. Si `cargo build` falla por dependencias nativas (OpenSSL, SQLite, V8), evaluar:
   - Usar `openssl-sys` con `vendored` o prebuilt Android.
   - Usar `libsqlite3-sys` con `bundled` si no encuentra SQLite bionic.
   - Evaluar si `v8-poc` es necesario para el build de producción; si no, excluirlo.
5. Evaluar si `syntect`/`two-face` compilan en Android; si no, gatearlos detrás de un feature condicional.
6. Evaluar integración de `codex-linux-sandbox` en Android; por ahora es stub, pero si se necesita sandboxing real, investigar alternativas nativas (no bubblewrap).

## 6. Archivos de referencia

- `codex/codex-rs/.cargo/config.toml`
- `codex/codex-rs/sandboxing/src/lib.rs`
- `codex/codex-rs/sandboxing/src/manager.rs`
- `codex/codex-rs/cli/src/main.rs`
- `codex/codex-rs/cli/src/debug_sandbox.rs`
- `codex/codex-rs/linux-sandbox/Cargo.toml`
- `codex/codex-rs/linux-sandbox/src/main.rs`
- `codex_build.sh`
- `AGENTS.md` (raíz del repo) — lineamientos del proyecto
- `codex/AGENTS.md` — lineamientos específicos de `codex-rs`

## 7. Notas adicionales

- No hay `rustup` en Termux. Todo el build debe usar el toolchain del sistema (`cargo`/`rustc` de `pkg`).
- `tcr` puede estar en `~/.local/bin`; el build script lo detecta ahí.
- NDK está en `/data/data/com.termux/files/home/Android/ndk/` con dos variantes: `29.0.14033849` y `r29-termux`.
- El target Rust `aarch64-linux-android` ya está instalado en el prefix de Termux.
- `cargo check` en este entorno no produjo avance útil; confiar en el build local en Termux.

## 8. Modo code / `codex-code-mode-host`

### Qué es

`codex-code-mode-host` es el **runtime companion out-of-process** del modo code
de Codex: un proceso hermano con **V8 embebido** (crates `codex-code-mode-host` +
`code-mode-runtime`, protocolo protobuf por stdio) que ejecuta el agente de
código de forma aislada del CLI principal. El CLI lo exige como **binario
hermano del ejecutable** (`current_exe.parent()/codex-code-mode-host`); si no
está presente, el modo code falla cerrado con `Code Mode is unavailable...`.

### Por qué hace falta el artefacto `rusty_v8`

`code-mode-runtime` depende de `v8 = "=150.4.0"` (rusty_v8, feature
`v8_enable_sandbox` → sufijo `ptrcomp_sandbox`). **No existe prebuilt de
`librusty_v8` para `aarch64-linux-android`** (ni Denoland ni OpenAI publican
ese target) → hay que compilar V8 desde fuente (`V8_FROM_SOURCE=1`, GN/ninja,
NDK r26c que descarga el build.rs, API 24) en el workflow
**`build-rusty-v8-android.yml`** (runner x86_64 `ubuntu-24.04`, ~60-90 min,
sccache + actions/cache) y publicar el resultado en la Release del port con
tag `rusty-v8-v<CODEX_V8_VERSION>` (versión pinneada en `scripts/env.sh`,
default `150.4.0`). Los 3 artefactos publicados:

- `librusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.a.gz` (gzip -6, mtime=0)
- `src_binding_ptrcomp_sandbox_release_aarch64-linux-android.rs`
- `rusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.sha256` (manifest de exactamente 2 líneas)

### Cómo se integra

- **Local (Termux)**: `codex_build.sh` descarga el artefacto a `build/rusty-v8/`
  (idempotente, verifica el manifest con `sha256sum -c`), exporta
  `RUSTY_V8_ARCHIVE` + `RUSTY_V8_SRC_BINDING_PATH` y compila
  `-p codex-code-mode-host` junto a `codex-cli`; copia el binario a
  `./codex-code-mode-host` (raíz, junto a `./codex-android`).
- **CI**: `scripts/build-codex-ci.sh` hace lo mismo (`setup_rusty_v8` +
  `-p codex-code-mode-host`) y el zip de release incluye `codex-code-mode-host`
  junto a `codex-android`.
- **Instalación**: `install.sh` (`--just codex` o default) instala `codex` y
  `codex-code-mode-host` en `$PREFIX/bin`.
- Con `RUSTY_V8_ARCHIVE` + `RUSTY_V8_SRC_BINDING_PATH` el crate `v8` **no
  necesita libclang ni NDK** en el build (solo linkea el `.a`); no se fuerza
  ninguna instalación extra.

### Requisito runtime

El crate `v8` usa `use_custom_libcxx` (feature default de rusty_v8) → el libc++
de V8 queda **estático y embebido** en `librusty_v8.a`, NO se linkea
`libc++_shared.so` dinámico. Por lo tanto **no debería requerir** el paquete
Termux `libc++`. Verifícalo con:

```bash
readelf -d "$PREFIX/bin/codex-code-mode-host" | grep NEEDED
```

Si apareciera `libc++_shared.so` en el NEEDED, instala el paquete Termux
`libc++`: `pkg install libc++`.

### Cómo verificar

```bash
ls -l "$PREFIX/bin/codex" "$PREFIX/bin/codex-code-mode-host"   # ambos presentes
./codex-android                                                # sin warning "Code Mode is unavailable"
```

