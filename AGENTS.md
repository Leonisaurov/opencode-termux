# Repository Guidelines

## Structure and routing

This repository is the Android/Termux port workspace. Work only inside the
product directory that owns the change:

- `opencode/`: OpenCode source, build, tests, patches, and artifacts.
- `kilo/`: Kilo source, build, configuration, tests, and artifacts.
- `bun/`: Bun source and Android runtime toolchain.
- `opentui/`: OpenTUI checkouts for OpenCode and Kilo plus its port tests.
- `ci/`: shared build-state helpers, runner setup, Docker assets, and pipeline
  orchestration; `.github/workflows/` contains CI entry points.

Codex is not a product of this workspace: its Android/Termux port builds in
`Leonisaurov/codex-termux` with its own pipeline, manifest, and installer.

Dependencies are exposed through product-local `deps/` links. Do not create
duplicate source checkouts, root-level build outputs, or ad-hoc test trees.
Generated state belongs under the owning product's `build/` and final files
under its `artifacts/`. Recoverable obsolete material belongs in the external
quarantine documented by the workspace owner.

## Development and validation

Use the CI workflows for builds; this workspace is not a local build runner.
For static checks, run `bash -n` on changed shell files, validate workflow YAML
with the repository's CI tooling, and inspect state inputs with:

```sh
python3 ci/scripts/test-build-state.py
```

Use `opentui/test/test-renderer-invariants.sh` for OpenTUI source-tree and
renderer invariants.
Never claim a build passed without reviewing its CI artifact and logs.

## CI operations

Use the local `gh` CLI to dispatch, inspect, and monitor GitHub Actions; do not
use `gita` for CI operations. A push run validates builds but does not publish
a release. Publishing must use the normal `workflow_dispatch` inputs so the
`publish` job consumes artifacts from that same run.

Do not download artifacts for local repackaging when the workflow can publish
them itself. For upstream products consumed during CI, represent source
changes as versioned commits in `ci/source-manifest.json` and include those
commits in the product cache contract; do not rely on a dirty checkout.

## Version pins and patch compatibility

Las versiones de Bun y OpenCode están fijadas deliberadamente por los parches
Android existentes. Desde B7 hay **dos linajes**:

- **OpenCode**: cross-compila con el host Bun `1.4.2` oficial (emisor) contra el
  runtime Bionic parcheado de la release externa `v1.4.2-android.1` de
  `Leonisaurov/bun-android`. Ambos pins, incluido el sha256 y el marcador de
  revisión que demuestra el linaje, viven solo en `ci/external-sources.lock` y
  los lee `ci/scripts/env.sh`. Este lane ya no produce ni consume el Bun del
  workspace y su piso de Android es **API 28**, no 24.
- **`bun/` y Kilo**: siguen con el Bun Android era-Zig `1.2.13` (grafo emitido por
  el host `1.3.2` y trasplantado al EOF), que es lo único que
  `ci/scripts/module-graph-patch.ts` sabe reparar.

OpenCode sigue fijado en `2.0.24`.

- No subir, reemplazar ni "alinear" estas versiones por inferencia, aunque haya
  versiones más nuevas en otros workflows, manifiestos o upstream.
- Cualquier actualización requiere primero verificar que todos los parches
  aplican y funcionan con la nueva versión, actualizar los pins de forma
  coordinada y contar con autorización explícita.

OpenTUI Android debe compilarse como Bionic desde el código fuente portado.
`patchelf` no es una solución válida para OpenTUI: no sustituye el port de
fuente ni debe usarse para fabricar `RPATH`, interpreter o `DT_NEEDED` después
del enlace. Los cambios del checkout local deben convertirse en commits
rastreados por `ci/source-manifest.json` y publicarse en el remoto declarado
antes de compilar; no se debe confiar en modificaciones sucias del submódulo ni
en un fallback musl. El target fijado para los artefactos Android de OpenTUI es
`aarch64-linux-android.24`, salvo autorización explícita para cambiarlo; ese `.so`
es forward-compatible y lo consume también el runtime API 28 de OpenCode sin
recompilar.
- Los workflows, scripts, manifiestos y nombres de artifacts deben consumir los
  inputs/versiones fijados; no deben introducir defaults contradictorios.
- Las adaptaciones de fuentes deben vivir en los commits indicados por
  `ci/source-manifest.json` o en fuentes externas fijadas por
  `ci/external-sources.lock`. CI debe validar el commit y el árbol limpio; no
  debe clonar una rama y mutarla con parches de build.
- OpenTUI 0.5.14 no conoce la plataforma `android`: su guard de assets nativos
  lanza antes de cualquier `import`. La adaptación no parchea el checkout sino el
  grafo, como plugin `onLoad` de `opencode/scripts/build-opencode-android.ts` (el
  mismo seam de `opencodePtyPlugin`), y deja el slot nativo como import
  **incondicional** porque el DCE de `--target` recorta las ramas del texto
  original. El paquete que resuelve es `@opentui/core-linux-arm64` y sobre sus
  bytes se aplica el swap del `.so` Bionic.

## Conventions

Shell uses Bash, `set -euo pipefail`, quoted paths, and the canonical Termux
`$TMPDIR`; do not add `/tmp` or `/data/local/tmp` to Termux scripts. Preserve
checkout-local Rust, TypeScript, and Bun conventions. Keep commits concise,
for example `ci: split product build roots` or `fix(android): ...`. PRs must
describe affected products, dependency/cache implications, and validation.
