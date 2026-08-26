#!/usr/bin/env bun
// build-kilo-android.ts — Build Kilo Code CLI standalone para Android/Termux (aarch64/bionic)
//
// Replica el `script/build.ts` oficial de Kilo (tag v7.4.20) pero con target = host:
// el Android Bun ejecuta este script y embebe SU runtime en el standalone (mismo
// patrón que scripts/build-android.ts de opencode). CLAVE: aplica
// createSolidTransformPlugin() que el CLI `bun build --compile` no aplica.
//
// NO copia del build.ts de Kilo: stage bubblewrap ni postprocesado del ELF,
// copyKiloConsole (deprecated), copyTreeSitterWasms, KiloSandboxWorker/Network,
// smoke tests, el loop de 12 targets, `bun install --os="*" --cpu="*"` (lo hace
// kilocode_build.sh) ni el upload a GH Releases. Solo el bundle del binario.
//
// Contrato de env vars (las usará kilocode_build.sh):
//   KILO_SRC            — checkout del fuente (default: kilo/src)
//   KILO_OUTFILE        — ruta del binario de salida (default: kilo/artifacts/kilo-android)
//   KILO_MINIFY         — "0" desactiva minify (default: minify ON)
//   MODELS_DEV_API_JSON — ruta a un snapshot de models.dev/api.json cacheado
//   KILO_VERSION        — versión baked en el define KILO_VERSION (default: pkg.version)
//   KILO_CHANNEL        — canal baked en el define KILO_CHANNEL (default: "latest")

import path from "path"
import fs from "fs"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

// ── Resolver el checkout de Kilo (chdir igual que build.ts:16 `process.chdir(dir)`) ──
const dir = process.env.KILO_SRC
  ? path.resolve(process.env.KILO_SRC, "packages/opencode")
  : path.resolve(__dirname, "../src/packages/opencode")

if (!fs.existsSync(path.join(dir, "package.json"))) {
  throw new Error(`build-kilo-android: no se encontró packages/opencode en ${dir}. Seteá KILO_SRC al checkout de kilocode.`)
}

process.chdir(dir)

// ── Versión desde package.json ──
// Replica `Script.version` del build.ts:304 (`KILO_VERSION: `'${Script.version}'``) SIN
// ejecutar `@opencode-ai/script`, porque al importarlo con KILO_VERSION sin setear hace
// fetch de red / `gh release list` (packages/script/src/index.ts:92-105). Con
// KILO_VERSION=7.4.20, Script.version devuelve exactamente ese valor sin red. Lo mismo
// aplica a Script.channel → "latest" (index.ts:34) y Script.release → KILO_BUILD_KIND.
const pkg = await Bun.file("./package.json").json()
const version: string = process.env.KILO_VERSION ?? pkg.version
const channel: string = process.env.KILO_CHANNEL ?? "latest"
const androidBunPath = process.env.ANDROID_BUN
if (!androidBunPath || !fs.existsSync(androidBunPath)) {
  throw new Error(`build-kilo-android: Android Bun no encontrado en ${androidBunPath ?? "<unset>"}`)
}

// ── Datos de models.dev (replica generate.ts de Kilo, 18 líneas) ──
// build.ts:305 `KILO_MODELS_DEV: generated.modelsData` y generate.ts usa
// `parseModelsSnapshot(raw).data` con raw = MODELS_DEV_API_JSON (archivo) o fetch.
// Aquí solo se lee el archivo del env; el refresh del cache lo maneja kilocode_build.sh.
// Sin env → snapshot vacío `{}` (el consumer models-dev.ts chequea typeof === "undefined",
// así que "{}" es seguro: cero providers, sin crash).
const shape = await import(path.join(dir, "src/kilocode/provider/models-snapshot-shape"))
let modelsData = "{}"
if (process.env.MODELS_DEV_API_JSON) {
  try {
    const raw = await Bun.file(process.env.MODELS_DEV_API_JSON).text()
    modelsData = JSON.stringify(shape.parseModelsSnapshot(raw).data)
  } catch (err) {
    console.warn(
      `build-kilo-android: no se pudo parsear MODELS_DEV_API_JSON (${process.env.MODELS_DEV_API_JSON}) — usando snapshot vacío.`,
      err,
    )
  }
}

