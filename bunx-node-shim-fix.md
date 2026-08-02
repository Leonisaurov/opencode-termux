# bunx-node-shim-fix: Reparación de `bun x` en Android/Termux

## Resumen

`bun x <paquete>` fallaba en Termux con `Cannot find module 'yargs'` (o la transitiva correspondiente) ejecutado por **Node.js del sistema**. El error era `node:internal/modules/cjs/loader` — no de Bun.

**Causa raíz (3 problemas encadenados)**:
1. El shim `node`→`bun` se creaba en `/data/local/tmp` (no escribible en Termux) → `env node` → Node.js del sistema.
2. Incluso con bun invocado, el bin wrapper `.bin/cowsay` (symlink) se pasaba tal cual a `Run.boot` → `require('./index')` relativo se resolvía contra `.bin/` y fallaba.
3. `needs_to_force_bun` era false porque Node.js del sistema está en PATH → el shim no se creaba.

**Solución (3 fixes en `android-bunx-node-shim.patch`)**:
1. `bunNodeDir()` usa el TMPDIR de Termux (`/data/data/com.termux/files/usr/tmp`) — respeta `$TMPDIR` en runtime.
2. `execAsIfNode` sigue el symlink del bin wrapper 1 nivel (readlink + join contra dirname) → resuelve al paquete real.
3. `needs_to_force_bun = true` en Android — Bun siempre es el runtime (node del sistema no entiende el layout symlink).

## Diagnóstico

### Problema 1 — Shim node→bun falla

`bun_node_dir` hardcodeaba `/data/local/tmp/bun-node-<sha>` en Android. En Termux ese dir no es escribible (app sandbox). El `symlinkZ` falla silenciosamente (`createFakeTemporaryNodeExecutable` traga errores) → PATH queda sin shim → `env node` → Node.js del sistema.

**Fix**: `bunNodeDir()` ahora deriva de `platformTempDir()` que respeta `$TMPDIR`/`$TMP`/`$TEMP` en runtime (bun.once-cached). El fallback de Android en `platformTempDir()` también apunta al TMPDIR de Termux.

### Problema 2 — Entry `.bin/cowsay` mal resuelto

`execAsIfNode` pasaba `normalized_filename` (el symlink `.bin/cowsay`) directamente a `Run.boot`. Los requires relativos se resolvían contra `node_modules/.bin/` (donde no hay nada) en vez de `node_modules/cowsay/`.

**Fix**: follow-symlink del bin wrapper 1 nivel antes de `Run.boot`:
```zig
const boot_entry = brk: {
    const link_target = switch (bun.sys.readlink(bun.path.z(normalized_filename, &entry_z_buf), &link_target_buf)) {
        .result => |target| target,
        .err => break :brk normalized_filename,
    };
    if (std.fs.path.isAbsolute(link_target)) break :brk link_target;
    const entry_dir = bun.path.dirname(normalized_filename, .posix);
    break :brk bun.path.joinAbsStringBufChecked(
        entry_dir,
        resolved_buf[0 .. resolved_buf.len - 1],
        &.{link_target},
        .posix,
    ) orelse normalized_filename;
};
```
Patrón: `node_fs._cpSymlink`.

### Problema 3 — `needs_to_force_bun` false

`needs_to_force_bun = force_using_bun or !found_node`. Como Node.js del sistema está en PATH, `found_node = true` → shim no se crea → `env node` → Node.js del sistema.

**Fix (formal)**: en Android, Bun debe ser SIEMPRE el runtime porque el layout symlink solo lo entiende bun:
```zig
var needs_to_force_bun = force_using_bun or !found_node or (comptime Environment.isAndroid);
```

## Por qué la solución es formal (no parche)

El principio rector es el mismo que `isBunCachePath`: **emular el comportamiento esperado**:

| Plataforma | Backend install | Runtime de bins | ¿Quién entiende el layout? |
|-----------|----------------|-----------------|---------------------------|
| Desktop | hardlink | node (si existe) | ✅ node (paths reales) |
| Termux | symlink → cache | bun (obligatorio) | ✅ solo bun |

En desktop, node puede ejecutar los bins porque el layout es hardlinks (paths reales). En Termux, el layout es symlinks al cache — solo bun lo entiende (via `isBunCachePath`). Por tanto, en Termux bun DEBE ser el runtime. No es arbitrario — es la consecuencia directa del backend symlink.

## Cadena completa que funciona

```
bun x cowsay (Android, needs_to_force_bun=true)
  → shim node→bun se crea en TMPDIR (fix 1) ✅
  → env node → shim → bun (no node del sistema) ✅
  → bun execAsIfNode → boot_entry sigue symlink bin 1 nivel (fix 2) ✅
  → node_modules/cowsay/cli.js (path lógico del paquete) ✅
  → require('./index') → node_modules/cowsay/index.js ✅
  → require('yargs') → walk-up desde node_modules/cowsay/ → node_modules/yargs ✅
```

## Verificación (Termux, BuildID e973f419)

| Test | Resultado |
|------|-----------|
| `bun x cowsay "hola"` | ✅ Exit 0, vaca ASCII |
| `bun x cowsay "Bun funciona en Termux!"` | ✅ Exit 0 |
| `bun x cowsay --help` (usa yargs) | ✅ Exit 0 |
| Shim `$TMPDIR/bun-node-*/node → /usr/bin/bun` | ✅ Creado correctamente |

## Commits

| Commit | Cambio |
|--------|--------|
| `db84f4d` | Fix 1: bunNodeDir TMPDIR Termux |
| `31350d0` | Fix 2: execAsIfNode follow-symlink |
| `3ec8c08` | Fix 3: force_bun Android |

## Archivos

- `patches/bun/android-bunx-node-shim.patch` — 3 fixes
- `bun-source/src/cli/run_command.zig` — bunNodeDir, execAsIfNode, needs_to_force_bun
- `bun-source/src/resolver/fs.zig` — platformTempDir fallback Termux
