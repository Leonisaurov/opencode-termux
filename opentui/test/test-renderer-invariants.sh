#!/usr/bin/env bash
# Prueba fresh-path + idempotencia de los parches de renderer y del bloque de
# invariantes que los mantiene. El builder legacy de Kilo contiene el bloque
# Python inline; el builder de OpenTUI aplica el equivalente como parche
# repository-owned sobre la fuente virgen.
#
#   fresh-path:  extrae los fuentes zig FRESCOS (git show HEAD) de cada checkout
#                de opentui y encadena los bloques python previos del script
#                (build.zig guard → renderer panic → pool hardening → writer len
#                guard → renderer invariantes) verificando que el pipeline aplica
#                sin fallos sobre código virgen.
#   idempotencia: re-ejecuta el bloque renderer invariantes sobre el archivo ya
#                parcheado → no debe producir cambios (diff vacío) y el python
#                debe reportar "ya parcheado".
#
# Uso: opentui/test/test-renderer-invariants.sh
set -euo pipefail

: "${TMPDIR:=/data/data/com.termux/files/usr/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
test -d "$TMPDIR" && test -w "$TMPDIR"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "$TMPDIR/renderer-invariants-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

run_fresh_and_idempotent() {  # $1=script, $2=src_dir, $3=label
    local script="$1" src="$2" label="$3"
    local out="$TMP/$label"
    mkdir -p "$out"

    # Fuentes frescos desde git HEAD
    git -C "$src" show "HEAD:packages/core/src/zig/renderer.zig" > "$out/renderer.zig"
    git -C "$src" show "HEAD:packages/core/src/zig/grapheme.zig" > "$out/grapheme.zig"
    git -C "$src" show "HEAD:packages/core/src/zig/link.zig" > "$out/link.zig"
    git -C "$src" show "HEAD:packages/core/src/zig/buffer.zig" > "$out/buffer.zig"
    git -C "$src" show "HEAD:packages/core/src/zig/build.zig" > "$out/build.zig" || true

    echo "=== $label: fresh-path (pipeline de bloques previos + renderer invariantes) ==="
    export RENDERER_ZIG="$out/renderer.zig" GRAPHEME_ZIG="$out/grapheme.zig" \
           LINK_ZIG="$out/link.zig" BUFFER_ZIG="$out/buffer.zig" BUILD_ZIG="$out/build.zig"
    python3 - "$script" "$out" <<'PYEOF'
import os, re, subprocess, sys

script, out = sys.argv[1], sys.argv[2]
with open(script, encoding="utf-8") as f:
    lines = f.readlines()

blocks = []  # (arg_vars, code)
i, n = 0, len(lines)
while i < n:
    m = re.match(r'\s*python3 - (.+?) <<\'PYEOF\'$', lines[i])
    if m:
        arg_vars = re.findall(r'\$([A-Z_]+)', m.group(1))
        code, i = [], i + 1
        while i < n and lines[i].rstrip("\n") != "PYEOF":
            code.append(lines[i]); i += 1
        i += 1  # saltar PYEOF
        blocks.append((arg_vars, "".join(code)))
    else:
        i += 1

# Ejecutar bloques en orden hasta incluir el nuevo (renderer invariantes)
ran_new = False
for idx, (arg_vars, code) in enumerate(blocks):
    is_new = "OTUI Android fix (renderer invariantes)" in code
    if not is_new and ran_new:
        break
    resolved = [os.environ.get(v, "") for v in arg_vars]
    if not resolved or not all(p and os.path.exists(p) for p in resolved):
        if not is_new:
            continue  # bloque que toca archivos no extraídos (p.ej. audio/vendor)
    r = subprocess.run([sys.executable, "-"] + resolved, input=code,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("STDOUT:", r.stdout)
        print("STDERR:", r.stderr)
        sys.exit(f"FALLO bloque python #{idx} de {script} (fresh-path {out})")
    if is_new:
        ran_new = True
    print(f"  bloque #{idx}: OK")

if not ran_new:
    sys.exit(f"no se encontró el bloque renderer invariantes en {script}")

# Verificación fresh-path: marcadores presentes
with open(os.path.join(out, "renderer.zig"), encoding="utf-8") as f:
    s = f.read()
need = [
    "OTUI Android fix (codepoint válido)",
    "OTUI Android fix (renderer invariantes): invariante 2 (url_bytes)",
    "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes)",
    "OTUI Android fix (renderer invariantes): invariante 2 (utf8Buf)",
]
missing = [m for m in need if s.count(m) < (2 if "codepoint" in m else 1)]
if missing:
    sys.exit(f"FRESH-PATH: marcadores faltantes en {out}/renderer.zig: {missing}")
print("  fresh-path OK: marcadores verificados en renderer.zig")
PYEOF

    echo "=== $label: idempotencia (re-ejecutar bloque renderer invariantes sobre parcheado) ==="
    python3 - "$script" "$out" <<'PYEOF'
import os, re, subprocess, sys

script, out = sys.argv[1], sys.argv[2]
with open(script, encoding="utf-8") as f:
    lines = f.readlines()

target = None
i, n = 0, len(lines)
while i < n:
    m = re.match(r'\s*python3 - (.+?) <<\'PYEOF\'$', lines[i])
    if m:
        arg_vars = re.findall(r'\$([A-Z_]+)', m.group(1))
        code, i = [], i + 1
        while i < n and lines[i].rstrip("\n") != "PYEOF":
            code.append(lines[i]); i += 1
        i += 1
        if "OTUI Android fix (renderer invariantes)" in "".join(code):
            target = (arg_vars, "".join(code))
            break
    else:
        i += 1

if not target:
    sys.exit(f"no se encontró el bloque renderer invariantes en {script}")
arg_vars, code = target
resolved = [os.environ.get(v, "") for v in arg_vars]
before = open(os.path.join(out, "renderer.zig"), "rb").read()
r = subprocess.run([sys.executable, "-"] + resolved, input=code,
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit(f"IDEMPOTENCIA: falló al re-aplicar: {r.stdout} {r.stderr}")
after = open(os.path.join(out, "renderer.zig"), "rb").read()
if before != after:
    sys.exit(f"IDEMPOTENCIA: re-aplicar cambió {out}/renderer.zig (diff no vacío)")
if "ya parcheado" not in r.stdout and "ya presentes" not in r.stdout:
    sys.exit(f"IDEMPOTENCIA: el python no reportó 'ya parcheado': {r.stdout}")
print("  idempotencia OK: diff vacío + 'ya parcheado'")
PYEOF
}

run_fresh_and_idempotent "$ROOT/kilo/scripts/build.sh" \
    "$ROOT/opentui/src/kilo" "kilo-0.3.4"

run_patch_chain_and_idempotent() {  # $1=src_dir, $2=label, $3...=patches
    local src="$1" label="$2"
    shift 2
    local out="$TMP/$label/source"
    mkdir -p "$out"

    # Extraer una fuente virgen sin tocar el checkout persistente ni sus parches
    # locales. Un repositorio temporal permite que git apply compruebe los
    # mismos paths que usará el workflow.
    git -C "$src" archive HEAD | tar -xf - -C "$out"
    git -C "$out" init -q

    echo "=== $label: fresh-path (parches repository-owned) ==="
    local patch
    for patch in "$@"; do
        git -C "$out" apply --check "$ROOT/$patch"
        git -C "$out" apply "$ROOT/$patch"
        echo "  aplicado: $patch"
    done

    echo "=== $label: idempotencia (reverse-check sin modificar) ==="
    local i
    for ((i = $#; i > 0; i--)); do
        patch="${!i}"
        git -C "$out" apply --reverse --check "$ROOT/$patch"
    done
    echo "  idempotencia OK: todos los parches tienen reverse-check limpio"
}

run_patch_chain_and_idempotent \
    "$ROOT/opentui/src/opencode" "opentui-0.4.5" \
    "opentui/patches/opentui/android-libc-link.patch" \
    "opentui/patches/opentui/android-termux-port.patch"

run_patch_chain_and_idempotent \
    "$ROOT/opentui/src/kilo" "opentui-0.3.4" \
    "opentui/patches/opentui/android-termux-port-kilo.patch" \
    "opentui/patches/opentui/android-termux-build-kilo.patch"

echo "ALL FRESH-PATH + IDEMPOTENCIA TESTS PASSED"
