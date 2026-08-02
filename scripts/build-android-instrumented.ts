#!/usr/bin/env bun
// build-android.ts - Build OpenCode standalone para Android/Termux
// Replica el build.ts oficial pero con target = host (Android Bun runtime).
// CLAVE: aplica createSolidTransformPlugin() que el CLI `bun build --compile` no aplica.

import { $ } from "bun"
import path from "path"
import { fileURLToPath } from "url"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const dir = path.resolve(__dirname, "../opencode-src/packages/opencode")

process.chdir(dir)

// Generate models data (igual que build.ts)
// NOTA: import() relativo se resuelve contra este módulo (scripts/), no contra el cwd.
// build.ts oficial usa "./generate.ts" porque vive dentro de packages/opencode/script/.
console.log(">>> [1] importando generate.ts...")
const generated = await import(path.join(dir, "script/generate.ts"))
console.log(">>> [2] generate.ts OK, modelsData length:", generated.modelsData?.length)

// Versión desde package.json
console.log(">>> [3] leyendo package.json...")
const pkg = await Bun.file("./package.json").json()
console.log(">>> [4] package.json OK, version:", pkg.version)

// Plugin solid (LA PIEZA CLAVE)
console.log(">>> [5] createSolidTransformPlugin...")
const plugin = createSolidTransformPlugin()
console.log(">>> [6] plugin OK")

// Tree-sitter worker embebido (igual que build.ts)
const treeSitterWorker = await Bun.file(
  fileURLToPath(import.meta.resolve("@opentui/core/parser.worker"))
).text()
const treeSitterWorkerPath = "opentui-tree-sitter-worker.js"
const workerPath = "./src/cli/tui/worker.ts"

console.log(">>> [7] antes de Bun.build, entrypoints:", ["./src/index.ts", workerPath, treeSitterWorkerPath])
// Build standalone con el runtime del Android Bun (target = host)
await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  plugins: [plugin],
  external: ["node-gyp"],
  format: "esm",
  minify: true,
  sourcemap: "none",
  splitting: true,
  compile: {
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    outfile: process.env.OPENCODE_OUTFILE ?? "/data/data/com.termux/files/home/Develop/Patch/opencode-termux/opencode-android",
    execArgv: [`--user-agent=opencode/${pkg.version}`, "--use-system-ca", "--"],
    windows: {},
  },
  files: {
    [treeSitterWorkerPath]: treeSitterWorker,
  },
  entrypoints: [
    "./src/index.ts",
    workerPath,
    treeSitterWorkerPath,
  ],
  define: {
    FFF_LIBC: JSON.stringify("gnu"),
    OPENCODE_VERSION: `'${pkg.version}'`,
    OPENCODE_MODELS_DEV: generated.modelsData,
    OTUI_TREE_SITTER_WORKER_PATH: "/$bunfs/root/" + treeSitterWorkerPath,
    OPENCODE_WORKER_PATH: workerPath,
    OPENCODE_CHANNEL: `'${pkg.version.split(".").slice(0,2).join(".")}'`,
    OPENCODE_LIBC: `'glibc'`,
  },
})

console.log(">>> [8] Bun.build retornó")
console.log("✅ Build complete: opencode-android")
