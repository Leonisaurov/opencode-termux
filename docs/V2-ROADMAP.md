# Hoja de ruta OpenCode v2 (2.0.24) — éxito por éxito

Archivo de seguimiento en el repo. Cada hito se cierra con **evidencia fechada**
(comando / log / artefacto / captura), nunca con "compila". Ninguna casilla se
marca sin su criterio de cierre. Rama de trabajo: `feat/opencode-v2`.

## Estado de partida (verificado)

- [x] **Fase 1 completa** — OpenCode 1.18.34 vendorizado (upstream `aec0b9a6…`), release `stack-v1.18.34`, instalado y validado en el teléfono. `main` publica 1.18.x.
- [x] **H2.0(a) / CP-A cerrado** — formato standalone de Bun compatible con `ci/scripts/module-graph-patch.ts`.
- [x] **H2.0(b) / CP-B cerrado (nivel artefacto)** — OpenTUI 0.5.14 compila, enlaza y carga como `aarch64-linux-android.24` con Zig 0.16.0 (sin `patchelf`). CI verde `37491176567`: gate `stubs=328 bionic=6624 undef=170 → OK`. Layout real: `packages/native/lib/aarch64-linux-android.24/libopentui.so`.
- [ ] Pendiente: H2.0(c), H2.0(d), decisión CP-C, y el re-port atómico H2.1–H2.6.

Hechos de upstream (tag `v2.0.24`): commit re-vendor `e7a34f09bfd9134dfade5a8ddb843f7030bc9a69`; `@opencode/cli` bin `./bin/opencode.cjs`, dev-entry `src/index.ts`, TUI vía `@opencode/tui` + `src/server-process.ts`; migraciones en `packages/core/src/database/{drizzle,migration}`; `script/build.ts` tiene targets fijos sin android ⇒ **no** se adopta.

## Fase A — corte de riesgo restante (runner desechable, antes de builds caros)

- [ ] **A1 · H2.0(c)** — árbol v2 y viabilidad de `bun --compile` a Bionic (decide **CP-C**).
      `bun install` de snapshot `e7a34f09`; confirmar entrada standalone `packages/cli/src/index.ts` (o `bin/opencode.cjs`); localizar worker del TUI (`@opencode/tui` + `server-process.ts`); **producir un `bun build --compile` real** que intente target bionic; decidir explícitamente no usar `script/build.ts`.
      **Cierre:** veredicto escrito en `PROGRESS.md` + log del probe. CP-C: si `packages/cli` no permite `--compile` propio a Bionic ⇒ abandonar v2 y reportar; si permite ⇒ continuar. (Validar en host NO prueba el binario Bionic.)

- [ ] **A2 · H2.0(d)** — migraciones, esquema y puntos de acoplamiento del build.
      Resolver el glob correcto para `opencode/scripts/build-opencode-android.ts` contra `packages/core/src/database/{drizzle,migration}`; verificar equivalentes de `models-snapshot` y `workerPath`/`entrypoints`/`tsconfig`; confirmar dónde vive el override de rutas de Termux en v2 (prepara B1).
      **Cierre:** tabla ruta-1.18 → ruta-v2 con existencia verificada en el árbol, en `PROGRESS.md`.

**Gate:** A1 y A2 verdes antes de invertir en el re-port. Si CP-C se dispara, se detiene aquí.

## Fase B — re-port atómico (solo si A verde). Cada paso = commit + validación

- [ ] **B1 · H2.1** — re-vendor v2.0.24. Sustituir **todo** `opencode/src` por snapshot `e7a34f09` (sin `.git` anidado; `bun.lock`/patches juntos). Re-portear el fix de rutas de Termux a su **ubicación v2 verificada en A2**. Actualizar `ci/source-manifest.json` (`opencode` → `e7a34f09`). Un commit.
      **Cierre:** `validate-source-tree.py` + árbol limpio + grep sin residuos de 1.18.x.

- [ ] **B2 · H2.2** — Bun 1.2.13 → 1.4.2. Re-vendor `bun/src` (tag 1.4.2) + **todos** los pines (`env.sh`, `setup-runner.sh`, `build-bun.yml`, `build-bun-target.yml`, `build-android.yml`, `build-opencode*.yml`, `build-kilo.yml`) + revalidar overlay WebKit/TinyCC/heap tagging. Bun 1.4.x es Rust ⇒ confirmar toolchain. **Ojo:** Kilo comparte Bun ⇒ congelar su pin o garantizarle el viejo.
      **Cierre:** `build-bun.yml` verde artefacto Bionic + `test-workflow-cache-contracts.py`.

- [ ] **B3 · H2.3** — OpenTUI 0.5.14: parche de runtime JS. Extraer cadenas reales de los chunks 0.5.14 (`chunk-node-*.js`, `index.node.js`, `node-assets.js`, `runtime-plugin*.node.js`); reescribir `ci/scripts/patch-opentui-core-runtime.py` + su test para el layout nuevo. Pin `env.sh` / `opentui_ref` a 0.5.14.
      **Cierre:** `test-patch-opentui-core-runtime.py` verde contra el artefacto 0.5.14 real.

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
