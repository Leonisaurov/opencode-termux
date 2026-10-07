# Progreso actual — 2026-09-10/11

La run `34553286047`, basada en `8a9608a`, terminó verde en los productores afectados:

- `detect`, Core, OpenTUI, Bun, OpenCode y Kilo: `success`.
- Rusty V8, Codex y publicación: `skipped` correctamente porque no cambiaron.

No se debe declarar el port funcional todavía.

### Correcciones publicadas

- `f71a75e`: corrigió tipos sentinel y la API de asignación usada por Zig 0.15 en Bun.
- `0ba9e55`: reemplazó concatenaciones comptime de `bunNodeDir()` por construcción runtime con `bufPrintZ` y `append`.
- `8a9608a`: reemplazó la llamada inexistente `joinAbsStringBufChecked` por `joinAbsStringBuf`, presente en el resolver vendorizado.

Los cambios ajenos del árbol no fueron modificados ni incluidos en esos commits.

### Artifacts descargados

Los artifacts de esa misma run están en `test-artifacts/34553286047/` e incluyen Bun, OpenTUI, OpenCode standalone, Kilo standalone y los paquetes ZIP, Debian y pacman/Termux de OpenCode.

La validación estructural pasó:

- Bun directo: `1.2.13`, código 0.
- ELF: AArch64, Android API 24, linker `/system/bin/linker64`.
- `validate-android-bundle.py opencode`: válido.
- `validate-android-bundle.py kilo`: válido.

### Bloqueo funcional pendiente

Al ejecutar los artifacts standalone directamente en Termux con `TMPDIR` y `BUN_TMPDIR` apuntando a `/data/data/com.termux/files/usr/tmp`:

- OpenCode termina con código 1: `EACCES: permission denied, mkdir '/tmp/opencode'`.
- Kilo termina con código 1: `EACCES: permission denied, mkdir '/tmp/kilo'`.
- `Bun.env.TMPDIR`, `Bun.env.BUN_TMPDIR` y una variable de prueba aparecen como `undefined`, incluso en el Bun Android directo.

La adaptación de entorno Bionic todavía no funciona en ejecución real. El problema queda aislado en la carga/acceso de variables (`env_loader.zig`, `bun.zig`/`getenvZ`, `std.c.environ` o inicialización del entorno), no en el module graph.

La investigación se detuvo antes de modificar más código. No lanzar otra run ni afirmar éxito hasta corregir la visibilidad de `TMPDIR`/`BUN_TMPDIR` y repetir los smoke tests sobre artifacts de una nueva run.

### Regresiones locales ya ejecutadas

Pasaron:

- `python3 ci/scripts/test-android-heap-tagging.py`
- `python3 ci/scripts/test-downstream-bundle-contracts.py`
- `python3 ci/scripts/test-module-graph-patch.py`
- `zig fmt --check bun/src/src/cli/run_command.zig`
- `git diff --check`

## Extracción de Codex — 2026-10-04

Codex y su dependencia Rusty V8 ya no son productos de este workspace. Se
extrajeron a su propio repositorio:

- `Leonisaurov/codex-termux` (público, rama `main`), creado como snapshot sin
  historia a partir de `opencode-termux@12d2c97`. El árbol `codex/src` se copió
  con `git archive | tar -x`, así que conserva el hash de árbol
  `ceabd0d75e1cd0851e4746d8c576ef6cd021810d` que consume el contrato de cache.
- Commits iniciales: `a30d7f6` (fuente vendeoreada) y `c19c50f` (pipeline
  codex-only). `4fb96c4` corrigió el `TMPDIR` del job `contracts`.
- La Release `rusty-v8-v150.4.0` se espejó allí con sus 3 assets validados por
  `sha256sum`, para que el primer build restaure V8 en vez de compilarlo (~110
  min) contra un `timeout-minutes: 150`.
- Publica su propio release `codex-v<versión>` con un manifest de esquema
  `codex-termux/v1` y su propio instalador; el esquema distinto impide que un
  manifest del stack se alimente al instalador de Codex o viceversa.

En este repositorio se retiró el cableado: `build-android.yml` (filtro de
rutas, inputs, outputs, bucle de `detect`, jobs `rusty-v8`/`codex`, `needs` de
`publish`), `build-codex.yml` y `build-rusty-v8-android.yml` borrados, y los
registros `changed-products.py`, `build-pipeline.sh`, `installer.py`,
`package-stack-release.py` y `ci/source-manifest.json` sin `codex`. Los tests
quedaron invertidos como guardas de ausencia: un re-añadido silencioso de Codex
falla CI. `install.sh --just codex` pasa a rechazar el componente por
`choices`, y un manifest publicado antes de la extracción que aún liste `codex`
se ignora (coberto por un test).

`ci/scripts/env.sh` **no** se tocó a propósito: es `--path` del contrato de
cache de todos los productos, así que hasta un comentario invalidaría las
caches de Bun/OpenTUI/OpenCode/Kilo. `CODEX_SOURCE_COMMIT` queda como variable
muerta.

### Ensayo local del publish del stack (2026-10-04)

Con un árbol sintético de artifacts ELF `aarch64` en `$TMPDIR`, sin tocar CI:

- `package-stack-release.py` emitió `manifest.json` con schema
  `opencode-termux.stack/v1` y exactamente `bun`, `opentui`, `opencode`, `kilo`.
- Un directorio de artifact huérfano `codex-android-aarch64-…` en el input se
  ignora sin fallo, que es lo que hacía el bloque "tolerar ausencia" retirado:
  una corrida antigua que aún suba Codex no rompe el publish.
- `installer.py --manifest … --all --yes` instaló los cuatro destinos validando
  checksum y arquitectura. Su rechazo cruzado del schema `codex-termux/v1` del
  otro repositorio también está probado (código 1).

La validación local no sustituye los smoke tests Android funcionales.

### Estado de la retirada (2026-10-04)

- `codex/src/codex-rs/target` (1.9 G) y `codex/src/.vscode` trasladados con `mv`
  al repositorio hermano; ningún fichero ignorado quedó bajo `codex/`.
- Commit `718689a` en `remove/codex-extract` (7625 ficheros de `codex/` + los 2
  workflows + el cableado de `ci/`), empujado a `origin`. Todavía sin PR: la
  revisión del stack en remoto (`publish` de 4 componentes) se lanza solo después
  de que `Leonisaurov/codex-termux` publique su propio release, para no dejar a
  `stack-v1.18.11` sin Codex antes de tiempo.
- Prueba contra la rama ya remota: `CODEX_INSTALL_REF=remove/codex-extract
  sh install.sh --just codex --dry-run` rechaza el componente con
  `invalid choice: 'codex'`.
- Compatibilidad inversa con el release publicado: `CODEX_INSTALL_REF=remove/codex-
  extract sh install.sh --all --dry-run` contra `stack-v1.18.11` (5 componentes)
  lista solo `bun, opentui, opencode, kilo` y reporta `Dry-run válido`, sin bajar
  los 350 MB de Codex.
- PR abierto: https://github.com/Leonisaurov/opencode-termux/pull/3 (base
  `rebase/codex-0.155.1`).
- Paridad de contrato con el repo nuevo: la última corrida vieja de
  `build-codex.yml` (`35683166526`) calculaba `ci-cache-v2-codex-eb4660af53126ae739d98
  b2f0786b867f666d919…` y el repo nuevo calcula exactamente ese digest, así que la
  extracción no cambió la identidad del contrato; lo que cambia es el namespace de
  cache, que en Actions es por repositorio.

## Estado del retiro y defecto heredado que se lleva Codex (2026-10-04)

- Estáticos del repo del stack, tras la retirada: `test-workflow-cache-contracts`,
  `test-changed-products`, `test-installer`, `test-build-state`, `test-cache-report`
  en OK y `bash -n` limpio sobre todos los `.sh` trackeados.
- Ensayo local del `publish` sin tocar releases: `package-stack-release.py` sobre un
  árbol sintético de ELF `aarch64` emite `opencode-termux.stack/v1` con exactamente
  `bun, opentui, opencode, kilo` y `--codex` ya es `unrecognized arguments`.
- `build-android.yml` solo se dispara por push en `main`, así que la verificación
  remota completa (detect sin `codex`/`rusty_v8` + jobs) llega con el merge de #3; un
  `workflow_dispatch` en la rama publicaría `stack-v1.18.11` desde un ref no `main`,
  y eso no se hace sin decisión del dueño del repo.
- Defecto que viajó con Codex, **no** con la extracción: `codex-code-mode-host`
  abortaba en Bionic con `TLS segment is underaligned`. El `rust-v0.155.1` re-vendor
  (aquí `3f42612`/`12d2c97`) barrió el stub `.tdata` alineado a 64 que el puerto tenía
  en `code-mode-host/src/main.rs`; el binario de `fee9a8d5` lo tenía (`p_align` 0x40) y
  por eso arrancaba. Se diagnosticó comparando ambos ELF publicados y se arregló en
  `Leonisaurov/codex-termux` (`3937e52`), con un gate de `PT_TLS` en el build.

### Cierre de la extracción (2026-10-04, después de la decisión del dueño)

- El PR #3 se fusionó en su base real, `rebase/codex-0.155.1` (`f3356fd`, árbol
  `f07284bca…`, idéntico al del commit de retirada). No fue a `main`: `main` está 35
  commits detrás de esta línea (OpenCode 1.18.30, Kilo, TinyCC, contratos de cache) y
  fusionar ahí habría sido una integración ajena a la extracción.
- Verificación remota del stack sin Codex: dispatch en `rebase/codex-0.155.1` con
  `release=1.18.11-codex-extract` (run `37220053216`) para no pisar `stack-v1.18.11`.
  `detect` OK con `for product in core opentui bun opencode kilo` y **sin** jobs
  `rusty-v8`/`codex`; el release de prueba se borra al leer los logs.
  **Resultado: run 135 `completed success` en `f3356fd`** — `detect`, `opentui`,
  `core`, `bun`, `opencode`, `kilo` y `publish` en success (`kilo/core` y `kilo/bun`
  `skipped` por ser reuso). El manifest publicado de prueba era
  `opencode-termux.stack/v1` con exactamente `bun, opentui, opencode, kilo` y sus
  cuatro assets; tras confirmar eso, el release y su tag `stack-v1.18.11-codex-extract`
  se borraron y `Latest` volvió a `stack-v1.18.11`. Con esto la Fase 6 del plan está
  cerrada: los dos repositorios tienen CI verde con el producto de cada uno.
- Instalador tolerante hacia atrás: el `installer.py` fusionado, contra el manifest
  publicado `stack-v1.18.11` (aún con componente `codex`), valida el esquema y
  selecciona exactamente `bun, opentui, opencode, kilo` — ignora `codex` sin error.
