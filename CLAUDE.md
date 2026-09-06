# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Repository purpose

This is the maintained Android/Termux port workspace for OpenCode, Kilo, and Codex. It builds native `aarch64` artifacts rather than wrapping host installations. OpenCode and Kilo bundle the Android Bun runtime and ARM64 OpenTUI runtime; Codex produces its Android CLI, code-mode host, and sandbox helper.

Read `AGENTS.md` before making changes. `WORKSPACE.md` is the quick navigation map. Work inside the product directory that owns a change and keep generated state under that product's `build/` and final artifacts under its `artifacts/`.

## Architecture

The producer graph is:

```text
ICU -> WebKit/JSC -> TinyCC -> Bun -> OpenTUI -> OpenCode -> packages
Rusty V8 -> Codex
```

- `bun/` contains the vendored Bun source, Android build scripts, WebKit/JSC overlay, TinyCC source, and Android CMake files.
- `opentui/` contains the versioned OpenTUI source trees for OpenCode and Kilo and the Android renderer build.
- `opencode/` and `kilo/` contain their source checkouts, build scripts, tests, dependencies, and artifacts.
- `codex/` contains the Codex checkout and Android build integration. For Codex-specific work, enter `codex/` and read its local `AGENTS.md`, `docs/`, `codex-rs/README.md`, and `justfile`.
- `ci/scripts/` contains the content-addressed build-state engine, cache contracts, change classification, runner setup, packaging helpers, and regression tests.
- `.github/workflows/` contains the dependency-aware producer workflows and the release orchestration workflow.

The build scripts use `ci/scripts/env.sh` to define canonical source, build, cache, state, and artifact locations. Do not create duplicate checkouts or root-level build directories. Do not work from historical paths such as `scripts/`, `patches/`, `opencode-src/`, `bun-source/`, or a shared root `build/`.

## Fixed compatibility inputs

These values are deliberate port compatibility constraints:

- Target: `aarch64-linux-android`, Android API 24, ABI `arm64-v8a`
- Android NDK: `28.1.13356709` (r28b)
- Bun target: `1.2.13`
- Bun host for standalone bundling: `1.3.2`
- WebKit/JSC: commit `017930ebf915121f8f593bef61cbbca82d78132d`
- ICU: `75.1`
- Zig: `0.15.2`
- OpenCode: `1.3.13`

Do not update or align these versions by inference. A version update requires coordinated verification of the source ports and explicit authorization.

Bun, OpenTUI, OpenCode, Kilo, and Codex source revisions are recorded in `ci/source-manifest.json`; external sources are pinned in `ci/external-sources.lock`. Source checkouts must be clean and must not contain nested Git metadata when a script validates them. WebKit is the exception: CI fetches its pinned external commit into `bun/build/webkit-src` and applies the explicit versioned overlay from `bun/webkit`.

## Build commands

Routine builds run in GitHub Actions because WebKit and Bun are long native builds. The complete local orchestration command exists for controlled environments, but it can take hours and requires the Android toolchain:

```sh
ci/scripts/build-pipeline.sh
BUILD_KILO=1 BUILD_CODEX=1 ci/scripts/build-pipeline.sh
```

The pipeline invokes these product scripts in dependency order:

```sh
bun/scripts/build-icu.sh
bun/scripts/build-webkit.sh
bun/scripts/build-tinycc.sh
bun/scripts/build-bun.sh
opentui/scripts/build-opentui.sh
opencode/scripts/build-opencode.sh
opencode/scripts/make-packages.sh
kilo/scripts/build.sh                 # when BUILD_KILO=1
codex/scripts/build-codex-android.sh  # when BUILD_CODEX=1
```

Run an individual script only when its prerequisites and environment are already available. `bun/src/Makefile` is an old upstream interface; use the repository-owned scripts above for the Android port rather than treating that Makefile as the canonical build.

The incremental state engine hashes declared inputs, values, dependencies, and validated outputs. Inspect state with:

```sh
python3 ci/scripts/build-state.py status --root . --state-dir bun/build/state
python3 ci/scripts/build-state.py verify --root . --state-dir bun/build/state --node webkit
```

