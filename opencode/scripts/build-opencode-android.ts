#!/usr/bin/env bun
/**
 * Build OpenCode v2 for Android (aarch64)
 *
 * This script:
 * 1. Bundles packages/cli with Bun.build() --compile for the host platform
 * 2. Extracts the module graph from the compiled binary
 * 3. Repairs it for the Android runtime and appends it to our Android bun
 *    binary to create the final standalone
 *
 * The v2 tree is the authority for what travels in the graph: the models
 * snapshot and the SQLite migrations are versioned sources imported by
 * packages/core, and @opentui/core 0.5.x resolves its tree-sitter worker as
 * a bundled file asset. No generated snapshot defines and no separate worker
 * entrypoint are needed anymore.
 */

import fs from "fs"
import path from "path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"
import { patchAndroidModuleGraph, validateAndroidModuleGraph, validateAndroidStandalone } from "./module-graph-patch"

// These are set by the build-opencode.sh wrapper script
const OPENCODE_DIR = process.env.OPENCODE_DIR || (() => { throw new Error("OPENCODE_DIR env var not set") })()
const ANDROID_BUN = process.env.ANDROID_BUN || (() => { throw new Error("ANDROID_BUN env var not set") })()
const OUTPUT_DIR = process.env.OUTPUT_DIR || (() => { throw new Error("OUTPUT_DIR env var not set") })()

// Validate Android bun exists
if (!fs.existsSync(ANDROID_BUN)) {
  console.error("Android bun binary not found at:", ANDROID_BUN)
  process.exit(1)
}

process.chdir(OPENCODE_DIR)

const VERSION = process.env.OPENCODE_VERSION || "2.0.24"
const CHANNEL = process.env.OPENCODE_CHANNEL || "latest"

console.log(`Building OpenCode v${VERSION} (channel: ${CHANNEL}) for Android aarch64`)

// The Android release ships without the web UI: an empty embedded asset map
// makes the server answer 404 on browser routes (non-local channel), while
// API and TUI paths are untouched. Baking the real archive would require a
// packages/app vite build here.
const appAssetsPlugin: BunPlugin = {
  name: "opencode-app-assets",
  setup(build) {
    build.onResolve({ filter: /^virtual:opencode-app-assets$/ }, () => ({
      path: "opencode-app-assets",
      namespace: "opencode",
    }))
    build.onLoad({ filter: /^opencode-app-assets$/, namespace: "opencode" }, () => ({
      loader: "js",
      contents: "export default {}",
    }))
  },
}

// persistent-pty resolves its native binary through @opencode-ai/pty, whose
// runtime require of the platform package crashes on Bionic. Upstream embeds
// per-target binaries and falls back to `undefined` (PATH lookup for an
// "opencode-pty" executable) where none exists; Android has no published
// bionic artifact, so we stub it explicitly.
const opencodePtyPlugin: BunPlugin = {
  name: "opencode-pty-binary",
  setup(build) {
    build.onLoad({ filter: /persistent-pty[/\\]pty-binding\.ts$/ }, () => ({
      loader: "js",
      contents: "export default undefined",
    }))
  },
}

// Mirror upstream's linux/arm64 glibc target so the binding is embedded via a
// static require; dlopen of the glibc .node fails on Bionic and watcher.ts
// degrades through its lazy try/catch.
const parcelWatcherPlugin: BunPlugin = {
  name: "parcel-watcher-binding",
  setup(build) {
    build.onLoad({ filter: /filesystem[/\\]watcher-binding\.ts$/ }, () => ({
      loader: "js",
      contents: `export default () => require("@parcel/watcher-linux-arm64-glibc")`,
    }))
  },
}

console.log("\n=== Step 1: Bundling OpenCode CLI ===")

const solidPlugin = createSolidTransformPlugin()

await Bun.$`rm -rf ${OUTPUT_DIR}`
await Bun.$`mkdir -p ${OUTPUT_DIR}`

// Build with --compile for the HOST platform to get a standalone binary;
// we'll extract the module graph from it. No bytecode/minify/splitting: the
// graph bytes as emitted (plain, unsplit) are what the pinned Android Bun and
// module-graph-patch.ts are proven to consume.
const hostBinaryPath = path.join(OUTPUT_DIR, "opencode-host")