- Desviación deliberada del plan en `ci/scripts/env.sh`: el plan pedía dejar la
  variable muerta `CODEX_SOURCE_COMMIT` con un comentario apuntando al repo nuevo, y
  no se hizo. Ese archivo es `--path` del contrato de cache de los cuatro productos
  que quedan, así que una línea de comentario habría invalidado sus caches — el propio
  plan lo prohibía en la misma nota. Queda byte-exacta, y se comprobó: el diff contra
  `12d2c97` de `env.sh`, `cache-contract.py`, `build-state.py`,
  `validate-source-tree.py`, `validate-android-bundle.py` y
  `ci/actions/incremental-cache/action.yml` es vacío. La variable ahora no la lee
  nadie (única aparición es su propio `export`).
- Codex al otro lado del cable: `codex-v0.155.1-2` publicado desde
  `Leonisaurov/codex-termux` y verificado en dispositivo (instalador `rc=0`,
  `PT_TLS codex-code-mode-host = 0x40`, `host-smoke rc=0`, `lock-regression PASS`, y
  sin ya el aviso `try_lock() not supported` del janitor de `arg0`). Los releases
  defectuosos `codex-v0.155.1` y `codex-v0.155.1-1` fueron borrados; sus tags quedan
  para poder recrearlos.
- Este archivo estaba sucio con trabajo previo (2026-09-10/11 y la extracción): con
  esta entrada se commiteó junto con ella.

## Desacople final: ya no queda relación con Codex en el stack (2026-10-05)

La extracción dejó tres relaciones residuales y un cuarto archivo que se decía
"referencia" pero era código muerto. Cortados los cuatro:

- `ci/scripts/env.sh`: fuera `CODEX_SOURCE_COMMIT` (`be2951ea…`), que no leía nadie. La
  sesión anterior la dejó byte-exacta para no barrer caches; el coste medido es menor:
  las claves *exactas* de los productos sí caen (`build-core.yml`, `build-bun.yml:96`,
  `build-bun-target.yml`, `build-opentui.yml`, `build-opencode.yml`, `build-kilo.yml` la
  hashean), pero los intermedios se restauran
  por `restore-prefix`, que no incluye el digest del contrato
  (`ci/actions/incremental-cache/action.yml:86-87`), así que es revalidación con cache
  compatible, no una compilación fría de WebKit.
- `install.sh`, `ci/scripts/installer.py` y `ci/scripts/test-installer.py`: las variables
  pasan a `STACK_INSTALL_{REPO,REF,MANIFEST_BASE,TEST_MODE}`. Eran homónimas de las que
  usa el instalador de `Leonisaurov/codex-termux` con otra default, así que exportar la
  variable para un repositorio alteraba el otro.
- `ci/workflows/build-android.full.yml`: borrado. No era referencia válida: invocaba
  `build-codex.yml`, que ya no existe aquí, y `package-stack-release.py --codex`, un flag
  que ese script no acepta. Su último estado queda en el history (`718689a`).
- `test-changed-products.py` y dos tests del instalador nombraban Codex; la aserción que
  importa es genérica —una ruta o un componente fuera del grafo no selecciona nada— y quedó
  como `retired/src/crate/Cargo.lock` y `retired-product`.

La valla sigue en un único sitio: `test-workflow-cache-contracts.py:79-108` comprueba que
`build-codex.yml` y `build-rusty-v8-android.yml` no existen y que `codex` no aparece en
`build-android.yml`. Lo que aún menciona Codex en el repo son los punteros a dónde vive
(`AGENTS.md`, `CLAUDE.md`, `README.md`, `docs/`) y el histórico de este archivo; los
`codex.ts`/`codex.txt` de `kilo/src` y `opencode/src` son el provider de autenticación
upstream, no el port.

Estático antes de subir: `bash -n install.sh ci/scripts/*.sh` OK y los 14
`ci/scripts/test-*.py` OK.

### La corrida de `main` que lo confirma (run `37403852475`, merge `1a32dcd`)

Verde, 34 min de `detect` a `kilo`, con `publish` `skipped` (aquí publicar sigue siendo
dispatch manual). Duraciones leídas: detect 17 s, opentui 1 m 15 s, core 6 m 29 s,
bun 21 m 58 s, opencode 5 m 28 s, kilo 3 m 8 s. Artifacts de esa misma run:
`bun-android-aarch64-1.2.13` (36 990 886 B), `opentui-android-aarch64-658db4cb…` (3 792 622 B), `opencode-android-aarch64-1.18.30`
(59 872 712 B),
`kilo-android-aarch64-7.4.20` (56 008 845 B) y `opencode-termux-1.18.30` (150 523 763 B).
Ninguno es de Codex.

El coste previsto se cumplió sin convertirse en build fría: el digest del contrato cambió
(`…02830c65…` de ayer → `…30c55442…` en esta run), los productos restauraron intermedios
por prefijo y revalidaron — WebKit no se recompiló; bun tardó 22 min, no horas.

Una anotación que aparece y **no** es regresión del cambio: `Cache save failed` en
`bun / build-bun` por `Unable to reserve cache with key ci-cache-v2-core-tinycc-
intermediates-…-30c55442…`. El `core` job ya había guardado esa clave exacta 21 minutos
antes (`gh cache list`: una entrada con ese key creado a las `02:29:50`); GitHub no
reescribe una clave existente, así que el segundo escritor pierde. Los bytes están en
cache. Es solapamiento productor/productor del propio DAG (dos jobs guardan el mismo
intermedio de tinycc), no algo introducido aquí, y no afectó a las salidas finales.


## Upgrade de OpenCode: por qué v2 y qué se comprobó antes de mover el pin (2026-10-05)

La petición fue «actualizar OpenCode a su última versión v2». Antes de tocar un pin
verificamos qué es «v2» aguas arriba, porque el pin actual (`1.18.30`, commit
`3104c1428ec91f809e5ab86631300de41eb6952e`) está declarado deliberadamente por AGENTS.md.

- **v2 existe y es la línea principal**: rama `v2` activa (head `b78d10cd`), tags `v2.0.1`…`v2.0.24`
  (`v2.0.24` → commit `e7a34f09…`, 2026-10-06) y publicación real como npm **`@opencode/cli`**
  (`dist-tags.latest = 2.0.24`) con binarios por target. Lo que engaña es el rótulo: el
  «Latest» de GitHub y `opencode-ai` (1.x) apuntan a **`v1.18.34`** (2026-09-30), línea congelada.
- v2 **no es un bump sino un re-port**: `packages/opencode/` desaparece (ahora `packages/cli`,
  `server`, `core`, `tui`), el root `package.json` pide `bun@1.4.2` (aquí 1.2.13) y el catalog
  sube `@opentui/*` de `0.4.5` a `0.5.14`, cuyo artefacto publicado cambia de nombres de chunk y
  invalida el matching string-exacto de `ci/scripts/patch-opentui-core-runtime.py`. Además
  `script/build.ts` de upstream fija 12 targets linux/darwin/win32 **sin android/bionic**, así que
  el pipeline propio (`opencode/scripts/build-opencode.sh` con su swap de `libopentui.so`) se
  re-ubica, no se reutiliza.
- Se acordó con el usuario: **dos fases** (primero 1.18.30 → 1.18.34, que valida la maquinaria de
  re-vendor; después v2 en rama `feat/opencode-v2`, con `main` siguiendo publica 1.18.x), pines de
  Bun y OpenTUI autorizados para la fase 2, y criterio de aceptación = TUI arrancando de verdad en
  el teléfono, no «compila».

### H1.0 — Comprobación de acoplamiento contra `v1.18.34` (sin tocar el árbol)

Objetivo fijado por tag pelado: `aec0b9a6d8898f68f923aaf08b7306d931fd9d76` (2026-09-30T22:39:32Z);
tarball `codeload` con sha256 `c2c60efde22639b64c7bfa740da39b9c8079391a7540e2f67bf91b36e5797f17`.

Fidelidad de la fuente, medida y no supuesta: los 6641 blobs del árbol git de upstream contra lo
extraído en disco dan **0 diferencias de contenido y 0 de modo**; la única entrada sin
contrapartida en el filesystem es `packages/console/app/public/email`, un symlink de modo `120000`
que `os.walk` recorre como directorio. El tarball reproduce el commit bit a bit.

Línea base del vendor actual, medida con el mismo método: `opencode/src` es exactamente
`3104c142` con **una sola** diferencia de contenido — `packages/core/src/global.ts`, el fallback
Termux de `TMPDIR` del commit `0d2185b` — y 0 diferencias de modo. No hay marcas locales ocultas.

Detalle reproducible: lo trackeado son los blobs de upstream **menos 8** rutas, y las 8 existen en
disco pero están ignoradas porque el snapshot arrastra los `.gitignore` de upstream y esas reglas
se filtran al workspace: `.opencode/.gitignore` y `.opencode/themes/.gitignore` (regla `.gitignore`
anidada), `.vscode/*.example.json` (`.vscode`), dos `opencode-brand-assets.zip` (`*.zip`),
`packages/opencode/script/build-node.ts` (`script/build-*.ts`) y `packages/storybook/debug-storybook.log`
(`*.log`). `validate-source-tree.py` solo exige tracked + sin `.git` anidado + sin gitlinks, así que
el estado es correcto; conviene saber, sin embargo, que un patrón así puede **silenciar fuentes que
sí hacen falta** en cuanto upstream las ponga en esas rutas.

Puntos de acoplamiento del build, comprobados uno a uno contra `v1.18.34`:

| Punto | 1.18.30 vendorizado | 1.18.34 | Consecuencia |
|---|---|---|---|
| `packages/opencode/` (ruta que fija `build-opencode.sh:36`) | presente | presente | intacto |
| `packages/opencode/src/index.ts` (entrypoint, `build-opencode-android.ts:148`) | `13540a73` | `13540a73` | blob idéntico |
| `packages/opencode/src/cli/tui/worker.ts` (`workerPath`, `:123`) | `4cf6b2d4` | `4cf6b2d4` | blob idéntico |
| `packages/core/src/global.ts` (nuestro fix) | `a192a4b4` | `a192a4b4` | el fix re-aplica limpio |
| `migration/<YYYYMMDDHHMMSS>/migration.sql` (`:76-86`) | 1 dir, `20260511173437_session-metadata` | 1 dir, el mismo, `migration.sql` 42 B | glob intacto |
| catalog `@opentui/core`/`solid`/`keymap` | `0.4.5` | `0.4.5` | `patch-opentui-core-runtime.py` sigue aplicando |
| `packageManager` | `bun@1.3.14` | `bun@1.3.14` | no se toca el pin de Bun en esta fase |
| `patches/*.patch` upstream | 19 | 19 | viaja con `bun.lock` (878 275 B) |

