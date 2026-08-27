# Repository Guidelines

## Structure and routing

This repository is the Android/Termux port workspace. Work only inside the
product directory that owns the change:

- `opencode/`: OpenCode source, build, tests, patches, and artifacts.
- `kilo/`: Kilo source, build, configuration, tests, and artifacts.
- `codex/`: Codex source, build, tests, scripts, and artifacts. For Codex
  work, enter this directory first and read its local `AGENTS.md`, `docs/`,
  `codex-rs/README.md`, and `justfile`.
- `bun/`: Bun source and Android runtime toolchain.
- `opentui/`: OpenTUI checkouts for OpenCode and Kilo plus its port tests.
- `ci/`: shared build-state helpers, runner setup, Docker assets, and pipeline
  orchestration; `.github/workflows/` contains CI entry points.

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

Use `opentui/test/test-renderer-invariants.sh` for OpenTUI patch idempotence.
Never claim a build passed without reviewing its CI artifact and logs.

## Version pins and patch compatibility

Las versiones de Bun y OpenCode están fijadas deliberadamente por los parches
Android existentes. Actualmente son Bun `1.2.13` y OpenCode `1.3.13`.

- No subir, reemplazar ni "alinear" estas versiones por inferencia, aunque haya
  versiones más nuevas en otros workflows, manifiestos o upstream.
- Cualquier actualización requiere primero verificar que todos los parches
  aplican y funcionan con la nueva versión, actualizar los pins de forma
  coordinada y contar con autorización explícita.

OpenTUI Android debe compilarse como Bionic desde el código fuente portado.
`patchelf` no es una solución válida para OpenTUI: no sustituye el port de
fuente ni debe usarse para fabricar `RPATH`, interpreter o `DT_NEEDED` después
del enlace. Los cambios del checkout local deben convertirse en un parche
rastreado bajo `opentui/patches/opentui/` y aplicarse en CI antes de compilar;
no se debe confiar en modificaciones sucias del submódulo ni en un fallback
musl. El target fijado para los artefactos Android de OpenTUI es
`aarch64-linux-android.24`, salvo autorización explícita para cambiarlo.
- Los workflows, scripts, manifiestos y nombres de artifacts deben consumir los
  inputs/versiones fijados; no deben introducir defaults contradictorios.

## Conventions

Shell uses Bash, `set -euo pipefail`, quoted paths, and the canonical Termux
`$TMPDIR`; do not add `/tmp` or `/data/local/tmp` to Termux scripts. Preserve
checkout-local Rust, TypeScript, and Bun conventions. Keep commits concise,
for example `ci: split product build roots` or `fix(android): ...`. PRs must
describe affected products, dependency/cache implications, and validation.
