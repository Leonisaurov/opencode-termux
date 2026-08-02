#!/usr/bin/env bash
# opencode_build.sh - Build OpenCode for Android/Termux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/env.sh" >/dev/null 2>&1

# ── Low-end optimizations (Android OOM killer) ──
# Forzar jobs=1 para reducir RAM peak (evita OOM killer en devices low-end).
# NOTA: env.sh setea JOBS=$(nproc) por defecto; lo sobreescribimos a 1.
export JOBS=1
export ZIG_JOBS="$JOBS"
# nice para dar prioridad a otros procesos del sistema
renice 19 $$ 2>/dev/null || true
# taskset: restringir a 1 core para reducir RAM peak (evita OOM killer en low-end)
command -v taskset >/dev/null 2>&1 || pkg install -y util-linux 2>/dev/null || echo "taskset no disponible"

# ── Config ──
ANDROID_BUN="${REPO_ROOT}/.bun-artifact/bun-downloaded"
OPENCODE_PKG="${OPENCODE_SRC}/packages/opencode"
OUTPUT="${REPO_ROOT}/opencode-android"
MARKERS="${WORK_DIR}/.markers"
mkdir -p "$MARKERS"

# [1/4] Android Bun
echo ":: [1/4] Verificando Android Bun..."
[ -f "$ANDROID_BUN" ] || { echo "FATAL: falta Android Bun en .bun-artifact/"; exit 1; }
chmod +x "$ANDROID_BUN"
echo "   OK ($(du -h "$ANDROID_BUN" | cut -f1))"

# [2/4] System deps
echo ":: [2/4] Dependencias del sistema..."
command -v patchelf >/dev/null 2>&1 || pkg install -y patchelf
command -v git >/dev/null 2>&1 || pkg install -y git
command -v zig >/dev/null 2>&1 || pkg install -y zig
echo "   OK"

# [3/4] OpenCode source + deps + parches
echo ":: [3/4] Preparando OpenCode..."
if [ ! -d "$OPENCODE_SRC/.git" ]; then
    echo "   Clonando opencode v${OPENCODE_VERSION}..."
    git clone --depth 1 --branch "v${OPENCODE_VERSION}" \
        https://github.com/anomalyco/opencode.git "$OPENCODE_SRC"
fi

