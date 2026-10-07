#!/usr/bin/env bash
# Build-probe helper for the B2 same-version sonda.
# Compiles the vendored OpenCode v2 CLI into a host standalone with the given
# bun, in an isolated copy of the tree (each host gets its own node_modules and
# lock). Never mutates the repo; all writes stay under $PROBE_DIR.
set -uo pipefail

HOST_BUN="$1"        # path to the host bun binary to compile with
TREE_SRC="$2"        # vendored opencode v2 tree (source of copy)
LABEL="$3"           # e.g. host-1.3.2
OUT_STANDALONE="$4"  # where to write the emitted standalone

P="$PROBE_DIR/$LABEL"
rm -rf "$P"
mkdir -p "$P"
cp -a "$TREE_SRC" "$P/src"
cd "$P/src"

# Bun <1.3 does not understand workspaces.catalog; normalize all trees the
# same way so the only variable is the bundler version.
python3 "$GITHUB_WORKSPACE/ci/scripts/v2-decatalog.py" "$P/src"
rm -f bun.lock

if ! timeout 25m "$HOST_BUN" install >"$P/install.log" 2>&1; then
  echo "INSTALL=failed label=$LABEL"
  tail -15 "$P/install.log"
  exit 10
fi
echo "INSTALL=ok label=$LABEL"

cat > "$P/build-probe.ts" <<'TS'
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"
// El virtual de assets lo provee upstream packages/cli/script/app-assets.ts;
// para la sonda basta un default vacio (B4 usa el plugin real).
const virtualAssets = {
  name: "opencode-virtual-assets",
  setup(build: any) {
    build.onResolve({ filter: /^virtual:opencode-app-assets$/ }, () => ({
      path: "virtual:opencode-app-assets",
      namespace: "opencode-virtual",
    }))
    build.onLoad({ filter: /.*/, namespace: "opencode-virtual" }, () => ({
      contents: "export default {}",
      loader: "js",
    }))
  },
}
const res = await Bun.build({
  target: "bun",
  conditions: ["bun", "node"],
  plugins: [virtualAssets, createSolidTransformPlugin()],
  compile: {
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    outfile: process.env.OUT_STANDALONE!,
  },
  entrypoints: ["./packages/cli/src/index.ts"],
  define: {
    OPENCODE_VERSION: "'2.0.24'",
    OPENCODE_CHANNEL: "'latest'",
    OPENCODE_LOCAL: "true",
  },
})
console.log("success=" + res.success)
if (!res.success) {
  for (const l of res.logs) console.error(l.message ?? l)
  process.exit(1)
}
TS

export OUT_STANDALONE
if timeout 30m "$HOST_BUN" run "$P/build-probe.ts" >"$P/compile.log" 2>&1; then
  echo "COMPILE=ok label=$LABEL"
else
  rc=$?
  echo "COMPILE=failed label=$LABEL rc=$rc"
  tail -25 "$P/compile.log"
  exit 11
fi
test -s "$OUT_STANDALONE" && echo "STANDALONE=emitido $(stat -c %s "$OUT_STANDALONE") bytes"
