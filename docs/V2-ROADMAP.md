# Hoja de ruta OpenCode v2 (2.0.24) — éxito por éxito

Archivo de seguimiento en el repo. Cada hito se cierra con **evidencia fechada**
(comando / log / artefacto / captura), nunca con "compila". Ninguna casilla se
marca sin su criterio de cierre. Rama de trabajo: `feat/opencode-v2`.

## Estado de partida (verificado)

- [x] **Fase 1 completa** — OpenCode 1.18.34 vendorizado (upstream `aec0b9a6…`), release `stack-v1.18.34`, instalado y validado en el teléfono. `main` publica 1.18.x.
- [x] **H2.0(a) / CP-A cerrado** — formato standalone de Bun compatible con `ci/scripts/module-graph-patch.ts`.
- [x] **H2.0(b) / CP-B cerrado (nivel artefacto)** — OpenTUI 0.5.14 compila, enlaza y carga como `aarch64-linux-android.24` con Zig 0.16.0 (sin `patchelf`). CI verde `37491176567`: gate `stubs=328 bionic=6624 undef=170 → OK`. Layout real: `packages/native/lib/aarch64-linux-android.24/libopentui.so`.
- [x] **H2.0(c) / CP-C cerrado** — `bun build --compile` emite un standalone con grafo extraible desde `packages/cli` de v2 (evidencia `37567822938`). **H2.0(d) cerrado** — tabla de acoplamiento verificada. Gate Fase A verde.
- [ ] Pendiente: el re-port atómico H2.1–H2.6.

Hechos de upstream (tag `v2.0.24`): commit re-vendor `e7a34f09bfd9134dfade5a8ddb843f7030bc9a69`; `@opencode/cli` bin `./bin/opencode.cjs`, dev-entry `src/index.ts`, TUI vía `@opencode/tui` + `src/server-process.ts`; migraciones en `packages/core/src/database/{drizzle,migration}`; `script/build.ts` tiene targets fijos sin android ⇒ **no** se adopta.

## Fase A — corte de riesgo restante (runner desechable, antes de builds caros)

- [x] **A1 · H2.0(c)** — árbol v2 y viabilidad de `bun --compile` a Bionic (decide **CP-C**). **CERRADO 2026-10-07 (CP-C no se dispara).** `37567822938`: `bun install` del workspace v2 OK con Bun 1.4.2; Test B emite standalone ELF de 135 MB con trailer `---- Bun! ----` presente. Ver evidencia en `PROGRESS.md`.
      `bun install` de snapshot `e7a34f09`; confirmar entrada standalone `packages/cli/src/index.ts` (o `bin/opencode.cjs`); localizar worker del TUI (`@opencode/tui` + `server-process.ts`); **producir un `bun build --compile` real** que intente target bionic; decidir explícitamente no usar `script/build.ts`.
      **Cierre:** veredicto escrito en `PROGRESS.md` + log del probe. CP-C: si `packages/cli` no permite `--compile` propio a Bionic ⇒ abandonar v2 y reportar; si permite ⇒ continuar. (Validar en host NO prueba el binario Bionic.)

- [x] **A2 · H2.0(d)** — migraciones, esquema y puntos de acoplamiento del build. **CERRADO 2026-10-07.** Tabla ruta-1.18→ruta-v2 con existencia verificada (entrada `packages/cli/src/index.ts`; migraciones `.ts` vía `migration.gen.ts` + drizzle/Effect en runtime; fix Termux → `packages/util/src/global-roots.ts`). Ver `PROGRESS.md`.
      Resolver el glob correcto para `opencode/scripts/build-opencode-android.ts` contra `packages/core/src/database/{drizzle,migration}`; verificar equivalentes de `models-snapshot` y `workerPath`/`entrypoints`/`tsconfig`; confirmar dónde vive el override de rutas de Termux en v2 (prepara B1).
      **Cierre:** tabla ruta-1.18 → ruta-v2 con existencia verificada en el árbol, en `PROGRESS.md`.

**Gate:** **[VERDE 2026-10-07]** A1 y A2 verdes ⇒ se autoriza el re-port (Fase B). CP-C no se disparó.

## Fase B — re-port atómico (solo si A verde). Cada paso = commit + validación

