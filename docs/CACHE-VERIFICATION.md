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
  (`${{ github.workspace }}/.ci/zig-<version>`), en core, bun, opentui, kilo
  y opencode. `actions/cache` versiona por la cadena de `path`, así que
  paths distintos guardaban una copia por producto; ahora es una sola entrada.
  `test-workflow-cache-contracts.py` lo verifica.

- Se conservan los **intermedios de objetos compilados** (WebKit `webkit-build`,
  Bun `bun-build`), que son lo que evita las recompilaciones
  largas. Solo se descartan capas **redundantes o re-descargables**:
  `kilo-dependencies` (registries re-descargables) y el host Bun `~/.bun`
  (re-instalable). Los checkpoints de fallo conservan el árbol completo.

## Fallback durable en Release (Rusty V8)

Rusty V8 y Codex ya no se construyen aquí: viven en
[`Leonisaurov/codex-termux`](https://github.com/Leonisaurov/codex-termux), donde
el patrón sigue siendo válido — una compilación en frío de V8 tarda ~110 min y
su artifact pesa ~36 MB, así que el par staged (`.a.gz` + `src_binding.rs` +
`.sha256`) se publica además en la Release `rusty-v8-v<version>`, que **no**
está sujeta a la cuota de cache. La lección para este repositorio es la misma
para cualquier productor caro: si su rebuild en frío supera el tiempo que admite
la cuota, espeja su artifact en una Release.


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
