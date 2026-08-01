# symlink-backend-bug: Bundler no resuelve transitivas con backend symlink en Android

## Resumen

El backend symlink (default en Android vía `android-default-backend.patch`) instala `node_modules/<pkg>/` como directorio real con **archivos internos symlink al cache** (`~/.bun/install/cache/<pkg>@@@1/`). Al hacer `bun run build` con un bundle transitivo (ej. react-dom → react/scheduler), el resolver **sigue el realpath del symlink** y el path del módulo pasa a ser el del cache. Desde el cache, el walk-up de `node_modules` sube por `~/.bun/install/cache/...` y nunca encuentra el `node_modules` del proyecto → `Could not resolve: "scheduler"` / `"react"`.

## Síntoma

En `bun-project` (react + react-dom + scheduler), tras borrar `node_modules` y `bun install`:

```
24190 |     var Scheduler = require("scheduler"),
                                    ^
error: Could not resolve: "scheduler". Maybe you need to "bun install"?
    at /data/data/com.termux/files/home/.bun/install/cache/react-dom@19.2.8@@@1/cjs/react-dom-client.development.js:24190:29

24191 |       React = require("react"),
                              ^
error: Could not resolve: "react". Maybe you need to "bun install"?
    at /data/data/com.termux/files/home/.bun/install/cache/react-dom@19.2.8@@@1/cjs/react-dom-client.development.js:24191:23
error: script "build" exited with code 1
Exit: 1
```

## Tests realizados

| Test | Resultado |
|------|-----------|
| `bun install` en bun-project (10 packages) | ✅ Exit 0 |
| Import directo de `scheduler` (script aislado) | ✅ Bundled 3 modules |
| Import directo de `react` (script aislado) | ✅ Bundled 3 modules |
| **Resolución transitiva (react-dom → react/scheduler)** | ❌ **Could not resolve** |

Los imports directos funcionan; solo falla la resolución transitiva desde un módulo cuyo archivo es symlink al cache.

## Estructura instalada (backend symlink)

```
node_modules/react/          → directorio REAL
node_modules/react/index.js  → symlink → ~/.bun/install/cache/react@19.2.8@@@1/index.js
node_modules/react/package.json → symlink → ~/.bun/install/cache/react@19.2.8@@@1/package.json
node_modules/react-dom/      → directorio REAL
node_modules/react-dom/cjs/react-dom-client.development.js → symlink → cache/react-dom@19.2.8@@@1/cjs/...
```

## Causa raíz

En `bun-source/src/resolver/resolver.zig`, líneas 1079-1081 y 1121:

```zig
const symlink_path = query.entry.symlink(&r.fs.fs, r.store_fd);
if (symlink_path.len > 0) {
    path.setRealpath(symlink_path);  // ← path pasa a ser el del CACHE
    ...
}
```

Cuando el archivo es un symlink al cache, el resolver establece el realpath (cache) como path del módulo. Desde el directorio del cache, el walk-up de `node_modules` sube por `~/.bun/install/cache/...` y **nunca encuentra el `node_modules` del proyecto**, donde viven `react`/`scheduler`.

### Por qué funciona en desktop

En desktop (Linux/macOS), el backend default es **hardlink** o **clonefile**: los archivos son hardlinks reales, el path queda en el proyecto → el walk-up de `node_modules` funciona. En Termux, el parche fuerza `Method.symlink` (Android no soporta hardlinks cross-directory por EACCES en app sandbox), y los archivos son symlinks → el realpath se dispara.

## Opciones de fix

### Opción A — Resolver retiene path lógico (más robusta)

En `resolver.zig`, cuando `path.setRealpath(symlink_path)` se dispara para un archivo bajo `~/.bun/install/cache/`, retener el **path lógico original** (el de `node_modules/`) como base para el walk-up de `node_modules`, de modo que los imports transitivos se resuelvan desde el proyecto. Es el comportamiento esperado en un layout estilo pnpm store + symlinks.

### Opción B — Symlinks de directorio en el instalador

Cambiar el instalador para que genere symlinks a nivel de directorio (`node_modules/react → ~/.bun/install/cache/react@...@@@1`) en vez de per-file. Con symlink de directorio, el archivo en sí no es symlink → el walk-up partiría de la ruta lógica. Requiere evaluar si el resolver maneja el dir-symlink correctamente en el path de módulo.

### Comparación

| Aspecto | Opción A (resolver) | Opción B (instalador) |
|---------|---------------------|----------------------|
| Alcance | Toca resolver.zig (resolución) | Toca PackageInstall.zig (instalación) |
| Riesgo | Afecta TODAS las resoluciones en Android | Solo cambia layout de install |
| Esfuerzo | Medio | Medio |
| Alineación con pnpm | ✅ (path lógico conservado) | ✅ (dir-symlink style) |
| Afecta global install? | Posible (verificar) | No |

## Referencias

- `patches/bun/android-default-backend.patch` — fuerza `Method.symlink` en Android (PackageInstall.zig:371-375)
- `bun-source/src/resolver/resolver.zig:1079-1081,1121` — `path.setRealpath(symlink_path)` (causa raíz)
- `bun-project/` — proyecto de reproducción (react, react-dom, scheduler)
- `bun-project/package.json` — dependencias del test
- Relacionado: `android-global-path-reconstruction.patch` (fix similar para global install, no para bundler)

## Resultado Final (verificado 1 Ago 2026)

**El bug está resuelto** con la combinación de dos fixes en `android-resolver-logical-path.patch`:

### Fix 1: Resolver conserva path lógico para cache paths
En `finalizeResult` (resolver.zig), las Ramas 1 y 2 (symlinks) ahora evitan `setRealpath` cuando el target está en el cache de Bun, conservando el path lógico de `node_modules`. Esto replica el comportamiento del backend hardlink de desktop.

### Fix 2 (el bug crítico): trailing slash en `isBunCachePath`
`fetchCacheDirectoryPath` preserva el trailing slash al resolver por HOME (ej. `.../.bun/install/cache/`), pero el prefix check de `isBunCachePath` esperaba el path SIN slash. Cuando `BUN_INSTALL_CACHE_DIR` no estaba seteada, `cache_path` retenía el `/` final, haciendo que `abs_path[cache_path.len]` fuera la primera letra del nombre del paquete (no un separador) → `isBunCachePath` devolvía `false` siempre → el fix 1 se desactivaba → la resolución transitiva fallaba.

**Fix**: normalizar el trailing separator al cachear `bun_cache_path`.

### Verificación en Termux
- `bun build` SIN env var: ✅ 14 módulos bundled, exit 0 (antes fallaba con `Could not resolve: scheduler`)
- `bun build` CON `BUN_INSTALL_CACHE_DIR`: ✅ 14 módulos, exit 0 (compatibilidad intacta)
- `bun install` limpio: ✅ 10 packages
- Build CI: ✅ 1200/1200, BuildID `1ecedd28273d6428e12d5ab92e175cf73d8216ea`

### Parches involucrados
- `android-resolver-logical-path.patch` (commit `9ae7253`) — contiene ambos fixes
- `android-default-backend.patch` — fuerza `Method.symlink` en Android (necesario para que el layout sea symlinks)

### Estado
✅ **Resuelto.** La env var `BUN_INSTALL_CACHE_DIR` es ahora opcional (solo redirección); el default por HOME funciona.