console.log("Building standalone binary for host platform...")
const result = await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  external: ["node-gyp"],
  plugins: [appAssetsPlugin, solidPlugin, parcelWatcherPlugin, opencodePtyPlugin],
  compile: {
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    outfile: hostBinaryPath,
    execArgv: [`--user-agent=opencode/${VERSION}`, "--use-system-ca", "--"],
  },
  entrypoints: ["./src/index.ts"],
  define: {
    OPENCODE_VERSION: `'${VERSION}'`,
    OPENCODE_CLI_NAME: "'opencode'",
    OPENCODE_CHANNEL: `'${CHANNEL}'`,
    OPENCODE_ARTIFACT: "'cli'",
    OPENCODE_LIBC: "'glibc'",
    // FFF_LIBC selects the fff native lib variant: "musl" or "gnu".
    FFF_LIBC: "'gnu'",
    "process.env.OPENTUI_LIBC": JSON.stringify("glibc"),
  },
})

if (!result.success) {
  console.error("Build failed:")
  for (const msg of result.logs) {
    console.error(msg)
  }
  process.exit(1)
}

console.log(`Host standalone binary: ${hostBinaryPath}`)

// Step 2: Extract module graph from host binary
console.log("\n=== Step 2: Extracting module graph ===")

const hostBinary = await Bun.file(hostBinaryPath).arrayBuffer()
const hostBytes = new Uint8Array(hostBinary)

// Standalone binary format (ELF):
//   [bun binary (seek_pos bytes)]
//   [module_graph bytes]
//   [total_byte_count as u64 LE (8 bytes)]
//
// Module graph internal layout:
//   [string data] [module list] [offsets (32 bytes)] [trailer "\n---- Bun! ----\n" (16 bytes)]
//
// offsets.byte_count = len(string_data) + len(module_list)
// total_byte_count = seek_pos + len(module_graph) + 8 = file_size
//
// We derive the module graph size from the trailer and offsets struct,
// WITHOUT relying on process.execPath (which may differ from the bun
// binary that was embedded during --compile).

const TRAILER_STR = "\n---- Bun! ----\n"
const TRAILER_LEN = TRAILER_STR.length // 16
const OFFSETS_SIZE_CONST = 32

const trailerBuf = Buffer.from(TRAILER_STR)
const searchBuf = Buffer.from(hostBytes.buffer, hostBytes.byteOffset, hostBytes.length)
const trailerEnd = hostBytes.length - 8 // trailer must end here
const expectedTrailerStart = trailerEnd - TRAILER_LEN

const foundTrailer = searchBuf.compare(
  trailerBuf, 0, TRAILER_LEN,
  expectedTrailerStart, trailerEnd
) === 0

if (!foundTrailer) {
  console.error("ERROR: Bun standalone trailer not found at expected position")
  console.error("       The standalone binary format may have changed.")
  process.exit(1)
}

const offsetsStart = expectedTrailerStart - OFFSETS_SIZE_CONST
const offsetsByteCount = Number(searchBuf.readBigUInt64LE(offsetsStart))

const moduleGraphSize = offsetsByteCount + OFFSETS_SIZE_CONST + TRAILER_LEN
const hostBunSize = hostBytes.length - 8 - moduleGraphSize

console.log(`Host standalone size: ${hostBytes.length}`)
console.log(`Derived host bun size: ${hostBunSize}`)
console.log(`Module graph size: ${moduleGraphSize}`)

if (hostBunSize <= 0) {
  console.error(`ERROR: Derived host bun size is ${hostBunSize} — something is wrong`)
  process.exit(1)
}

const moduleGraphBytes = hostBytes.slice(hostBunSize, hostBytes.length - 8)
console.log(`Module graph extracted: ${moduleGraphBytes.length} bytes`)
console.log(`Trailer verified: OK`)

// Step 3: Preserve the module graph emitted by the pinned host Bun
console.log("\n=== Step 3: Preserving the versioned module graph ===")

// The module graph format (from StandaloneModuleGraph.zig):
//   [string data: all file names, contents, sourcemaps, bytecodes concatenated]
//   [CompiledModuleGraphFile array]
//   [Offsets struct: 32 bytes]
//   [trailer: "\n---- Bun! ----\n"]
//
// Offsets struct layout (32 bytes, little-endian, unchanged across Bun versions):
//   byte_count:              u64  (8 bytes) - size of everything before the Offsets struct
//   modules_ptr.offset:      u32  (4 bytes)
//   modules_ptr.length:      u32  (4 bytes)
//   entry_point_id:          u32  (4 bytes)
//   compile_exec_argv.offset:u32  (4 bytes)
//   compile_exec_argv.length:u32  (4 bytes)
//   flags:                   u32  (4 bytes)
//
// NOTE: CompiledModuleGraphFile layout varies between Bun versions. The
// versioned OpenCode source and the pinned host Bun are the authority for the
// graph; this assembly step must not rewrite its bytes or offsets.

