# Verificación y presupuesto de caches

Guía para comprobar que el sistema de cache del pipeline es correcto y cabe en la
cuota de GitHub. Complementa a [`PORTING-AND-CI.md`](PORTING-AND-CI.md) y a la
skill `github-actions-cache`.

## Presupuesto

- Cuota de cache de GitHub Actions: **10 GiB por repositorio**. Al excederse,
  GitHub desaloja entradas por LRU; un build caliente se vuelve frío sin aviso.
- Consulta actual:

  ```sh
  python3 ci/scripts/cache-report.py
  ```

  Imprime total, las entradas más grandes y las **keys duplicadas** (misma key,
  varias versiones por path). `actions/cache` versiona por la cadena de `path`,
  así que dos jobs que cachean la misma key lógica bajo paths distintos (p. ej.
  un NDK por producto) dejan una copia grande por path.

- Regla aplicada: el NDK usa **un único path absoluto compartido**
  (`${{ github.workspace }}/.ci/android-ndk`) y el toolchain de Zig otro
  (`${{ github.workspace }}/.ci/zig-<version>`), en core, bun, opentui, kilo,
  codex y opencode. `actions/cache` versiona por la cadena de `path`, así que
  paths distintos guardaban una copia por producto; ahora es una sola entrada.
  `test-workflow-cache-contracts.py` lo verifica.

- Se conservan los **intermedios de objetos compilados** (WebKit `webkit-build`,
  Bun `bun-build`, Codex `sccache`), que son lo que evita las recompilaciones
  largas. Solo se descartan capas **redundantes o re-descargables**:
  `codex-cargo-target` (redundante con `sccache`), `codex-cargo-dependencies` y
  `kilo-dependencies` (registries re-descargables) y el host Bun `~/.bun`
  (re-instalable). Los checkpoints de fallo conservan el árbol completo.

## Fallback durable de Rusty V8

Rusty V8 es el caso más caro: una compilación en frío tarda ~110 min y su
artifact es pequeño (~36 MB). La cuota de cache (10 GiB) puede desalojarlo, así
que su par staged (`.a.gz` + `src_binding.rs` + `.sha256`) también se publica en
la Release **`rusty-v8-v<version>`**, que **no** está sujeta a la cuota.

- `build-rusty-v8-android.yml` intenta primero la cache exacta; si falta,
  **descarga la Release y valida `sha256sum`** antes de compilar desde fuente.
  Un fallback válido evita por completo el rebuild de V8.
- Tras un build desde fuente correcto, publica/actualiza la Release
  (best-effort) para mantenerla fresca.
- El job `rusty-v8` del orquestador tiene `contents: write` para poder publicar.


## Matriz de verificación

Cada escenario se puede provocar con un push (el detector elige el cierre
afectado) o con `workflow_dispatch` (construye todo el stack; más lento). Observa
con `gh run view RUN --json jobs` y los logs de los pasos `Cache ...` /
`Validate ... cache`.

| # | Escenario | Cómo provocarlo | Resultado esperado |
|---|---|---|---|
| 1 | Cold | toolchain o cache inexistente | El productor compila; guarda final + intermedios; no falla. |
| 2 | Warm idéntico | repetir el mismo commit/inputs | Hit en la cache exacta; el paso de build se salta. |
| 3 | Cambio pequeño de fuente | editar un archivo del producto | Solo ese producto (y sus consumidores) reconstruye; los demás, hit. |
| 4 | Cambio de dependencia | cambiar `bun/**` | Bun y sus consumidores reconstruyen; core/opentui según contrato. |
| 5 | Cambio de toolchain | cambiar `ANDROID_NDK_VERSION`/`ZIG_VERSION`/API | Invalidan los productores que la usan; final miss, build corre. |
| 6 | Cache corrupta | alterar un output y forzar `verify` | `verify` falla, el producto no se reutiliza y se reconstruye. |
| 7 | Evicción | borrar una cache | Miss → reconstruye; nunca debe fallar por falta de cache. |

Observaciones útiles:

```sh
gh run view RUN_ID --json jobs --jq '.jobs[] | "\(.status)/\(.conclusion) \(.name)"'
gh run view RUN_ID --log | rg -i 'Cache (hit|restored from key|not found)'
```

## Intermedios y checkpoints

- Los restores de intermedios usan un **prefijo de compatibilidad** (no la key
  exacta): siguen siendo útiles aunque la key final cambie, y por eso no se
  podan al cambiar un contrato.
- Los checkpoints de fallo son **por intento** (`run_id-run_attempt`) y no deben
  promoverse a artifact final.
- El artifact final (`-artifact`) es exacto: si la key cambia, la entrada vieja
  queda inalcanzable y puede podarse (ver `cache-report.py`).

## Trampa de mtimes (resumen)

Objetos restaurados pueden quedar más nuevos que el checkout y hacer que
Ninja/make no recompilen un fuente cambiado. Mitigaciones aplicadas:

- Bun y TinyCC refrescan mtimes de los fuentes antes de compilar.
- WebKit/ICU re-materializan el checkout/overlay o extraen el tarball tras el
  restore.
- Zig usa hashing de contenido (seguro entre runners).

## Poda

- Borra una cache: `gh api -X DELETE repos/OWNER/REPO/actions/caches/ID`.
- Borra por key: `gh actions-cache delete <key> --confirm` (si está disponible).
- Tras cambiar un esquema o un contrato, poda las entradas del esquema anterior.
- No podas los intermedios de un productor que aún se reutiliza; solo los
  artifacts finales inalcanzables y las keys duplicadas.

## Evidencia registrada

- Run completa del stack (Rusty V8 + Codex + `publish`) en success.
- Cache hits observados: `core/opentui/bun/opencode/kilo` terminan en minutos
  cuando no cambiaron; solo se reconstruye el producto afectado.
- Incidente: al terminar esa run la cuota subió a 13.61 GiB (intermedios de
  WebKit/Bun/Codex + finals) y el LRU **desalojó Rusty V8**, cuyo rebuild en
  frío tarda ~110 min. Se añadió el fallback durable en Release y se podaron
  capas redundantes/re-descargables; quedó en **9.68 GiB** (bajo las 10 GiB) con
  los objetos compilados intactos.
