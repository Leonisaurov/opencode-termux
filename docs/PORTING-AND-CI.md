# Guía de diagnóstico, parches y caches (port Android/Termux)

Documento práctico para el mantenimiento del port. Recoge el modelo de fuentes,
cómo encontrar el commit correcto de una dependencia, cómo razonar sobre las
caches de CI y cómo diagnosticar fallos silenciosos en binarios Android. Está
escrito desde incidentes reales de este repositorio.

## 1. Verificar una TUI sin bloquear la sesión (tmux)

Una TUI ocupa la pantalla y no termina sola: lanzarla en primer plano bloquea al
agente. El helper `ci/scripts/tui-smoke.sh` la ejecuta en una sesión tmux
detached, espera a que pinte y devuelve el panel capturado por stdout.

```sh
# Render básico
bash ci/scripts/tui-smoke.sh --wait 20 -- ~/opencode-android

# Afirmar que la TUI renderizó y que no hay error visible
bash ci/scripts/tui-smoke.sh --wait 22 \
  --grep "Ask anything" \
  --reject "Unexpected error|loadedPath|tccdefs|render library" \
  -- ~/opencode-android
```

Opciones:

| Opción | Descripción |
| --- | --- |
| `--size WxH` | Tamaño del panel (default `120x32`). |
| `--wait S` | Segundos antes de capturar (default 8; OpenCode 1.18.x tarda ~30 s en pintar en un dispositivo lento). |
| `--send STRING` | Envía teclas tras la espera (repetible), p. ej. para interactuar o salir. |
| `--grep REGEX` | Falla si el panel **no** coincide. |
| `--reject REGEX` | Falla si el panel coincide (útil para detectar errores). |
| `--keep` | Deja la sesión viva para inspección manual. |

Para ver color/escapes o el scrollback:

```sh
tmux new-session -d -s tui -x 100 -y 30
tmux send-keys -t tui "$HOME/opencode-android" Enter
sleep 20
tmux capture-pane -t tui -p -e | cat -v     # con secuencias ANSI
tmux capture-pane -t tui -p -S -50          # incluye scrollback
tmux display-message -p -t tui '#{alternate_on} #{cursor_x},#{cursor_y}'
tmux kill-session -t tui
```

Nota: una captura vacía con `alternate_on=1` significa que la TUI está activa y
redibujando; suele hacer falta `-S` (scrollback) o más `--wait` para ver el
contenido estable.

## 2. Modelo de fuentes: vendorizado, no parches en CI

Antes este workspace clonaba fuentes y les aplicaba parches en build mediante
`bun/scripts/apply-patches.sh` y directorios `*/patches/`. Ese modelo se retiró
en `86b5916 ci: vendor Android source trees`: hoy las fuentes viven versionadas
en el monorepo y cada producto fija su revisión en:

- `ci/source-manifest.json` (productos vendorizados: bun, opencode, kilo, codex,
  opentui-opencode, opentui-kilo).
- `ci/external-sources.lock` (fuentes externas fijadas: WebKit, TinyCC).

Reglas de oro:

- Las adaptaciones Android pertenecen al **árbol fuente vendorizado** o a un
  overlay externo fijado. No se aplican parches ad-hoc en CI.
- No usar `patchelf`, cirugía ELF post-link, submódulos sucios ni fallback musl.
- Si hace falta cambiar una dependencia externa, se actualiza su commit en el
  lock y se valida que el CI parte de ese commit exacto y con árbol limpio.

Referencias históricas útiles:

- `git log --all --oneline -- '**/*.patch'` lista los parches que existieron.
- La rama `update-v1.18.6` es la era "todo con parches" (muchos `patches/bun/*`,
  `patches/opentui/*`, `patches/tinycc/*`). Comparar sus hunks contra el fuente
  vendorizado ayuda a detectar adaptaciones que no se trasladaron.

## 3. Encontrar el commit correcto de una dependencia

