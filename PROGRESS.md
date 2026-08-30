# Estado de continuidad — fuentes versionadas

Fecha: 2026-08-30

## Completado en este checkout

- Bun, OpenCode, Kilo, Codex y ambos árboles de OpenTUI están vendorizados como
  fuentes normales dentro de este monorepo y están identificados por commits
  exactos en [`ci/source-manifest.json`](ci/source-manifest.json).
- El checkout raíz es autosuficiente: no usa `.gitmodules`, gitlinks ni pushes
  a repositorios upstream para reconstruir las fuentes.
- Los lockfiles de OpenCode y Kilo ya no contienen `patchedDependencies`.
- Los workflows validan fuentes limpias y usan commits, lockfiles y contratos
  de fuente en sus claves de cache; ya no invocan `apply-patches.sh`.
- El port Android/Bionic de OpenTUI/Kilo, incluida la materialización segura de
  assets mediante `$TMPDIR`, vive en el árbol fuente versionado.

## Estado de la migración

- Integrar en fuentes versionadas el parche de Zig vendorizado de Bun y las
  adaptaciones de WebKit y Rusty V8; sus fuentes externas siguen siendo
  entradas explícitas del contrato y no se mutan durante CI.
- Sustituir las reglas `patches = [...]` de Bazel/Codex por dependencias fuente
  ya modificadas o reglas locales versionadas.
- Ejecutar la matriz CI fría/caliente y revisar los artefactos finales. No se
  afirma una build completa hasta disponer de esos logs y artefactos.

Las referencias a `apply_patch` que formen parte de Codex/OpenCode siguen
siendo funcionales del producto y no pertenecen a este inventario de build.