// ── Plugin solid (LA PIEZA CLAVE, build.ts:33 + plugins: [plugin] en :270) ──
// Resuelto desde el checkout de Kilo para usar @opentui/solid@0.3.4 (la versión que
// Kilo cataloga), NO la del cache global de bun (~/.bun/install/cache tiene 0.5.1 de
// opencode). El export "./bun-plugin" de @opentui/solid apunta a scripts/solid-plugin.ts
// (verificado contra el tarball npm 0.3.4: package/scripts/solid-plugin.ts existe y
// "./bun-plugin" → "./scripts/solid-plugin.ts"; bun resuelve .js→.ts).
// NUNCA hacer fallback al cache global: un plugin de versión equivocada embebido en
// el binario produce un bundle corrupto SIN error → fallo explícito.
let createSolidTransformPlugin: typeof import("@opentui/solid/bun-plugin").createSolidTransformPlugin
try {
  const candidates = [
    path.join(dir, "node_modules/@opentui/solid/scripts/solid-plugin.ts"),
    path.join(dir, "../../node_modules/@opentui/solid/scripts/solid-plugin.ts"),
  ]
  const found = candidates.find((p) => fs.existsSync(p))
  if (found) {
    const mod = await import(found)
    createSolidTransformPlugin = mod.createSolidTransformPlugin
  } else {
    throw new Error(
      `no se encontró scripts/solid-plugin.ts en el checkout de Kilo ` +
        `(candidates: ${candidates.join(", ")}). @opentui/solid@0.3.4 SÍ lo incluye ` +
        `(export "./bun-plugin" → scripts/solid-plugin.ts). Revisá que bun install haya ` +
        `instalado @opentui/solid@0.3.4 en node_modules (NO 0.5.1 de opencode).`,
    )
  }
} catch (err) {
  // Antes caía silenciosamente al cache global (~/.bun/install/cache: 0.5.1 de opencode)
  // con console.warn → bundle potencialmente corrupto sin error en el build.
  throw new Error(
    `build-kilo-android: no se pudo resolver createSolidTransformPlugin desde el checkout ` +
      `de Kilo (requerido @opentui/solid@0.3.4). Causa: ${(err as Error).message}. ` +
      `Asegurate de que el checkout de Kilo tenga node_modules/@opentui/solid@0.3.4 ` +
      `(corre bun install en kilocode_build.sh [3/4]).`,
  )
}
const plugin = createSolidTransformPlugin()

// ── parser.worker.js de @opentui/core (build.ts:254-256) ──
const localPath = path.resolve(dir, "node_modules/@opentui/core/parser.worker.js")
const rootPath = path.resolve(dir, "../../node_modules/@opentui/core/parser.worker.js")
const parserWorker = fs.realpathSync(fs.existsSync(localPath) ? localPath : rootPath)

const workerPath = "./src/cli/tui/worker.ts"
const sessionExportWorkerPath = "./src/kilocode/session-export/worker.ts"
const indexingWorkerPath = "./src/kilocode/indexing-worker.ts"

// ── OTUI_TREE_SITTER_WORKER_PATH (build.ts:264-265 + :306) ──
// bunfsRoot es "/$bunfs/root/" para linux (build.ts:264) y workerRelativePath =
// path.relative(dir, parserWorker) (build.ts:265). El parser.worker.js entra como
// ENTRYPOINT (build.ts:300), así el path relativo dentro del bunfs lo resuelve.
const bunfsRoot = "/$bunfs/root/"
const workerRelativePath = path.relative(dir, parserWorker).replaceAll("\\", "/")

