# Mantenimiento documental

- [x] Inventariar la integración actual de Codex Android.
- [x] Definir enrutamiento explícito para Codex, OpenCode, Kilo, Bun y Termux.
- [x] Separar fuentes upstream, scripts del port, caches y artefactos.
- [x] Documentar la regla de `TMPDIR` y el preflight de builds pesados.
- [x] Añadir manifiestos y caches verificables al mapa de builds.
- [x] Mantener los checkouts Codex/Kilo aislados de los scripts comunes.
- [ ] Revisar este mapa cuando cambien checkouts, workflows o artefactos.

## Compilación incremental

- [ ] Medir hits/misses, tiempos y estadísticas de compilador de todos los jobs.
- [x] Crear contrato y función común de claves para target/API/NDK/toolchain/
      fuente/lockfiles/parches (`ci/scripts/cache-contract.py`; Bun/Core
      conectados).
- [x] Añadir rutas persistentes comunes para Cargo, Zig, ccache/sccache y Bun.
- [x] Añadir helper de resumen estándar `ci/scripts/ci-summary.sh`.
- [x] Separar caches de dependencias, intermediates y artifacts finales en los
      workflows de Bun, OpenTUI, Rusty V8 y Codex.
- [x] Integrar `ccache` para CMake/Bun y conservar `sccache` para Rusty V8,
      con rutas persistentes y validación.
- [x] Persistir y validar caches de Zig por target y toolchain.
- [x] Mejorar cache de Bun: cache global `~/.bun/install/cache` separada y
      lock/script inputs; no usar `node_modules` como contrato.
- [x] Corregir la clave de Codex para incluir el commit real del checkout
      externo, toolchain, lockfile y script de manifest.
- [x] Separar instalación, bundling y ensamblado de OpenCode; Kilo conserva su
      cache de dependencias independiente.
- [ ] Añadir detector de cambios y fallback de cache validado al DAG.
- [x] Añadir resumen de observabilidad por job y pruebas de contrato/hit/
      invalidación/corrupción de manifest.
- [ ] Medir cold/warm/pequeño/dependencia/toolchain en un runner CI real.
- [ ] Ejecutar actionlint/YAML/shell/tests y una comparación de tiempos antes y
      después; no lanzar builds locales pesadas.