El delta real entre ambas tags, en lo que nos afecta, es de dependencias de providers:
`@ai-sdk/gateway` `3.0.104→3.0.191`, `@ai-sdk/provider` `3.0.8→3.0.16`, `@ai-sdk/togetherai`
`2.0.41→2.0.68`, `gitlab-ai-provider` `6.15.0→6.18.0`, y `open` `10.1.2→11.0.4` que sube a
devDependencies de la raíz. Nada de esto toca el grafo de módulos ni el bundle standalone, que es
donde viven nuestras adaptaciones.

Veredicto H1.0: la Fase 1 es un re-vendor mecánico de riesgo bajo, y el árbol 1.18.34 es apto para
sustituir el actual sin re-derivar ninguna adaptación.

### H1.1–H1.2 — Re-vendor y pins de 1.18.34 (commit `0fd589a`)

El árbol `opencode/src` es ahora el commit upstream `aec0b9a6` medido, no inferido: contra el
`git/trees` de la tag da **0 diferencias de contenido y 0 de modo** sobre 6641 blobs, con una única
desviación intencional — `packages/core/src/global.ts` (blob `77372df0`, el fallback Termux de
`TMPDIR`), que viaja byte a byte idéntico al que ya teníamos. El delta de la fuente son 249 ficheros.
Lo trackeado vuelve a ser upstream menos las mismas 8 rutas que filtran los `.gitignore` de upstream
(`*.zip`, `*.log`, `.vscode`, `.gitignore` anidados y `script/build-*.ts`), así que la regla del vendor
anterior se reprodujo sin tocarla.

Pins movidos en el mismo commit: `ci/source-manifest.json`, `ci/scripts/env.sh` (versión y
`OPENCODE_SOURCE_COMMIT`), defaults de `build-opencode.yml`, `build-android.yml` y
`build-opencode-docker.yml`, el fallback de `build-opencode-android.ts`, `releases/manifest.example.json`
(tag `opencode-v1.18.34-android`) y `AGENTS.md`/`CLAUDE.md`/`README.md`. No queda ninguna aparición de
`1.18.30` ni de `3104c142` fuera del histórico de este archivo. Los 14 `ci/scripts/test-*.py` y
`validate-source-tree.py` pasan, y `bash -n ci/scripts/env.sh` también.

Se compró ademas que la resolución de OpenTUI no se mueve: `bun.lock` viejo y nuevo fijan
`@opentui/{core,solid,keymap}@0.4.5` con los mismos prefijos `sha512`, lo que es la condición real de
que `ci/scripts/patch-opentui-core-runtime.py` siga apuntando a los mismos bytes. El pin de Bun queda
en 1.2.13 porque 1.18.34 sigue declarando `packageManager: bun@1.3.14`, igual que 1.18.30.

### H2.0(a) — El riesgo de Bun en la fase v2 es el toolchain, no el formato

Medido contra `oven-sh/bun` (las tags llevan prefijo `bun-`):

- **`bun-v1.4.2` ya no tiene build Zig**: 0 ficheros `.zig`, `build.zig` eliminado y 1532 `.rs`, con
  `src/standalone_graph/` como nueva casa del grafo. El techo aún-Zig es **`bun-v1.3.14`** (1299 `.zig`,
  `build.zig` presente). Subir el Bun del port a 1.4.x no es mover un pin: es re-portear el runtime a
  cargo/NDK y re-validar ahí WebKit, TinyCC e ICU.
- **El formato del grafo sobrevive**: el trailer `\n---- Bun! ----\n` está tal cual en
  `src/standalone_graph/StandaloneModuleGraph.rs:863`. Es decir, la hipótesis de
  `ci/scripts/module-graph-patch.ts` (`TRAILER`, `OFFSETS_SIZE = 32`) no la rompe la riscritura; el
  problema es cómo se construye el binario, no cómo se lee.
- **Bun publica builds android oficiales desde `bun-v1.3.14`**: `bun-linux-aarch64-android.zip` aparece
  en 1.3.14, 1.4.0 y 1.4.2 (35 154 316 B en 1.4.2), y **no existe** en 1.2.13 ni en 1.3.2. Eso abre una
  tercera vía para la fase 2 que hoy no está decidida.
- Lo que fija la decisión es arquitectónico y está verificado en el source:
  `opencode/scripts/build-opencode-android.ts:290-311` ensambla el producto como
  `[bytes del bun Android] + [module graph] + [u64]`. Bun no es solo el compilador del bundle, es el
  **runtime embebido** del binario final. Un bun de glibc es inviable (el port ya carga ese problema con
  el binario glibc del auto-update oficial), pero un bun Bionic oficial sería, en principio, una base
  válida para ese ensamblado, y alinearía versiones: hoy conviven host 1.3.2 y runtime 1.2.13.

Queda pendiente clasificar el ELF de ese asset (tipo, `PT_INTERP`, `NEEDED`, API mínima) antes de
proponer cambiar el Bun del port de fuente a artefacto: eso contraviene el principio actual de compilar
desde fuente y necesita autorización explícita.

#### H2.0(a-i) Dónde cae exactamente la frontera y qué bloquea de verdad la ruta barata

Barrido de `build.zig`/`Cargo.toml` por tag en `oven-sh/bun` (`gh api contents?ref=bun-vX`), el
2026-10-06: `1.2.13`, `1.3.0`, `1.3.5`, `1.3.9`, `1.3.11`, `1.3.13` y `1.3.14` conservan `build.zig` y
no tienen `Cargo.toml`; `1.4.0`, `1.4.1` y `1.4.2` invierten el estado. `bun-v1.3.15` **no existe** como
tag, así que la cota es exacta: **1.3.14 último Zig, 1.4.0 primer Rust**. No hay escalón intermedio que
probar.

Lo que cambia el cálculo de coste es el carácter del requisito de Bun en v2. En `v2.0.24` el
`bun@1.4.2` está declarado en `packageManager` del `package.json` raíz y **no hay campo `engines`** ni
en la raíz ni en `packages/cli`; el propio 1.18.34 vendorizado declara `packageManager: bun@1.3.14`, o
sea justo el último Bun Zig. Por tanto ningún chequeo de manifiesto impide bundlear fuente v2 con un
Bun de era Zig: la exigencia 1.4.2 es cómo se construye upstream, no una barrera de ejecución. La
decisión entre re-portear Bun a cargo/NDK (R1), consumir su asset android oficial (R2) o quedarse en
Zig (R3) queda entonces condicionada por dos preguntas medibles en un runner, no por este barrido:

1. si el código v2 usa APIs de runtime que nuestro Bun embebido no tenga, y
2. si el runtime standalone rechaza un grafo escrito por un `bun build --compile` de versión distinta
   (hoy empaquetamos y ejecutamos el mismo 1.2.13, así que nunca se ha probado el desajuste).

Inventario nativo de `packages/cli@v2.0.24`, porque cada uno es un punto de fricción con Bionic
semejante al swap de `libopentui.so`: `@opencode-ai/pty` 0.2.0, `@parcel/watcher` 2.5.1,
`web-tree-sitter` 0.25.10, `tree-sitter-bash` 0.25.0, `tree-sitter-powershell` 0.25.10,
`@silvia-odwyer/photon-node` 0.3.4 y el catálogo OpenTUI en `0.5.14` (`core`/`solid`/`keymap`, con
`@effect/*` en `4.0.0-rc.112`). En 1.18.34 el catálogo sigue en `0.4.5`, lo que confirma que la
reescritura de `patch-opentui-core-runtime.py` es obligatoria en la fase 2 y no opcional.

Nota de higiene: `/usr/tmp/bun-142/v1_2_13.zig` y `v1_4_2.zig` quedaron en 0 bytes (ref inexistente en
esa ruta); la evidencia válida son los listados `files-1213.txt` (10 233 rutas) y `files-142.txt`
(19 743 rutas) generados del árbol de cada tag.

#### H2.0(a-ii) El bun Bionic oficial de 1.4.2 corre acá, y el formato 1.4.2 se entiende

Medido en el dispositivo el 2026-10-06 sobre `bun-linux-aarch64-android.zip` de la tag
`bun-v1.4.2` (35 154 316 B comprimido, `bun` de 86 800 440 B), descargado en `$PREFIX/tmp`.

Clasificación ELF (`readelf`):

- `ELF64`, `Type: DYN` (PIE), `Machine: AArch64`, `PT_INTERP = /system/bin/linker64`.
- `DT_NEEDED`: `libc.so`, `libm.so`, `libdl.so`; **cero** referencias `GLIBC_*` ⇒ Bionic verdadero,
  no el ELF glibc que ya nos rompe el auto-update.
- Nota `.note.android.ident` presente, con `r27c` en el campo de versión (NDK r27c; el port usa
  28.1.13356709). API mínima no se puede leer de esa nota.
- Ejecutado en el teléfono: `bun --version` → `1.4.2`, rc=0. Con 5 386 MB disponibles.

Formato standalone, medido compilando un TS de 61 B con ese mismo bun (`bun build --compile`):
`bun build --compile` **funciona en el build android** y el artefacto resultante **corre** (rc=0,
imprime su salida). Pero el layout cambió respecto de lo que asume nuestra maquinaria:

- `ci/scripts/module-graph-patch.ts:33-56` y `opencode/scripts/build-opencode-android.ts:196-229`
  suponen `[bun][grafo][u64]`, con el trailer `\n---- Bun! ----\n` terminando 8 bytes antes del EOF.
  En 1.4.2 el trailer está **128 549 bytes antes del EOF**: tras él van las **section headers del ELF**,
  reubicadas.
- Comparando el artefacto (88 536 832 B) contra el bun base byte a byte: **el único campo del header
  ELF que cambia es `e_shoff`** (86 798 264 → 88 534 656). `e_type`, `e_machine`, `e_entry`, `e_phoff`,
  `e_phnum` (8), `e_shnum` (34), `e_shentsize` (64) y `e_shstrndx` son idénticos, y en ambos archivos
  `e_shoff + e_shnum·e_shentsize == tamaño del archivo`. La inserción del grafo desplazó las section
  headers **1 736 392 bytes**.
- Dentro del bloque de offsets de 32 bytes, `byte_count` ya no satisface la invariante
  `byte_count == offsets_start` que el parser exige para no abortar: en 1.4.2 vale 163 para un grafo de
  un solo módulo (lista de módulos en 98..150, argv en 162 de longitud 0), y el texto fuente embebido
  aparece 163+32 bytes antes del trailer. Es decir, el campo sigue ahí y es interpretable, pero su
  semántica relativa al tamaño total del grafo es otra.

Consecuencia para los checkpoints del plan: **CP-A no dispara**. El cambio de formato es acotado y
conocido — localizar el grafo escaneando el trailer hacia atrás (funciona), y reubicar las section
headers parcheando `e_shoff` al ensamblar, que es exactamente lo que Bun 1.4.2 hace por dentro. No hay
que reescribir `module-graph-patch.ts` desde cero, hay que añadirle la cola ELF. Tampoco hace falta
re-portear Bun 1.4.x a cargo/NDK (R1) para tener un runtime Bionic de la versión que pide v2: la ruta
R2 (consumir el asset android oficial como runtime embebido) pasa de teórica a empírica en el nivel
"existe y arranca".

