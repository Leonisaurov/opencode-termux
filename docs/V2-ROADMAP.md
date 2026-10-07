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

- [ ] **B4 · H2.4** — adaptación de build. `build-opentui.sh` y `build-opencode.sh`: entrada → `packages/cli`, reubicar swap de `libopentui.so` (`packages/native/lib`) y su glob de fallback; actualizar en el mismo commit `test-downstream-bundle-contracts.py` y `test-changed-products.py`.
      **Cierre:** los dos contratos + `bash -n` + `build-opencode.yml` cache-contract paridad.

- [ ] **B5 · H2.5** — pines/docs/tag. `OPENCODE_VERSION` → 2.0.24, docs (`AGENTS.md`, `CLAUDE.md`, `README.md`, `PROGRESS.md`), `releases/manifest`, tag `opencode-v2.0.24-android`. Probar `installer.py` con `test-installer.py`.
      **Cierre:** grep de `1\.18\.34` sin residuos en rutas de producto v2 + `test-installer.py` verde.

- [ ] **B6 · H2.6** — dispositivo. `build-android.yml` con pins nuevos, publicar con `workflow_dispatch` (job `publish` consume ESA corrida). En el teléfono: `install.sh`, `opencode --version` = 2.0.24, `tui-smoke.sh`, **capturas tmux de la TUI renderizando** y una sesión real con **migraciones SQLite ejecutándose en Bionic**.
      **Cierre:** release `v2.0.24-android` + evidencia en `PROGRESS.md`. **Merge a `main` solo con B6 verde.**

## Contratos y encaje de rama

Cada pin movido genera keys `ci-cache-v2-*` nuevas ⇒ la rama no contamina `main`. `test-workflow-cache-contracts.py` exige paridad exacta productor/consumidor ⇒ opencode+v2, Bun 1.4.2 y OpenTUI 0.5.14 cambian **atómicamente por producto**. Se mantiene: prohibición de `ci/source-manifest.json` en keys, naming `-android`, "empujar al remoto declarado antes de compilar".

## Verificación por paso (nunca "compila")

Estáticos por commit: `test-build-state.py`, `validate-source-tree.py`, `test-workflow-cache-contracts.py`, `test-downstream-bundle-contracts.py`, `test-module-graph-patch.py`, `test-patch-opentui-core-runtime.py`, `test-installer.py`, `bash -n`. CI vía `gh` (dispatch + monitor; publicar solo con `workflow_dispatch`). Dispositivo: `install.sh` + `--version` + `tui-smoke.sh` + capturas tmux + sesión real.

## Límites de lo afirmable

"Compila" ≠ "arranca". Un `bun build` en host no valida el binario Bionic. El cache-hit no prueba que el binario corresponda al pin. La paridad funcional v2 (providers, MCP, sesiones, portapapeles) no se declara más allá del smoke. CP-C sigue abierto hasta A1.