No basta con el lock: el **consumidor** dicta la ABI. Ejemplo real de este
repositorio:

- `bun/src/src/deps/tcc.zig` declara `tcc_relocate(s1, void*)` (dos argumentos).
  Eso significa que el Bun fijado espera un TinyCC con esa ABI.
- Bun upstream fija TinyCC en `cmake/targets/BuildTinyCC.cmake`:
  `oven-sh/tinycc @ 29985a3b59898861442fa3b43f663fc1af2591d7`.
- Ese commit es `0.9.28rc`, tiene `tcc_relocate` de dos argumentos y ya incluye
  `tccdefs.h`, `tccdbg.c` y `arm64-asm.c`.

Método:

1. Lee el contrato del consumidor (bindings Zig/TS, headers, scripts de build).
2. Busca el pin real en la fuente upstream del consumidor (p. ej.
   `cmake/targets/BuildTinyCC.cmake`), no solo en tu lock.
3. `curl`/`gh api` el commit candidato y verifica la firma exacta:
   `rg "tcc_relocate" libtcc.h tccrun.c`, `cat VERSION`, presencia de archivos.
4. Fija ese commit en `ci/external-sources.lock` y añade un test de contrato
   (ver `ci/scripts/test-tinycc-sources.py`).

## 4. Caches: reglas y trampas

Arquitectura (ver `ci/actions/incremental-cache/action.yml`):

- **Final** (`save-final`/`restore-final`): key exacta con solo un output
  validado (artefacto). Nunca se restaura a medias.
- **Intermediate** (`save-intermediate`/`restore-intermediate`): objetos y caches
  de compilador reutilizables; se restauran por prefijo estable.
- **Checkpoint** (`save-checkpoint`/`restore-checkpoint`): árbol resumible por
  intento (solo en fallo) para continuar un build interrumpido.

Cada producto calcula su key con `ci/scripts/cache-contract.py`, que hashea
`paths`, `values`, el runner/target/NDK y los ficheros del propio motor
(`ENGINE_PATHS`). Reglas:

1. **La key debe incluir el árbol fuente real**, no solo el commit upstream. Se
   usa `git ls-tree HEAD <path>` como `--value` (Bun/OpenCode/OpenTUI/Kilo). Si
   solo se incluye `source-manifest.json`, una edición del port no invalida la
   cache y se restaura un artefacto viejo.
2. **Productor y consumidor deben calcular exactamente los mismos argumentos.**
   Un `--path`/`--value` de diferencia cambia la key y el restore nunca acierta.
   Lo valida `ci/scripts/test-workflow-cache-contracts.py`.
3. `build-state.py verify` valida **solo los outputs** (digests de salida). El
   contrato de **entradas** es la key. No uses `verify` como prueba de que las
   fuentes no cambiaron.

### Trampa de mtimes (importante)

Los objetos restaurados desde una cache pueden quedar con mtime más nuevo que el
checkout reciente. Ninja y `make` usan mtimes, así que **no recompilan** un
fuente cambiado y enlazan el binario anterior. Síntoma visto: un binario con la
revisión git del commit anterior y fixes ausentes.

Mitigaciones aplicadas:

- **Bun** (`bun/scripts/build-bun.sh`) y **TinyCC**
  (`bun/scripts/build-tinycc.sh`) refrescan el mtime de los fuentes
  (`find ... -exec touch {} +`) antes de compilar. `ccache` mantiene barato lo
  que no cambió.
- **WebKit** e **ICU** re-materializan el checkout/overlay (o extraen el tarball)
  después de restaurar, por lo que los fuentes quedan más nuevos que los objetos
  restaurados y Ninja/make detectan los cambios.
- Zig usa hashing de contenido, no mtimes: sus caches son seguras entre runners.

Si un producto nuevo restaura objetos de compilador, replica el guard de mtimes.

### Higiene del cache