Límites de lo afirmado acá: solo se ejecutaron `--version` y un standalone trivial compilado y corrido
por el mismo bun 1.4.2. No está probado (a) que un grafo escrito por un bun host x86_64 de otra versión
sea aceptado por este runtime, (b) que el ensamblado `[bun android 1.4.2] + [grafo]` de nuestra pipeline
siga funcionando con la cola ELF, ni (c) que el binario aguante la carga real de OpenCode (JIT, fs,
pty, SQLite) bajo este kernel. Nada de eso se afirma con esta medición.

#### H2.0(a-iii) La frontera de formato está justo en 1.3.14/1.4.0, y eso elige la ruta

Mismo experimento con el Bun **1.3.14** que ya está instalado en el teléfono
(`$PREFIX/bin/bun`, el último tag con `build.zig`), compilando el mismo TS de una línea:

- `filesize = 91 609 755`, trailer en `91 609 731` ⇒ **cierra 8 bytes antes del EOF**, como
  supone nuestro parser.
- `byte_count = 139`, lista de módulos en `86..138`, argv en `138` de longitud 0. Aplicando la
  fórmula de `build-opencode-android.ts:220` (`hostBunSize = len - 8 - (byte_count + 32 + 16)`)
  da **91 609 560**, que es el tamaño real del binario `bun` de Termux: **delta 0, exacto**.
- El `u64` final vale `91 609 755`, igual al tamaño del archivo.

Comparado con el 1.4.2 medido arriba (trailer a 128 549 bytes del EOF, `e_shoff` reescrito, sin
`u64` final), la conclusión es que **la rotura de formato coincide exactamente con la frontera
Zig→Rust**: hasta `1.3.14` el ensamblado `[bun][grafo][u64]` sigue intacto; desde `1.4.0` hay que
reubicar la tabla de secciones ELF al ensamblar.

Otro dato que baja el riesgo y sale del propio repo (`.github/workflows/build-opencode.yml:51`,
`ci/scripts/setup-runner.sh:14`): el Bun host que escribe el grafo hoy es **1.3.2** mientras el
runtime embebido se compila desde **1.2.13**. Es decir, el artefacto que publicamos ya ejerce en
producción un desajuste de versiones entre productor del grafo y runtime, así que la hipótesis de
que Bun rechace un grafo de otra versión está refutada en la práctica para ese salto.

**Decisión de ruta que queda habilitada.** Para la fase 2 el eje deja de ser "Bun" y pasa a ser
OpenTUI:

- **R3 (Bun ≤1.3.14, era Zig) es la vía barata y pasa a ser la primera a intentar.** No toca
  `module-graph-patch.ts` ni el ensamblado de `build-opencode-android.ts`; conserva Zig 0.15.2,
  el overlay de WebKit, TinyCC e ICU, y el techo 1.3.14 es además el último punto donde conviven
  "aún Zig" y "asset android oficial ya existe". Lo único que habría que subir es nuestro port
  Android de Bun de 1.2.13 a 1.3.14 (re-vendor de `bun/src`, mismo toolchain).
- **R1 (re-portear Bun 1.4.x a cargo/NDK)** queda como último recurso: además del port del
  toolchain obliga a escribir la cola ELF en el ensamblado.
- **R2 (consumir el asset android oficial)** es técnicamente viable en el nivel "existe, es
  Bionic y arranca", pero sigue contraviniendo el principio de compilar desde fuente y necesita
  autorización explícita; con R3 abierta, no es la que hay que pedir primero.

Lo que R3 **no** resuelve, y es el riesgo que queda por medir: si el código de `v2.0.24` usa APIs
de runtime que un Bun 1.3.14 no implemente, y si `@opentui/{core,solid,keymap}@0.5.14` compila
contra Bionic API 24 (CP-B, que sigue siendo el candidato fatal). Ninguna de las dos se decide con
esta medición.

## Fase 1 cerrada: 1.18.34 publicado y verificado con la TUI real (2026-10-06)

**CI.** La corrida de push `37412517206` sobre el commit `0fd589a` terminó `success` en los seis
nodos (`detect`, `core`, `opentui`, `bun`, `opencode`, `kilo`), con `publish` saltado por ser
empuje. Confirmó la predicción del plan sobre las caches: `core` y `opentui` resolvieron por
**hit** de restore-key (`ci-cache-v2-core-icu-intermediates-…`, `ci-cache-v2-opentui-intermediates-…`),
es decir el pin nuevo no ensució los nodos que no lo consumen, mientras el nodo `opencode`
recompiló desde el árbol vendorizado y pasó `Build OpenCode standalone binary` + `Verify OpenCode
binary`. El `detect` además ejecutó `Validate static CI contracts` en verde.

**Publicación.** `build-android.yml` por `workflow_dispatch` (`37416769756`, `release=1.18.34`,
`bun=1.2.13`, `opentui_ref=658db4cb…`, `opencode=1.18.34`, `kilo=7.4.20`) quedó `success` con el
job `publish` corrido, y publicó el tag **`stack-v1.18.34`** (2026-10-06T05:11:29Z) con
`manifest.json` y los cuatro assets (`bun-1.2.13-…`, `opentui-658db4cb…-…`, `opencode-1.18.34-android-aarch64.tar.gz`,
`kilo-7.4.20-…`). El `publish` consumió artefactos de esa misma corrida, sin rempaquetado local.

**Dispositivo.** `install.sh 1.18.34 --just opencode --prefix ~/.local --yes --smoke-test` instaló
limpio (checksum y arquitectura validados) y `opencode --version` responde `1.18.34`. Antes de
probar hubo que corregir una regresión del entorno: `~/.config/fish/config.fish` tenía una segunda
línea `fish_add_path ~/.opencode/bin` que el instalador oficial vuelve a agregar, y con eso
`opencode` resolvía al ELF **glibc** del auto-update (`interpreter /lib/ld-linux-aarch64.so.1`),
que no arranca en Bionic. Sacada esa ruta de `fish_user_paths` y comentada la línea, `opencode`
vuelve a resolver a `~/.local/bin/opencode`.

**TUI real.** Manejada con `ci/scripts/tui-smoke.sh` y capturas tmux escalonadas sobre una sesión
de 120x32. El arnés se validó antes contra `top` en la misma pane (pintó), para no confundir una
espera corta con un fallo del artefacto. Resultados con 1.18.34:

- t=20 s pane vacía (el binario ya toma la pantalla alternativa y limpia); t=40 s **12 líneas
  renderizadas**: logo, caja de entrada con `Ask anything…`, línea `Build · Fledge Alpha Free
  OpenCode Zen`, ayuda `tab agents  ctrl+p commands` y estado `~/Develop/Patch/opencode-termux:main`
  con la versión. Es el mismo perfil de arranque en frío que dio 1.18.30 (≈30-40 s), así que el
  re-vendor no cambió el tiempo de arranque perceptiblemente.
- Entrada viva: escrito `hola desde la prueba` sin Enter, el texto aparece en la caja (`┃ hola desde
  la prueba`), y dos `Ctrl+C` devuelven el control y cierran la ventana sin quedar colgada.
- Ninguna captura mostró `panic`, `Unexpected error` ni trazas nativas.

Con esto H1.3 y H1.4 quedan cerrados: **1.18.34 es la versión publicada del stack** y la maquinaria
de re-vendor + pin coordinado + publicación + verificación en dispositivo está ejercitada, que era
el objetivo secundario de la fase 1. Lo medido no cubre providers, MCP ni sesiones reales: el
criterio acordado fue arranque de TUI con evidencia, y paridad funcional más allá del smoke no se
declara.

## H2.0(b-i) De dónde sale realmente el OpenTUI del port y cuánto hay que re-portear

Primer hecho, incómodo: el commit que versiona al OpenTUI de OpenCode — `658db4cbe0da…`, en
`ci/source-manifest.json` bajo `opentui-opencode` con `mode: vendored` — **no resuelve en ningún
repo plausible**: da 422 en `anomalyco/opentui` (el repo que declara `repository.url` del paquete),
en `sst/opentui` y en `opentui/opentui`, y 404 en `Leonisaurov/opentui`. Tampoco es el `gitHead` que
npm publica para `@opentui/core@0.4.5`, que es `0c8c4f7cff29…`. A diferencia de `opencode`
(`aec0b9a6…`, verificado blob a blob) y `bun`, cuyo commit sí es comprobable contra upstream, el
pin de OpenTUI hoy **no es verificable**: funciona como identificador opaco de cache, y la única
garantía de que el árbol es 0.4.5 es el `version` declarado en `packages/core/package.json`.

Medido el árbol vendorizado contra el árbol git upstream de 0.4.5 (`git/trees?recursive=1` de
`0c8c4f7c`, 1117 blobs) comparando SHA de blob por ruta:

- **0 ficheros ausentes** en lo local: no se tiró nada de upstream.
- **67 ficheros con contenido distinto**, agrupados: 32 bajo `packages/core/src`, 20 bajo
  `packages/web/src`, 4 en `packages/web/scripts`, 2 en `packages/core/scripts`, 2 en
  `packages/examples/src`, más `README.md`, `bun.lock`, `packages/core/.gitignore`,
  `packages/core/README.md`, `packages/core/package.json`, `packages/core/dev/print-env-vars.ts`
  y `packages/core/docs/development.md`.
- **732 rutas que solo existen en lo local**, concentradas en `packages/core/src/benchmark/…`, lo
  que indica que el árbol no es un checkout git limpio sino una mezcla con material del paquete
  publicado (y con `.zig-cache/` y `zig-pkg/` dentro del árbol de fuente, que no deberían estar
  versionados).

Lo que importa para la fase 2: el port Android vive en la capa **Zig**, no en un parche lateral. De
los 67 ficheros distintos, ~10 son exactamente el núcleo nativo — `packages/core/src/zig/`
con `build.zig`, `build.zig.zon`, `lib.zig`, `link.zig`, `renderer.zig`, `renderer-output.zig`,
`grapheme.zig`, `audio.zig`, `buffer.zig` — además de `packages/core/src/lib/env.ts` y su test.
Subir a `0.5.14` (el catálogo que fija `v2.0.24`, `gitHead` upstream `31a93fbe6699…`) no es cambiar
un `opentui_ref`: es **re-aplicar ese port sobre una base que se movió**, archivo por archivo, sin
historial común que cherry-pickear, porque hoy no existe un commit upstream verificable contra el
que diffear.

