# opencode-termux

Cross-compila [OpenCode](https://github.com/anomalyco/opencode) + [Bun](https://bun.sh) para Android/Termux (aarch64).

## Branch activa

- `update-v1.18.6` es la rama de trabajo. `main` está atrás.
- `README.md` está desactualizado. `scripts/env.sh` es la fuente de verdad de versiones y variables de entorno.

## Pipeline de Build (orden obligatorio)

```
build-bun.yml ──→ artifact: bun-android-aarch64-1.3.14 (~45 min)
     ↓
build-opencode.yml ──→ OpenCode binary + packages (~5 min)
```

Los workflows son independientes y comparten caché vía `actions/cache`.

### build-bun.yml
- Cross-compila Bun 1.3.14 entero usando `scripts/build.ts` (TypeScript) → genera `build.ninja` → `ninja`.
- No usa CMake. Bun 1.3.14 eliminó CMake por completo.
- Requiere WebKit cache pre-existente (`fail-on-cache-miss: true`) — WebKit se construye en otro workflow.
- Steps principales: restore NDK/Zig/ICU/WebKit → clone Bun + apply patches → `bun run build.ts --configure-only` → `ninja bun` → strip → upload artifact.

### build-opencode.yml
- Consume el binario Bun del paso anterior (restaurado de cache).
- Compila `libopentui.so` con Zig, luego build de OpenCode + module graph transplant.
- Produce ZIP + pacman + deb packages.
- Si se dispara con tag `v*`, crea GitHub Release automático.

### Build local (NO en Termux — OOM killer)
```bash
source scripts/env.sh
./scripts/apply-patches.sh
./scripts/build-bun.sh        # ~45 min, requiere x86_64
./scripts/build-opentui.sh
./scripts/build-opencode.sh
```

## Stack (lo no-obvio que un agente adivinaría mal)

- **Dos Zigs distintos**: Bun necesita el fork `oven-sh/zig`. OpenTUI usa ziglang.org estándar 0.15.2. NO mezcles. `setup-runner.sh` instala zig estándar; el fork lo maneja el build system de Bun automáticamente.
- **Host Bun debe coincidir con target Bun** (ambos 1.3.14) para compatibilidad del module graph. `build-opencode-android.ts` extrae el module graph del host Bun y lo concatena al binario Android usando el trailer `\n---- Bun! ----\n`.
- **ICU 75.1**: Se cross-compila desde fuente con `scripts/build-icu.sh`. No hay binarios prebuilt para Android.
- **WebKit/JSC**: commit `017930ebf915121f8f593bef61cbbca82d78132d`. Se construye aparte con `scripts/build-webkit.sh` y se cachea.
- **API level 24**: Mínimo para Termux 64-bit. Forzado en `env.sh` como `aarch64-linux-android24`.

## Parches — Estado Actual

| Parche | Estado | Dónde se aplica | Notas |
|--------|--------|-----------------|-------|
| `patches/bun/pr31198.diff` | ✅ ACTIVO | `apply-patches.sh` con `git apply` | Fix `CouldntReadCurrentDirectory` en Android. Portado de Rust→Zig (Bun 1.3.14 migró el resolver) |
| `patches/bun/android-support.patch` | ⏭️ SKIPPED | `apply-patches.sh` (comentado) | Los 3 hunks ya están en Bun 1.3.14 upstream |
| `patches/webkit/android-support.patch` | ✅ ACTIVO | `apply-patches.sh` con `git apply` | JSC Android: polling traps, aligned_alloc, crash handler |
| `patches/bun/build-zig-no-link-obj.patch` | 📎 REFERENCIA | Inline con sed+python3 en `apply-patches.sh` | El parche en disco es solo documentación |
| `patches/zig/posix-android-sigaction.patch` | 🔄 APLICADO POR BUILD | `build-bun.sh` (implícito) | Se aplica al vendor/zig/ que Bun descarga automáticamente |
| `patches/opentui/android-libc-link.patch` | ⚠️ HUÉRFANO | No se aplica en ningún script | `build-opentui.sh` usa target musl + patchelf en vez de este parche |

## Cachés — Claves Exactas

### build-bun.yml
| Clave | Contenido |
|-------|-----------|
| `android-ndk-28.1.13356709` | NDK ~1.5 GB |
| `zig-0.15.2` | Zig estándar ~300 MB |
| `icu-android-75.1-24` | ICU cross-compilado |
| `webkit-android-<commit>-<patch_hash>` | **fail-on-cache-miss: true** — si no existe, falla |
| `bun-android-1.3.14-<hash_bun>-<hash_pr>-<hash_zig>` | Binario Bun. Incluye SHA256 de 3 parches |

### build-opencode.yml
| Clave | Contenido |
|-------|-----------|
| `bun-host-1.3.2` | ⚠️ Key desactualizada — `setup-runner.sh` instala 1.3.14 |
| `opentui-android` | libopentui.so |

### Cache bust
Si cambias un parche y no ves rebuild: verifica que la cache key incluya el hash de ese parche. Si no, borra la cache manualmente con `gh cache delete <key>` o cambia la key en el workflow.

## Comandos Clave

```bash
# Disparar builds desde CLI
gh workflow run build-bun.yml --ref update-v1.18.6
gh workflow run build-opencode.yml --ref update-v1.18.6

# Monitorear (NUNCA uses --progress)
gita notify build-bun.yml
gita notify build-opencode.yml

# Descargar artifact del último build exitoso
gh run download <RUN_ID> --dir <dir>

# Instalar binario Bun en Termux
./install.sh --just bun

# Cache
gh cache list --key bun-android
gh cache delete <cache-id>
```

## Quirks Gotcha

- **Bionic stubs**: `libdl.so`, `libpthread.so`, `librt.so`, `libutil.so` (y sus `.a`) no existen en NDK — están en libc. `setup-runner.sh` crea stubs con `echo 'INPUT(-lc)' >`. Sin estos, el linker falla.
- **Strip ARM64**: `build.ninja` usa `/usr/bin/strip` (x86_64 host) que NO procesa ARM64. `build-bun.sh` lo parchea a `${NDK_TOOLCHAIN}/bin/llvm-strip`.
- **Zig rules en build.ninja**: Se parchean con `sed` para que los comandos zig corran desde `$BUN_SRC` (no `$BUILD_DIR`). Zig resuelve imports relativos al CWD.
- **OOM en Termux**: NO compiles Bun localmente en Termux. Android OOM killer mata el proceso. Usa GitHub Actions siempre.
- **LLVM/Clang 21**: Bun 1.3.14 configure requiere Clang 21. NDK trae Clang 19. `setup-runner.sh` crea symlinks de compiler-rt del NDK al directorio de Clang 21.
- **OpenTUI con musl, no NDK**: `build-opentui.sh` usa target `aarch64-linux-musl` (Zig provee musl) y luego `patchelf --add-needed libc.so` para compatibilidad con Android `dlopen()`.
- **`@parcel/watcher`**: Binding nativo `.node` es x86_64, no funciona en Android.
- **`bun upgrade`**: Deshabilitado en Android.
- **`Dockerfile`**: Está en `scripts/Dockerfile`, no en la raíz. La cache key `bun-host-1.3.2` en `build-opencode.yml` está desactualizada (host actual es 1.3.14).

## Problemas Conocidos

- TinyCC FFI puede no producir ARM64 válido.
- `build-opencode.yml` requiere WebKit cache pre-existente — si no hay, falla inmediatamente.
- `patches/opentui/android-libc-link.patch` huérfano: existe en disco pero ningún script lo aplica.
- cache key `bun-host-1.3.2` desactualizada en `build-opencode.yml` (host actual: 1.3.14).

## Archivos que sí importan

```
patches/                           # Parches organizados por componente
├── bun/pr31198.diff               # ACTIVO - CouldntReadCurrentDirectory fix
├── webkit/android-support.patch   # ACTIVO - JSC Android patches
├── zig/posix-android-sigaction.patch
└── opentui/android-libc-link.patch # HUÉRFANO

scripts/
├── env.sh                         # Fuente de verdad: versiones y paths
├── apply-patches.sh               # Clona repos + aplica parches
├── build-bun.sh                   # Cross-compila Bun (zig + ninja)
├── build-opentui.sh               # libopentui.so
├── build-opencode.sh              # OpenCode bundle
├── build-opencode-android.ts      # Module graph transplant
├── build-icu.sh / build-webkit.sh / build-tinycc.sh / setup-runner.sh / make-packages.sh
└── Dockerfile                     # ⚠️ Aquí, no en raíz

.github/workflows/
├── build-bun.yml                  # CI Bun (~45 min)
├── build-opencode.yml             # CI OpenCode (~5 min)
└── docker-image.yml

install.sh                         # Instalador para Termux
```
