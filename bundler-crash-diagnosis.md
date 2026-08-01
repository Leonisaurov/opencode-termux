# bundler-crash-diagnosis: Crash del bundler de Bun en Android ARM64

## Resumen

El bundler de Bun 1.3.14-canary.1 en Android ARM64 crashea con SIGSEGV (exit 133/SIGTRAP) al compilar module graphs grandes (el de opencode). El runtime básico funciona (bunli, FFI, allocator), pero `Bun.build({compile})` con graphs grandes muere con `panic: Segmentation fault at address 0x7XXXXXXXXX`.

**Causa raíz**: `mi_expand` en `mimalloc_compat.cpp` estaba implementado como `std::realloc`, que PUEDE mover el bloque. La semántica real de `mi_expand` es "expandir in-place o devolver NULL, nunca mover". Esto rompe el contrato de `std.mem.Allocator.resize` de Zig ("si true, el puntero NO cambia") y causa **use-after-free silencioso** en los `ArrayList.grow` del bundler.

## Síntoma

- `panic: Segmentation fault at address 0x75F935B000` (dirección varía entre runs: 0x769F468000, 0x74508D2000, 0x6F7F2E0000 — no determinista)
- Exit 133 (SIGTRAP) según bash
- Ocurre DENTRO de `Bun.build()` con module graph grande
- NO ocurre con builds triviales

## Tests realizados

### Test 1-2: Bundler base y compile trivial (PASS)
```bash
bun build mini.ts --outfile mini-out.js          # ✅ exit 0, 65 bytes
bun build mini.ts --compile --outfile mini-compile  # ✅ exit 0, 91.5 MB binario
```
El bundler base y `--compile` funcionan en archivos pequeños.

### Test 3-4: Bundler sobre opencode sin compile (errores normales, NO crash)
```bash
bun build src/index.ts                          # ❌ error normal: "Browser build cannot import node:v8"
bun build src/index.ts --target=bun --format=esm # ❌ error normal: "Could not resolve @opentui/core-darwin-x64"
```
El bundler produce errores de resolución normales sobre opencode — NO crashea. Un bundler roto no daría errores tan limpios.

### Test 5: Las 7 variantes del build completo (TODAS crashean)

| Variante | Plugin | Define | Entries | Compile | Minify | Split | Resultado |
|----------|--------|--------|---------|---------|--------|-------|-----------|
| full | ✅ | ✅ | 3 | ✅ | ✅ | ✅ | 💥 SIGSEGV @ 0x6BB6272000 |
| index-only | ✅ | ✅ | 1 | ✅ | ✅ | ✅ | 💥 SIGSEGV @ 0x74D2F16000 |
| noplugin | ❌ | ✅ | 3 | ✅ | ✅ | ✅ | 💥 SIGSEGV @ 0x79AFE6E000 |
| nodefine | ✅ | ❌ | 3 | ✅ | ✅ | ✅ | 💥 SIGSEGV @ 0x6F5A814000 |
| nocompile | ✅ | ✅ | 3 | ❌ | ✅ | ✅ | 💥 SIGSEGV @ 0x7499406000 |
| nominify | ✅ | ✅ | 3 | ✅ | ❌ | ✅ | 💥 SIGSEGV @ 0x79827DC000 |
| nosplitting | ✅ | ✅ | 3 | ✅ | ✅ | ❌ | 💥 SIGSEGV @ 0x5AF (null-deref) |

TODAS crashean → el crash NO depende de plugin/define/compile/minify/splitting/entries. El punto común es el module graph grande de opencode procesado por el bundler.

## Causa raíz: `mi_expand` semánticamente incorrecto

### La semántica REAL de `mi_expand` (mimalloc)

> "Expand in place, **or return NULL** if the memory cannot be expanded (i.e. **it will move**)."

1. **NUNCA mueve el bloque**. O expande in-place devolviendo el MISMO puntero, o devuelve NULL dejando `p` intacto.
2. `mi_expand(NULL, n)` → como `mi_malloc(n)`.
3. Si `newsize <= mi_usable_size(p)` → devuelve `p` sin tocar nada.

### Nuestra implementación (BUG)

```cpp
void* mi_expand(void* p, size_t newsize)
{
    return std::realloc(p, newsize);  // ❌ PUEDE mover y libera el viejo
}
```

`std::realloc` puede mover el bloque: devuelve dirección nueva y libera la vieja. Si el chunk siguiente está ocupado y `newsize > chunk_size`, mueve.