const mgTrailer = "\n---- Bun! ----\n"
const mgTrailerBuf = Buffer.from(mgTrailer)
const OFFSETS_SIZE = 32

const mgBuf = Buffer.from(moduleGraphBytes)
const trailerPosInMg = mgBuf.lastIndexOf(mgTrailerBuf)
if (trailerPosInMg < 0) throw new Error("Trailer not found in module graph!")

const mgOffsetsStart = trailerPosInMg - OFFSETS_SIZE
const byteCount = Number(mgBuf.readBigUInt64LE(mgOffsetsStart))
const modOff = mgBuf.readUInt32LE(mgOffsetsStart + 8)
const modLen = mgBuf.readUInt32LE(mgOffsetsStart + 12)
const entryId = mgBuf.readUInt32LE(mgOffsetsStart + 16)
const argvOff = mgBuf.readUInt32LE(mgOffsetsStart + 20)
const argvLen = mgBuf.readUInt32LE(mgOffsetsStart + 24)
const flags = mgBuf.readUInt32LE(mgOffsetsStart + 28)

console.log(`Module graph: trailer at ${trailerPosInMg}, offsets at ${mgOffsetsStart}`)
console.log(`byte_count=${byteCount}, modules_ptr=(${modOff},${modLen}), entry_id=${entryId}`)
console.log(`String data region: [0, ${modOff}), Module list: [${modOff}, ${modOff + modLen})`)

const patchedModuleGraph = patchAndroidModuleGraph(
  mgBuf.slice(0, trailerPosInMg + mgTrailerBuf.length),
  "opencode",
)
validateAndroidModuleGraph(patchedModuleGraph.graph, "opencode")
const finalModuleGraph = patchedModuleGraph.graph
console.log(`Module graph size: ${finalModuleGraph.length} bytes; undici repairs: ${patchedModuleGraph.patchCount}`)

// Step 4: Create Android standalone binary
console.log("\n=== Step 4: Creating Android standalone binary ===")

const androidBunBytes = new Uint8Array(await Bun.file(ANDROID_BUN).arrayBuffer())
const androidBunSize = androidBunBytes.length
console.log(`Android bun size: ${androidBunSize}`)

// New total_byte_count = android_bun_size + module_graph.length + 8
const newTotalByteCount = androidBunSize + finalModuleGraph.length + 8

const outputSize = androidBunSize + finalModuleGraph.length + 8
const output = new Uint8Array(outputSize)

output.set(androidBunBytes, 0)

// Copy the module graph emitted by the pinned host Bun
output.set(new Uint8Array(finalModuleGraph.buffer, finalModuleGraph.byteOffset, finalModuleGraph.length), androidBunSize)

// Write new total_byte_count as u64 LE
const totalView = new DataView(output.buffer, outputSize - 8, 8)
totalView.setUint32(0, newTotalByteCount & 0xFFFFFFFF, true)
totalView.setUint32(4, Math.floor(newTotalByteCount / 0x100000000), true)

const androidOutputPath = path.join(OUTPUT_DIR, "opencode")
await Bun.write(androidOutputPath, output)
fs.chmodSync(androidOutputPath, 0o755)

console.log(`\nAndroid standalone binary: ${androidOutputPath}`)
console.log(`Size: ${(outputSize / 1024 / 1024).toFixed(1)} MB`)

// Verify
const verifyBytes = new Uint8Array(await Bun.file(androidOutputPath).arrayBuffer())
const verifyView = new DataView(verifyBytes.buffer, verifyBytes.length - 8, 8)
const verifyTotal = verifyView.getUint32(0, true) + verifyView.getUint32(4, true) * 0x100000000
console.log(`Verification: total_byte_count=${verifyTotal}, file_size=${verifyBytes.length}, match=${verifyTotal === verifyBytes.length}`)

const elfMagic = String.fromCharCode(verifyBytes[0], verifyBytes[1], verifyBytes[2], verifyBytes[3])
console.log(`ELF magic: ${elfMagic === "\x7fELF" ? "OK" : "INVALID"}`)
validateAndroidStandalone(verifyBytes, "opencode")
console.log("Module graph validation: OK")

console.log("\n=== Build complete! ===")
console.log(`Output: ${androidOutputPath}`)
