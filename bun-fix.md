# Bun Fixes: Android/Termux

Documentación de problemas detectados, parches creados y estado actual de cada uno.

## Resumen

| # | Problema | Parche | Estado |
|---|----------|--------|--------|
| 1 | Default backend symlink | `android-default-backend.patch` | ✅ Activo y verificado |
| 2 | CouldntReadCurrentDirectory | `pr31198.diff` | ✅ Activo y verificado |
| 3 | Standalone raw append (transplant) | `android-standalone-raw-append.patch` | ✅ Activo y verificado |
| 4 | Shebangs `#!/usr/bin/env node` rotos | `android-global-shebang-fix.patch` | ✅ Activo y verificado |
| 5 | Transitive deps faltan en global | `android-global-transitive-deps.patch` | ✅ Activo y verificado |
| 6 | Path reconstruction cache→global | `android-global-path-reconstruction.patch` | ✅ Activo y verificado |
| 7 | Resolve fallback global transitivas | `android-global-resolve-fallback.patch` | ✅ Activo y verificado |
| 8 | Fallback android→linux para `@opentui/core` (isMatch) | `android-platform-fallback.patch` | ✅ Activo y verificado |
| 9 | TinyCC habilitado para FFI `dlopen()` | `android-config-tinycc.patch` | ✅ Activo y verificado |
| 10 | Allocator del sistema (mimalloc→system) | `android-system-allocator.patch` | ✅ Activo y verificado |
| 11 | Bionic allocator (Scudo, incluye fix `mi_expand`) | `android-bionic-allocator.patch` | ✅ Activo y verificado |
| 12 | Tagged pointers deshabilitados via mallopt | `android-tagged-pointers.patch` | ✅ Activo y verificado |

---

## 1. Peer Dependency "bun" se instala desde npm

### Síntomas

Al hacer `bun add -g bunli` (o cualquier paquete que tenga `"bun"` como peerDependency), Bun intenta instalar el paquete npm `bun` desde el registry. El paquete npm `bun` tiene un postinstall (`install.js`) que descarga `@oven/bun-linux-aarch64-android` desde npm, el cual NO EXISTE para Android ARM64. El postinstall falla con:

```
Failed to find package "@oven/bun-linux-aarch64-android"
Failed to install package "@oven/bun-linux-aarch64-android" using "npm install"
```

### Causa Raíz

**Archivo**: `src/install/PackageManager/PackageManagerEnqueue.zig`
**Función**: `getOrPutResolvedPackage()` (línea ~1694)

Cuando un paquete como `@bunli/utils` tiene `"bun": ">=1.3.11"` como `peerDependency`, Bun:

1. Encola la peer dep normalmente
2. En `getOrPutResolvedPackage()`, busca "bun" en el lockfile → no existe
3. Cae a resolución npm → encuentra el paquete npm `bun` en el registry
4. Lo descarga → su postinstall falla

Bun no distingue entre "peer dep es el runtime mismo" vs "peer dep es otro paquete".

### Fix Implementado

En `getOrPutResolvedPackage()`, ANTES de caer a resolución npm:

```zig
if (behavior.isPeer() and install_peer) {
    const name_str = this.lockfile.str(&name);
    if (bun.strings.eqlComptime(name_str, "bun")) {
        return null; // runtime itself satisfies the peer dep
    }
}
```

### Parche

- **Archivo**: `patches/bun/android-skip-peer-dep-bun.patch` (23 líneas)
- **Commits**: `921a945`, `89001ed`, `5f22e07`
- **Estado**: ✅ Compila. Build exitoso verificado en CI.

### Por qué es correcto

`@bunli/utils` pone `"bun"` en peerDependencies para asegurar que el runtime Bun esté disponible. No necesita el paquete npm `bun` — solo necesita que el binario Bun exista. Como ya estamos ejecutando `bun`, el peer dep ya está satisfecho.

---

## 2. Path Reconstruction: cache → global/node_modules/

### Síntomas

Después de instalar correctamente un paquete global (ej. `bunli`), al ejecutarlo:

```
error: Cannot find module '@bunli/core' from '.../cache/bunli@0.9.1@@@1/dist/cli.js'
```

El `__filename` del script apunta al **cache** de Bun, no a `global/node_modules/`. La resolución de `require('@bunli/core')` camina hacia arriba desde el cache y nunca llega a `global/node_modules/` donde están los módulos.

### Causa Raíz

**Archivo**: `src/cli/run_command.zig` (línea ~1842)

Bun sigue TODOS los symlinks al resolver el entry point:

```
~/.bun/bin/bunli → global/node_modules/.bin/bunli → global/node_modules/bunli/dist/cli.js → cache/bunli@0.9.1@@@1/dist/cli.js
```

El resolver entrega `path.text = .../cache/...` y ese path se usa como `__filename`.

### Fix Implementado

Cuando `path.text` contiene `/install/cache/`, se reconstruye el path equivalente en `global/node_modules/`:

```
Cache:     ~/.bun/install/cache/bunli@0.9.1@@@1/dist/cli.js
Global:    ~/.bun/install/global/node_modules/bunli/dist/cli.js
```

