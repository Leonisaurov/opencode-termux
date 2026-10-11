#!/usr/bin/env bun
/**
 * Build OpenCode v2 for Android (aarch64)
 *
 * One step: `Bun.build({ compile: { target: "bun-linux-arm64-android" } })`.
 * Bun 1.4.2 cross-compiles the standalone by embedding the target's own bun
 * ELF, so the module graph is linked into the `.bun` section instead of being
 * appended to the EOF of a separately built binary. The base that gets
 * embedded is the patched Android runtime materialized and seeded into Bun's
 * fetch cache by ci/scripts/materialize-bun-base.sh, which is what makes the
 * emitted standalone carry the Leonisaurov/bun-android lineage.
 *
 * The v2 tree is the authority for what travels in the graph: the models
 * snapshot and the SQLite migrations are versioned sources imported by
 * packages/core, and @opentui/core 0.5.x resolves its tree-sitter worker as
 * a bundled file asset.
 */

import fs from "fs"
import path from "path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`${name} env var not set`)
  return value
}

// These are set by the build-opencode.sh wrapper script
const OPENCODE_DIR = requireEnv("OPENCODE_DIR")
const BUN_BASE = requireEnv("OPENCODE_BUN_BASE")
const OUTPUT_DIR = requireEnv("OUTPUT_DIR")
const TARGET = process.env.OPENCODE_BUN_TARGET || "bun-linux-arm64-android"
// Lineage of the patched base, read from ci/external-sources.lock by the
// wrapper. The standalone embeds the base ELF verbatim, so this marker is the
// only proof that the graph was emitted against the Android runtime and not
// against the official glibc build.
const REVISION_MARKER = requireEnv("OPENCODE_BUN_REVISION_MARKER")
// The Bionic library that build-opencode.sh swapped into the arm64 slot; the
// standalone must carry exactly these bytes.
const NATIVE_LIBRARY = requireEnv("OPENCODE_LIBOPENTUI")

// Validate the patched base exists: seeding the fetch cache is the caller's
// job, and silently falling back to the official ELF would ship a glibc-less
// Bionic runtime without any error.
if (!fs.existsSync(BUN_BASE)) {
  console.error("Bun Android base not found at:", BUN_BASE)
  console.error("Run ci/scripts/materialize-bun-base.sh first.")
  process.exit(1)
}

process.chdir(OPENCODE_DIR)

const VERSION = process.env.OPENCODE_VERSION || "2.0.24"
const CHANNEL = process.env.OPENCODE_CHANNEL || "latest"

console.log(`Building OpenCode v${VERSION} (channel: ${CHANNEL}) for Android aarch64 (target ${TARGET})`)

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

// persistent-pty resolves its native binary through @opentui-ai/pty, whose
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

// OpenTUI has no idea Android exists. Two facts measured on the CI probe
// (run 38115779161) and the reason this plugin rewrites published text:
//
//   1. getNativeAssetDescriptor() throws on platform "android" before the
//      OTUI_ASSET_ROOT seam is ever consulted, so no alias package can help.
//   2. --target specializes process.platform at bundle time, so every
//      `if (process.platform === "linux")` branch in resolveNativeLibraryPath
//      is dead-code eliminated: the graph would carry no libopentui.so at all
//      (probe F: a branched import yields 0 embeddings, an unconditional one
//      yields 1).
//
// So the rewrite maps android onto the linux/arm64 asset descriptor and makes
// the import unconditional. The bytes actually embedded are whatever lives in
// node_modules/@opentui/core-linux-arm64/libopentui.so, which
// build-opencode.sh swaps for the Bionic library built by this workspace.
const ANDROID_NATIVE_SLOT = "@opentui/core-linux-arm64"

const TARGET_HEADER = "function getCurrentNodeAssetTarget() {"
const TARGET_ORIGINAL = `  return {
    platform: process.platform,
    arch: process.arch,
`
const TARGET_REPLACEMENT = `  const android = process.platform === "android";
  return {
    platform: android ? "linux" : process.platform,
    arch: android ? "arm64" : process.arch,
`

const RESOLVE_HEADER = "async function resolveNativeLibraryPath() {"
const RESOLVE_TAIL = 'throw new Error(`OpenTUI is not supported on the current platform: ${asset.packageName}`);'
const RESOLVE_REPLACEMENT = `${RESOLVE_HEADER}
  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());
  const configuredPath = resolveAssetRootPath(asset.key);
  if (configuredPath !== undefined) {
    return configuredPath;
  }
  return (await import("${ANDROID_NATIVE_SLOT}")).default;
}
`

function countOccurrences(haystack: string, needle: string): number {
  if (needle === "") return 0
  let n = 0
  let at = 0
  for (;;) {
    const found = haystack.indexOf(needle, at)
    if (found < 0) return n
    n += 1
    at = found + needle.length
  }
}

