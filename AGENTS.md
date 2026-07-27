# opencode-termux

Cross-compila [OpenCode](https://github.com/anomalyco/opencode) y [Bun](https://bun.sh) para Android/Termux (aarch64).

## Branch activa: `update-v1.18.6`

El README.md está desactualizado (menciona Bun 1.2.13, OpenCode 1.3.13). La realidad actual está en `scripts/env.sh`.

## Stack

| Componente | Versión | Notas |
|---|---|---|
| OpenCode | 1.18.6 | Monorepo: entrypoint en `packages/opencode/src/index.ts` |
| Bun (target) | 1.3.14 | Cross-compilado con zig build (Bun eliminó CMake en 1.3.14) |
| Bun (host) | 1.3.14 | Para codegen y bundle de OpenCode |
| WebKit/JSC | commit `017930eb` | Incluido en Bun 1.3.14 |
| ICU | 75.1 | Incluido en Bun 1.3.14 |
| Zig | 0.15.2 | Se necesita el FORK de oven-sh/zig para Bun; ziglang.org estándar para OpenTUI |
| Android NDK | r28b (API 24) | NDK r28b con API 24 mínima |

## Pipeline de Build

```
build-bun.yml → cross-compila Bun 1.3.14 (zig build + ninja, ~45 min)
     ↓
build-opencode.yml → OpenTUI (zig build) + OpenCode bundle + packages (~5 min)
```

Los workflows son independientes y comparten caché vía `actions/cache`.

## Estructura del repo

```
patches/
├── bun/android-support.patch       # Parches para Bun (680+ líneas)
├── webkit/android-support.patch     # Parches para WebKit (92 líneas)
├── zig/posix-android-sigaction.patch # Parche Zig stdlib para Bionic
└── opentui/android-libc-link.patch   # Parche OpenTUI para NDK libc
scripts/
├── env.sh                           # Variables de entorno y versiones
├── setup-runner.sh                  # Instala dependencias en CI runner
├── build-bun.sh                     # Cross-compila Bun con zig build + ninja
├── build-opentui.sh                 # Compila libopentui.so con Zig
├── build-opencode.sh                # Clona OpenCode y ejecuta build
├── build-opencode-android.ts        # Script central: module graph transplant
└── make-packages.sh                 # Crea ZIP + pacman + deb
Dockerfile                            # Imagen Docker con todo pre-instalado
.github/workflows/
├── build-bun.yml                    # Cross-compila Bun
├── build-opencode.yml               # Build final de OpenCode
└── docker-image.yml                 # Build de imagen Docker
```

## Comandos clave

```bash
# Disparar build desde CLI
gh workflow run build-bun.yml --ref update-v1.18.6
gita notify build-bun.yml           # Esperar sin --progress

gh workflow run build-opencode.yml --ref update-v1.18.6
gita notify build-opencode.yml

# Descargar artefactos
gh run download <RUN_ID> --dir <dir>
```

## Cachés compartidas

Las caches de `actions/cache` son el mecanismo de paso de artefactos entre workflows:
- `bun-android-1.3.14` — Binario de Bun cross-compilado
- `android-ndk-28.1.13356709` — NDK (~1.5 GB)
- `zig-0.15.2` — Zig estándar (~300 MB)
- `opentui-android` — libopentui.so
- `bun-host-1.3.14` — Host Bun (~200 MB)

## Quirks importantes

1. **Bun 1.3.14 eliminó CMake**: ahora usa `build.ts` (TypeScript) que genera `build.ninja`, luego `ninja` ejecuta todo. `build-bun.sh` ya no usa cmake.
2. **Zig fork vs estándar**: Bun usa `oven-sh/zig` fork (commit `04e7f6ac`). OpenTUI usa ziglang.org estándar 0.15.2. NO se debe forzar vendor/zig/ a zig estándar.
3. **Module graph transplant**: `build-opencode-android.ts` extrae el module graph del Bun host (x86_64) y lo concatena al Bun target (Android). Usa el trailer `\n---- Bun! ----\n` y struct Offsets de 32 bytes.
4. **Bionic stubs**: `libdl.so`, `libpthread.so`, etc. no existen en NDK (están en libc). `setup-runner.sh` crea stubs `INPUT(-lc)`.
5. **Patches se regeneran por versión**: `android-support.patch` es específico para cada versión de Bun. Al cambiar de versión, hay que regenerar los hunks.
6. **API level 24**: Es el mínimo para Termux 64-bit. Forzado en target de Zig.
7. **Host Bun pinneado**: Debe coincidir con target Bun (1.3.14) para compatibilidad del module graph. Host Bun 1.3.2 produce module graph de 36-byte stride; 1.3.14 produce 52-byte stride — el script es agnóstico.
8. **Orden de builds**: build-bun → build-opencode. build-bun produce el binario de Bun que build-opencode necesita.

## Problemas conocidos

- `CouldntReadCurrentDirectory` en Bun oficial Android (PR #31198 fix incluido en parche)
- `@parcel/watcher` .node binding no funciona (es x86_64)
- `bun upgrade` deshabilitado en Android
- TinyCC FFI puede no producir ARM64 válido
- README.md desactualizado respecto a versiones