### Contrato de Zig que se rompe

`std.mem.Allocator.resize`: "si devuelve `true`, el puntero NO cambia y ahora hay `new_len` bytes".

Con `mi_expand = std::realloc`:
- `realloc` mueve → devuelve puntero NUEVO no-NULL → `resize=true`
- El caller sigue usando el puntero VIEJO (ya liberado)
- → **use-after-free silencioso**

### Cadena de activación en el bundler

```
BundleThread.zig:107 → MimallocArena.init() → mi_heap_new()
BundleThread.zig:110 → allocator = heap.allocator() (MimallocArena vtable)
bundler ensureUnusedCapacity (15 sites) → ArrayListUnmanaged.grow → allocator.realloc
  → primero .resize → MimallocArena.vtable_resize → mi_expand [compat: std::realloc]
  → si realloc mueve → resize=true con puntero NUEVO
  → el bundler sigue usando memory[0..new_len] (puntero VIEJO, ya liberado)
  → USE-AFTER-FREE → SIGSEGV en module graphs grandes
```

Sitios del bundler que dependen del contrato "resize no mueve":
- `ensureUnusedCapacity` (15 sites): AstBuilder, bundle_v2, LinkerContext, options, analyze_transpiled_module, defines, computeChunks...
- `shrinkRetainingCapacity` (4 sites): transpiler, options, scanImportsAndExports, LinkerContext

## El fix

`mi_expand` debe implementar la semántica in-place de mimalloc:

```cpp
void* mi_expand(void* p, size_t newsize)
{
    // mi_expand expands in place or returns NULL — it never moves the block.
    // std::realloc may move and free the old pointer, which breaks the Zig
    // Allocator.resize contract ("if true, the pointer did not change") and
    // causes silent use-after-free in the bundler's ArrayList grows.
    if (p == nullptr)
        return std::malloc(newsize);
    if (newsize == 0) {
        std::free(p);
        return nullptr;
    }
    if (malloc_usable_size(p) >= newsize)
        return p;
    return nullptr;
}
```

## Otras funciones del compat verificadas (correctas)

| Función | Verdict | Nota |
|---------|---------|------|
| `mi_realloc` (`:25`) | ✅ Correcto | `realloc` SÍ puede mover (semántica de mi_realloc) |
| `mi_realloc_aligned` (`:62`) | ✅ Correcto | fresh aligned + memcpy + free |
| `mi_usable_size` / `mi_malloc_usable_size` | ✅ Correcto | `malloc_usable_size` con NULL→0 (mimalloc devuelve 0 para NULL) |
| `mi_heap_*` singleton/no-op | ⚠️ Debilidad | `mi_heap_contains → true` siempre: aceptable porque no hay GC de arenas en Android |
| `mi_is_in_heap_region` / `mi_check_owned → true` | ✅ Por diseño | Call-sites en Android bajo `use_mimalloc` o rama `else` que libera directo |
| `mi_free_size` / `mi_free_size_aligned` → `free` | ✅ Correcto | Pierde el assert de tamaño (documentado en basic.zig) |
| `mi_zalloc` → `calloc(1,size)` | ✅ Correcto | |
| `mi_collect` no-op | ✅ | Único caller directo bajo `use_mimalloc` |

## Pendientes / investigaciones futuras

1. **`MimallocWTFMalloc.h:84`** — `reallocBuffer` usa `std::realloc`. Si ese path se usa para resize con contrato de no-movimiento, podría tener el mismo problema. REVISAR.
2. **`mi_heap_contains → true`** — ¿`MimallocArena.ownsPtr()` se usa en algún path de decisión de free en Android (riesgo de doble-free), o solo en asserts? REVISAR.
3. **Reconstruir Bun** con el fix de `mi_expand` y re-testear el build de opencode en Termux.
4. **Verificar el bundler** con el module graph completo de opencode después del fix.

## Referencias

- `bun-source/src/jsc/bindings/mimalloc_compat.cpp` — archivo del fix (mi_expand)
- `bun-source/src/bun_alloc/MimallocArena.zig` — arena usada por el bundler (ThreadLocalArena)
- `bun-source/src/bundler/BundleThread.zig:107,110` — init del arena en el bundler
- `test-fiel.ts` — test con 7 variantes (`/data/data/com.termux/files/home/.cache/opencode/tmp/test-fiel.ts`)
