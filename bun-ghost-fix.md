# bun-ghost-fix: Paquete fantasma "bun" para peer dependencies (Android/Termux)

## Resumen

`bun add -g bunli` fallaba con `error: postinstall script from "bun" exited with 1`.
Causa: las deps de bunli (`@bunli/utils`, `@bunli/tui`, `@bunli/runtime`) declaran
`bun >=1.3.11` como peerDependency → Bun descargaba el paquete `bun@1.3.14` de npm →
su `postinstall install.js` (que self-instala el binario) falla en Android
(`require.resolve('@oven/bun-linux-aarch64-android')` falla + fallback `npm install` ENOENT)
→ el install global aborta.

**No era el bug #25110** (deps transitivas): las transitivas de bunli se instalaban
correctamente. El fallo era exclusivamente el postinstall del peer dep `bun`.

## Solución: paquete fantasma funcional (no skip)

**Decisión de diseño**: en vez de "ignorar" el peer dep bun (que rompía la lógica del
resolver y ocultaba el peer), se satisface con un paquete `bun` LOCAL fantasma
(folder dependency). Así los proyectos que requieren `bun` como peer lo ven satisfecho
y el `bun@npm` (inútil en Android — su postinstall falla siempre) nunca se descarga.

El ghost es FUNCIONAL, no vacío (responde a la objeción "si un postinstall necesita bun"):

| Componente | Contenido | Propósito |
|------------|-----------|-----------|
| `package.json` | `{"name":"bun","version":"1.3.14","main":"index.js","bin":{"bun":"bin/bun"}}` — **sin scripts** | Satisface el peer dep (range) |
| `bin/bun` | symlink al self-exe real (`$PREFIX/bin/bun`) | Postinstalls que ejecuten `bun` via `node_modules/.bin/bun` |
| `index.js` | `export * from "bun";` | `import "bun"` / `require("bun")` |

Ubicación: `$BUN_INSTALL/bun-ghost/` (default `~/.bun/bun-ghost/`), creado on-demand
por el propio Bun (idempotente).

## Implementación (parche `patches/bun/android-bun-ghost.patch`)

- **Archivo**: `src/install/PackageManager/PackageManagerEnqueue.zig`
- **Punto**: al inicio de `getOrPutResolvedPackage` (antes del bloque peer)
- **Lógica**: si `version.tag.isNPM()` y `name == "bun"` → crear/obtener el ghost →
  construir el paquete sintético folder **inline** (replicando la rama transitiva
  `.folder` existente: `appendPackage` + `successFn` + `return` con `is_first_time`)
- **Sin scripts garantizado**: el paquete sintético folder se crea con
  `meta.setHasInstallScript(false)` → el postinstall de `bun@npm` nunca corre
- **Fallback seguro**: si el ghost no se puede crear (permisos), se loguea el error
  (`bun-ghost: failed to create ghost package: <err>`) y se cae al flujo npm normal
  (que fallará en Android, pero no crashea el install)
- **Idempotente**: `ensureBunGhostPackageExists` retorna temprano si
  `package.json` ya existe; el symlink tolera `PathAlreadyExists`

### Lecciones de compilación Zig 0.15 (del ciclo de CI)
1. Parámetros de función son `const` — NO se puede mutar `version` para redirigir
   al folder (el primer diseño falló: "cannot assign to constant"). La solución fue
   resolver inline con retorno temprano.
2. `std.fs.cwd().makeOpenPath` retorna `fs.Dir` (no-void) — debe capturarse
   (`var x = try ...; defer x.close()`).
3. Las funciones de nivel de archivo no son métodos del struct — invocación libre
   con `this` explícito.
4. `zig ast-check` valida sintaxis, NO tipos — la semántica solo la valida el CI.

## Verificación (BuildID 7aba35f6)

| Test | Resultado |
|------|-----------|
| `bun add -g bunli` | ✅ Exit 0, 134 packages, sin postinstall fallido |
| Ghost creado | ✅ `~/.bun/bun-ghost/` (package.json 1.3.14, bin/bun symlink, index.js) |
| Peer satisfecho | ✅ lockfile: `bun@file:.../bun-ghost` — sin `@oven/bun-linux-aarch64-android` descargado |
| `bunli --version` | ✅ Exit 0 |
| `bun x cowsay` | ✅ Exit 0 (sin regresión) |

## Limitaciones aceptadas (MAJOR del code review)

- **Lockfile no portable**: la resolución queda como `bun@file:<path absoluto>`
  (máquina-específica). Aceptado: proyecto Termux-específico; el CI y el dispositivo
  regeneran sus propios lockfiles.
- El ghost aplica a TODOS los "bun" (peer, dep directa, transitiva) — correcto en
  Android donde `bun@npm` nunca podría funcionar.

## Commits

| Commit | Cambio |
|--------|--------|
| `ad5d469` | parche + apply-patches.sh |
| `5871cb5` | cache key incluye hash del parche ghost |
| `20e0079` | función libre vs método |
| `fab5250` | resolución inline sin mutar version (rediseño definitivo) |
