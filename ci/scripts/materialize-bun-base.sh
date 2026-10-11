#!/usr/bin/env bash
# Materializa la base que `bun build --compile --target=bun-linux-arm64-android`
# embute en el standalone de Android.
#
# La base NO es el asset crudo de la release: el host del port trae ~190 MB de
# DWARF, así que se despoja con --strip-debug (que preserva .dynsym/.dynamic y la
# sección .bun donde 1.4.2 enlaza el grafo). Medições de la sonda B7
# (run 38115779161): 289.397.512 B -> 102.294.896 B, y el standalone resultante
# pesa 104.227.488 B con el marcador de revisión del port dentro.
#
# Bun resuelve la base como UN archivo en su caché de instalación
# (<caché>/bun-linux-aarch64-android-v<versión>). Sembrar esa ruta hace el
# cross-compile hermético: sin red y sin variables de entorno durante el build.
#
# Uso: ci/scripts/materialize-bun-base.sh [--dir <salida>] [--no-seed]
# Imprime en stdout la ruta del ELF despojado. Todo lo demás va a stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# env.sh lee los pins de ci/external-sources.lock; el banner se descarta porque
# este script imprime la ruta de la base en stdout.
source "$SCRIPT_DIR/env.sh" >/dev/null

OUT_DIR="${OPENCODE_BUN_BASE_DIR:-$WORK_DIR/bun-android-base}"
SEED=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) OUT_DIR="$2"; shift 2 ;;
        --dir=*) OUT_DIR="${1#*=}"; shift ;;
        --no-seed) SEED=0; shift ;;
        *) echo "ERROR: argumento desconocido: $1" >&2; exit 2 ;;
    esac
done

RELEASE="$BUN_ANDROID_RELEASE"
ASSET="$BUN_ANDROID_ASSET"
EXPECTED_SHA="$BUN_ANDROID_SHA256"
MARKER="$BUN_ANDROID_REVISION_MARKER"
CACHE_NAME="$BUN_BASE_CACHE_NAME"
URL="$BUN_ANDROID_URL"

mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/${ASSET}.raw"
STRIPPED="$OUT_DIR/${ASSET}-stripped"

# El sha256 del asset fija la descarga; si el crudo ya verifica, no se vuelve a
# pedir (las corridas de un mismo job llaman a este script más de una vez).
if [ -f "$RAW" ] && echo "${EXPECTED_SHA}  $RAW" | sha256sum -c --status -; then
    echo ">>> base cruda ya verificada: $RAW" >&2
else
    echo ">>> descargando la base ${RELEASE}/${ASSET}" >&2
    curl -fsSL --retry 3 -o "$RAW.new" "$URL" >&2
    mv "$RAW.new" "$RAW"
fi
echo "${EXPECTED_SHA}  $RAW" | sha256sum -c - >&2

if [ ! -f "$STRIPPED" ] || ! grep -aq "$MARKER" "$STRIPPED" 2>/dev/null; then
    STRIP=""
    for candidate in "${NDK_TOOLCHAIN:-}/bin/llvm-strip" "$(command -v llvm-strip || true)" \
                     "$(command -v aarch64-linux-gnu-strip || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && STRIP="$candidate" && break
    done
    test -n "$STRIP" || { echo "ERROR: no hay llvm-strip/aarch64-linux-gnu-strip disponible" >&2; exit 1; }
    echo ">>> despojando DWARF con $STRIP" >&2
    "$STRIP" --strip-debug "$RAW" -o "$STRIPPED.new"
    mv "$STRIPPED.new" "$STRIPPED"
    chmod 0755 "$STRIPPED"
fi

# Puertas estructurales: un ELF despojado que no conserve lo que bun necesita
# para el grafo y que linker64 cargue es peor que un fallo de descarga.
{
    echo "--- readelf -h ---"
    readelf -h "$STRIPPED"
    echo "--- readelf -d ---"
    readelf -d "$STRIPPED"
    echo "--- secciones ---"
    readelf -S "$STRIPPED"
} >&2
HEADER="$(readelf -h "$STRIPPED")"
DYNAMIC="$(readelf -d "$STRIPPED")"
SECTIONS="$(readelf -S "$STRIPPED")"
echo "$HEADER" | grep -q 'ELF64'                    || { echo "ERROR: no es ELF64" >&2; exit 1; }
echo "$HEADER" | grep -q 'AArch64'                  || { echo "ERROR: no es AArch64" >&2; exit 1; }
echo "$HEADER" | grep -qE 'Type:[[:space:]]*DYN'    || { echo "ERROR: no es PIE (ET_DYN)" >&2; exit 1; }
echo "$DYNAMIC" | grep -q 'Shared library: \[libc.so\]' || { echo "ERROR: sin DT_NEEDED libc.so (no es bionic)" >&2; exit 1; }
echo "$SECTIONS" | grep -q '\.bun\b'                || { echo "ERROR: se perdió la sección .bun" >&2; exit 1; }
echo "$SECTIONS" | grep -q '\.dynsym'               || { echo "ERROR: se perdió .dynsym" >&2; exit 1; }
test "$(echo "$SECTIONS" | grep -c '\.debug_')" = "0" || { echo "ERROR: aún hay DWARF" >&2; exit 1; }
grep -aq "$MARKER" "$STRIPPED" || { echo "ERROR: falta el marcador de revisión $MARKER" >&2; exit 1; }
echo ">>> base despojada: $(stat -c%s "$STRIPPED") B, marcador $MARKER presente" >&2
sha256sum "$STRIPPED" >&2

if [ "$SEED" = "1" ]; then
    # Todas las rutas de caché que bun puede consultar: la por defecto del runner
    # y la que exporta ci/scripts/env.sh. Se escribe el archivo directo (0755),
    # que es la forma que la sonda comprobó que reutiliza sin descargar.
    for CACHE in "$HOME/.bun/install/cache" "$BUN_INSTALL_CACHE"; do
        [ -n "$CACHE" ] || continue
        mkdir -p "$CACHE"
        install -m 0755 "$STRIPPED" "$CACHE/$CACHE_NAME"
        echo ">>> sembrado $CACHE/$CACHE_NAME" >&2
    done
fi

echo "$STRIPPED"