- Los intermediate/checkpoint guardan el árbol de build completo; mantén las
  rutas acotadas para no inflar el cuota (el repo ya rozó el límite de 10 GB y se
  desalojaron caches de Rusty V8).
- Prefiere `--path` de scripts + lockfiles + `git ls-tree` de la fuente a hashear
  árboles gigantes cuando el commit ya identifica el contenido.
- Los tests estáticos (`ci/scripts/test-*.py`) corren en el job `detect` para
  atajar regresiones de contrato antes de gastar runners.

## 5. Diagnóstico de fallos silenciosos (exit 255)

Una TUI/CLI que termina sin mensaje suele ser un `exit(-1)` explícito, no una
señal. Procedimiento:

```sh
# 1) Captura la salida real (la TUI puede limpiar la pantalla)
bash ci/scripts/tui-smoke.sh --wait 20 --login - 2> /tmp/tui.err
# o redirige solo stderr dentro de un pty.

# 2) Traza la última syscall y la pila con strace
strace -f -k -e trace=exit_group -o /tmp/str.out ./binario
tail -40 /tmp/str.out        # busca exit_group(-1) y el stack

# 3) Backtrace con gdb: quién llama a exit y con qué código
gdb -q -batch \
  -ex 'break exit' -ex 'run' \
  -ex 'printf "status=%d\n", (int)$x0' \
  -ex 'bt 12' \
  --args ./binario
```

Caso real: `exit_group(-1)` venía de
`tccrun.c: exit(tcc_error_noabort("'tcc_relocate()' twice is no longer supported"))`.
La versión nueva de TinyCC cambió `tcc_relocate` a un argumento; Bun lo llamaba
dos veces (consulta de tamaño + relocación). Restaurar el commit fijado por Bun
resolvió el aborto.

## 6. Casos resueltos (checklist)

- **`process.env` vacío en Android**: `runEnvLoader` retornaba antes de
  `loadProcess()` si no podía leer el directorio raíz
  (`CouldntReadCurrentDirectory`). Ahora carga el entorno de proceso primero y
  `loadProcess` lee `/proc/self/environ` en Linux.
- **`os.tmpdir()` usa `/tmp` en Termux**: `@opencode-ai/core/global.ts` y
  `bun/src/src/js/node/os.ts` resuelven `TMPDIR` → `PREFIX/tmp` → `os.tmpdir()`.
- **`undefined is not an object (evaluating 'loadedPath.startsWith')`**: el
  `@opentui/core@0.4.5` publicado no trae el guard del fuente OpenTUI
  vendorizado. `opencode/scripts/build-opencode.sh` aplica
  `ci/scripts/patch-opentui-core-runtime.py` antes del bundling.
- **`include file 'tccdefs.h' not found`**: libtcc debe compilar sus predefinidos
  embebidos. `build-tinycc.sh` define `CONFIG_TCC_PREDEFS 1` y genera
  `tccdefs_.h` con `c2str`.
- **Rusty V8/Codex fuera del flujo** (temporal): se quitaron de
  `build-android.yml` y se guardó el DAG completo en
  `ci/workflows/build-android.full.yml`. `publish` y el instalador toleran la
  ausencia de `codex`.

## 7. Comandos de verificación útiles

```sh
# Contratos y tests estáticos (los mismos que corre CI en `detect`)
python3 ci/scripts/test-workflow-cache-contracts.py
python3 ci/scripts/test-tinycc-sources.py
python3 ci/scripts/test-patch-opentui-core-runtime.py
python3 ci/scripts/test-downstream-bundle-contracts.py

# Calcular una key de cache como lo hace un workflow
python3 ci/scripts/cache-contract.py key --root . --product bun \
  --path bun/scripts/build-bun.sh --value BUN_VERSION=1.2.13

# Estado de los nodos de build
python3 ci/scripts/build-state.py status --root . --state-dir bun/build/state

# Validar YAML/expresiones de GitHub Actions
actionlint .github/workflows/*.yml
```
