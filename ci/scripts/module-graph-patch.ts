#!/usr/bin/env bun

type Product = "opencode" | "kilo"

export type ModuleGraphPatchResult = {
  graph: Uint8Array
  patchCount: number
}

type GraphLayout = {
  trailerStart: number
  offsetsStart: number
  stringEnd: number
  moduleOffset: number
  moduleLength: number
}

type Replacement = {
  start: number
  end: number
  value: string
}

const TRAILER = Buffer.from("\n---- Bun! ----\n")
const OFFSETS_SIZE = 32
function fail(message: string): never {
  throw new Error(`module-graph-patch: ${message}`)
}

function identifierPattern(identifier: string): string {
  return identifier.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function parseLayout(graph: Uint8Array): GraphLayout {
  if (graph.length < OFFSETS_SIZE + TRAILER.length) {
    fail("module graph is shorter than its footer")
  }
  const trailerStart = graph.length - TRAILER.length
  if (!Buffer.from(graph.subarray(trailerStart)).equals(TRAILER)) {
    fail("module graph trailer is missing or misplaced")
  }
  const offsetsStart = trailerStart - OFFSETS_SIZE
  const view = new DataView(graph.buffer, graph.byteOffset, graph.byteLength)
  const byteCount = Number(view.getBigUint64(offsetsStart, true))
  const moduleOffset = view.getUint32(offsetsStart + 8, true)
  const moduleLength = view.getUint32(offsetsStart + 12, true)
  const argvOffset = view.getUint32(offsetsStart + 20, true)
  const argvLength = view.getUint32(offsetsStart + 24, true)
  if (byteCount !== offsetsStart) {
    fail(`offsets byte_count ${byteCount} does not match ${offsetsStart}`)
  }
  if (moduleOffset > byteCount || moduleLength > byteCount - moduleOffset) {
    fail("module list points outside the graph")
  }
  if (argvOffset > byteCount || argvLength > byteCount - argvOffset) {
    fail("compile argv points outside the graph")
  }
  return { trailerStart, offsetsStart, stringEnd: moduleOffset, moduleOffset, moduleLength }
}

function declaredInSegment(segment: string, identifier: string): boolean {
  const name = identifierPattern(identifier)
  return new RegExp(`\\b(?:var|let|const|function|class)\\s+${name}\\b`).test(segment)
}

function findDefaultExports(segment: string): Array<{ object: string; exported: string }> {
  const result: Array<{ object: string; exported: string }> = []
  const pattern = /\b[A-Za-z_$][A-Za-z0-9_$]*\(\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*,\s*\{\s*default\s*:\s*\(\)\s*=>\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\}\s*\)/g
  for (const match of segment.matchAll(pattern)) {
    result.push({ object: match[1], exported: match[2] })
  }
  return result
}

function findImportBindings(segment: string): Array<{ binding: string; index: number }> {
  const result: Array<{ binding: string; index: number }> = []
  const pattern = /\bimport\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+from\s*["']undici["']\s*;?/g
  for (const match of segment.matchAll(pattern)) {
    result.push({ binding: match[1], index: match.index ?? 0 })
  }
  return result
}

function findReplacements(segment: string, product: Product, base: number): Replacement[] {
  const replacements: Replacement[] = []
  for (const imported of findImportBindings(segment)) {
    const afterImport = segment.slice(imported.index)
    const exports = findDefaultExports(segment)
    for (const exported of exports) {
      const assignment = new RegExp(`\\b${identifierPattern(exported.exported)}\\s*=\\s*${identifierPattern(imported.binding)}\\b`)
      if (!assignment.test(afterImport)) continue
      const objectPattern = identifierPattern(exported.object)
      const callPattern = product === "opencode"
        ? new RegExp(`__reExport\\(\\s*${objectPattern}\\s*,\\s*([A-Za-z_$][A-Za-z0-9_$]*)\\s*\\)`, "g")
        : new RegExp(`\\b[A-Za-z_$][A-Za-z0-9_$]*\\(\\s*${objectPattern}\\s*,\\s*([A-Za-z_$][A-Za-z0-9_$]*)\\s*\\)`, "g")
      const candidates: Array<{ start: number; end: number; identifier: string }> = []
      for (const match of afterImport.matchAll(callPattern)) {
        const identifier = match[1]
        if (identifier === imported.binding || declaredInSegment(afterImport, identifier)) continue
        const full = match[0]
        const identifierStart = (match.index ?? 0) + full.lastIndexOf(identifier)
        candidates.push({
          start: imported.index + identifierStart,
          end: imported.index + identifierStart + identifier.length,
          identifier,
        })
      }
      if (candidates.length > 1) {
        fail(`ambiguous undici re-export for ${imported.binding}`)
      }
      if (candidates.length === 1) {
        const candidate = candidates[0]
        if (candidate.identifier.length !== imported.binding.length) {
          fail(`cannot replace ${candidate.identifier} with ${imported.binding}: length differs`)
        }
        replacements.push({ start: base + candidate.start, end: base + candidate.end, value: imported.binding })
      }
    }
  }
  return replacements
}

function findAllReplacements(graph: Uint8Array, product: Product): Replacement[] {
  const layout = parseLayout(graph)
  const stringData = graph.subarray(0, layout.stringEnd)
  const replacements: Replacement[] = []
  let start = 0
  while (start < stringData.length) {
    const end = stringData.indexOf(0, start)
    const segmentEnd = end < 0 ? stringData.length : end
    const segmentBytes = stringData.subarray(start, segmentEnd)
    if (segmentBytes.includes(0x75)) {
      const segment = Buffer.from(segmentBytes).toString("latin1")
      if (segment.includes("undici") && segment.includes("import")) {
        replacements.push(...findReplacements(segment, product, start))
      }
    }
    start = segmentEnd + 1
  }
  return replacements
}

function applyReplacements(graph: Uint8Array, replacements: Replacement[]): Uint8Array {
  const output = new Uint8Array(graph)
  for (const replacement of replacements) {
    const encoded = Buffer.from(replacement.value, "latin1")
    if (encoded.length !== replacement.end - replacement.start) {
      fail("replacement changes module graph length")
    }
    output.set(encoded, replacement.start)
  }
  return output
}

export function patchAndroidModuleGraph(graph: Uint8Array, product: Product): ModuleGraphPatchResult {
  const replacements = findAllReplacements(graph, product)
  const patched = applyReplacements(graph, replacements)
  const remaining = findAllReplacements(patched, product)
  if (remaining.length > 0) {
    fail(`module graph still contains ${remaining.length} vulnerable undici re-export(s)`)
  }
  return { graph: patched, patchCount: replacements.length }
}

export function validateAndroidModuleGraph(graph: Uint8Array, product: Product): void {
  parseLayout(graph)
  if (findAllReplacements(graph, product).length > 0) {
    fail(`module graph contains a vulnerable ${product} undici re-export`)
  }
}

export function extractAndroidModuleGraph(binary: Uint8Array): Uint8Array {
  if (binary.length < 8 + OFFSETS_SIZE + TRAILER.length) fail("standalone binary is too short")
  if (binary[0] !== 0x7f || binary[1] !== 0x45 || binary[2] !== 0x4c || binary[3] !== 0x46) fail("standalone output is not ELF")
  const footer = new DataView(binary.buffer, binary.byteOffset + binary.length - 8, 8)
  const total = footer.getBigUint64(0, true)
  if (total !== BigInt(binary.length)) fail("standalone total_byte_count does not match file size")
  const trailerStart = binary.length - 8 - TRAILER.length
  const offsetsStart = trailerStart - OFFSETS_SIZE
  const view = new DataView(binary.buffer, binary.byteOffset, binary.byteLength)
  const byteCount = Number(view.getBigUint64(offsetsStart, true))
  const graphSize = byteCount + OFFSETS_SIZE + TRAILER.length
  const runtimeSize = binary.length - 8 - graphSize
  if (runtimeSize <= 0) fail("standalone module graph has no runtime prefix")
  const graph = binary.slice(runtimeSize, binary.length - 8)
  parseLayout(graph)
  return graph
}

export function validateAndroidStandalone(binary: Uint8Array, product: Product): void {
  const graph = extractAndroidModuleGraph(binary)
  validateAndroidModuleGraph(graph, product)
}

if (import.meta.main) {
  const [, , command, product, file] = Bun.argv
  if ((command !== "validate-standalone" && command !== "validate-graph") || (product !== "opencode" && product !== "kilo") || !file) {
    console.error("usage: bun module-graph-patch.ts validate-standalone|validate-graph opencode|kilo FILE")
    process.exit(2)
  }
  const bytes = new Uint8Array(await Bun.file(file).arrayBuffer())
  if (command === "validate-standalone") validateAndroidStandalone(bytes, product)
  else validateAndroidModuleGraph(bytes, product)
  console.log(`module-graph-patch: valid ${product} ${file}`)
}