Consecuencia para **CP-B**: la pregunta "¿compila 0.5.14 como Bionic API 24?" está subordinada a
otra más cara — "¿sabemos reconstruir el port Zig sobre 0.5.14?". Antes de despachar un build de
prueba hay que resolver el linaje (fixear el pin a un commit upstream real y separar el port en
commits propios visibles), porque sin eso no hay forma de decir qué es de upstream y qué es nuestro,
y el intento de porteo se convierte en adivinanza. También encarece la ruta R3: si nos quedamos en
Bun era-Zig pero OpenTUI 0.5.14 exige re-portear Zig, el coste de v2 ya no está en el runtime sino
en esta capa.

## H2.0(b-ii) El linaje resuelto: la base real es `9eabce70` y el port son 8 ficheros Zig

Medición fechada 2026-10-05, comparando por SHA de blob el árbol vendorizado contra árboles
`git/trees?recursive=1` de upstream. Esta sección **corrige** dos afirmaciones de b-i.

La base upstream del árbol vendorizado es el commit **`9eabce704096837148d935554fcae9c19e6e21f4`**
(`feat(core): add audio input capture (#1297)`, 2026-07-29T12:09:07Z). El testeo fue por barrido de
la ventana entre el `gitHead` de 0.4.5 (`0c8c4f7c`, 2026-07-17) y el commit de image rendering
(`078bb448`, 2026-08-02), puntuando cada candidato contra los 1.142 blobs locales sin junk:

| candidato | fechas | upOnly | localOnly | SHA distinto |
|---|---|---|---|---|
| **`9eabce70`** | 07-29 | **0** | **0** | **8** |
| `da5507e1` | 07-30 | 0 | 0 | 10 |
| `5918d8e5` | 08-02 | 0 | 0 | 12 |
| `a1503fbe` | 08-02 | 3 | 0 | 22 |
| `078bb448` | 08-02 | 140 | 1 | 72 |

Cero rutas sobrantes y cero faltantes significa que el árbol **es** un checkout de ese commit, no
una mezcla con el paquete publicado como sugería b-i. Las 732 rutas "solo locales" se descomponen en
**533 de `zig-pkg/` + 174 de `.zig-cache/`** y **25 fuentes reales**, y las 25 están todas explicadas
por commits entre 07-17 y 07-29 (`b5dae243` FFI fast-path, `6064dcdc` skill/docs, `f26eb147`
render-runtime bench, `34e78b2f` stdin-log, `9eabce70` audio capture). Los 67 ficheros "distintos"
que reportaba b-i contra 0.4.5 eran **drift de upstream**, no adaptaciones nuestras. La aritmética
cuadra: 1.675 rutas versionadas (`git ls-files`) + 174 de caché local sin versionar (`.zig-cache`,
cubierto por `.gitignore`) = 1.849 en disco, de las que 1.142 son fuentes reales.

Detalle que invierte la sospecha de b-i sobre el `zig-pkg/` versionado: **no es basura, es parte del
port**. `build.zig.zon` es uno de los 8 ficheros modificados y su delta es exactamente convertir las
dependencias de red en dependencias locales:

```
- .uucode = { .url = "…/uucode/archive/84ceda85….tar.gz", .hash = … }
+ .uucode = { .path = "zig-pkg/uucode-0.1.0-ZZjBPtA_…" }
- .yoga   = { .url = "git+https://github.com/facebook/yoga#v3.2.1", .hash = … }
+ .yoga   = { .path = "zig-pkg/N-V-__8AAOYl0gAU…" }
```

Es decir: 20 MB de `zig-pkg/` están commitados para que el build Bionic sea **hermético/offline**, y
borrarlos rompería la propiedad que AGENTS.md exige (CI no debe bajar y mutar dependencias).

Corolario que achica el problema: el port Android es **exactamente 8 ficheros** bajo
`packages/core/src/zig/`, y nada más. `lib/env.ts` y su test, `platform/ffi.ts`, `platform/runtime.ts`,
`audio.zig` y `renderer.ts` coinciden **bit a bit** con upstream en esa base, así que b-i se equivocó
al contarlos como núcleo del port. El delta real, medido contra los blobs de `9eabce70`:

| fichero | líneas |
|---|---|
| `renderer.zig` | +145 −12 |
| `grapheme.zig` | +85 −34 |
| `build.zig` | +36 −37 |
| `link.zig` | +29 −10 |
| `buffer.zig` | +27 −6 |
| `lib.zig` | +6 −6 |
| `renderer-output.zig` | +6 −0 |
| `build.zig.zon` | +2 −4 |

Total **+236 −103 en 8 ficheros**, con 36 marcadores explícitos `Android/Bionic/Termux`. Es superficie
re-porteable a mano con revisión, no una reescritura de capas.

El coste de 0.5.14 medido contra esa base (`31a93fbe6699…`, 2026-09-30) cambia el cuadro en dos ejes
distintos:

1. **Deriva de contenido**: los mismos 8 ficheros acumulan **4.841 líneas cambiadas en 155 hunks**
   (`renderer.zig` 1.864, `lib.zig` 1.219, `buffer.zig` 1.016, `build.zig` 375, `renderer-output.zig`
   316, `grapheme.zig` 29, `link.zig` 6, `build.zig.zon` 16). Re-portear sobre eso es merge de tres
   bandas contra ficheros que se movieron ~5× más que nuestro parche.
2. **Deriva estructural**: desde `6dec16a7` (`native: move Zig sources into packages/native (#1391)`,
   2026-08-20) **`packages/core/src/zig/` deja de existir**: en 0.5.14 hay 0 ficheros `.zig` ahí y 128
   en `packages/native/src/` + `packages/native/build.zig{,.zon}`. Los 8 ficheros del port tienen
   contraparte directa en la ruta nueva (verificado, descargado), pero el wiring de build (target,
   linker, la capa que consume nuestro overlay WebKit/TinyCC) vive en un paquete que aún no existía.

Las fechas de release acotan la alternativa barata: `0.5.0` 08-03, `0.5.2` 08-12, `0.5.4` 08-18,
`0.5.6` 08-20, `0.5.7` 08-23. Un objetivo **≤ 0.5.5 conserva la vieja ruta** `packages/core/src/zig/`
y reduce la deriva de 4.841 líneas a fracción, pero `v2.0.24` fija en su catálogo
`@opentui/core: "0.5.14"` **exacto** (medido en `package.json` raíz, bloque `workspaces.catalog`; no
en `dependencies`), así que bajar la versión solo es defendible si se prueba que el código TUI de v2
no usa APIs introducidas después de 0.5.5. Eso no está medido: es el siguiente paso, y es de fuente,
no de build.

Qué queda afirmable y qué no: la base `9eabce70` está probada por coincidencia exacta de rutas y por
un delta de 8 ficheros que se puede leer entero. **No** se afirma que el port se aplique limpia sobre
0.5.14 ni sobre 0.5.5 — la primera choca contra el move y los 155 hunks, la segunda exige la verificación
de superficie de API. **No** se toca todavía el pin `658db4cb…`: moverlo a `9eabce70…` es metadata
correcta (el pin actual no lo valida nada: `validate-source-tree.py` no mira el campo `commit` y ningún
test lo referencia), pero `OPENTUI_REF` entra en las keys `ci-cache-v2-opentui-intermediates-*` del
productor y de los tres consumidores, en el nombre del artefacto y en el `build-info.txt` que se
atestigua, así que re-anclarlo cuesta un miss garantizado de OpenTUI (recompilación Zig completa) y
debe ir en su propio commit coordinado, igual que H1.2. El pin de Kilo (`5b3d5205…`) quedó **sin
resolver**: su árbol no coincide con ninguna de las bases medidas (182 upOnly / 264 SHA distintos
contra `9eabce70`), y no se lo toca porque Kilo comparte Bun pero no esta decisión.

## H2.0(b-iii) La puerta real de CP-B no es el diff de 8 ficheros: es Zig 0.16 y las libs C

Medición sobre los `gitHead` que publica npm por versión (no sobre tags anotados), cruzando
`minimum_zig_version` del manifiesto Zig y el contenido vendorizado. Dos hechos cambian el orden de
magnitud del problema:

**1) La frontera de toolchain está en 0.5.2, no en 0.5.14.**

| versión | fecha | gitHead | `minimum_zig_version` | dónde vive el Zig |
|---|---|---|---|---|
| 0.4.5 | 07-17 | `0c8c4f7c` | **0.15.2** | `packages/core/src/zig/` |
| **nuestra base** | 07-29 | `9eabce70` | **0.15.2** | `packages/core/src/zig/` |
| 0.5.0 | 08-03 | `1bc4d2a5` | 0.15.2 | `packages/core/src/zig/` |
| 0.5.1 | 08-04 | `ad9a818d` | 0.15.2 | `packages/core/src/zig/` |
| 0.5.2 | 08-12 | `14b3d135` | **0.16.0** | `packages/core/src/zig/` |
| 0.5.6 | 08-20 | `c1ae55b4` | 0.16.0 | `packages/native/src/` (move `6dec16a7`) |
| 0.5.14 | 09-30 | `31a93fbe` | 0.16.0 | `packages/native/src/` |

Nuestro pin es `ZIG_VERSION=0.15.2` (`ci/scripts/env.sh:27`) y upstream declara `.zig-version =
0.16.0` desde 0.5.2. Zig **rechaza** construir un paquete cuyo `minimum_zig_version` supera al
compilador activo, así que cualquier objetivo ≥ 0.5.2 obliga a subir Zig, y eso no es un cambio de
número: es revalidar contra 0.16 el cruce a Bionic que hoy sostiene el overlay WebKit, TinyCC y el
heap tagging que medimos en el port de Bun. Ese trabajo no estaba en el plan.

**2) El stack de libs C que hoy no compilamos entra ya en 0.5.0.** Contando blobs bajo `*/vendor/*`
(mismo método, árbol upstream puro): nuestra base tiene **1**, `0.5.0` tiene **97** y `0.5.1` **129**,
con el mismo reparto que `0.5.14` (**149**): `libwebp` 85, `lcms2` 32, `stb` 6, `wuffs` 3, `miniaudio`
1 más `README.md`/`update.sh`. En 0.5.14 se añade además `ghostty-vt` (`src/ghostty-vt.zig`,
`src/embedded-terminal/ghostty.zig`, dependencia `.lazy` en `packages/native/build.zig.zon`) y el par
de scripts `vendor/update-zig-deps.sh` / `vendor/update.sh`. Es decir: decodificación de imágenes
(webp + perfiles de color + SIMD) pasa por C que hay que cross-compilar contra
`aarch64-linux-android.24` con NDK, y **el coste aparece desde 0.5.0**, no solo en 0.5.14; ghostty es
lo único exclusivo del escalón caro.

Con esto, el árbol de decisiones de **CP-B** queda medido en tres escalones de coste creciente:

