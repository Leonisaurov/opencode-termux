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
  - Fingerprint incremental v3 en `build/.markers/build-fingerprint-codex` (skip total si nada cambió).
  - Obtiene la fuente con el MISMO mecanismo que el CI: helper compartido `scripts/codex-prepare-source.sh` (verifica/clona el ref pinneado `CODEX_REF` desde `scripts/env.sh` y aplica `patches/codex/*.patch` 01..18 con `verify_patched_state`).
  - Compila `codex-cli` (→ `./codex-android`), `codex-tui`, `codex-linux-sandbox` y **`codex-code-mode-host`** para `aarch64-linux-android` (tcr `-o 1000 -r 1024 -j 1` + reintentos anti-OOM; el host se copia a `./codex-code-mode-host`, junto a `./codex-android`).

## 4. Decisiones técnicas

1. **Sandboxing en Android**: No hay `bubblewrap`/`landlock`/`seccomp` útil en Termux. Se mantiene la compilación, pero el flujo de `codex sandbox` falla temprano con mensaje claro.
2. **IDE IPC**: ya usa `SO_PEERCRED` en Android (`tui/src/ide_context/ipc.rs`); se preserva sin cambios.
3. **Clipboard**: `arboard` ya está excluido en Android (`tui/Cargo.toml`). Se mantiene el fallback OSC 52 / tmux.
4. **Certificados**: `network-proxy/src/native_certs.rs` ya incluye la ruta Termux `/data/data/com.termux/files/usr/etc/tls/cert.pem`.
5. **Target Rust**: `aarch64-linux-android` ya está instalado en Termux (`/data/data/com.termux/files/usr/lib/rustlib/aarch64-linux-android/`). No hace falta `rustup target add`.
6. **`.cargo/config.toml`**: Se usa `linker = "aarch64-linux-android-clang"` y `ar = "llvm-ar"`. No se fuerza `crt-static` ni `link-self-contained` para usar la libc del sistema.
7. **`debuginfo=trace-args` inválido**: corregido a `debuginfo=line-tables-only` porque `trace-args` no es un valor válido en esta toolchain.

## 5. Pendientes reales

El port está **completo y publicado**: Release `v0.134.0-alpha.3` con el asset
`codex-v0.134.0-alpha.3-android-aarch64.zip` (los 4 binarios), modo code
funcional en Termux, build local (`./codex_build.sh`) y CI (`build-codex.yml`)
compartiendo el mismo fuente. Todos los pasos históricos de esta sección
(OpenSSL vía `vendored`, artefacto rusty_v8 para V8, sandbox stub, TUI en pty)
quedaron resueltos y documentados en §8.

Pendientes no bloqueantes:

1. **Caveat del instalador**: `install.sh --just codex` resuelve primero
   `releases/latest`; si esa release no trae asset de codex (p.ej. la publicó
   opencode), cae al fallback `releases?per_page=100` ordenado por la API
   (`created_at` desc) y toma el **primer** asset que matchee el patrón — sin
   filtrar por la versión esperada. Si después de `v0.134.0-alpha.3` se publica
   otra release con asset de codex, el fallback instalará esa. Para fijar
   versión concreta: `./install.sh --release v0.134.0-alpha.3 --just codex` (el
   tag de la release de codex es `v<version>`).
2. **Regenerar `rusty-v8-v<CODEX_V8_VERSION>`** al subir la versión del crate
   v8 (ver §8): el artefacto no tiene prebuilt Android y lo consumen CI y local.

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

- **Local (Termux)**: `codex_build.sh` usa el MISMO fuente que el CI (helper
  compartido `scripts/codex-prepare-source.sh`: clona `CODEX_REF` de
  `scripts/env.sh` + aplica `patches/codex/*.patch` 01..18 con
  `verify_patched_state`), descarga el artefacto a `build/rusty-v8/`
  (idempotente, verifica el manifest con `sha256sum -c`), exporta
  `RUSTY_V8_ARCHIVE` + `RUSTY_V8_SRC_BINDING_PATH` y compila
  `-p codex-code-mode-host` junto a `codex-cli`; copia el binario a
  `./codex-code-mode-host` (raíz, junto a `./codex-android`).
- **CI**: `scripts/build-codex-ci.sh` hace lo mismo (`setup_rusty_v8` +
  `-p codex-code-mode-host`) y el zip de release incluye `codex-code-mode-host`
  junto a `codex-android`. El CI usa **sccache** (cache de compilación de cargo,
  key por ref + hashes de `patches/codex/*.patch`) para no recompilar todos los
  crates en cada run.
- Con `RUSTY_V8_ARCHIVE` + `RUSTY_V8_SRC_BINDING_PATH` el crate `v8` **no
  necesita libclang ni NDK** en el build (solo linkea el `.a`); no se fuerza
  ninguna instalación extra.

### Release e instalación

- **Trigger**: push de tag `codex-v*` (NO `v*` — colisiona con los tags de
  opencode) o input `release=true` en `build-codex.yml`. La Release se crea con
  tag `v<version>` (softprops/action-gh-release normaliza el prefijo `codex-v`)
  y el asset `codex-v<version>-android-aarch64.zip`.
- **Input `bins`**: permite compilar/empaquetar solo un subconjunto (p.ej.
  `codex-code-mode-host`) reutilizando el sccache del CI.
- **Precedencia**: la Release `rusty-v8-v<CODEX_V8_VERSION>` DEBE publicarse
  ANTES de correr `build-codex.yml` — `setup_rusty_v8` descarga sus 3 assets y
  verifica el manifest con `sha256sum -c` (fail-fast si no está).
