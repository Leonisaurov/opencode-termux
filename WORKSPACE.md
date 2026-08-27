# Workspace map

`AGENTS.md` is the operational guide. This file is the quick navigation map.

Each product owns its source, tests, scripts, build state, and artifacts:

```text
opencode/{src,build,test,scripts,patches,deps,artifacts}
kilo/{src,build,test,scripts,patches,deps,artifacts,config}
codex/{src,build,test,scripts,artifacts,more}
bun/{src,build,test,scripts,patches,artifacts,cmake}
opentui/{src/{opencode,kilo},build,test,scripts,patches,artifacts}
ci/{scripts,docker}
```

`opencode/deps/` and `kilo/deps/` point to the shared Bun and product-specific
OpenTUI checkouts. CI follows the dependency graph Bun → OpenTUI/OpenCode or
Kilo, and Rusty V8 → Codex. It uses caches and artifacts between workflows;
local builds are intentionally not part of the routine.

Do not work from historical root paths such as `scripts/`, `patches/`,
`opencode-src/`, `bun-source/`, or `build/`. Do not reset dirty nested
checkouts. The root should contain documentation, repository metadata, CI
configuration, and product directories—not binaries, logs, or scratch tests.