- **≤ 0.5.1** (Zig 0.15.2, vieja ruta): no exige subir Zig, pero introduce las cinco libs C y deja
  19 ficheros Zig del port con drift contra el resto del árbol (182 rutas upstream que aún no
  tenemos y 80 con SHA distinto; la única ruta local que upstream ya no tiene es
  `packages/examples/src/audio-capture-demo.test.ts`, borrada aguas arriba, no un añadido nuestro).
- **0.5.2–0.5.5** (Zig 0.16, vieja ruta): subir Zig **y** las libs C.
- **0.5.6+ / 0.5.14** (Zig 0.16, `packages/native`, ghostty-vt): las dos anteriores más la
  reubicación estructural y 4.841 líneas de drift en los 8 ficheros del port.

Ninguno de los tres es "barato", y el que el catálogo de `v2.0.24` exige es el tercero (`0.5.14`
exacto, medido en `workspaces.catalog`). Lo que **no** se afirma: que subir Zig 0.16 rompa el port
(destruye la cache y obliga a revalidar el overlay, pero no está probado que falle); que las libs C
compilen o no en Bionic API 24 (todavía no se intentó ninguna); ni que opencode v2 funcione con un
OpenTUI anterior a 0.5.14 — eso depende de la superficie de API que use su `packages/tui`, que tampoco
está medida. Por lo tanto la pregunta que decide si la fase 2 sigue viva dejó de ser "¿re-porteamos 8
ficheros?" y pasó a ser **"¿cuánto cuesta Zig 0.16 en Bionic?"**, y esa es la que hay responder antes
de gastar un dispatch de OpenTUI.

## H2.0(b-iv) Zig no es de OpenTUI: es una toolchain compartida por cuatro productos

Comprobado el consumo de `ZIG_VERSION` (`env.sh:27` = `0.15.2`, mismo valor repetido en
`setup-runner.sh:10`): lo declaran **`build-bun.yml:27`, `build-bun-target.yml:24`,
`build-core.yml:21`, `build-kilo.yml:34`, `build-opencode.yml:58` y `build-opentui.yml:54`**, y los
seis lo restauran de la **misma** key `ci-cache-v2-toolchain-<os>-<arch>-zig-<ZIG_VERSION>-api-…`.
No es un detalle de nombrado: Bun compila código Zig en Android, y `bun/scripts/build-bun.sh` lo
demuestra con su wiring explícito de caché (`$BUN_BUILD/cache/zig/{local,global}`, symlink
`.zig-cache -> …`, target `clone-zig` en `cmake/tools/SetupZig.cmake:88`). Dentro de ese archivo upstream
queda el rastro de la era del compilador: `# LLVM 18.1.7 does not compatible with what bitcode Zig
0.13 outputs`.

Consecuencia directa sobre la tabla de b-iii: **mover `ZIG_VERSION` a 0.16 para desbloquear OpenTUI
≥ 0.5.2 no es un cambio de un pin, es un bump de toolchain transversal**. El efecto sería recompilar
Bun 1.2.13 (código Zig era-0.13/0.14/0.15) contra un compilador dos menores más nuevo, con el
coste adicional de miss garantizado en la toolchain compartida y en las caches `*-opentui-intermediates`
y `*-bun-intermediates`, y poniendo a prueba a la vez el overlay WebKit, TinyCC y el heap-tagging que
`build-bun.yml:42` valida por separado. Ninguna de esas cuatro cosas se tocó nunca desde que el port
está verde.

Las dos formas defendibles de seguir, ambas medidas y ninguna barata:

1. **Toolchain por producto**: convertir `ZIG_VERSION` en un pin por consumidor (`ZIG_VERSION_BUN` vs
   `ZIG_VERSION_OPENTUI`), con keys `ci-cache-v2-toolchain-…-zig-<ver>` ya separadas de facto por el
   propio nombre del job. Es trabajo de workflows y de `test-workflow-cache-contracts.py` (paridad
   productor/consumidor), pero deja a Bun intacto en 0.15.2.
2. **Quedarse en OpenTUI ≤ 0.5.1** (era Zig 0.15.2, vieja ruta `packages/core/src/zig/`), que evita el
   bump transversal pero paga igualmente las libs C de imagen (97/129 ficheros vendorizados) y el
   drift de 19 ficheros Zig, y exige probar que el `packages/tui` de `v2.0.24` no usa APIs nacidas
   después de 0.5.1.

Ninguna está elegida. Lo que sí queda descartado por medición es el optimismo de b-i/b-ii: el coste de
la fase 2 **no** era "re-aplicar 8 ficheros", porque la capa nativa de OpenTUI cambió de ruta, de
toolchain mínima y de conjunto de dependencias C antes de llegar a 0.5.14.

## H2.0(b-v) CP-B resuelto en fuente: cuatro causas medidas, ninguna necesita `patchelf`

**Decisión de toolchain.** Se implementó la opción 1 de b-iv (toolchain por producto), no el bump
transversal: `build-opentui.yml:53` fija `ZIG_VERSION: "0.16.0"` (el `SUPPORTED_ZIG_VERSIONS` del
`build.zig` de 0.5.14 lo exige) y `build-opencode.yml` declara los dos valores (`ZIG_VERSION "0.16.0"`
para el consumidor de OpenTUI, `BUN_ZIG_VERSION "0.15.2"` para core/bun, que siguen intactos). El
peligro era silencioso: `test-workflow-cache-contracts.py` comparaba solo *nombres* de options, así que
una divergencia literal de valores no la detectaba nadie. Se añadieron afirmaciones explícitas de que
(a) OpenTUI y quien consume su lib pinnean el mismo Zig, (b) core/bun/build-bun comparten 0.15.2,
(c) Bun y OpenTUI pinnean Zig **distintos** por diseño, y (d) la key del job opentui se recalcula con
`ZIG_VERSION` y las de core/bun con `BUN_ZIG_VERSION`, para que queden byte-idénticas a sus productores.

**Causa 1 — `TranslateC` no propaga `--libc`.** En Zig 0.15.2 **y** 0.16.0 el paso `TranslateC` ignora
el archivo `--libc`: clang no recibe ningún directorio de encabezados Bionic y miniaudio.h/Yoga.h
fallan en `<pthread.h>`/`<math.h>`. El defecto no es de la versión, es del paso. Por eso 0.4.5 nunca lo
vio: su grafo no tenía **ningún** `b.addTranslateC`, todo `@cImport` corría dentro del `Compile`, que sí
obedece `--libc`. 0.5.14 introdujo los pasos sueltos de miniaudio y Yoga y ahí apareció la clase de
fallo. El fix pasa los dos directorios como `-isystem` (`addSystemIncludePath`), derivados del mismo
`android-libc.txt` que usa el link: si header search y link config se leen por separado, driftean.

**Causa 2 — se pierde el API level.** `<sys/cdefs.h>` aborta con `#error Unversioned target triples are
not supported!` cuando no hay `__ANDROID_MIN_SDK_VERSION__`, porque el driver clang se lo inyecta al
target Android y translate-c no. Se reponen los predefines del driver en el paso:
`__ANDROID_MIN_SDK_VERSION__=<api>`, `__ANDROID_API__=__ANDROID_MIN_SDK_VERSION__`,
`__ANDROID_API_FUTURE__=10000`, `__ANDROID__`, `__ANDROID_NDK__`. La forma `-D nombre=valor` partida en
argv es exactamente la que emite `defineCMacro`, y el nivel se pide con `-Dbionic-api-level` con
fallback al query del target.

**Causa 3 — anotación de nullability dentro del declarador de array.** AOSP escribe
`const struct timeval __times[_Nullable 2]` (`sys/time.h:47`), sintaxis que el frente de translate-c
rechaza como error duro aunque el camino `cc` la tolera (los system headers silenciaban el diagnóstico).
No es un capricho de Termux: la línea es idéntica en el header upstream, luego el NDK de CI se comporta
igual. Se neutralizan `_Nullable`/`_Nonnull` a vacío — no dicen nada a los bindings traducidos.

**Causa 4 — `-lm` no es resoluble.** Con archivo `--libc`, Zig no deja **ninguna** ruta de búsqueda de
bibliotecas del sistema (`unable to find dynamic system library 'm' … searched paths: none`), y Bionic ya
pliega `dl`, `pthread` y `m` dentro de `libc.so`. Los tres salen del link Android; la línea de comando
real que el probe generó para `aarch64-linux-android.24` audita el inventario final: termina en
`-lc++ -lc` y nada más. Esto reproduce la decisión que ya validó 0.4.5 (dl/pthread guardados) y añade
`m`, que es lo que 0.5.14 trajo dentro.

**Validación local sin gastar CI.** En el teléfono, con Zig 0.16.0 y los headers Bionic reales de
Termux: translate-c de miniaudio.h y Yoga.h sale limpio (stderr de 0 bytes) y el grafo completo
`zig build build-aarch64-linux-android.24` avanza hasta compilar **libc++, libc++abi y libunwind desde
fuente** para `-target aarch64-unknown-linux5.10.0-android24` con `-isystem $PREFIX/include` e
`-isystem $PREFIX/include/aarch64-linux-android`. El enlace local fue posible con un `--libc` cuyo
`crt_dir` apunta a enlaces simbólicos de **Bionic real del sistema** (`/system/lib64/libc.so`, `libm.so`,
`libdl.so`), que es lo que las stubs del NDK representan en CI; el resultado es `ELF64/AArch64`,
`Type: DYN`, `for Android 24` y `NEEDED libm.so, libc.so, libdl.so`, sin `libc++_shared.so` (la C++
runtime queda estática).

## H2.0(b-vi) "compila" no era la respuesta: el primer .so no cargaba

El artefacto anterior pasó translate-c, compiló todo, **enlazó y cumplía todos los checks que hace el
workflow** (ELF64, AArch64, `NEEDED: libc.so`). Y sin embargo era inservible: `dlopen` lo rechazó con
`cannot locate symbol "pthread_tryjoin_np"`. La causa es de ABI, no de compilación:
`src/clipboard/host.zig` (backend de portapapeles Wayland/X11, nuevo en la serie 0.5) declara
`extern "c" fn pthread_tryjoin_np` y lo llama en la rama `.linux` de `tryJoinThread`. Para Zig, Android
**es** `.linux` (solo difiere el `abi`), así que la rama se instancia, el enlace la deja como símbolo
indefinido y el fallo aparece en runtime. Medido sobre el Bionic real del aparato: no existe ni
`pthread_tryjoin_np` ni `pthread_timedjoin_np`; sí existen `pthread_join`, `pthread_detach`,
`pthread_kill`.

El fix emula la prueba de terminación con lo que Bionic garantiza: `pthread_kill(handle, 0)` devuelve
**ESRCH** justo cuando el hilo joinable ya terminó sin ser cosechado (medido en el teléfono con un
programa C: `rc=3` y `pthread_join` inmediato después), y entonces se cosecha con `thread.join()`.
Vive detrás de `builtin.abi == .android` en la misma rama `.linux`, de forma que glibc/freebsd/macos/windows
conservan su camino intacto.