- [x] **B1 · H2.1** — re-vendor v2.0.24. **CERRADO 2026-10-07 (`6550ea3`).** `opencode/src` sustituido por `e7a34f09` (8067 ficheros; sin `.git` anidado; `node_modules` ignorado). Fix Termux porteado de `packages/core/src/global.ts` → `packages/util/src/global-roots.ts`. `ci/source-manifest.json`: opencode → `e7a34f09`. `validate-source-tree.py` OK (7 árboles). *Conocido pendiente:* `test-downstream-bundle-contracts.py` está rojo en `OPENCODE_WORKER` (ruta 1.18 inexistente) por diseño — lo cubre B4.
      **Cierre:** `validate-source-tree.py` + árbol limpio + grep sin residuos de 1.18.x.

- [x] **B2 · H2.2** — estrategia "Probe 1.2.13 primero". **CERRADO 2026-10-07 (corridas n4–n7, `8905f8a`): veredicto — NO hace re-port de Bun.** El emisor host **1.3.2** construye el CLI v2 (`target:"bun"`, decatalog, lock propio) y su grafo, tras `patchAndroidModuleGraph` (undici, patchCount=1) + `validateAndroidStandalone`, **corre sobre nuestro bun Android 1.2.13-canary**: `--version` ⇒ `opencode v2.0.24` rc=0 en el teléfono. Fallo restante = artefacto de plataforma (`@opencode-ai/pty-linux-x64-musl` referenciado; swap nativo → B4), no wire-format. Hallazgos de layout: grafo 1.4.2 (Rust) no legible por el runtime (trailer movido); emisor 1.2.13 no construye v2. Consecuencia: **CP-D descartado**; pin Bun Android queda 1.2.13, `HOST_BUN_VERSION` 1.3.2 sigue siendo el emisor; los pines de `build-bun.yml`/Kilo NO se tocan.
      **Evidencia:** `probe-trivial-1.3.2-android` ⇒ `PROBE_BUN_1.3.2_OK`; `probe-v2-1.3.2-android` ⇒ `opencode v2.0.24` + arranque de server con error acotado al paquete pty host (captura tmux 2026-10-07); veredictos en `PROGRESS.md`.

- [x] **B3 · H2.3** — OpenTUI 0.5.14: el parche 0.4.5 se convirtió en **verificador del guard**. **CERRADO 2026-10-07 (`f4a38f5`).** Hallazgo: upstream 0.5.14 publica la ruta bun YA protegida (`const loaded = …` + `typeof loaded !== "string"`, literal en `chunk-bun-sjw2d9bq.js:965-970`); el bloque sin proteccion del 0.4.5 ya no existe. La llamada restante sin guard vive en `loadBundledFilePath` (ruta node) envuelta en try/catch ⇒ degrada al fallback, no es objetivo de parche. El script verifica el texto real, parchea si reaparece el layout 0.4.5 y falla ante cualquier tercer layout. Pines: `opentui-opencode` = `31a93fbe` (0.5.14) ya correcto en manifest/workflows.
      **Evidencia:** 10/10 unitarios + corrida real contra el tarball 0.5.14 (`verified=2 patched=0 irrelevant=2`, rc=0) + `test-workflow-cache-contracts.py` verde.

- [x] **B4 · H2.4** — adaptación de build. **CERRADO 2026-10-07 (`cf2cf3e`, sonda `37575020163`).** `build-opencode-android.ts` reescrito al árbol v2: entrada única `packages/cli/src/index.ts`; caen los pasos 1.18 de models-snapshot y defines de migraciones/worker (todo viaja versionado en el grafo; OpenTUI 0.5.14 resuelve su parser-worker como file asset). Plugins espejo de upstream: assets de web-ui `{}` (canal no-local ⇒ 404 solo en rutas de navegador; TUI/API intactas), stub `undefined` del `pty-binding` (elimina el crash Bionic de `@opencode-ai/pty` visto en B2), require estático del watcher glibc (degrada por su try/catch). Defines: `OPENCODE_LIBC='glibc'`, `FFF_LIBC='gnu'`, `OPENTUI_LIBC=glibc`, `OPENCODE_ARTIFACT='cli'`. `build-opencode.sh`: `OPENCODE_PKG` → `packages/cli`, `bun install --os="*" --cpu="*"` de `@opentui/core`/`@opencode-ai/pty` como upstream, y swap del `.so` en **`@opentui/core-linux-arm64`** (la rama que resuelve el dispositivo). *Errata B6 (`5abfad6`): el bundler embebe el paquete del host del runner (x64); el swap correcto es `core-linux-x64`, como en 1.18.* Contratos: `test-downstream-bundle-contracts.py` exige el layout v2 y prohíbe los defines 1.18. Evidencia de ensamblado real: la corrida stand-alone de `build-opencode.yml` no puede materializar Bun en rama (artifact intra-DAG + cache scopeada por rama) ⇒ sonda `v2-probe-assembly.yml` baja los artefactos verdes de main con las validaciones del producto y corre el script real: install 4833+832 paquetes, guard OpenTUI `verified=24 patched=0`, swap en `.bun/@opentui+core-linux-arm64@0.5.14`, grafo 58.9 MB, undici repairs=1, standalone AArch64 `total=file_size=156,552,762`, `validate-standalone` OK; **en el teléfono el mismo artifact: `opencode v2.0.24` rc=0**. *Pendiente B6:* TUI completa + migraciones SQLite; degradados conocidos: watcher/fff/pty nativos (stub) y web-ui.
      **Cierre:** los dos contratos + `bash -n` + `build-opencode.yml` cache-contract paridad.

