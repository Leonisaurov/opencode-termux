# opencode-termux

Infraestructura de **ports nativos de CLIs de IA para Termux** (aarch64) sobre una base común: **Android Bun 1.3.14 cross-compilado (bionic)** + **libopentui.so** + parches de standalone. Tres casos de uso de primera clase:

- **OpenCode** ([anomalyco/opencode](https://github.com/anomalyco/opencode), default v1.18.11) — compilado en **CI** (`build-opencode.yml`, runner ARM64 nativo)
- **Kilo Code CLI** v7.4.20 ([Kilo-Org/kilocode](https://github.com/Kilo-Org/kilocode), fork de opencode) — compilado **en local en Termux** (`./kilocode_build.sh` → `./kilo-android`)
- **OpenAI Codex CLI** v0.134.0-alpha.3 ([openai/codex](https://github.com/openai/codex), pin `CODEX_REF` en `scripts/env.sh`) — **Rust puro** (sin Bun/Zig/libopentui): `./codex_build.sh` (local) + `build-codex.yml` (CI); incluye `codex-code-mode-host` (modo code con **V8 embebido**)

## Branch activa

- `update-v1.18.6` es la rama de trabajo; `main` está atrás.
- `scripts/env.sh` es la fuente de verdad de versiones: Bun **1.3.14**, Zig **0.15.2**, ICU **75.1**, OpenCode **1.18.11**, API **24**, Codex **0.134.0-alpha.3** (`CODEX_REF`/`CODEX_VERSION`) y crate v8 **150.4.0** (`CODEX_V8_VERSION`). Los binarios oficiales de Bun para Android no funcionan → se cross-compila desde fuente.

## Pipeline

```
CI (GitHub Actions):  build-bun.yml → build-opentui.yml → build-opencode.yml (ubuntu-24.04-arm)
                       build-rusty-v8-android.yml → build-codex.yml (ubuntu-24.04/ubuntu-latest, cargo cross)
Termux (local):       ./opencode_build.sh | ./kilocode_build.sh | ./codex_build.sh  (tcr anti-OOM)
```

- **build-bun.yml** — cross-compila Bun 1.3.14 (`scripts/build.ts` → `build.ninja` → `ninja`); aplica `patches/` ANTES del build; cache key `bun-android-1.3.14-<hashes>` (SHA256 de todos los parches).
- **build-opentui.yml** — libopentui.so con el Zig **estándar** de ziglang.org 0.15.2 (NO el fork oven-sh/zig de Bun). CI: target `aarch64-linux-musl` + `patchelf --add-needed libc.so`. Cache `opentui-android-<commit>` (key por commit → upgrade = cambiar el pin `opentui_ref`, nada más).
- **build-opencode.yml** — ensambla en runner **ARM64 nativo** (host==target). Restaura `bun-android-*` (`fail-on-cache-miss: true`) y `opentui-android-<commit>` (si cache miss, recompila el .so en el runner). Host Bun = release oficial `bun-linux-aarch64.zip` pinneado a v1.3.14 (DEBE coincidir con el target: module graph). `bun build --compile --compile-executable-path=<android-bun>` + patchelf al .so (NEEDED libc.so + libm.so) → Release con 3 assets (opencode zip + bun tar.gz + libopentui.so tar.gz) en tag `v*` o input `release=true`.
- **Local** — `opencode_build.sh`/`kilocode_build.sh` compilan libopentui.so contra **bionic** (`aarch64-linux-android.24`, NO musl) y ensamblan con el Android Bun local; fingerprint incremental (skip total si nada cambió).
- **build-rusty-v8-android.yml** — compila desde fuente el artefacto `librusty_v8` para `aarch64-linux-android` (el crate v8 no tiene prebuilt Android): runner x86_64 `ubuntu-24.04`, `V8_FROM_SOURCE=1`, NDK r26c, API 24, ~87 min, sccache + actions/cache. Publica la Release `rusty-v8-v<CODEX_V8_VERSION>` con 3 assets (`librusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.a.gz`, `src_binding_…rs`, manifest `.sha256` de 2 líneas). Parches `patches/rusty-v8/` (android-ndk-args + bindgen-android-sysroot).
- **build-codex.yml** — cross-compila Codex (Rust puro contra el NDK r28b recortado a aarch64) en runner x86_64 `ubuntu-latest` con sccache; inputs `bins` (solo los binarios deseados) y `release`; tag `codex-v*` (no colisiona con `v*` de opencode) → Release con tag `v<version>` (softprops). `scripts/build-codex-ci.sh` descarga el artefacto rusty_v8 (`setup_rusty_v8`, verifica manifest sha256), compila y empaqueta `codex-v<version>-android-aarch64.zip` con `codex-android` (+ tui/sandbox/host según `bins`).
- **Local codex** — `codex_build.sh` (Termux, tcr anti-OOM, fingerprint v3) usa el MISMO mecanismo de obtención de fuente que el CI: helper compartido `scripts/codex-prepare-source.sh` (verifica/clona el ref pinneado `CODEX_REF` desde `scripts/env.sh` y aplica los parches `patches/codex/*.patch` 01..18 con `verify_patched_state`). Local y CI comparten el mismo código fuente.

## ⚠️ Cómo NO compilar

- **NUNCA `--compile-executable-path` desde host x86_64** (cross-arch): inyecta la sección `.bun` vía `elf.zig:writeBunSection()` y corrompe el ELF Android ARM64 (SIGTRAP en startup). Solo funciona donde host==target (runner `ubuntu-24.04-arm`).
- **NUNCA `--target=bun-linux-arm64-android`**: errores de resolución de módulos.
- **NO compilar Bun en Termux** (`scripts/build-bun.sh`): OOM killer mata procesos >500 MB RAM. Los builds de los ports (opencode/kilo) SÍ corren en Termux con `tcr` y `JOBS=3` (JOBS=1 en RAM baja).
- **`$TMPDIR`, no `/tmp`** en Termux: `/data/data/com.termux/files/usr/tmp`. Ahí van caches zig, el .so materializado (Fix4) y los zips del installer.
- **CI: NO usar `curl.sh latest`** para el host bun — debe ser la release oficial pinneada (1.3.14).

## Stack (no-obvio)

- **Dos Zigs**: Bun necesita el fork `oven-sh/zig`; OpenTUI usa ziglang.org 0.15.2. NO mezclar.
- **Host Bun == target Bun** (1.3.14) para compatibilidad del module graph inyectado.
- **ICU 75.1** se cross-compila desde fuente (sin prebuilt Android).
- **Bionic stubs**: `libdl.so`/`libpthread.so`/`librt.so`/`libutil.so` no existen en NDK (están en libc) → stubs `INPUT(-lc)` en `setup-runner.sh` (CI) y `kilocode_build.sh` (local).
- **Clang 21** requerido por el configure de Bun 1.3.14; NDK trae Clang 19 → symlinks de compiler-rt en `setup-runner.sh`.
- **Strip ARM64**: `build.ninja` usa `/usr/bin/strip` (x86_64) → `build-bun.sh` lo parchea a `llvm-strip` del NDK.
- **API level 24**: mínimo para Termux 64-bit.
- **`@parcel/watcher`**: binding `.node` no sirve en Android.
- **`bun upgrade`** deshabilitado en Android.
- libopentui.so: **CI = musl + patchelf**; **local = bionic (`android.24`)** con NEEDED libc/libm nativo.

## Parches

Aplicados por `scripts/apply-patches.sh` salvo nota; la cache key de bun incluye sus SHA256:

| Parche | Estado | Propósito |
|--------|--------|-----------|
| `bun/pr31198.diff` | ✅ | Fix `CouldntReadCurrentDirectory` en Android |
| `bun/android-default-backend.patch` | ✅ | Default install backend = symlink |
| `bun/android-standalone-raw-append.patch` | ✅ | inject() raw append + fallback fromExecutable() (trailer al final del archivo) |
| `bun/android-global-shebang-fix.patch` | ✅ | Shebangs `node`→`bun` en global install |
| `bun/android-global-transitive-deps.patch` | ✅ | Verifica transitivas + resolver en global install |
| `bun/android-global-path-reconstruction.patch` | ✅ | Reconstruye path global node_modules desde cache |
| `bun/android-global-resolve-fallback.patch` | ✅ | Fallback resolución de transitivas globales |
| `bun/android-platform-fallback.patch` | ✅ | Mapea `android-arm64`→`linux-arm64` para bindings |
| `bun/android-bun-ghost.patch` | ✅ | Satisface peer/dep `bun` con paquete fantasma local (evita `bun@npm`, postinstall falla en Android) |
| `bun/android-config-tinycc.patch` | ✅ | TinyCC para Android |
| `bun/android-system-allocator.patch` | ✅ | Allocator Scudo |
| `bun/android-bionic-allocator.patch` | ✅ | Allocator bionic formal (sin mimalloc) |
| `bun/android-tagged-pointers.patch` | ✅ | Desactiva TBI en ARM64 (Scudo abort) |
| `bun/android-resolver-logical-path.patch` | ✅ | Path lógico node_modules para symlinks del cache |
| `bun/android-bunx-node-shim.patch` | ✅ | TMPDIR en el shim node→bun (`bun x`) |
| `webkit/android-support.patch` | ✅ | JSC Android: polling traps, aligned_alloc |
| `zig/posix-android-sigaction.patch` | 🔄 build-bun.sh | Al vendor/zig que descarga Bun |
| `bun/android-support.patch` | ⏭️ SKIPPED | Ya en Bun 1.3.14 upstream |
| `bun/build-zig-no-link-obj.patch` | 📎 inline python3 | build.zig compat Zig 0.15.2 (no_link_obj) |
| `opentui/android-libc-link.patch` | ⚠️ HUÉRFANO | No se aplica (musl + patchelf) |

### Parches de codex (`patches/codex/`, aplicados por `scripts/codex-prepare-source.sh`)

Orden estricto 01..18; cada parche toca un archivo. Catálogo completo con pin del commit base: `patches/codex/README.md`. Los clave:

| Parche | Propósito |
|--------|-----------|
| `16-bionic-stubs-build.patch` | **build.rs del crate host (nuevo)**: inyecta los stubs bionic (`CODEX_BIONIC_STUBS_O`) y `libclang_rt.builtins-aarch64-android.a` del NDK (`CODEX_CLANG_RT_BUILTINS`) vía `cargo:rustc-link-arg` cuando las env vars están presentes — **NO vía RUSTFLAGS** (reemplazarían los rustflags del `.cargo/config.toml` parcheado) |
| `17-openssl-vendored-workspace.patch` | `openssl-sys` vendored en el package manifest de `code-mode-host` (no puede ir en el workspace virtual: es virtual manifest) — habilita builds parciales tipo solo host |
| `18-tls-align-stub.patch` | Stub TLS asm (`.tdata` `.p2align 6`) en el bin del host: bionic ARM64 exige PT_TLS `p_align >= 64` con skew 0; V8 trae `thread_local` con alineación 8 y sin el stub el linker64 aborta. `global_asm!` + ancla `#[used]` (Rust stable no emite `.tdata` nativo en android) |
| `01..15-*.patch` | `[target.aarch64-linux-android]` en `.cargo/config.toml` (01); cfg `any(linux, android)` en sandboxing/debug_sandbox (02-05); linux-sandbox stub (06-07); `protoc` de Termux sin `protoc-bin-vendored` (08); `openssl-sys` vendored en core (09); neutralización de `flock` bionic en app server/thread-store/message-history/rollout/MCP OAuth (10-15) |

### Parches de rusty_v8 (`patches/rusty-v8/`, aplicados por `build-rusty-v8-android.yml`)

| Parche | Propósito |
|--------|-----------|
| `android-ndk-args.patch` | Re-declara `android_ndk_version`/`android_ndk_root` en `build/config/android/config.gni` del fork denoland/chromium_build (sin ellos `gn gen` falla con "Undefined identifier ANDROID_NDK_VERSION_ROLL") |
| `bindgen-android-sysroot.patch` | Rama `target_os == "android"` en `build_binding()` del build.rs del crate: bindgen con `--target=aarch64-linux-android24` + `--sysroot` del NDK r26c (sin ella falla con "bits/wordsize.h not found"; NO usa `BINDGEN_EXTRA_CLANG_ARGS_*` porque se filtrarían a los bindgens x86_64 de las host tools) |

## Bugs conocidos (upstream)

- **`bun add -g` no instala transitivas** → [#25110](https://github.com/oven-sh/bun/issues/25110); workaround `bunx`. PRs: [#30659](https://github.com/oven-sh/bun/pull/30659) (abierto), [#30473](https://github.com/oven-sh/bun/pull/30473)/[#32182](https://github.com/oven-sh/bun/pull/32182) (merged). **No confundir** con `bun add -g bunli`: ese fallaba por el postinstall del peer `bun` (bun@npm) — resuelto con el ghost patch.
- **fromExecutable()**: `StandaloneModuleGraph.fromExecutable()` lee la sección `.bun` del ELF; si está vacía (vaddr=0) → null → Bun arranca como CLI normal, sin buscar el trailer al final del archivo. El raw-append patch añade ese fallback.
- **Warning transitivas en `bun add -g`** → [#20376](https://github.com/oven-sh/bun/issues/20376): falso positivo funcional (las deps importan OK); `--linker=isolated` rompe el ghost.
- **`splitting:true` corrupto** en Bun 1.3.14 (codegen) → [#25621](https://github.com/oven-sh/bun/issues/25621); kilo usa `splitting:false`.
- **Binarios oficiales de Kilo no corren en Termux** → [Kilo-Org/kilocode#12445](https://github.com/Kilo-Org/kilocode/issues/12445); se recompila contra bionic.

## Cachés (actions/cache + locales)

| Clave | Contenido | fail-on-cache-miss |
|-------|-----------|-------------------|
| `android-ndk-28.1.13356709` | NDK ~1.5 GB | no |
| `zig-0.15.2` / `zig-0.15.2-arm-v2` | Zig estándar x86_64 / aarch64 (fallback opentui) | no |
| `icu-android-75.1-24` | ICU cross-compilado | no |
| `webkit-android-<commit>-<patch_hash>` | WebKit build | **sí** |
| `bun-android-1.3.14-<hashes>` | Binario Bun ~88 MB | sí (en build-opencode) |
| `opentui-src-<commit>` / `opentui-android-<commit>` | fuente opentui / libopentui.so (key por commit) | no |
| `bun-target-1.3.14-<hashes>` | tarball target runtime (build-bun-target.yml) | no |
| `codex-rust-1.95.0` | toolchain Rust del `rust-toolchain.toml` de codex | no |
| `codex-ndk-r28b` | NDK r28b recortado a aarch64 | no |
| `codex-cargo-<ref>-<patch hashes>` | registro/git de cargo (codex) | no |
| `codex-sccache-<ref>-<patch hashes>` | sccache del build de codex | no |
| `rusty-v8-android-<ver>-<hashes>` | V8 desde fuente: NDK r26c + clang + gn_out + build + sccache | no |

Locales (Termux, no actions/cache): `.bun-artifact/bun-downloaded` (Android Bun), `build/opentui-src-kilo`, `build/opentui-zig-deps`, `build/models-dev-api.json`, `build/.markers/build-fingerprint*`, `build/rusty-v8` (artefacto librusty_v8 descargado), `codex/` (checkout de fuente de openai/codex).

## Comandos clave

```bash
# CI — disparar builds (--ref update-v1.18.6)
gh workflow run build-bun.yml --ref update-v1.18.6
gh workflow run build-opentui.yml --ref update-v1.18.6
gh workflow run build-opencode.yml --ref update-v1.18.6
gh workflow run build-opencode.yml -f release=true   # o pushear tag v* → Release 3 assets
gh workflow run build-rusty-v8-android.yml --ref update-v1.18.6   # artefacto librusty_v8 (Release rusty-v8-v<ver>)
gh workflow run build-codex.yml --ref update-v1.18.6 -f release=true   # o pushear tag codex-v* → Release v<ver>

# Monitorear (NUNCA --progress)
gita notify build-bun.yml
gita notify build-opentui.yml
gita notify build-opencode.yml
gita notify build-rusty-v8-android.yml
gita notify build-codex.yml

# Termux — instalar desde GitHub Releases (NO compila)
./install.sh                          # bun + opencode + opentui + codex
./install.sh --just opencode          # solo un componente (bun|opencode|opentui|codex)
./install.sh --just codex             # codex + codex-code-mode-host
./install.sh --release v1.18.11       # tag concreto

# Termux — build local de ports (requiere .bun-artifact/bun-downloaded)
./opencode_build.sh                   # → ./opencode-android
./kilocode_build.sh                   # → ./kilo-android
./codex_build.sh                      # → ./codex-android + ./codex-code-mode-host

# Host x86_64 (NO Termux — OOM killer)
source scripts/env.sh && ./scripts/apply-patches.sh
./scripts/build-bun.sh                # ~45 min
./scripts/build-opentui.sh && ./scripts/build-opencode.sh
```

## Kilo Code (port local en Termux)

Port de primera clase de **Kilo Code CLI v7.4.20**. Compilado EN LOCAL en Termux (`./kilocode_build.sh` → `./kilo-android`, standalone ~149 MB), mismo approach que opencode con las piezas que cataloga Kilo: `@opentui/core`/`@opentui/solid` **0.3.4** (vs 0.4.5) y src de opentui separado `build/opentui-src-kilo` (commit `9b216a58…` = tag v0.3.4).

```bash
./kilocode_build.sh      # fingerprint incremental (skip total si nada cambió)
./kilo-android --version # → 7.4.20
./kilo-android models    # ~300 modelos del snapshot models.dev baked (varía según refresh)
./kilo-android tui       # TUI funcional (verificada en pty real; el modelo de IA responde)
```

### Archivos del sistema

- `kilocode_build.sh` (raíz, ~650 líneas) — orquestador, adaptación de `opencode_build.sh`: fases [1/4]-[4/4] (Android Bun → deps → source+deps+parches → compile), compila libopentui.so 0.3.4 (target `aarch64-linux-android.24`), `bun install --frozen-lockfile --ignore-scripts` con el Android Bun vía `tcr`, parches "OTUI Android fix" (doble loop node_modules + store `.bun/`), patchelf NEEDED libc/libm, cache models.dev, RAM check.
- `scripts/build-kilo-android.ts` — replica `script/build.ts` de Kilo: entrypoints `[index.ts, parser.worker.js, cli/tui/worker.ts, session-export/worker.ts, indexing-worker.ts]`, **`splitting:false`** (bug #25621), conditions `[bun,node]`, external `[node-gyp, ...LanceDB]`, plugin solid 0.3.4 resuelto del checkout **sin fallback silencioso** (throw), defines `FFF_LIBC`/`KILO_LIBC`/`OPENTUI_LIBC` = musl, sandbox/bwrap = `undefined`.

Fingerprint incremental (`build-fingerprint-kilo`): `kilo_version`, `kilo_opentui_ref`, `zig_version`, `models_cache_sha`, `android_bun`, `otui_fix_present`, `output_sha` + hashes de lockfiles/package.json/scripts locales. Se guarda solo tras build EXIT=0 (un build fallido no deja skip válido).

### Hallazgos clave (toolchain, no de Bun)

1. **Fetch de zig 0.15.2 roto en Termux** (`TemporaryNameServerFailure` — bug del resolver HTTP de zig, no del DNS; curl baja la misma URL OK). `fetch_opentui_zig_deps` descarga las deps del `build.zig.zon` con curl a `build/opentui-zig-deps/` y reescribe las urls a `file://` (hash intacto); el zon se restaura tras el build.
2. **`@opentui/core` 0.3.4 tiene layout distinto** (globs `index-*.js`, no `chunk-bun-*.js`; sin `platform: process.platform,`) → parches "OTUI Android fix" adaptados (Fix2/Fix3/Fix4, marcador verificado en el store `.bun/`).
3. **Fix4 — materializar el .so del bunfs antes de dlopen**: en el standalone, 0.3.4 resuelve el .so vía path virtual `$bunfs/root/libopentui-<hash>.so` y `bun.dlopen()` NO abre paths virtuales. El parche extrae el .so a `$TMPDIR` (join(basename)) con `writeFileSync(Bun.file().arrayBuffer())` antes del dlopen. Fail-fast: sin marcador Fix4 en el store, el build aborta.
4. **Compilar el .so contra bionic, no musl — símbolo `__errno_location`**: el fallback musl referencia `__errno_location` (musl/glibc) que bionic NO exporta → dlopen falla (`cannot locate symbol`). El guard `if (target.result.abi != .android)` en `build.zig` (port del fix de 0.4.5) evita linkear `dl`/`pthread` (fusionadas en libc) → `.so` bionic válido (`__errno@LIBC`).
5. **Stubs bionic** (`INPUT(-lc)` en sysroot del NDK + crt_dir) como red de seguridad (patrón de `setup-runner.sh`).
6. **Runtime en Android**: `bun-pty` (FFI `forkpty`) en condition `bun` (no `node-pty`); LanceDB external (sin prebuilt Android → `indexing.vectorStore="qdrant"`); bubblewrap/sandbox degradan solos (defines `"undefined"`); Kilo Console omitida (deprecated).
7. **Crash TUI (SIGABRT) tras uso prolongado — fix en libopentui.so (no de Bun)**: dos panics sucesivos del renderer. (a) `renderer.zig` "no grapheme bytes in pool for gid" → catch defensivo `catch &[_]u8{}`. (b) `Writer.zig` `@memcpy` con len corrupto — `ClassPool.get` devolvía slice con len gigante para slots unowned → hardening del GraphemePool: len guard en `ClassPool.get` (`MAX_UNOWNED_LEN=4096` → `error.InvalidId`), panics de GraphemeTracker + `LinkTracker.addCellRef` degradados (sin abort), `@intCast(cell.char)` enmascarado con `& 0x1F_FFFF` + catch 0 (4 sitios: 0.3.4 y 0.4.5), unreachable de decref eliminado. Sin fix upstream en 0.4.5 (parches propios).
8. **Parches TUI automáticos**: bloques idempotentes con marcadores "OTUI Android fix" + fail-fast en `kilocode_build.sh` y también en `scripts/build-opentui.sh` (flujo 0.4.5). Verificado: rebuild EXIT=0, dlopen OK, TUI en pty sin panic (estrés emojis/ZWJ/resize), `--version` 7.4.20.

### Diferencia con opencode

Mismo approach (Android Bun embebe runtime + libopentui.so + patchelf + defines musl), con `@opentui/*` **0.3.4** vs **0.4.5** y src de opentui separado (`build/opentui-src-kilo`). Extras de Kilo omitidos en `build-kilo-android.ts`: stage bubblewrap, `patchelf --set-interpreter`, Kilo Console, tree-sitter wasms, sandbox workers, smoke tests, loop de 12 targets y upload a GH Releases.

## Codex (port Rust, V8 embebido)

Port de primera clase de **OpenAI Codex CLI v0.134.0-alpha.3** ([openai/codex](https://github.com/openai/codex), pin `CODEX_REF` en `scripts/env.sh`). **Rust puro**: sin Bun/Zig/libopentui. Compilado en **CI** (`build-codex.yml`, runner x86_64 `ubuntu-latest`, cargo cross contra el NDK r28b recortado a aarch64) y **en local en Termux** (`./codex_build.sh` → `./codex-android`). Compila 4 binarios: `codex-cli` (→ `codex-android`), `codex-tui`, `codex-linux-sandbox` (stub que degrada en Android) y **`codex-code-mode-host`** — el runtime companion del **modo code** con **V8 embebido** (crate `v8`/rusty_v8 150.4.0, `v8_enable_sandbox`). El modo code **funciona en Termux**: es el único port del ecosistema que incluye el host — termux-user-repository (TUR) lo omite y deja el modo code fail-closed ("Code Mode is unavailable").

```bash
./codex_build.sh         # fingerprint v3 incremental (skip total si nada cambió)
./codex-android --version
gh workflow run build-rusty-v8-android.yml --ref update-v1.18.6   # artefacto librusty_v8 (solo si cambia CODEX_V8_VERSION)
gh workflow run build-codex.yml --ref update-v1.18.6 -f release=true   # o pushear tag codex-v* → Release v<ver>
./install.sh --just codex   # codex + codex-code-mode-host en $PREFIX/bin
```

### Pipeline del port

- **build-rusty-v8-android.yml** — compila el artefacto `librusty_v8` para `aarch64-linux-android` desde fuente (el crate v8 no tiene prebuilt Android): runner x86_64 `ubuntu-24.04`, `V8_FROM_SOURCE=1`, NDK r26c que descarga el build.rs, API 24, ~60-90 min, sccache + actions/cache. Publica la Release `rusty-v8-v<CODEX_V8_VERSION>` (default `150.4.0`) con 3 assets: `.a.gz` (gzip -6, mtime=0), `src_binding…rs` y manifest `.sha256` de exactamente 2 líneas.
- **build-codex.yml** — cross-compila Codex contra el NDK r28b; inputs `bins` (compilar solo los binarios deseados, p.ej. solo el host) y `release`; push de tag `codex-v*` (no colisiona con `v*` de opencode) o input `release=true` → Release con tag `v<version>` (softprops). `scripts/build-codex-ci.sh` descarga el artefacto rusty_v8 (`setup_rusty_v8`, verifica el manifest con `sha256sum -c`), compila y empaqueta `codex-v<version>-android-aarch64.zip` con `codex-android` (+ tui/sandbox/host según `bins`). Usa sccache (cache de compilación de cargo) y **sin `--locked`**: los parches del port desincronizan el Cargo.lock de upstream.
- **Local** — `codex_build.sh` (Termux, tcr `-o 1000 -r 1024 -j 1` + reintentos anti-OOM, fingerprint v3) usa el MISMO mecanismo de fuente que el CI: helper compartido `scripts/codex-prepare-source.sh` (verifica/clona el ref pinneado `CODEX_REF` de `scripts/env.sh` y aplica `patches/codex/*.patch` 01..18 con `verify_patched_state`). Local y CI comparten el mismo código fuente.
- **Instalación** — `install.sh --just codex` (y default) descarga el zip de la Release del repo del port (patrón `codex-v[0-9][0-9A-Za-z._+-]*-android-aarch64\.zip`, con fallback a `releases?per_page=100`) e instala `codex` (de `codex-android`) y `codex-code-mode-host` en `$PREFIX/bin`.

### Diferencia con opencode/kilo

- **Sin Bun/Zig/libopentui**: la base común (Android Bun) no participa; cargo cross puro contra bionic del NDK.
- **V8 embebido**: el host embebe V8 (rusty_v8 con `use_custom_libcxx`) → libc++ **estático**, sin `libc++_shared.so` (verificado NEEDED libdl/liblog/libm/libc).
- **Artefacto rusty_v8 propio**: workflow dedicado (build-rusty-v8-android.yml) + Release `rusty-v8-v<ver>` que consumen CI y local vía `RUSTY_V8_ARCHIVE` + `RUSTY_V8_SRC_BINDING_PATH`.
- **Problemas bionic resueltos** (por qué el host funciona en Termux):
  - **Símbolos faltantes en bionic API 24** → `scripts/bionic-stubs.c` (`aligned_alloc`→`memalign`, `strtof_l`/`strtod_l`, `__clear_cache`) + `libclang_rt.builtins-aarch64-android.a` del NDK, inyectados vía build.rs del crate host (parche 16, env vars `CODEX_BIONIC_STUBS_O`/`CODEX_CLANG_RT_BUILTINS`; **no** RUSTFLAGS).
  - **TLS**: el host abortaba en Termux ("TLS segment is underaligned: alignment is 8 (skew 0)... needs ≥ 64"); termux-elf-cleaner lo pasaba a 64 pero con skew 32 → seguía abortando. Fix: parche 18 `patches/codex/18-tls-align-stub.patch` — stub asm `.tdata .p2align 6` con `global_asm!` que fuerza PT_TLS p_align 64 y skew 0. **Superior al enfoque oficial de Termux** (termux-elf-cleaner introduce skew; ver termux/termux-packages#8273).
  - **openssl-sys vendored** a nivel del crate host (parche 17) para builds parciales (bins sin codex-cli); `--locked` eliminado de cargo (los parches desincronizan el Cargo.lock de upstream).

## 🚧 Pendientes

| Prioridad | Tarea | Estado |
|-----------|-------|--------|
| 🔴 | Rebuild Android Bun con parche fromExecutable() + fromExecutable en CI | ⏳ |
| 🟡 | Build vía termux-docker + QEMU (elimina el transplant) | ⏳ |
| 🟡 | Integrar port de Kilo en CI con runner ARM64 nativo (análogo a build-opencode.yml) | ⏳ |
| 🟡 | Modo code depende del artefacto `rusty-v8-v<CODEX_V8_VERSION>` en la Release del repo del port (regenerar con build-rusty-v8-android.yml al cambiar la versión del crate v8) | ⏳ |
| 🟢 | `bun add -g bunli` resuelto con ghost patch (BuildID 7aba35f6) | ✅ |
| 🟢 | Warning transitivas = bug upstream #20376, falso positivo (`--linker=isolated` rompe el ghost) | ✅ |
| 🟢 | Port Kilo v7.4.20: `kilo-android` 149M funcional — TUI en pty real + modelo de IA responde | ✅ |
| 🟢 | Port Codex v0.134.0-alpha.3: `codex-android` + `codex-code-mode-host` — modo code FUNCIONAL en Termux (TLS stub + stubs bionic); único port con el host (TUR lo omite); `install.sh --just codex` | ✅ |