// ── LanceDB external (build.ts:273 `external: ["node-gyp", ...LanceDBRuntime.external]`) ──
// Copia literal de LanceDBRuntime.external — packages/opencode/src/kilocode/lancedb.ts:14-24.
// Mantenemos el indexing-worker como entrypoint (igual que Kilo): el bundle es JS puro;
// lo nativo de @lancedb/lancedb queda externalizado y se resuelve en runtime vía
// Npm.add (KILO_LANCEDB_PATH). Caveat runtime en Android: no hay prebuilt de lancedb
// para android → `indexing.vectorStore="lancedb"` no funcionará; usar "qdrant".
const LANCEDB_EXTERNAL = [
  "@lancedb/lancedb",
  "@lancedb/lancedb-darwin-arm64",
  "@lancedb/lancedb-linux-arm64-gnu",
  "@lancedb/lancedb-linux-arm64-musl",
  "@lancedb/lancedb-linux-x64-gnu",
  "@lancedb/lancedb-linux-x64-musl",
  "@lancedb/lancedb-win32-arm64-msvc",
  "@lancedb/lancedb-win32-x64-msvc",
] as const

// ── Bundle host + reemplazo por el runtime Bun Android ──
// NOTA: el build.ts:291 setea `target: name.replace(pkg.name, "bun")` (cross-compile).
// En Termux host y target coinciden (Android Bun embebe su propio runtime), por eso se
// omite `target` igual que scripts/build-android.ts de opencode.
await Bun.build({
  // build.ts:268
  conditions: ["bun", "node"],
  // build.ts:269
  tsconfig: "./tsconfig.json",
  // build.ts:270
  plugins: [plugin],
  // build.ts:272 — Script.release ? "none" : "external"; nosotros SIEMPRE "none" (MVP sin maps)
  sourcemap: "none",
  // build.ts:273
  external: ["node-gyp", ...LANCEDB_EXTERNAL],
  // build.ts:275
  format: "esm",
  // build.ts:276 — minify: true; respeta KILO_MINIFY !== "0" (patrón OPENCODE_MINIFY)
  minify: process.env.KILO_MINIFY !== "0",
  // build.ts:277-284 — CRÍTICO: splitting desactivado por bug de Bun 1.3.14 codegen
  // ("Exported binding needs to refer to a top-level declared variable"; oven-sh/bun#25621).
  // Con splitting:true Bun emite cross-chunk re-exports que corrompen el binario al
  // arrancar. NO usar splitting:true.
  splitting: false,
  // build.ts:286-297
  compile: {
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    outfile: `${process.env.KILO_OUTFILE ?? path.resolve(__dirname, "../artifacts/kilo-android")}.host`,
    // build.ts:294 — execArgv: [`--user-agent=kilo/${Script.version}`, "--use-system-ca", "--"]
    execArgv: [`--user-agent=kilo/${version}`, "--use-system-ca", "--"],
    windows: {},
  },
  // build.ts:299 — packages/app eliminado; sin web UI embebida
  files: {},
  // build.ts:300 — entrypoints: ["./src/index.ts", parserWorker, workerPath, sessionExportWorkerPath, indexingWorkerPath]
  entrypoints: ["./src/index.ts", parserWorker, workerPath, sessionExportWorkerPath, indexingWorkerPath],
  // build.ts:302-322 — defines replicados para Android = linux + musl, sin sandbox
  define: {
    // build.ts:303 — FFF_LIBC: item.abi === "musl" ? "musl" : "gnu" → musl
    FFF_LIBC: JSON.stringify("musl"),
    // build.ts:304 — KILO_VERSION: `'${Script.version}'` (pkg.version 7.4.20, sin fetch)
    KILO_VERSION: `'${version}'`,
    // build.ts:305 — KILO_MODELS_DEV: generated.modelsData (snapshot del env o "{}")
    KILO_MODELS_DEV: modelsData,
    // build.ts:306 — OTUI_TREE_SITTER_WORKER_PATH: bunfsRoot + workerRelativePath
    OTUI_TREE_SITTER_WORKER_PATH: bunfsRoot + workerRelativePath,
    // build.ts:307 — KILO_WORKER_PATH
    KILO_WORKER_PATH: workerPath,
    // build.ts:309 — KILO_SESSION_EXPORT_WORKER_PATH
    KILO_SESSION_EXPORT_WORKER_PATH: sessionExportWorkerPath,
    // build.ts:310 — KILO_INDEXING_WORKER_PATH (mantenido; ver nota LanceDB arriba)
    KILO_INDEXING_WORKER_PATH: indexingWorkerPath,
    // build.ts:311 — sin sandbox: "undefined" (KiloSandboxWorker.filename omitido)
    KILO_SANDBOX_MUTATION_WORKER_PATH: "undefined",
    // build.ts:312 — sin sandbox: "undefined" (solo linux con sandbox tendría relay)
    KILO_SANDBOX_NETWORK_RELAY_PATH: "undefined",
    // build.ts:313 — sin sandbox: "undefined"
    KILO_SANDBOX_SECCOMP_PATH: "undefined",
    // build.ts:315 — KILO_CHANNEL: `'${Script.channel}'` → "latest" (sin red, ver arriba)
    KILO_CHANNEL: `'${channel}'`,
    // build.ts:316 — KILO_LIBC: linux ? `'${item.abi ?? "glibc"}'` → 'musl' (selecciona @parcel/watcher-linux-arm64-musl)
    KILO_LIBC: "'musl'",
    // build.ts:318 — KILO_BWRAP_SHA256: bwrap ? ... : "undefined" → "undefined" (sin bubblewrap)
    KILO_BWRAP_SHA256: "undefined",
    // build.ts:319 — KILO_BUILD_KIND: Script.release ? 'release' : 'source' → 'release' (MVP)
    KILO_BUILD_KIND: "'release'",
    // build.ts:321 — "process.env.OPENTUI_LIBC": JSON.stringify(abi ?? "glibc") → "musl"
    "process.env.OPENTUI_LIBC": JSON.stringify("musl"),
  },
})

