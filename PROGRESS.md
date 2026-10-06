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