// Returns the rewritten chunk text, or null when the file is not the bun
// flavored runtime chunk. The package ships several chunks with the same
// function name; only the bun one carries the platform branch and the
// unsupported-platform throw, while the node one resolves
// `import(asset.packageName)` dynamically and has nothing to fix. Throws when
// the bun chunk drifted from what the rewrite knows how to repair: a silent
// no-op here would ship a standalone whose TUI cannot load its native library,
// and CI could not tell.
function rewriteOpenTuiForAndroid(text: string): string | null {
  if (!text.includes(RESOLVE_HEADER)) return null
  if (text.includes(RESOLVE_REPLACEMENT)) return text // already rewritten
  if (!text.includes(RESOLVE_TAIL)) return null // node-flavored chunk: no branch to map

  if (countOccurrences(text, RESOLVE_HEADER) !== 1) {
    throw new Error(`opentui-android: expected exactly one ${RESOLVE_HEADER}, found ${countOccurrences(text, RESOLVE_HEADER)}`)
  }
  const tailAt = text.indexOf(RESOLVE_TAIL)
  const bodyEnd = text.indexOf("\n}", tailAt)
  if (bodyEnd < 0) throw new Error("opentui-android: cannot find the end of resolveNativeLibraryPath")

  let out = text.slice(0, text.indexOf(RESOLVE_HEADER)) + RESOLVE_REPLACEMENT + text.slice(bodyEnd + 2)

  if (countOccurrences(out, TARGET_HEADER) !== 1) {
    throw new Error(`opentui-android: expected exactly one ${TARGET_HEADER}, found ${countOccurrences(out, TARGET_HEADER)}`)
  }
  if (!out.includes(TARGET_ORIGINAL)) throw new Error("opentui-android: getCurrentNodeAssetTarget layout changed; refusing to guess")
  out = out.replace(TARGET_ORIGINAL, TARGET_REPLACEMENT)
  return out
}

const opentuiAndroidPlugin: BunPlugin = {
  name: "opentui-android-native-slot",
  setup(build) {
    build.onLoad({ filter: /[\\/]@opentui[\\/]core[\\/][A-Za-z0-9_.-]+\.js$/ }, async (args) => {
      const text = await Bun.file(args.path).text()
      const rewritten = rewriteOpenTuiForAndroid(text)
      if (rewritten === null) return undefined
      console.log(`[opentui-android] native slot -> ${ANDROID_NATIVE_SLOT} in ${path.basename(args.path)}`)
      return { loader: "js", contents: rewritten }
    })
  },
}

// In 1.4.2 the module graph is linked into the binary, so there is no EOF
// trailer to parse: the checks are the ELF identity of an Android PIE plus the
// base lineage, which together prove the runtime is the patched Bionic ELF.
function assertAndroidStandalone(binary: Uint8Array, nativeLib: Uint8Array): void {
  const view = new DataView(binary.buffer, binary.byteOffset, binary.byteLength)
  if (String.fromCharCode(binary[0], binary[1], binary[2], binary[3]) !== "\x7fELF") {
    throw new Error("not an ELF binary")
  }
  if (binary[4] !== 2) throw new Error(`expected ELFCLASS64, got ${binary[4]}`)
  const type = view.getUint16(16, true)
  if (type !== 3) throw new Error(`expected ET_DYN (PIE) for Android, got ${type}`)
  const machine = view.getUint16(18, true)
  if (machine !== 183) throw new Error(`expected EM_AARCH64, got ${machine}`)
  const asBuf = Buffer.from(binary.buffer, binary.byteOffset, binary.byteLength)
  if (asBuf.indexOf(Buffer.from(REVISION_MARKER, "utf8")) < 0) {
    throw new Error(`base lineage marker ${REVISION_MARKER} not embedded: the official glibc bun was used`)
  }
  // Prove the Bionic library reached the graph: a window of its bytes must be
  // present verbatim. Without this, a runtime that silently selected another
  // package (or a swap that found no slot) would ship an arm64-glibc library
  // that the phone cannot dlopen.
  const window = nativeLib.subarray(Math.floor(nativeLib.length / 2), Math.floor(nativeLib.length / 2) + 4096)
  if (asBuf.indexOf(Buffer.from(window)) < 0) {
    throw new Error(`libopentui.so bytes not embedded from ${NATIVE_LIBRARY}`)
  }
}

console.log("\n=== Bundling and compiling for Android ===")

const solidPlugin = createSolidTransformPlugin()

await Bun.$`rm -rf ${OUTPUT_DIR}`
await Bun.$`mkdir -p ${OUTPUT_DIR}`

const outputPath = path.join(OUTPUT_DIR, "opencode")

const result = await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  external: ["node-gyp"],
  plugins: [appAssetsPlugin, solidPlugin, parcelWatcherPlugin, opencodePtyPlugin, opentuiAndroidPlugin],
  compile: {
    target: TARGET,
    autoloadBunfig: false,
    autoloadDotenv: false,
    autoloadTsconfig: true,
    autoloadPackageJson: true,
    outfile: outputPath,
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

const bytes = new Uint8Array(await Bun.file(outputPath).arrayBuffer())
console.log(`\nAndroid standalone binary: ${outputPath}`)
console.log(`Size: ${(bytes.length / 1024 / 1024).toFixed(1)} MB`)

assertAndroidStandalone(bytes, new Uint8Array(await Bun.file(NATIVE_LIBRARY).arrayBuffer()))
console.log(`Standalone validation: OK (base lineage ${REVISION_MARKER})`)

console.log("\n=== Build complete! ===")
console.log(`Output: ${outputPath}`)