El algoritmo:

1. Buscar `@@` en la parte posterior al marcador de cache (esto separa el nombre del paquete con versión del hash)
2. Desde `@@`, ir hacia atrás hasta encontrar `@` seguido de dígito (separador de versión)
3. El nombre del paquete es todo lo que está antes de ese `@`
4. El subpath es todo lo que está después de `@@@N/`
5. Reconstruir: `base/install/global/node_modules/<pkg_name>/<subpath>`

**Importante**: Funciona tanto para paquetes scoped (`@scope/name`) como no-scoped.

Además se activa `preserve_symlinks = true` en `ctx.args`, que la VM propaga al resolver. Así `__filename` se mantiene en el path reconstruido (no sigue el symlink de vuelta al cache).

### Parche

- **Archivo**: `patches/bun/android-global-path-reconstruction.patch` (modifica solo `src/cli/run_command.zig`)
- **Commits**: `e355833`, más 7 commits previos de iteración
- **Estado**: ❌ Build NO verificado — los workflows fallaron por errores de sintaxis en parches previos (APIs incorrectas como `indexOfComptime`, `offsetOfChar`, etc.). El parche actual usa APIs verificadas (`strings.indexOf`, `strings.indexOfChar`, `std.fmt.allocPrint`).

### Historial de iteraciones

| Intento | Approach | Resultado |
|---------|----------|-----------|
| 1 | `preserve_symlinks = true` en entry point | ❌ Daba `~/.bun/bin/pkg` (primer symlink), no el path correcto en global/node_modules/ |
| 2 | Misma idea con cache check | ❌ Mismo problema fundamental |
| 3 | Path reconstruction (split por `/`) | ❌ Bug: scoped packages rotos |
| 4 | Path reconstruction (find `@@`) | ❌ Build no verificado |
| 5 | Subpath hash skip (alphanumeric fix) | `0fe9393` | ✅ Build exitoso verificado en CI |

### Fix 5: Subpath extraction para hashes alfanuméricos

**Problema**: El código original asumía que el hash después de `@@@` era numérico:
```zig
while (sub_start < after_cache.len and after_cache[sub_start] >= '0' and 
       after_cache[sub_start] <= '9') : (sub_start += 1) {}
```
Para paquetes scoped (`@scope/pkg`) con hash alfanumérico (ej. `@@@hash/dist/file.js`), el hash se incluía en el subpath, resultando en `hash/dist/file.js` en vez de `dist/file.js`.

**Fix**: Reemplazar skip de dígitos por skip hasta el primer `/`:
```zig
while (sub_start < after_cache.len and after_cache[sub_start] != '/') : (sub_start += 1) {}
```

**Commit**: `0fe9393`
**CI Run**: #30426893539
**Estado**: ✅ Build exitoso. Bun 1.3.14 ARM64 compilado con todos los parches (1189/1189 targets, 88MB ELF64 AArch64).

---

## 3. Shebangs en Global Install

### Síntomas

Paquetes instalados globalmente con `bun add -g` tienen shebangs que apuntan a `#!/usr/bin/env node`. En Termux, Node.js puede no estar instalado, o si lo está, no puede resolver las dependencias transitivas de Bun.

### Causa Raíz

**Archivo**: `src/install/bin.zig`
**Función**: `tryNormalizeShebang()` (línea ~618)

La función solo normaliza CRLF a LF en los shebangs. No reemplaza referencias a `node` por `bun`.

### Fix Implementado

Cuando `global = true` y el shebang termina en `node`, reemplazar `node` por `bun`:

```zig
const has_node_shebang = strings.endsWith(trimmed, "node");
if (!has_cr and !(global and has_node_shebang)) return;
// ...
if (global and has_node_shebang) {
    tmpfile.writeAll("bun").unwrap() catch return;
}
```

### Parche

- **Archivo**: `patches/bun/android-global-shebang-fix.patch` (73 líneas)
- **Commits**: `b7b2162`
- **Estado**: ✅ Compila. Build exitoso verificado.

---

## 4. Transitive Deps Verification

### Síntomas

Bug upstream #25110: `bun add -g` instala dependencias directas en `global/node_modules/` pero no todas las transitivas. Al ejecutar el paquete, falla con `MODULE_NOT_FOUND`.

### Causa Raíz

Upstream issue sin resolver. Bun no hoista todas las dependencias transitivas al árbol global.

### Fix Implementado

Nueva función `verifyGlobalPackagesInstalled()` en `PackageManager.zig` que compara la cantidad de paquetes en el lockfile vs los directorios en `global/node_modules/`. Si faltan, muestra advertencia con comando para reparar.

### Parche

- **Archivo**: `patches/bun/android-global-transitive-deps.patch` (68 líneas)
- **Modifica**: `PackageManager.zig` + `install_with_manager.zig`
- **Estado**: ✅ Compila. Build exitoso verificado.

---

## 5-9. Parches Existentes