A state hit reuses a validated node. A changed leaf invalidates its descendants through dependency manifests. Failed or interrupted manifests are not valid final outputs, although compiler/build-system directories may be retained for resumable retries.

## Tests and static validation

Run the complete repository CI regression suite with:

```sh
for test_file in ci/scripts/test-*.py; do
  python3 "$test_file"
done
```

Run an individual regression test directly, for example:

```sh
python3 ci/scripts/test-build-state.py
python3 ci/scripts/test-webkit-overlay.py
python3 ci/scripts/test-webkit-compat-header.py
python3 ci/scripts/test-webkit-libpas-platform.py
python3 ci/scripts/test-changed-products.py
python3 ci/scripts/test-ci-summary.py
python3 ci/scripts/test-installer.py
```

Useful checks for changed files are:

```sh
bash -n bun/scripts/build-webkit.sh
python3 -m compileall -q ci/scripts
git diff --check
opentui/test/test-renderer-invariants.sh
```

There is no separate repository-wide lint command documented for the port. Use the product's own conventions and test commands when working inside a vendored upstream checkout. Do not claim a native build passed without checking the CI job result, logs, and validated artifact or state manifest.

## CI workflows

- `build-core.yml` builds ICU, WebKit/JSC, and TinyCC and exposes their validated artifacts to downstream workflows.
- `build-bun.yml` consumes the Core outputs and builds Android Bun.
- `build-opentui.yml` builds `libopentui.so` with Zig for `aarch64-linux-android.24` and validates its Android `libc.so` dependency.
- `build-opencode.yml` builds the standalone OpenCode bundle.
- `build-kilo.yml` builds Kilo from the same Bun dependency graph.
- `build-rusty-v8-android.yml` produces the Rusty V8 dependency used by Codex.
- `build-codex.yml` builds Codex after the verified Rusty V8 artifact is available.
- `build-android.yml` detects affected producers, runs the required dependency closure, and publishes only for `workflow_dispatch`. Push runs validate and upload artifacts but do not publish releases.

Dispatch or inspect workflows with the local GitHub CLI:

```sh
gh workflow run build-core.yml --repo Leonisaurov/opencode-termux --ref main
gh run view RUN_ID --repo Leonisaurov/opencode-termux
gh run view RUN_ID --repo Leonisaurov/opencode-termux --log-failed
```

Use the repository's `monitor-gh-run` helper for long-running observations when available. Do not use `gh run watch` or tight polling loops; spaced, event-driven, or background monitoring avoids exhausting the GitHub API rate limit. Publishing requires the normal `workflow_dispatch` inputs so all producer artifacts come from the same run.

## Cache and source rules

The cache contract uses the `ci-cache-v2` schema. Exact caches contain only validated final outputs. Intermediate caches preserve compiler/build state, and stage-specific recovery checkpoints preserve resumable trees after failures. A cache hit is not sufficient by itself: manifests and output digests must validate before a consumer uses the result.

When changing source, toolchains, workflows, cache validators, or dependency contracts, check the affected producer closure and its cache identity. Do not include generated checkout contents such as `WEBKIT_SRC` as a source identity input when the checkout is materialized by the build script; include the pinned commit, overlay, scripts, and lockfiles instead.

Android adaptations belong in the versioned source trees or explicitly pinned external overlay. OpenTUI must compile as Bionic from source; `patchelf`, post-link ELF surgery, dirty submodule state, and a musl fallback are not valid substitutes. Preserve the WebKit overlay's exact inventory and keep it compatible with the pinned WebKit commit.

## Shell and workspace conventions

Shell scripts use Bash with `set -euo pipefail`, quoted paths, and the canonical Termux temporary directory. Use `$TMPDIR`; do not introduce `/tmp` or `/data/local/tmp` in Termux scripts. Keep generated files, compiler caches, state manifests, and package outputs in the owning product's configured directories. Avoid resetting or deleting dirty nested checkouts and do not overwrite unrelated working-tree changes.
