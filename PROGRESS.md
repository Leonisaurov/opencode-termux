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