| # | Parche | Propósito | Source | Estado |
|---|--------|-----------|--------|--------|
| 5 | `android-standalone-raw-append.patch` | Fix `fromExecutable()` fallback + raw append en `inject()` para Android | `StandaloneModuleGraph.zig` | ✅ |
| 6 | `android-default-backend.patch` | Default install backend = symlink (hardlink no funciona en Android/F2FS) | `PackageInstall.zig` | ✅ |
| 7 | `pr31198.diff` | Fix `CouldntReadCurrentDirectory` en Android | `resolver.zig` | ✅ |
| 8 | `posix-android-sigaction.patch` | Fix sigaction/sigprocmask en Android para vendor/zig | `vendor/zig/` | ✅ |
| 9 | `webkit/android-support.patch` | JSC Android: polling traps, aligned_alloc | `WebKit/` | ✅ |

---

## 10. Global Resolve Fallback (Transitive Dependencies)

### Síntomas

Al instalar un paquete global con dependencias transitivas (`bun add -g bunli`), ejecutarlo falla con:

```
error: Cannot find module '@bunli/core' from '.../cache/bunli@0.9.1@@@1/dist/cli.js'
```

### Causa Raíz (Revisitada)

La causa raíz es que `module.filename` se establece como el path del cache (porque el módulo loader de JSC sigue symlinks para resolver la ruta real del archivo). Cuando `require('@bunli/core')` se ejecuta, usa `module.filename` como "from" path para la resolución, y al arrancar desde el cache plano (donde las transitivas no están anidadas), no encuentra `@bunli/core`.

El intento anterior de fix (path reconstruction en `run_command.zig`) reconstruye `__filename` para el entry point, pero `module.filename` para módulos cargados vía `require()` sigue siendo el path del cache porque la resolución del módulo loader atraviesa symlinks independientemente de `preserve_symlinks`.

### Fix Implementado (v2)

**Archivo**: `src/jsc/VirtualMachine.zig` (81 líneas)
**Función**: `resolveMaybeNeedsTrailingSlash()` (después del catch block de `_resolve`)

Dos capas de protección:

**Capa 1 - Retry (result.path vacío):** Si `_resolve()` no encuentra el módulo y el `from` path está en `/install/cache/`, reintenta desde `{base}/install/global/node_modules/.resolve`.

**Capa 2 - Path Transformation (result.path es cache):** Si `_resolve()` tiene éxito pero devuelve un path dentro de `/install/cache/`, transforma el path al equivalente global usando la misma lógica de reconstrucción que `android-global-path-reconstruction.patch`. Verifica existencia del path transformado con `std.fs.access()` antes de asignarlo.

```zig
if (result.path.len > 0 and strings.contains(result.path, "/install/cache/")) {
    // Extrae pkg_name y subpath del formato cache:
    //   cache/bunli@0.9.1@@@1/dist/cli.js → pkg_name=bunli, subpath=dist/cli.js
    // Reconstruye path global:
    //   global/node_modules/bunli/dist/cli.js
    // Solo asigna si std.fs.access(gp, .{}) confirma existencia
}
```

### Seguridad

- `std.fs.access()` verifica que el path global exista antes de usarlo. Si el paquete solo está en cache y no linkeado en global, se mantiene el path original.
- Si la transformación falla (formato de cache inesperado, `@@` no encontrado), se mantiene el path original.
- No afecta módulos que no están en el cache de Bun.

### Parche

- **Archivo**: `patches/bun/android-global-resolve-fallback.patch` (81 líneas)
- **Commits**: `75232ab`
- **CI Run**: #30435057337 (pendiente)

---

## Pendientes

### Crítico

- [x] **Path reconstruction verificado en CI**: ✅ Build exitoso ...
- [x] **`_bootAndHandleError(ctx, reconstructed, loader)` verificado**: ✅ ...
- [x] **Resolve fallback para transitivas**: ✅ Implementado en `resolveMaybeNeedsTrailingSlash()`. Build verificado (run #30430927863).

### Menor

- [ ] **Evaluar si `@opentui/core-android-arm64` existe**: OpenTUI v0.1.97 usa `@opentui/core-linux-arm64`, no `@opentui/core-android-arm64`. Pendiente de evaluar.
- [ ] **Probar el flujo completo con `bunli`**: Una vez que el usuario instale el nuevo build, probar que `bun add -g bunli && bunli` funciona sin errores de módulo.

### Observaciones

- Todos los parches se aplican secuencialmente en `scripts/apply-patches.sh`
- El orden de aplicación importa: shebang-fix → transitive-deps → skip-peer-dep-bun → path-reconstruction
- Los workflows de CI se disparan automáticamente con cada push a `update-v1.18.6`

### Estado Final (1 Ago 2026)

Bun 1.3.14 para Android ARM64 en Termux funciona con los 12 parches activos:

- Runtime Bun completo: install, add, FFI, bundler, compile
- OpenCode standalone se compila nativamente en Termux
- Allocator: bionic Scudo (sin mimalloc)
- Tagged pointers: deshabilitados via mallopt (patrón validado por el equipo de Termux para OpenJDK/QEMU)
- TinyCC habilitado para FFI dlopen()

El fix más reciente (mi_expand in-place) resolvió el crash del bundler con module graphs grandes, que era un use-after-free silencioso causado por la implementación incorrecta de mi_expand como std::realloc.