- **Instalación**: `install.sh` (`--just codex` o default) descarga el zip con el
  patrón `codex-v[0-9][0-9A-Za-z._+-]*-android-aarch64\.zip` desde
  `releases/latest` y, si esa release no trae el asset (p.ej. la de opencode),
  cae al fallback `releases?per_page=100` tomando el primer asset que matchee.
  Instala `codex` (de `codex-android`) y `codex-code-mode-host` en `$PREFIX/bin`.

### Requisito runtime (verificado)

El crate `v8` usa `use_custom_libcxx` (feature default de rusty_v8) → el libc++
de V8 queda **estático y embebido** en `librusty_v8.a`, NO se linkea
`libc++_shared.so` dinámico → **no requiere** el paquete Termux `libc++`.
Verificado en esta sesión sobre el binario de la Release:

```bash
readelf -d "$PREFIX/bin/codex-code-mode-host" | grep NEEDED
# → libdl.so  liblog.so  libm.so  libc.so   (SIN libc++_shared.so)
```

Si apareciera `libc++_shared.so` en el NEEDED, instala el paquete Termux
`libc++`: `pkg install libc++` (indicaría un port roto, no el caso actual).

### Link del host contra bionic API 24 (stubs)

`librusty_v8.a` precompilado referencia 4 símbolos que **bionic API 24 no
exporta**: `__clear_cache` (vive en compiler-rt del NDK), `aligned_alloc`
(API 28 en bionic), `strtof_l` y `strtod_l` (glibc). El link del host los
resuelve con:

- **`scripts/bionic-stubs.c`** — stubs compilados contra el clang del NDK
  (`aarch64-linux-android24-clang -c -O2 -Wall -Wextra`) →
  `target/bionic-stubs.o` (define `__clear_cache`/`aligned_alloc`/`strtof_l`/
  `strtod_l`).
- **`libclang_rt.builtins-aarch64-android.a`** del NDK (find en
  `toolchains/llvm/prebuilt`).

Ambas rutas se inyectan al link vía el **build.rs del crate host**
(`codex-rs/code-mode-host/build.rs`, parche 16) leyendo las env vars
`CODEX_BIONIC_STUBS_O` y `CODEX_CLANG_RT_BUILTINS` que exportan
`scripts/build-codex-ci.sh` (CI) y `codex_build.sh` (Termux) — **NO vía
RUSTFLAGS** (un RUSTFLAGS global reemplazaría los rustflags del
`.cargo/config.toml` parcheado, que ya incluyen `target-feature=-crt-static`).

Además, **`openssl-sys` vendored** se declara también en el package manifest de
`code-mode-host` (parche 17) para habilitar builds parciales tipo solo host; no
puede ir en el workspace root porque es un virtual manifest (cargo rechaza
secciones `[target.*]` ahí).

### TLS (p_align 64, skew 0)

El host abortaba en Termux al arrancar:

```
executable's TLS segment is underaligned: alignment is 8 (skew 0)...
needs to be at least 64
```

V8 trae `thread_local` con alineación 8; bionic ARM64 exige el PT_TLS con
`p_align >= 64` y `p_vaddr % 64 == 0` (skew 0). **`termux-elf-cleaner` NO
basta**: sube el p_align a 64 pero introduce skew 32 y el abort persiste
(termux/termux-packages#8273). Fix: **parche 18**
(`patches/codex/18-tls-align-stub.patch`) — stub asm `.tdata .p2align 6` vía
`global_asm!` + ancla `#[used]` que fuerza p_align 64 y skew 0 (Rust stable NO
emite `.tdata` nativo en android: `thread_local!` → emutls, de ahí el asm).

### Por qué es el único port con modo code

termux-user-repository (TUR) publica un paquete `codex` para Termux pero
**omite `codex-code-mode-host`** → el modo code queda fail-closed ("Code Mode is
unavailable"). Este port es el único que compila y publica el host (V8 desde
fuente para `aarch64-linux-android` vía `build-rusty-v8-android.yml`) y lo
instala como binario hermano de `codex`.

### Cómo verificar

```bash
ls -l "$PREFIX/bin/codex" "$PREFIX/bin/codex-code-mode-host"   # ambos presentes
./codex-android                                                # sin warning "Code Mode is unavailable"

file "$PREFIX/bin/codex-code-mode-host"                        # ELF aarch64, for Android 24, built by NDK r28b
readelf -l "$PREFIX/bin/codex-code-mode-host" | grep -A2 TLS   # p_align 0x40 y p_vaddr % 64 == 0 (skew 0)
readelf -d "$PREFIX/bin/codex-code-mode-host" | grep NEEDED    # libdl/liblog/libm/libc (sin libc++_shared.so)
```

### Sandbox de codex en Android (proot)

El sandbox de codex en Android usa el wrapper proot **`codex-linux-sandbox`**
(instalado por `install.sh` en `$PREFIX/bin`). Es **obligatorio** si
`sandbox_mode` es `read-only` o `workspace-write`: con los parches 19/20, sin el
wrapper las tools fallan cerrado (por diseño). Es aislamiento de **conveniencia,
no una frontera de seguridad**: el guest hereda el env del host y la red real
(sin netns no hay red aislada); los dirs sensibles (`~/.ssh`, `~/.codex`,
`~/.aws`, `~/.netrc`, `~/.config/gh`) están ocultos con binds vacíos, pero NO
confíes secretos de producción dentro del sandbox.

