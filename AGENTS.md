# Repository Guidelines

## Project Structure & Module Organization

This repository ports OpenCode and related runtimes to Android/Termux.
`patches/` contains Bun, WebKit, Zig, and OpenTUI changes; `scripts/` contains
the build and packaging pipeline; `.github/workflows/` contains CI; and
`termux-packages/` contains package recipes. Upstream checkouts are kept in
`codex/`, `opencode-src/`, and `bun-source/`. Generated or cached checkouts
live under `build/` and are not sources of truth. The root artifacts
`codex-android`, `codex-code-mode-host`, and `codex-linux-sandbox` are Android
runtime outputs.

For Codex work, enter `codex/` first and read `codex/AGENTS.md`, its relevant
`docs/`, `codex-rs/README.md`, and `justfile`. For OpenCode, Kilo, or Bun work,
read the local `AGENTS.md`/`CONTEXT.md` in the corresponding checkout before
editing it.

## Build, Test, and Development Commands

From the repository root:

```sh
source scripts/env.sh
./scripts/apply-patches.sh
./scripts/build-opencode.sh
```

Use the component scripts (`build-icu.sh`, `build-webkit.sh`,
`build-bun.sh`, and `build-opentui.sh`) when rebuilding individual layers.
Codex development commands run from `codex/` or `codex/codex-rs/`; follow its
`justfile` and use `just test`, not direct `cargo test`.

## Coding Style & Naming Conventions

Shell scripts use Bash with `set -euo pipefail`; validate them with `bash -n`.
Use quoted paths, descriptive uppercase environment variables, and preserve
existing script conventions. Rust and TypeScript formatting/linting rules are
defined by their checkout-local instructions.

## Testing Guidelines

Run focused checks for changed components. Use
`.scripts/test-renderer-invariants.sh` for OpenTUI patch idempotence and
`just test -p <crate>` for changed Codex crates. Validate final binaries with
`file` and architecture/linker inspection; do not claim a build passed without
checking its artifact.

## Commit & Pull Request Guidelines

Use concise conventional commits such as `fix(android): ...`, `ci: ...`, or
`docs: ...`. Pull requests should explain affected layers, pins or patches,
validation performed, cache/build implications, and any Android/Termux
limitations. Include logs or artifact details for build and CI changes.

## Security & Configuration Tips

Use `TMPDIR` for Termux temporaries; do not introduce `/tmp` or
`/data/local/tmp` into Termux scripts. Preflight architecture, API/NDK,
toolchain, memory, storage, and caches before heavy builds. The proot sandbox
is filesystem isolation of convenience and does not isolate network access.