const outputPath = process.env.KILO_OUTFILE ?? path.resolve(__dirname, "../artifacts/kilo-android")
const hostPath = `${outputPath}.host`
const hostBytes = new Uint8Array(await Bun.file(hostPath).arrayBuffer())
const trailer = Buffer.from("\n---- Bun! ----\n")
const trailerStart = hostBytes.length - 8 - trailer.length
const trailerFound = Buffer.from(hostBytes).subarray(trailerStart, trailerStart + trailer.length).compare(trailer) === 0
if (!trailerFound) throw new Error("build-kilo-android: trailer Bun no encontrado en el binario host")
const offsetsStart = trailerStart - 32
const graphByteCount = Number(Buffer.from(hostBytes).readBigUInt64LE(offsetsStart))
const graphSize = graphByteCount + 32 + trailer.length
const hostRuntimeSize = hostBytes.length - 8 - graphSize
if (hostRuntimeSize <= 0 || hostRuntimeSize >= hostBytes.length) {
  throw new Error(`build-kilo-android: tamaño de runtime host inválido: ${hostRuntimeSize}`)
}
const moduleGraph = hostBytes.slice(hostRuntimeSize, hostBytes.length - 8)
const androidBun = new Uint8Array(await Bun.file(androidBunPath).arrayBuffer())
const outputSize = androidBun.length + moduleGraph.length + 8
const output = new Uint8Array(outputSize)
output.set(androidBun, 0)
output.set(moduleGraph, androidBun.length)
const total = new DataView(output.buffer, outputSize - 8, 8)
total.setUint32(0, outputSize & 0xffffffff, true)
total.setUint32(4, Math.floor(outputSize / 0x100000000), true)
await Bun.write(outputPath, output)
fs.chmodSync(outputPath, 0o755)
await Bun.write(hostPath, "")
console.log(`✅ Build complete: kilo-android (${(outputSize / 1024 / 1024).toFixed(1)} MB, Android Bun embebido)`)