**El contrato que esto obliga.** `readelf -d` no puede ver esta clase de defecto, así que el workflow
ahora sí: el paso `Verify dynamic symbols resolve against Bionic` lista los símbolos indefinidos del
`.so` y exige que **todos** resuelvan contra las stubs públicas del NDK
(`sysroot/usr/lib/aarch64-linux-android/*.so`), que son exactamente la superficie que el linker de
Android permite enlazar a una app. Con el artefacto roto el comando señalaba `pthread_tryjoin_np`; con
el fix señala **0 de 179**. `test-renderer-invariants.sh` fija además la adaptación y una afirmación
negativa que falla si alguien vuelve a dejar `tryjoin` en el camino Android.

**Veredicto CP-B: no se dispara.** OpenTUI `0.5.14` compila, enlaza y **carga como
`aarch64-linux-android.24` con Zig `0.16.0`**, verificado con `dlopen` real en el teléfono. Lo que CI
todavía tiene que confirmar, y solo eso: que el enlace con el NDK r28b y `-Doptimize=ReleaseSafe`
produce el mismo ELF verificable (mismo inventario de símbolos, mismas `NEEDED`), y que el paso nuevo
pasa sobre ese artefacto. Ninguna de las otras dos trampas de H2.0 se activó: CP-A quedó cerrado en
(a) y CP-C se mide en (c).

**Lo que NO se afirma:** que el `.so` de CI sea byte-idéntico al del probe (modo de optimización y
`crt_dir` distintos); que cargar la lib equivale a que el TUI de OpenCode v2 funcione con ella (eso es
H2.3/H2.6); que la emulación de tryjoin esté probada bajo carga real de portapapeles — el backend
Wayland/X11 no tiene display server en Termux, de modo que su `tryJoinThread` no se ejercita en el
camino que nos importa; y no se afirma nada sobre `models-snapshot` ni las migraciones de v2 (H2.0(d)).

## H2.0(b-vii) CI: el build y el enlace Bionic son verdes; la puerta de símbolos era el falso negativo

Corrida `37488100178` (feat/opencode-v2, HEAD `da69561`), NDK r28b + Zig `0.16.0`:

- Paso 17 `Build libopentui.so` **success** y paso 18 `Verify libopentui.so` **success** ⇒ el `.so`
  se compila y enlaza como `aarch64-linux-android.24` y es ELF `AArch64` con `NEEDED libc.so`.
  **CP-B queda confirmado en CI**: la fuente compila y enlaza como Bionic con el NDK real.
- Falló el paso 19 `Verify dynamic symbols resolve against Bionic`, y la subida del artefacto se
  saltó por eso. La lista "missing" eran símbolos que Bionic exporta sí o sí (`close`, `calloc`,
  `clock_gettime`, `accept4`, `__system_property_get`, `abort`…). Firmas de un **oracio vacío**, no
  de un `.so` roto.

**Causa.** El gate construía el set Bionic con `nm -D --defined-only` sobre las stubs del NDK. En una
stub linker los símbolos de la API pública están en `.dynsym` con `st_shndx = UND`; `--defined-only`
los descarta todos ⇒ `BIONIC` vacío ⇒ `comm -23` reporta cada símbolo indefinido como ausente. El
mismo `.so`, cargado en el teléfono, da dlopen OK (H2.0(b-vi)).

**Fix** (commit `131fa12`, solo workflow + test; no altera ninguna cache key porque el paso es
post-build). El oracio se construye con `readelf --dyn-syms -W` tomando todo `GLOBAL/WEAK` de tipo
`FUNC/OBJECT` **sin filtrar por sección**, que vale tanto para stub (Ndx=UND) como para lib real. Se
añade canary positivo (`grep -qx close "$BIONIC"`) y un `test -s` sobre ambos lados, para que un
oracio roto falle explícito y no con una "missing" engañosa. `test-renderer-invariants.sh` fija la
forma del oracio y prohíbe reintroducir `nm -D --defined-only`.

**Validación local del oracio corregido**, contra el `.so` del probe y libs Android reales:
`undef=179`, `bionic=4275`, `comm -23` **vacío**; YAML parsea (29 pasos) y las invariantes pasan.

**Lo que NO se afirma aquí:** que la corrida de confirmación (`37489824791`) esté verde todavía — eso
se lee al cerrar. Que el `.so` de CI sea byte-idéntico al del probe. Seguir en H2.3/H2.6 la
integración real de la TUI; este hito cierra CP-B (compila + enlaza + carga como Bionic), no el TUI v2.

## H2.0(b-viii) CI verde: CP-B confirmado a nivel de artefacto, tras corregir tres falsos negativos del gate

La sustancia de CP-B se confirmó en la **primera** corrida (`37488100178`): los pasos
`Build libopentui.so` y `Verify libopentui.so` fueron verdes con NDK r28b + Zig `0.16.0`, es decir
el `.so` compila y enlaza como `aarch64-linux-android.24` (ELF AArch64, `NEEDED libc.so`). El único
fallo era el paso nuevo de verificación de símbolos, que bloqueaba la subida del artefacto. Ese paso
dio **tres falsos negativos**, cada uno reproducido en local antes de tocar nada:

1. `nm -D --defined-only` sobre stubs del NDK devuelve un oracio vacío: los símbolos públicos de una
   stub linker viven con `Ndx=UND`, y `--defined-only` los descarta todos ⇒ marcaba como "missing"
   toda la libc. Corregido leyendo `.dynsym` con `readelf` y tomando todo `GLOBAL/WEAK` sin filtrar
   por sección (commit `131fa12`).
2. Faltaban **IFUNC** y **cobertura**: Bionic exporta `strcmp/strcpy/strchr/memchr` como IFUNC (no
   FUNC), y el glob de un solo nivel se dejaba fuera las stubs por API y `libm`/`libdl` (`socket`,
   `pthread_create`, `dlopen`, `atan2`). Corregido aceptando `FUNC/OBJECT/IFUNC` y recorriendo
   `find "$STUB_DIR" -name '*.so'` de todo el triple (commit `c936223`). Prueba local: sin el arreglo
   de string-func quedaban 6 IFUNC "missing".
3. `find` barre también entradas `.so` que en el sysroot son **scripts de enlazado ASCII** (no ELF);
   `readelf` falla sobre ellas y bajo `pipefail` abortaba el paso entero en ~20 ms sin diagnóstico.
   Corregido envolviendo el `readelf` del recorrido con `{ ... || true; }`, dejando estricta la
   lectura del `.so` real (commit `d8fdcad`). Reproducido en local: loop estricto ⇒ rc=1 sin salida;
   con `|| true` ⇒ rc=0 y oracio lleno.

**Corrida verde de cierre — `37491176567` (HEAD `d8fdcad`): `completed / success`.**

- Gate: `diagnostico: stubs=328 bionic=6624 undef=170` y `OK: 170 simbolos indefinidos resuelven`.
  `Build libopentui.so`, `Verify libopentui.so`, `Write build info`, `Save libopentui.so a cache` y
  `Upload libopentui.so artifact` todos success.
- Artefacto publicado por CI: `opentui-android-aarch64-31a93fbe66992298d6d0f27481fa781f43d0c1e2`,
  6 247 603 bytes, `expired=false`.

**Nota de inventario.** El `.so` de CI reporta 170 símbolos indefinidos frente a 179 del probe del
teléfono: la diferencia se debe a modo de optimización (`ReleaseSafe`) y `crt_dir` distintos, no a
una divergencia de ABI. El invariante que importa es que **todos** resuelvan contra la API pública de
Bionic, y así es (missing vacío), igual que el dlopen real en dispositivo.

**Veredicto CP-B: no se dispara, confirmado a nivel de artefacto.** OpenTUI `0.5.14` compila, enlaza,
**carga** y ahora CI lo valida y lo publica como `aarch64-linux-android.24` con Zig `0.16.0`, sin
`patchelf`. El gate queda como contrato anti-regresión: ya no se puede publicar un `.so` con un
símbolo fuera de Bionic.

**Lo que NO se afirma:** que el `.so` de CI sea byte-idéntico al del probe; que esto valide el TUI de
OpenCode v2 con la lib (eso es H2.3/H2.6); nada sobre `models-snapshot` ni migraciones (H2.0(d)); ni
que la emulación de `tryjoin` esté probada bajo carga real de portapapeles (no hay display server).

## H2.0(c) y H2.0(d) — corte de riesgo v2 restante (2026-10-07)

Corrida de evidencia: workflow de sondeo desechable `V2 Probe (H2.0c / CP-C)` sobre el upstream
público `anomalyco/opencode` en `e7a34f09…`, Bun `1.4.2`, runner efímero (`37567822938`: todos los
pasos success). Tres corridas previas (`37567333898`, `37567583229`, `37567822938`) afinaron el
*harness* (no el port): el workflow inyecta `bash -e`, así que `bun build … ; rc=$?` abortaba antes
de capturar; y los `find | head | tee` bajo `pipefail` daban SIGPIPE. Ambos ya corregidos.

**H2.0(c) / CP-C: NO se dispara, confirmado.**

- `bun install` del workspace v2 completo **resuelve** con Bun 1.4.2 (postinstall: `bun run --cwd
  packages/core fix-node-pty` — apuntar para la pty de Android en B4).
- **Test B** (`Bun.build({compile})` con plugin `@opentui/solid` + un proveedor del módulo virtual
  `virtual:opencode-app-assets`): emite un standalone ELF real de **135 308 768 bytes** con el trailer
  `\n---- Bun! ----\n` **presente** (`success=true`). Ese trailer es la entrada que
  `ci/scripts/module-graph-patch.ts` y `opencode/scripts/build-opencode-android.ts` necesitan para
  extraer el grafo de módulos y montarlo sobre el binario Bun de Android. Luego el pipeline de
  intercambio de grafo tiene input válido desde el árbol v2.
- **Test A** (bare, sin plugins): falla **solo** en `Could not resolve: "virtual:opencode-app-assets"`
  (`packages/cli/src/app-assets.ts:11`). Es un asunto de plugin de build, no incapacidad de Bun: el
  upstream lo provee con `packages/cli/script/app-assets.ts` (hornea assets web brotli); en B4 se
  registra el equivalente. `load()` además tiene fallback por runtime si `OPENCODE_LOCAL`.

**H2.0(d) — tabla de acoplamiento ruta-1.18 → ruta-v2 (existencia verificada en el árbol):**

