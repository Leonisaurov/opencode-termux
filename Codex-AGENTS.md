# Codex-AGENTS.md — Port Android de OpenAI Codex CLI

Guía de agente del port **Codex v0.134.0-alpha.3** (Rust puro, sin Bun/Zig/libopentui)
de [openai/codex](https://github.com/openai/codex) → Termux / aarch64 / bionic API 24.
Compila 4 binarios: `codex-cli` (→ `codex-android`), `codex-tui`, `codex-linux-sandbox`
(stub que degrada en Android) y **`codex-code-mode-host`** — runtime companion del
**modo code** con **V8 embebido** (crate `v8`/rusty_v8 150.4.0, `v8_enable_sandbox`).
El modo code **funciona en Termux**: es el único port del ecosistema que incluye el
host (termux-user-repository lo omite → fail-closed, "Code Mode is unavailable").

## Fuente de verdad

- `scripts/env.sh` pinnea: `CODEX_REF` (commit `50ef7395…`), `CODEX_VERSION`
  (0.134.0-alpha.3) y `CODEX_V8_VERSION` (150.4.0). Subir de versión = tocar esto.
- LOCAL y CI comparten el **mismo** fuente vía `scripts/codex-prepare-source.sh`:
  verifica/clona `CODEX_REF` + aplica `patches/codex/*.patch` (orden 01..18) con
  `verify_patched_state` (byte-idéntico, fail-fast). **NO edites `codex/` a mano**:
  es el checkout local gitignored; un cambio manual rompe el verify y no llega a CI.
- Catálogo completo de los 18 parches con el pin del commit base: `patches/codex/README.md`.

## Comandos

```bash
# Artefacto V8 (solo si cambia CODEX_V8_VERSION o se perdió la Release)
gh workflow run build-rusty-v8-android.yml --ref update-v1.18.6
gita notify build-rusty-v8-android.yml   # ~60-90 min

# Build + Release de codex (bins default: codex tui linux-sandbox codex-code-mode-host)
gh workflow run build-codex.yml --ref update-v1.18.6 -f release=true
# Solo un binario (rápido, p.ej. solo el host):
gh workflow run build-codex.yml --ref update-v1.18.6 -f bins=codex-code-mode-host
gita notify build-codex.yml

# Instalación desde la Release
./install.sh --just codex

# Build local (misma fuente que CI; fingerprint v3; tcr anti-OOM)
./codex_build.sh   # → codex-android + codex-code-mode-host

# Verificar binario del host
file codex-code-mode-host
readelf -l codex-code-mode-host | grep -A2 TLS     # p_align 0x40 y p_vaddr % 64 == 0 (skew 0)
readelf -d codex-code-mode-host | grep NEEDED      # libdl/liblog/libm/libc (sin libc++_shared.so)
```

## Trampas (todas reales, probadas en sesión)

- **TLS**: el host aborta en Termux ("TLS segment is underaligned: alignment is 8 (skew 0)... needs ≥ 64"). Fix obligatorio = parche 18 (stub `.tdata .p2align 6` → p_align 64, skew 0). **termux-elf-cleaner NO basta**: sube el p_align a 64 pero introduce skew 32 → sigue abortando (termux/termux-packages#8273).
- **Símbolos bionic API 24** faltantes (`aligned_alloc`, `strtof_l`, `strtod_l`, `__clear_cache`) → `scripts/bionic-stubs.c` + `libclang_rt.builtins-aarch64-android.a` del NDK, inyectados por el build.rs del crate host (parche 16, env vars `CODEX_BIONIC_STUBS_O`/`CODEX_CLANG_RT_BUILTINS`). **NUNCA vía RUSTFLAGS**: un RUSTFLAGS global reemplaza el `.cargo/config.toml` parcheado y rompe el link (tampoco en `codex_build.sh`).
- **`--locked` NO** en cargo de codex: los parches desincronizan el Cargo.lock de upstream (se regenera; `codex_build.sh` restaura `git checkout -- Cargo.lock` al final para que `verify_patched_state` siga pasando). En el build de V8 **SÍ** se usa `--locked` (build-rusty-v8-android.yml, `cargo +1.91.0 build --locked`).
- **NO `BINDGEN_EXTRA_CLANG_ARGS_*`** genéricas para el bindgen de v8: se filtran TAMBIÉN a las host tools x86_64 del ninja y rompen con `-msse3`. El parche `bindgen-android-sysroot.patch` añade la rama android en `build_binding()` (`--target=aarch64-linux-android24` + `--sysroot` del NDK r26c), solo para el bindgen del crate.
- **V8 solo en runner x86_64**: el NDK r26c que descarga el build.rs del crate v8 solo trae host `linux-x86_64` (no usar runner ARM64).
- **`codex-code-mode-host` = binario hermano**: el CLI lo busca como `current_exe.parent()/codex-code-mode-host`; sin él el modo code falla cerrado. `install.sh` lo instala junto a `codex` en `$PREFIX/bin`; el zip de release DEBE incluirlo.
- **Trigger push de codex = `codex-v*`** (NO `v*`: colisiona con los tags de opencode). Con tag `codex-v*` o `-f release=true` la Release sale con tag `v<version>` (softprops normaliza el prefijo `codex-v`).
- **Orden de publicación**: la Release `rusty-v8-v<CODEX_V8_VERSION>` DEBE existir ANTES de correr `build-codex.yml` — `setup_rusty_v8` descarga sus 3 assets y verifica el manifest con `sha256sum -c` (fail-fast si no está publicada).
- **`install.sh --just codex`** usa releases/latest con fallback `releases?per_page=100` (patrón `codex-v[0-9][0-9A-Za-z._+-]*-android-aarch64\.zip`); si se publica otra release después, latest puede cambiar — el fallback lo cubre.
- **Sandbox proot obligatorio**: el wrapper `codex-linux-sandbox` (instalado por `install.sh` en `$PREFIX/bin`) es **obligatorio** si `sandbox_mode` es `read-only`/`workspace-write` — con los parches 19/20, sin él las tools fallan cerrado (por diseño). Aislamiento de **conveniencia, no frontera de seguridad**: el guest hereda el env del host y la red real; los dirs sensibles (`~/.ssh`, `~/.codex`, `~/.aws`, `~/.netrc`, `~/.config/gh`) están ocultos con binds vacíos en el guest, pero NO confíes secretos de producción dentro del sandbox.

## Verificación de artefactos

```bash
file codex-code-mode-host   # ELF 64-bit LSB pie executable, ARM aarch64, ... for Android 24, built by NDK r28b
readelf -l codex-code-mode-host | grep -A2 TLS   # p_align 0x40 (64) y p_vaddr % 64 == 0 → skew 0
readelf -d codex-code-mode-host | grep NEEDED    # libdl.so liblog.so libm.so libc.so — SIN libc++_shared.so
```

No debe listar `libc++_shared.so`: V8 usa `use_custom_libcxx` → libc++ estático embebido
en `librusty_v8.a` (si apareciera, `pkg install libc++`, pero eso indicaría un port roto).

## Referencias

- `AGENTS.md` → sección "Codex (port Rust, V8 embebido)", Pipeline, Cachés y Pendientes.
- `Codex-port.md` → diseño completo del port; §8 "Modo code" con requisitos runtime.
- `patches/codex/README.md` → catálogo 01..18 + parches de rusty_v8.
- Fuentes ejecutables: `codex_build.sh`, `scripts/codex-prepare-source.sh`, `scripts/build-codex-ci.sh`,
  workflows `.github/workflows/build-codex.yml` y `build-rusty-v8-android.yml`.