- [x] **B5 · H2.5** — pines/docs/tag. **CERRADO 2026-10-07 (`0761fe6`).** `OPENCODE_VERSION`→`2.0.24` y `OPENCODE_SOURCE_COMMIT`→`e7a34f09` en `env.sh` (consonante con `ci/source-manifest.json`, que ya estaba correcto desde B1); defaults de `build-android.yml` (incluido `release`, que nombra `stack-v2.0.24`), `build-opencode.yml` y `build-opencode-docker.yml` a `2.0.24`; docs de pines (`AGENTS.md` añade que el grafo lo emite el host Bun `1.3.2`, `CLAUDE.md`, `README.md` incl. ejemplo de `--release`) y `releases/manifest.example.json` a la línea v2; fixture de `test-installer.py` sobre `v2.0.24` (el regex ya aceptaba el formato). Verde: `test-installer` 10/10, `test-workflow-cache-contracts`, bundle-contracts, build-state, source-tree, changed-products, `bash -n` y los 3 YAML; **grep `1\.18\.34` sin residuos** fuera de historias/PROGRESS. *Decisión:* el tag `opencode-v2.0.24-android` se crea con la publicación de B6, no antes de la verificación en dispositivo.

- [x] **B6 · H2.6** — dispositivo. **CERRADO 2026-10-07.** Primera release con swap incorrecto (arm64) ⇒ TUI no cargaba la `.so`; fix `5abfad6` volviendo al swap `core-linux-x64` (el bundler embebe el paquete del host del runner). Re-publicación: `build-android.yml` 37602945465 sobre `5abfad6`, jobs verdes incluido `publish`, asset `opencode-2.0.24-android-aarch64.tar.gz` 53,618,276 B. En el teléfono con el asset publicado: `install.sh --just opencode --prefix ~/.local --smoke-test` rc=0, `opencode --version` = 2.0.24, TUI tmux renderizando (standalone y background service), **48 migraciones drizzle v2 aplicadas en Bionic**, sesión real `opencode run -m ollama-cloud/nemotron-3-nano:30b` ⇒ **RELEASEOK**. Cleanup: sondas desechables retiradas, 8 suites estáticas verdes.
      **Cierre:** release `stack-v2.0.24` regenerada + tag `opencode-v2.0.24-android` + evidencia en `PROGRESS.md`. Merge a `main` ejecutado con B6 verde.

## Contratos y encaje de rama

Cada pin movido genera keys `ci-cache-v2-*` nuevas ⇒ la rama no contamina `main`. `test-workflow-cache-contracts.py` exige paridad exacta productor/consumidor ⇒ opencode+v2, Bun 1.4.2 y OpenTUI 0.5.14 cambian **atómicamente por producto**. Se mantiene: prohibición de `ci/source-manifest.json` en keys, naming `-android`, "empujar al remoto declarado antes de compilar".

## Verificación por paso (nunca "compila")

Estáticos por commit: `test-build-state.py`, `validate-source-tree.py`, `test-workflow-cache-contracts.py`, `test-downstream-bundle-contracts.py`, `test-module-graph-patch.py`, `test-patch-opentui-core-runtime.py`, `test-installer.py`, `bash -n`. CI vía `gh` (dispatch + monitor; publicar solo con `workflow_dispatch`). Dispositivo: `install.sh` + `--version` + `tui-smoke.sh` + capturas tmux + sesión real.

