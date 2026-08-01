# symlink-resolve-progress: Plan de implementación Opción A (resolver conserva path lógico)

## Objetivo

Arreglar el bug del backend symlink en Android: los bundles transitivos (react-dom → react/scheduler) fallan con `Could not resolve` porque el resolver reescribe `path.text` al realpath del cache de Bun, y el walk-up de `node_modules` desde el cache nunca encuentra los hermanos del proyecto.

## Contexto

- Bug documentado: `symlink-backend-bug.md`
- Backend symlink (Android): `android-default-backend.patch` → `Method.symlink`
- Opción B (dir-symlink layout) implementada pero NO suficiente: el resolver reescribe al realpath igualmente (`dir.abs_real_path` en finalizeResult)
- Verificación del CRITICAL: `path.pretty` conserva el path lógico, pero el walk-up usa solo `dir_info.abs_path` + `getParent()` — nunca `pretty`

## Plan de implementación (Opción A formal)

### Fase 1 — Investigación
- [ ] Cómo obtener el cache dir de Bun dentro del resolver (resolver.zig)
- [ ] ¿`global_cache` en resolver.zig:1969 es la vía?
- [ ] ¿`BUN_INSTALL_CACHE_DIR` / default `~/.bun/install/cache/`?
- [ ] Verificar que conservar path lógico replica el comportamiento desktop (hardlink)

### Fase 2 — Diseño
- [ ] Función helper formal: `isCachePath(path)` o similar
- [ ] Ubicación: resolver.zig (o helper en fs.zig)
- [ ] Cómo se obtiene el cache path UNA vez (lazy static)

### Fase 3 — Implementación
- [ ] En `finalizeResult` (resolver.zig:1087-1121), Rama 2 (dir.abs_real_path):
  - Si el realpath está en el cache de Bun → conservar path.text lógico (NO setRealpath)
  - path.is_symlink = true (tracking)
  - Si no está en el cache → comportamiento actual
- [ ] Revisar interacción con standalone (`android-standalone-raw-append.patch`)
- [ ] Revisar dedupe del module graph

### Fase 4 — Verificación
- [ ] Code-review (code-reviewer)
- [ ] Build en CI
- [ ] Test en Termux: bun-project (react/react-dom/scheduler) → `bun run build`
- [ ] Test paquete scoped (`@scope/pkg`)

### Fase 5 — Documentación
- [ ] Actualizar `symlink-backend-bug.md` con la solución
- [ ] Actualizar `bun-fix.md` si corresponde

## Estado actual

- [x] Opción B implementada (installWithDirSymlink) — SE PERDIÓ al regenerar el parche bionic, no está en el binario
- [x] CRITICAL verificado: resolver reescribe al realpath incluso con dir-symlinks
- [x] Opción A implementada en resolver.zig (isBunCachePath + Ramas 1/2)
- [x] CRITICAL: isBunCachePath depende de env_loader (podía ser null) → corregido con fetchCacheDirectoryPath(env, null)
- [x] MAJOR: hasPrefix no path-aware → corregido con trailing separator check
- [x] MAJOR: is_symlink inconsistente → quitado en Rama 2
- [x] BUG CRÍTICO: trailing slash en cache_path de HOME rompía isBunCachePath → corregido (normalizar trailing separator)
- [x] Verificación: bun build SIN env var funciona (14 módulos, exit 0)
- [x] Build CI exitoso (BuildID 1ecedd28)

## Decisiones clave

| Decisión | Estado |
|----------|--------|
| Conservar path lógico para cache paths | ✅ Implementado (Fix 1: Ramas 1/2 evitan `setRealpath` en cache) |
| Detección formal del cache path | ✅ Implementado (`isBunCachePath` + `fetchCacheDirectoryPath(env, null)`) |
| Trailing separator en `cache_path` de HOME | ✅ Corregido (Fix 2: normalizar trailing separator) |
| Replicar comportamiento desktop (hardlink) | ✅ Verificado (14 módulos, exit 0; BuildID `1ecedd28`) |