if [ ! -f "$MARKERS/opencode-deps" ]; then
    cd "$OPENCODE_SRC"

    # ── Compilar libopentui.so con Zig 0.15.2 ──
    echo "   Compilando libopentui.so (Zig 0.15.2)..."
    if [ ! -f "$MARKERS/opentui-built" ]; then
        # Target bionic (NDK r29) en vez de musl: el .so usa __errno nativo de
        # bionic, ya NO necesita shim errno ni LD_PRELOAD.
        export OPENTUI_TARGET="aarch64-linux-android.24"
        export ZIG_LIBC_FILE="$REPO_ROOT/build/libc-android.txt"
        bash "$SCRIPT_DIR/scripts/build-opentui.sh" 2>&1
        touch "$MARKERS/opentui-built"
        echo "   libopentui.so compilado"
    else
        echo "   SKIP (ya compilado)"
    fi

    # Buscar el .so compilado (prioridad: android.24 → musl → cualquiera)
    BUILT_SO="${OPENTUI_SRC}/packages/core/src/lib/aarch64-linux-android.24/libopentui.so"
    if [ ! -f "$BUILT_SO" ]; then
        BUILT_SO="${OPENTUI_SRC}/packages/core/src/lib/aarch64-linux-musl/libopentui.so"
    fi
    if [ ! -f "$BUILT_SO" ]; then
        BUILT_SO=$(find "$OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null | head -1)
    fi

    if [ -n "$BUILT_SO" ] && [ -f "$BUILT_SO" ]; then
        mkdir -p "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl"
        cp "$BUILT_SO" "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so"
        echo "   .so copiado: $(du -h "$BUILT_SO" | cut -f1)"
    fi

    # ── Instalar dependencias ──
    echo "   Instalando dependencias (puede tardar)..."
    # 1 core para reducir RAM peak (evita OOM killer en low-end)
    if command -v taskset >/dev/null 2>&1; then
        taskset -c 1 "$ANDROID_BUN" install --frozen-lockfile --ignore-scripts 2>/dev/null || \
        taskset -c 1 "$ANDROID_BUN" install --ignore-scripts
    else
        "$ANDROID_BUN" install --frozen-lockfile --ignore-scripts 2>/dev/null || \
        "$ANDROID_BUN" install --ignore-scripts
    fi

    # ── Copiar libopentui.so (FALLBACK: .bun/ cache) ──
    # Método principal: .so compilado con Zig (paso anterior).
    # Este bloque solo se usa si el compilado no llegó a node_modules/.
    # Bun descarga @opentui/core-linux-arm64-musl en .bun/ cache pero no lo copia
    # a node_modules/ porque Android Bun no resuelve optionalDependencies
    # para android-arm64 (busca core-android-arm64 que no existe en npm).
    if [ ! -f "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so" ]; then
        echo "   Preparando libopentui.so (fallback .bun/ cache)..."
        BUN_CACHE=$(find "$OPENCODE_SRC/node_modules/.bun" -path "*/core-linux-arm64-musl/libopentui.so" -type f 2>/dev/null | head -1)
        if [ -z "$BUN_CACHE" ]; then
            BUN_CACHE=$(find "$OPENCODE_SRC/node_modules/.bun" -name "libopentui.so" -type f 2>/dev/null | head -1)
        fi

        if [ -n "$BUN_CACHE" ]; then
            mkdir -p "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl"
            cp "$BUN_CACHE" "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so"
            # Copiar package.json y metadatos para que el require() funcione
            PKG_DIR="$(dirname "$BUN_CACHE")"
            [ -f "$PKG_DIR/package.json" ] && cp "$PKG_DIR/package.json" "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/"
            [ -f "$PKG_DIR/index.js" ] && cp "$PKG_DIR/index.js" "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/"
            [ -f "$PKG_DIR/index.bun.js" ] && cp "$PKG_DIR/index.bun.js" "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/"
            echo "   .so copiado desde .bun/ cache ($(du -h "$OPENCODE_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so" | cut -f1))"
        else
            echo "   ⚠️  libopentui.so no encontrado en .bun/ cache"
        fi
    else
        echo "   libopentui.so ya presente (compilado con Zig)"
    fi

    # ── Copiar también al store .bun/ (Bun embeble desde aquí) ──
    # OJO: va DESPUÉS del bun install (arriba) porque el store .bun/ se crea
    # durante el install. Bun embebe el .so desde el store, no desde node_modules/@opentui/.
    if [ -n "$BUILT_SO" ] && [ -f "$BUILT_SO" ]; then
        for BSO in $(find "$OPENCODE_SRC/node_modules/.bun" -name "libopentui.so" -type f 2>/dev/null); do
            cp "$BUILT_SO" "$BSO"
            echo "   store .bun/ actualizado: $(basename $(dirname $(dirname $(dirname "$BSO"))))"
        done
    fi

    # ── Parchear chunk de @opentui/core para mapear android → linux-musl ──
    # @opentui/core detecta process.platform y busca @opentui/core-android-arm64
    # que no existe. Parcheamos getCurrentNodeAssetTarget() y
    # resolveNativeLibraryPath() en el chunk de Bun.
    echo "   Parcheando @opentui/core para android..."
    OTUI_PATCHED=0
    for CHUNK in $(find "$OPENCODE_SRC/node_modules/@opentui/core" -name "chunk-bun*" -type f ! -name "*.js.map" 2>/dev/null); do
        # Fix 1: getCurrentNodeAssetTarget() mapea android → linux
        # NOTA: Fix 1 usa \n en el reemplazo de sed — requiere GNU sed (funciona en Termux).
        sed -i 's/platform: process\.platform,/\/\/ OTUI Android fix\n    platform: process.platform === "android" ? "linux" : process.platform,/g' "$CHUNK"
        # Fix 2: resolveNativeLibraryPath() acepta android como linux
        sed -i 's/if (process\.platform === "linux") {/if (process.platform === "linux" || process.platform === "android") {/g' "$CHUNK"
        sed -i 's/if (process\.env\.OPENTUI_LIBC === "musl") {/if (process.platform === "android" || process.env.OPENTUI_LIBC === "musl") {/g' "$CHUNK"
        OTUI_PATCHED=$((OTUI_PATCHED+1))
        echo "   chunk parcheado: $(basename "$CHUNK")"
    done
    # También buscar en .bun/ cache por si no está en node_modules directo
    # OJO: el dir del store es @opentui+core@<ver>+<hash>/node_modules/@opentui/core/.
    # El bug del patrón viejo: el segmento del scoped package comienza con '@'
    # (@opentui+core@0.4.5+hash), y el patrón '*/opentui+core*' exigía que
    # 'opentui+core' siguiera inmediatamente a un '/' literal — nunca ocurre.
    for CHUNK in $(find "$OPENCODE_SRC/node_modules/.bun" -path "*/@opentui+core*/chunk-bun*" -type f ! -name "*.js.map" 2>/dev/null); do
        sed -i 's/platform: process\.platform,/\/\/ OTUI Android fix\n    platform: process.platform === "android" ? "linux" : process.platform,/g' "$CHUNK"
        sed -i 's/if (process\.platform === "linux") {/if (process.platform === "linux" || process.platform === "android") {/g' "$CHUNK"
        sed -i 's/if (process\.env\.OPENTUI_LIBC === "musl") {/if (process.platform === "android" || process.env.OPENTUI_LIBC === "musl") {/g' "$CHUNK"
        OTUI_PATCHED=$((OTUI_PATCHED+1))
        echo "   chunk parcheado (.bun): $(basename "$CHUNK")"
    done

    # Verificación fail-fast: el marcador real debe existir en el store.
    # (El contador mide archivos procesados, no sustituciones — no es fiable.)
    OTUI_PATCHED_FILES=$(grep -rl "OTUI Android fix" "$OPENCODE_SRC/node_modules/.bun" 2>/dev/null | wc -l)
    if [ "$OTUI_PATCHED_FILES" -eq 0 ]; then
        echo "ERROR: OTUI Android fix no se aplicó a ningún chunk — abortando (platform=android rompería la TUI)"
        exit 1
    fi
    echo "   OTUI Android fix verificado en $OTUI_PATCHED_FILES archivo(s) del store"

    # ── Aplicar patchelf al .so ──
    SO=""
    for dir in core-linux-arm64-musl core-linux-arm64 core-linux-x64; do
        candidate="$OPENCODE_SRC/node_modules/@opentui/$dir/libopentui.so"
        [ -f "$candidate" ] && { SO="$candidate"; break; }
    done
    if [ -z "$SO" ]; then
        SO=$(find "$OPENCODE_SRC/node_modules/@opentui" -name "libopentui.so" -type f 2>/dev/null | head -1)
    fi

    if [ -n "$SO" ]; then
        if ! readelf -d "$SO" 2>/dev/null | grep -q "NEEDED.*libc.so"; then
            echo "   Aplicando patchelf (NEEDED libc.so)..."
            patchelf --remove-needed libdl.so.2 "$SO" 2>/dev/null || true
            patchelf --remove-needed libpthread.so.0 "$SO" 2>/dev/null || true
            patchelf --remove-needed librt.so.1 "$SO" 2>/dev/null || true
            patchelf --add-needed "libc.so" "$SO"
            echo "   patchelf OK"
        else
            echo "   .so OK (NEEDED libc.so presente)"
        fi
        # Android/bionic: math functions (pow, etc.) están en libm.so, no en libc.so como musl
        if ! readelf -d "$SO" 2>/dev/null | grep -q "NEEDED.*libm.so"; then
            echo "   Aplicando patchelf (NEEDED libm.so)..."
            patchelf --add-needed "libm.so" "$SO"
            echo "   patchelf OK"
        else
            echo "   .so OK (NEEDED libm.so presente)"
        fi
    else
        echo "   ⚠️  libopentui.so no encontrado"
    fi

    touch "$MARKERS/opencode-deps"
    echo "   deps OK"
else
    echo "   SKIP (deps ya instaladas)"
fi

# [4/4] Compilar
# Cache: si el binario ya está compilado, salir sin recompilar nada
if [ -f "$MARKERS/opencode-built" ] && [ -f "$OUTPUT" ]; then
    echo "   SKIP (binario ya compilado, rm $MARKERS/opencode-built para recompilar)"
    ls -lh "$OUTPUT" | awk '{print "   " $5 " " $NF}'
    exit 0
fi

# Verificar RAM disponible
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
echo "   RAM disponible: ${MEM_AVAIL}MB"
if [ -n "$MEM_AVAIL" ] && [ "$MEM_AVAIL" -lt 400 ] 2>/dev/null; then
    echo "   ⚠️  RAM baja (<400MB), el build puede fallar por OOM"
    echo "   Intenta: cerrar apps, o ejecutar: export JOBS=1"
fi

echo ":: [4/4] Compilando (puede tardar 5-15 min)..."
# Usa scripts/build-android.ts con createSolidTransformPlugin (el CLI `bun build --compile` no aplica plugins).
# El Android Bun ejecuta el script y embebe SU runtime en el standalone (target = host).
# build-android.ts lee OPENCODE_OUTFILE del entorno (fallback hardcodeado al mismo path).
# 1 core para reducir RAM peak (evita OOM killer en low-end)
TASKSET_PREFIX=""
if command -v taskset >/dev/null 2>&1; then
    TASKSET_PREFIX="taskset -c 1"
fi
cd "$REPO_ROOT"
OPENCODE_OUTFILE="$OUTPUT" $TASKSET_PREFIX "$ANDROID_BUN" run scripts/build-android.ts 2>&1

echo ""
echo "✅ Build completado: ${OUTPUT}"
echo "   Ejecutable directo (nativo bionic, sin wrapper): ${OUTPUT}"
echo "   Usalo así: ${OUTPUT} <comando>"
ls -lh "$OUTPUT" | awk '{print "   " $5 " " $NF}'
file "$OUTPUT" | awk -F: '{print "   " $2}'

# Cache: marcar como compilado para futuras ejecuciones (borrar manualmente para recompilar)
touch "$MARKERS/opencode-built"