## Límites de lo afirmable

"Compila" ≠ "arranca". Un `bun build` en host no valida el binario Bionic. El cache-hit no prueba que el binario corresponda al pin. La paridad funcional v2 (providers, MCP, sesiones, portapapeles) no se declara más allá del smoke. CP-C sigue abierto hasta A1.

## Epílogo — la travesía v2 (2026-10-05 → 2026-10-07)

**Salida.** Con la fase 1 cerrada (OpenCode 1.18.34 vendorizado, publicado como
`stack-v1.18.34` y verificado con la TUI real en el teléfono), el plan aprobó subir a la
línea v2 por pasos, con esta hoja como archivo de seguimiento y el mandato de cerrar cada
paso con evidencia, nunca con "compila".

**Corte de riesgo (H2.0).** Antes de tocar productos se midieron las cuatro incógnitas:
CP-A el formato standalone de Bun sigue parseable por `module-graph-patch.ts`; CP-B la
librería OpenTUI 0.5.14 compila y **carga** como Bionic `aarch64-linux-android.24` con Zig
0.16 (tres falsos negativos del gate de símbolos medidos y corregidos; `patchelf` nunca fue
opción); CP-C un `bun build --compile` propio sobre el árbol v2 es viable (la ruta del
`script/build.ts` de upstream, sin targets android, se descartó documentadamente); CP-D las
migraciones v2 viajan versionadas (`packages/core/src/database/*`), sin defines 1.18.

**Re-port atómico (B1–B5).** `6550ea3` re-vendió `e7a34f09` completo con su fix de rutas
Termux reubicado. La matriz de emisores B2 resolvió lo que parecía un bump obligatorio de
Bun: el grafo del host 1.3.2 carga en el runtime Android 1.2.13, así que **Bun no se
subió a 1.4.2** — los pines coordinados quedaron 1.2.13/1.3.2 y el riesgo Rust quedó fuera
del port. `f4a38f5` reescribió el parche de runtime JS para el layout de chunks 0.5.14.
`cf2cf3e` reescribió el bundler v2 (`packages/cli`, plugins espejo de upstream: assets
web-ui vacíos, stub `pty-binding`, require estático del watcher glibc) y, como la rama no
puede materializar Bun por CI (cache scopeada por rama, artefactos intra-DAG), nació la
sonda `v2-probe-assembly.yml`: baja los artefactos verdes de main con las validaciones del
producto y corre el script real. `0761fe6` movió pines, docs y defaults a 2.0.24.

**Dispositivo (B6) y la lección cara.** La primera release publicada instalaba, respondía
`--version` y hasta listaba modelos — pero la TUI moría en `resolveRenderLib`. `strings`
sobre el binario dio la causa: el grafo embebía **solo** `@opentui/core-linux-x64`; el
bundler resuelve el paquete nativo contra el **host del runner**, no contra el teléfono, y
el swap a arm64 de B4 nunca llegó a los bytes embebidos. `5abfad6` restauró el contrato de
1.18 (swap sobre x64) y la re-publicación (37602945465) generó el asset correcto. Con el
asset **publicado** instalado en el teléfono: TUI renderizando en tmux en los dos modos
(standalone y background service), 48 migraciones drizzle v2 ejecutadas sobre Bionic, y dos
sesiones reales de extremo a extremo (`TERMUXOK`, `RELEASEOK`) con auth, red y server
funcionando desde el dispositivo.

**Llegada.** Tag `opencode-v2.0.24-android` sobre `5abfad6`, release `stack-v2.0.24`
regenerada, sondas desechables retiradas, 8 suites estáticas verdes, y merge a `main`
(`557185d`) ejecutado solo con B6 verde — que era la condición del plan.

**Lo que se aprendió y queda vigente.**
1. "Compila/instala/--version OK" no toca la ruta TUI: la aceptación era el teléfono y lo
   salvó el teléfono.
2. El contrato del swap lo decide **dónde corre el bundler**, no dónde corre el binario.
3. Los artefactos de GitHub son repo-wide pero las caches son por rama: una rama puede
   sondear artefactos verdes de main, no su cache.
4. Cada pin movido genera keys nuevas: los bumps van atómicos por producto o el contrato
   de paridad los rechaza antes de gastar CI.
