# Plan documental del workspace

## Objetivo

Mantener una única guía de enrutamiento para que el trabajo futuro se dirija
al checkout correcto y lea sus instrucciones locales antes de modificar nada.

## Estado de implementación

- [x] Auditar checkouts, artefactos, scripts, workflows y documentación Codex.
- [x] Añadir `AGENTS.md` raíz con rutas para Codex, OpenCode, Kilo, Bun y
      componentes del port.
- [x] Añadir `WORKSPACE.md` como mapa humano breve.
- [x] Enlazar la guía desde el README raíz.
- [x] Eliminar referencias a scripts y parches Codex inexistentes.
- [x] Añadir motor content-addressed en `scripts/build-state.py`, locks y
      manifiestos por nodo.
- [x] Integrar ICU, WebKit, TinyCC, Bun, OpenTUI, OpenCode y empaquetado.
- [x] Integrar Kilo mediante `kilocode_build.sh` y Codex mediante
      `scripts/build-codex-android.sh`.
- [x] Añadir pruebas de hit, invalidación por fuente y propagación de
      dependencias.
- [ ] Ejecutar preflight y builds pesados en el host/CI con aprobación de
      escalada; esta fase no los lanza automáticamente.
- [x] Añadir contrato `ci-cache-v1`, rutas persistentes de caches y validación
      reutilizable de outputs; falta medirlo en un runner real.
- [x] Añadir resumen estándar de cache/estado/compilador/tiempo para jobs que
      lo incorporen; falta conectar estadísticas reales de cada compilador.

## Criterio de mantenimiento

Los checkouts upstream conservan su documentación propia. La raíz solo
documenta integración, portabilidad Android/Termux, rutas y artefactos que
realmente existen en este workspace.

## Plan: compilación incremental óptima para Bun, Zig, Rust y Android

### Resultado buscado

Reducir el trabajo después de cambios pequeños sin usar una cache como contrato
de corrección. Cada producto tendrá tres capas separadas: dependencias
descargadas, resultados de compilación reutilizables por contenido y artefactos
finales validados. El DAG seguirá entregando artifacts entre jobs dentro de la
misma ejecución.

### Decisiones de arquitectura

- Mantener `build-state.py` para saltar un nodo completo cuando sus entradas y
  salidas no cambiaron; no pretender que ese motor haga recompilación por
  función.
- Rust usará `target/` restaurado para Cargo y `sccache` para objetos Rust/C/C++.
  Las claves incluirán target, API Android, NDK, toolchain, lockfile, fuente
  fijada y parches.
- Rusty V8 conservará `ninja`/GN y `sccache`; sus caches incluirán `gn_out`,
  intermediates y objetos, pero nunca sustituirán la validación del artifact.
- Zig conservará sus caches de proyecto y globales mediante rutas explícitas
  (`--cache-dir`/`--global-cache-dir` o sus variables equivalentes), separadas
  por target, API, NDK, versión de Zig y hash de parches.
- Bun separará la cache global de paquetes (`~/.bun/install/cache`) de la
  cache de compilación C/C++ (`ccache` cuando el build lo soporte). No se
  tratará `node_modules` como cache primaria; `bun.lock` y una instalación
  reproducible serán la fuente de verdad.
- OpenCode y Kilo se dividirán en nodos de instalación, generación/bundling y
  ensamblado. Un cambio TypeScript no debe invalidar Bun, OpenTUI ni sus
  dependencias nativas.
- Las caches de GitHub tendrán una clave exacta content-addressed y un
  `restore-keys` seguro solo para recuperar intermediates; el resultado
  restaurado deberá pasar validación antes de saltar el build. Las caches
  parciales nunca convertirán un productor requerido en opcional.

### Fases y checkpoints

#### Fase 1: medición y contrato de cache

Estado: contrato implementado en `ci/scripts/cache-contract.py`; las claves de
Bun y Core ya lo consumen. La medición en CI sigue pendiente.

- Registrar por job `cache-hit`, cache restaurada, `BUILD_STATE`, duración,
  tamaño y estadísticas de `sccache`/`ccache`.