| Punto | 1.18.x (nuestro pipeline) | v2.0.24 (verificado) | Acción |
|---|---|---|---|
| Paquete de entrada | `packages/opencode/src/index.ts` | `packages/cli/src/index.ts` (dev entry; `bin/opencode.cjs` se genera en build) | `build-opencode.sh:36` OPENCODE_PKG → `packages/cli` |
| Migraciones | `packages/opencode/migration/<ts>/migration.sql` (inline como define `OPENCODE_MIGRATIONS`) | `packages/core/src/database/migration/*.ts` + `migration.gen.ts` (imports estáticos; aplicadas vía drizzle-orm + Effect **en runtime**) | Eliminar el paso 2 de SQL-inline; las migraciones viajan en el grafo; riesgo → B6 (SQLite sobre Bionic) |
| models-snapshot | fetch `models.dev/api.json` → `src/provider/models-snapshot.js` en build | generado y versionado por `packages/core/script/update-models-snapshot.ts`; providers en `packages/ai/src/providers/*` | No hace falta fetch en build; verificar snapshot versionado presente tras re-vendor |
| worker TUI | `./src/cli/tui/worker.ts` + `@opentui/core/parser.worker.js` | `@opencode/tui` (`packages/tui/src`) + `packages/cli/src/server-process.ts`; parser worker de `@opentui/core` sigue presente | Reubicar `workerPath`/`entrypoints`; confirmar worker en B4 |
| Fix rutas Termux | `packages/core/src/global.ts` (tmp → `$PREFIX/tmp` cuando TMPDIR no definido) | `packages/util/src/global-roots.ts` (`os.tmpdir()`; XDG por `os.homedir()`) | **Portar el fallback de tmp** a `global-roots.ts` (no suponer, verificar en B1) |
| tsconfig | `./tsconfig.json` en `packages/opencode` | `packages/cli/tsconfig.json` | Apuntar entrypoint/tsconfig al paquete cli |

**Gate Fase A: A1 y A2 verdes** ⇒ se autoriza el re-port atómico (Fase B). Se elimina el workflow de
sondeo (su pregunta está respondida).

**Lo que NO se afirma:** que el standalone host (ELF x86-64/glibc) sea el binario Bionic — eso se
re-confirma con `build-bun.yml` y en el teléfono. Que el plugin virtual del Test B (default vacío)
sustituya al de assets real (eso es B4). Nada sobre migraciones ejecutándose en Bionic (B6); ni sobre
paridad de providers/MCP/pty (más allá del smoke).

### B1 · H2.1 — re-vendor v2.0.24 (2026-10-07)

Commit `6550ea3`. `opencode/src` sustituido íntegro por el snapshot `e7a34f09` (tarball codeload,
sin `.git` anidado; `node_modules` queda fuera por el `.gitignore` del propio árbol). 8067 ficheros
cambiados; el único binario grande versionado es `packages/core/src/models-dev/snapshot.txt` (5,3 MB)
— confirma H2.0(d): en v2 el catálogo de modelos ya viene **versionado**, no se hace `fetch` en build.

Adaptación propia porteadada (la única verificada en el árbol 1.18): el fallback de `TMPDIR` al
prefijo Termux pasa de `packages/core/src/global.ts` a su equivalente v2
`packages/util/src/global-roots.ts` (`os.tmpdir()` ⇒ `TMPDIR ?? $PREFIX/tmp ?? os.tmpdir()`).
`ci/source-manifest.json`: `opencode` → `e7a34f09`.

**Cierre:** `validate-source-tree.py` OK (7 árboles, sin `.git` anidado); `test-build-state.py`,
`test-workflow-cache-contracts.py`, `test-module-graph-patch.py`, `test-changed-products.py` en verde.

**Rojo por diseño (queda para B4):** `test-downstream-bundle-contracts.py` falla en
`assert OPENCODE_WORKER.is_file()` porque `build-opencode.sh`/`build-opencode-android.ts` siguen
punterando a `packages/opencode/src/cli/tui/worker.ts` (inexistente en v2). Es exactamente el trabajo
de B4 (entrada → `packages/cli`, worker → `server-process.ts`/`@opencode/tui`, migraciones en el
grafo, plugin de assets virtual); no se despacha `build-android.yml` hasta tener B4+B5 verdes.

### B2 · H2.2 — hallazgo estructural y sonda same-version (2026-10-07)

Comparación directa de las dos implementaciones del grafo standalone:

- 1.2.13 vendida (`bun/src/src/StandaloneModuleGraph.zig`, commit `d7b539a5`): entrada de tabla
  `{ name, contents, sourcemap, bytecode, encoding, loader, module_format }`; `Offsets` =
  `{ byte_count: usize, modules_ptr: StringPointer, entry_point_id: u32, compile_exec_argv_ptr,
  flags: packed u32 }`; trailer `"\n---- Bun! ----\n"`.
- 1.4.2 upstream (`src/standalone_graph/StandaloneModuleGraph.rs`, tag `bun-v1.4.2`): entrada
  reordenada con `module_info` y `bytecode_origin_path` nuevos; `Offsets` conserva los cinco
  campos al inicio pero `Flags` gana 7 bits nuevos (`HAS_SOURCE_HASHES`, `HAS_BUILTIN_BYTECODE`,
  `HAS_STARTUP_MODULE_COUNT`, …). ⇒ **un grafo emitido por 1.4.2 no es legible por un runtime
  1.2.13**: la entrada de tabla tiene otro layout y los flags desconocidos se descartan.**

Consecuencia operativa (estrategia elegida "Probe 1.2.13 primero"): la sonda buena es
**same-version** — compilar el árbol v2 con bun **host 1.2.13**, extraer el grafo (preserve-bytes,
como hace `build-opencode-android.ts`) y anexarlo a **nuestro bun Android 1.2.13** del artefacto
`bun-android-aarch64-1.2.13`. Workflow desechable `v2-probe-bun1213.yml` (no publica nada):

1. S2: `bun install` del workspace v2 con 1.2.13 (el `bun.lock` está escrito por 1.4.2; se prueba
   `--frozen-lockfile` y, si falla, install suave).
2. S3: grafo trivial aislado (control puro de wire-format, sin tocar el workspace).
3. S4: `Bun.build({compile})` de `packages/cli` con plugin de assets virtual + solid.
4. S5: anexión de ambos grafos al bun Android y validación ELF AArch64 + trailer.

**Interpretación del veredicto:** si `probe-trivial-android` arranca en el teléfono ⇒ wire-format
compatible; B2 queda reducido a "¿1.2.13 construye v2?" (S2/S4). Si el trivial falla ⇒ CP-D:
re-port Bun 1.4.2 (Zig→Rust) obligatorio. Sin `build-android.yml`, sin release.

## B2 · H2.2 — matriz de emisores: 1.3.2 construye v2 y su grafo CARGA en el runtime canary (2026-10-07)

Sonda `v2-probe-bun1213.yml` en modo matriz (emisores host 1.2.13/1.3.2/1.4.2 sobre
nuestro bun Android 1.2.13-canary, fuente `d7b539a5`, artefacto verde de main
`37412517206`). Corridas: `37571698205` (n4), `37572115762` (n5), `37572396191` (n6).

Hallazgos con evidencia:

1. **Grafo trivial 1.3.2 anexado corre en el teléfono**: `probe-trivial-1.3.2-android`
   imprimió `PROBE_BUN_1.3.2_OK` (rc correcto) en tmux. Confirma la aritmética del pie
   (`total_byte_count = filesize`, no longitud de grafo — el bug de la primera anexion
   hacia que el runtime ignorara el grafo y mostrara help).
2. **El árbol v2 se instala con los tres emisores** tras decatalog (`v2-decatalog.py`)
   + lock propio + `bin/bun` en PATH para el postinstall `fix-node-pty` (rc=127 sin eso).
3. **Compilación del CLI v2 (`packages/cli/src/index.ts`, `target:"bun"`, solid +
   virtual-assets)**: 1.2.13 NO (bundler antiguo), **1.3.2 SÍ**, **1.4.2 SÍ**.
4. **Layout del grafo por emisor** (volcado de los últimos 64 bytes en `50_assemble.txt`):
   1.3.2 coincide con el parser del producto; 1.2.13 pone bits de flags donde 1.3.2 pone
   `byte_count`; 1.4.2 (Rust) mueve el trailer fuera de `file_size-24..-8` — coherente con
   el hallazgo estructural: el runtime 1.2.13 no leerá grafos 1.4.2 sin más.
5. **El grafo v2 de 1.3.2 CARGA en el runtime canary**: `probe-v2-1.3.2-android` ejecutó
   módulos desde `/$bunfs/root/index.js` y murió en `ReferenceError: undici is not
   defined` (`__reExport(exports_Undici, undici)`) — exactamente el caso que
   `patchAndroidModuleGraph` (pipeline 1.18) resuelve. La sonda no lo estaba aplicando.

**Decisión**: la re-sonda (`8905f8a`, corrida n7) anexa con el código del producto
(`patchAndroidModuleGraph` + `validateAndroidStandalone`). Si `probe-v2-1.3.2-android`
levanta `--version`/TUI ⇒ **B2 colapsa a "emisor 1.3.2 + runtime actual" y el re-port
Bun 1.4.2 (CP-D) NO es necesario**. Si el undici de v2 no cae del parche ⇒ se amplía
`module-graph-patch.ts` (rama B2) o CP-D como fallback.

## B3 · H2.3 — CERRADO (2026-10-07, `f4a38f5`)

El guard no-string que el parche 0.4.5 inyectaba **ya lo publica upstream en 0.5.14**
(literal en `chunk-bun-sjw2d9bq.js`/`chunk-node-80p7e6t6.js`). `patch-opentui-core-runtime.py`
se reescribió como verificador: `verified` si el guard está, `patched` si reaparece el
layout 0.4.5, **rc=1 ante cualquier tercer layout** (fuerza revisión, no nave ciegas).
La llamada restante sin guard vive en `loadBundledFilePath` (ruta node) envuelta en
try/catch upstream ⇒ degrada al fallback, no es objetivo. Evidencia: 10/10 unitarios +
ejecución real contra el tarball 0.5.14 (`verified=2 patched=0 irrelevant=2`, rc=0) +
`test-workflow-cache-contracts.py` verde. Pines `opentui-opencode`/`opentui_ref` =
`31a93fbe` (0.5.14) ya correctos; sin cambios.

### B2 · corrida n7 (`37572826830`) — veredicto ejecutado en dispositivo (2026-10-07)

`patchAndroidModuleGraph`: trivial patchCount=0, v2 patchCount=1; `validateAndroidStandalone`
OK. En el teléfono, `probe-v2-1.3.2-android --version` ⇒ **`opencode v2.0.24` rc=0**;
ejecución interactiva (tmux) ⇒ el CLI levanta y lanza el server de fondo, fallando en
`Cannot find module '@opencode-ai/pty-linux-x64-musl/package.json' from '/$bunfs/root/index.js'`
— artefacto opcional de plataforma del host embebido por el bundler; corresponde al swap de
B4, no al wire-format. **B2 cerrado sin re-port Bun** (CP-D descartado): pin Android 1.2.13,
emisor 1.3.2.