- Inventariar rutas reales producidas por cada build y eliminar paths que solo
  contienen el binario final cuando se necesiten intermediates.
- Definir una función común de clave con versión de esquema, runner, target,
  API, NDK, toolchain, fuente, lockfiles y hashes de parches.

Checkpoint: un build frío y otro idéntico muestran qué capas se restauran y
cuánto trabajo evitan, sin aceptar artifacts incompletos.

#### Fase 2: nativos (Bun, OpenTUI y Rusty V8)

- Habilitar `ccache`/`sccache` antes de configurar CMake, Zig, Cargo o GN.
- Cachear ICU/WebKit/TinyCC y Bun con intermediates, usando validadores de
  salida y sin mezclar arquitecturas.
- Cachear Zig por target y conservar `.zig-cache`/global cache sin incluirlo en
  los hashes de entrada del motor de estado.
- Mantener Rusty V8 con GN/Ninja y `sccache`; medir si Cargo incremental aporta
  algo frente a sccache antes de activarlo globalmente en builds release.

Checkpoint: modificar un archivo nativo pequeño y comprobar recompilación de
objetos afectados, no reconstrucción completa; un cambio de NDK/ABI debe
invalidar todo lo necesario.

#### Fase 3: Rust (Codex y dependencias)

- Separar cache de registry/git de `target/` y de objetos `sccache`.
- Incluir el commit resuelto del checkout externo de Codex y el parche de sus
  manifests en la clave, no solo el lockfile del workspace raíz.
- Mantener OpenSSL vendorizado para Android y hacer que su compilación también
  use el cache de compilador cuando sea posible.
- Activar `CARGO_INCREMENTAL` únicamente para los perfiles donde la medición
  demuestre beneficio; conservar sccache como mecanismo entre runners.

Checkpoint: cambiar un crate hoja y verificar que crates no afectados aparecen
como `Fresh`/cache hit, mientras que un cambio en el lockfile fuerza resolución
correcta.

#### Fase 4: JS/TS y empaquetado

- Cachear Bun global install y la cache de transpiler por versión de Bun,
  plataforma y lockfile; usar instalación congelada.
- Mantener `build-state.py` como fast path para bundling sin cambios.
- Separar generación de paquetes, reemplazo de `libopentui.so` y ensamblado
  final para que un cambio de metadata no reconstruya fuentes nativas.
- No prometer recompilación parcial de un bundle standalone si Bun no ofrece un
  cache persistente de grafo para ese modo; medir y documentar el límite.

Checkpoint: cambiar solo TypeScript, solo OpenTUI y solo metadata, verificando
qué nodos se ejecutan y que el artifact final sigue siendo reproducible.

#### Fase 5: DAG, observabilidad y aceptación

- Añadir detector de cambios y fallbacks de cache validados para hojas no
  afectadas, conservando `needs` y artifacts del mismo run.
- Publicar un resumen por job con capas hit/miss, objetos compilados y tiempo.
- Probar cold build, warm build idéntico, cambio pequeño, cambio de dependencia,
  cambio de toolchain y cache corrupta.

### Criterio de éxito

- Un build idéntico no recompila ningún nodo válido.
- Un cambio pequeño en Rust/C++/Zig recompila solo unidades afectadas o sus
  dependientes directos, con evidencia de estadísticas.
- Cambios de ABI/API/NDK/toolchain invalidan caches incompatibles.
- Bun reutiliza paquetes y compilación nativa, aunque el bundling final pueda
  seguir siendo completo.
- Un cache miss o cache corrupta nunca produce un artifact sin validación ni
  oculta un fallo del DAG.

### Fuentes oficiales consultadas

- GitHub Actions: caching y `restore-keys`: <https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching>
- Cargo profiles e incremental: <https://doc.rust-lang.org/cargo/reference/profiles.html>
- sccache: <https://github.com/mozilla/sccache> y <https://github.com/mozilla-actions/sccache-action>
- Zig Build System y sus directorios de cache: <https://ziglang.org/learn/build-system/>
- Bun global cache/install: <https://bun.sh/docs/pm/global-cache> y <https://bun.sh/docs/pm/cli/install>
- Bun bundler/watch: <https://bun.sh/docs/bundler>
