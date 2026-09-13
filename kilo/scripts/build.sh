#!/usr/bin/env bash
# kilocode_build.sh - Build Kilo Code CLI for Android/Termux
#
# ADAPTACIÓN 1:1 de opencode_build.sh (mismo proyecto) sustituyendo opencode→kilocode:
#   - Fingerprint incremental con markers prefijados "kilo" (build-fingerprint-kilo)
#   - Fases [1/4]..[4/4]: Android Bun, deps de sistema, source+deps+parches, compile
#   - OpenTUI Android fixes are carried by the pinned OpenTUI source commit.
#   - Cache models.dev con refresh >10080 min
#   - Invocación directa del Android Bun, usando todos los CPUs disponibles
# Diferencias deliberadas (documentadas inline):
#   1. libopentui.so se compila para @opentui/core 0.3.4 (kilo) en un src SEPARADO
#      (build/opentui-src-kilo) — NO se reutiliza build/opentui-src (checkout 0.4.5
#      de opencode). scripts/build-opentui.sh fija OPENTUI_SRC incondicionalmente vía
#      env.sh, así que los pasos esenciales (zig build + validación ELF Android) van inline.
#   2. Instalación de deps en el ROOT del monorepo (kilo es monorepo con workspaces).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PRODUCT=kilo
# Snapshot del override del usuario ANTES de que env.sh defina JOBS (nproc si no viene seteada)
JOBS_OVERRIDE="${JOBS:-}"
source "$SCRIPT_DIR/../../ci/scripts/env.sh" >/dev/null 2>&1

# ── Low-end optimizations (Android OOM killer) ──
# JOBS: usa todos los CPUs del runner por defecto; respeta un override explícito.
export JOBS="${JOBS_OVERRIDE:-$(nproc)}"
export ZIG_JOBS="$JOBS"

# ── Config ──
ANDROID_BUN="${ANDROID_BUN:-${REPO_ROOT}/bun/artifacts/bun-android}"
HOST_BUN="${HOST_BUN:-bun}"

# Kilo Code CLI v7.4.20 (fork de opencode). KILO_SRC por defecto = el checkout ya
# clonado (build/kilocode-src-latest). BUILD_DIR/WORK_DIR vienen de env.sh.
KILO_BRANCH="${KILO_BRANCH:-v7.4.20}"
KILO_REPO="${KILO_REPO:-https://github.com/Kilo-Org/kilocode.git}"
export KILO_SRC="${KILO_SRC:-${REPO_ROOT}/kilo/src}"

# KILO_VERSION default derivado del package.json del checkout (sed + head, sin node).
# Si no hay checkout todavía (primer run) o no se puede leer, fallback 7.4.20.
KILO_VERSION="${KILO_VERSION:-$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$KILO_SRC/packages/opencode/package.json" 2>/dev/null | head -1)}"
KILO_VERSION="${KILO_VERSION:-7.4.20}"

# Opentui para kilo: @opentui/core cataloga 0.3.4 en v7.4.20 (gitHead verificado:
# la tag v0.3.4 de anomalyco/opentui apunta al commit 9b216a58d974704ae638b3043aece2eb70b5ff19,
# confirmado con git ls-remote). OJO: NO reutilizamos build/opentui-src (el checkout
# 0.4.5 de opencode) → src separado build/opentui-src-kilo para no colisionar.
KILO_OPENTUI_REF="${KILO_OPENTUI_REF:-5b3d520550e118fd436f682bd67242b95a05318b}"
KILO_OPENTUI_TAG="${KILO_OPENTUI_TAG:-v0.3.4}"
KILO_OPENTUI_SRC="${KILO_OPENTUI_SRC:-${REPO_ROOT}/opentui/src/kilo}"
KILO_OPENTUI_TARGET="aarch64-linux-android.24"
# libc bionic del NDK para zig (mismo archivo que usa opencode_build.sh)
ZIG_LIBC_FILE="${ZIG_LIBC_FILE:-$WORK_DIR/android-libc.txt}"
ZIG_BIN="${ZIG_BIN:-zig}"

OUTPUT="${KILO_OUTFILE:-${ARTIFACT_DIR}/kilo-android}"
MARKERS="${WORK_DIR}/.markers"
FINGERPRINT_FILE="$MARKERS/build-fingerprint-kilo"
# Cache del snapshot models.dev (el sha va al fingerprint → invalida el binario)
MODELS_CACHE="${WORK_DIR}/models-dev-api.json"
# Deps del build.zig.zon de opentui descargadas con curl (workaround del fetch de
# zig 0.15.2 en Termux/Android, ver fetch_opentui_zig_deps abajo). Persistente en
# build/ para reutilizarse entre runs (idempotente por nombre de archivo).
ZIG_DEPS_DIR="${WORK_DIR}/opentui-zig-deps"
mkdir -p "$MARKERS"

# Put the legacy multi-phase builder behind the shared graph. Its internal
# markers remain useful for phase-level work, while this manifest is the
# authoritative cross-run decision and dependency boundary.
incremental_exec kilo \
    --input "$SCRIPT_DIR/build.sh" --input "$REPO_ROOT/ci/scripts/env.sh" \
    --input "$SCRIPT_DIR/build-kilo-android.ts" \
    --input "$REPO_ROOT/ci/scripts/module-graph-patch.ts" --input "$KILO_SRC" \
    --input "$KILO_OPENTUI_SRC/packages/core/src/zig/build.zig.zon" \
    --input "$KILO_OPENTUI_SRC/packages/core/src/lib/$KILO_OPENTUI_TARGET/libopentui.so" \
    --input "$MODELS_CACHE" --input "$ANDROID_BUN" \
    --value "KILO_VERSION=$KILO_VERSION" \
    --value "KILO_BRANCH=$KILO_BRANCH" \
    --value "KILO_OPENTUI_REF=$KILO_OPENTUI_REF" \
    --output "$OUTPUT"

# ── Compilación incremental: fingerprint ──
# Compara el estado actual (código fuente, scripts, Android Bun, lockfiles) contra
# el fingerprint guardado del último build exitoso. Si coincide Y el binario existe,
# skip total. Los markers (kilo-built/kilo-deps/opentui-kilo-built) son archivos
# VACÍOS de 0 bytes: solo dicen "alguna vez se compiló" y NO detectan cambios de código.
compute_fingerprint() {
    local fp=""
    fp+="fingerprint_version=1\n"

    # kilo HEAD (fallback: hash de src/ si git no está disponible)
    local kilo_head="" kilo_dirty="" st=""
    if git -C "$KILO_SRC" rev-parse HEAD >/dev/null 2>&1; then
        kilo_head="$(git -C "$KILO_SRC" rev-parse HEAD 2>/dev/null)"
        if st="$(git -C "$KILO_SRC" status --porcelain 2>/dev/null)"; then
            kilo_dirty="$(printf '%s' "$st" | sha256sum | cut -c1-16)"
        else
            kilo_dirty="git-err"
        fi
    else
        if [ -d "$KILO_SRC/packages/opencode/src" ]; then
            kilo_head="$(find "$KILO_SRC/packages/opencode/src" -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-40)"
        else
            kilo_head="src-missing"
        fi
        kilo_dirty="git-err"
    fi
    fp+="kilo_head=${kilo_head}\n"
    fp+="kilo_dirty=${kilo_dirty}\n"

    # lockfile + package.json del checkout (raíz y paquete opencode/kilo)
    local kilo_root_lock="missing" kilo_root_pkg="missing"
    local kilo_pkg_lock="missing" kilo_pkg_pkg="missing"
    [ -f "$KILO_SRC/bun.lock" ] && kilo_root_lock="$(sha256sum "$KILO_SRC/bun.lock" | cut -c1-16)"
    [ -f "$KILO_SRC/package.json" ] && kilo_root_pkg="$(sha256sum "$KILO_SRC/package.json" | cut -c1-16)"
    [ -f "$KILO_SRC/packages/opencode/bun.lock" ] && kilo_pkg_lock="$(sha256sum "$KILO_SRC/packages/opencode/bun.lock" | cut -c1-16)"
    [ -f "$KILO_SRC/packages/opencode/package.json" ] && kilo_pkg_pkg="$(sha256sum "$KILO_SRC/packages/opencode/package.json" | cut -c1-16)"
    fp+="kilo_root_bun_lock=${kilo_root_lock}\n"
    fp+="kilo_root_package_json=${kilo_root_pkg}\n"
    fp+="kilo_pkg_bun_lock=${kilo_pkg_lock}\n"
    fp+="kilo_pkg_package_json=${kilo_pkg_pkg}\n"

    # scripts locales del build (cambios aquí disparan rebuild)
    local script="" h="missing"
    for script in \
        "$REPO_ROOT/ci/scripts/env.sh" \
        "$SCRIPT_DIR/build-kilo-android.ts" \
        "$REPO_ROOT/ci/scripts/module-graph-patch.ts" \
        "$SCRIPT_DIR/build.sh" \
        "$REPO_ROOT/opentui/scripts/build-opentui.sh" \
        "$KILO_OPENTUI_SRC/packages/core/src/zig/build.zig.zon"; do
        h="missing"
        if [ -f "$script" ]; then
            h="$(sha256sum "$script" 2>/dev/null | cut -c1-16)"
        fi
        fp+="sha_${script//[^a-zA-Z0-9]/_}=${h}\n"
    done

    # Source commits and the Android OpenTUI output are part of the dependency
    # tree. A source edit therefore invalidates the marker automatically.
    local opentui_so_sha="missing"
    [ -f "$KILO_OPENTUI_SRC/packages/core/src/lib/$KILO_OPENTUI_TARGET/libopentui.so" ] \
        && opentui_so_sha="$(sha256sum "$KILO_OPENTUI_SRC/packages/core/src/lib/$KILO_OPENTUI_TARGET/libopentui.so" | cut -c1-16)"
    fp+="kilo_opentui_so_sha=${opentui_so_sha}\n"

    # KILO_VERSION va baked en el define KILO_VERSION del binario → invalidar si cambia
    fp+="kilo_version=${KILO_VERSION}\n"

    # Opentui 0.3.4 para kilo: ref/tag del checkout + libc file del NDK → afectan al .so
    fp+="kilo_opentui_ref=${KILO_OPENTUI_REF}\n"
    fp+="kilo_opentui_tag=${KILO_OPENTUI_TAG}\n"
    local zig_libc_sha="missing"
    [ -f "$ZIG_LIBC_FILE" ] && zig_libc_sha="$(sha256sum "$ZIG_LIBC_FILE" 2>/dev/null | cut -c1-16)"
    fp+="zig_libc_file=${zig_libc_sha}\n"
    # Versión de zig → afecta al .so de opentui (APIs de build.zig cambian por versión;
    # ya pasó: 0.16 rompió el build de 0.3.4, solo 0.15.2 compila)
    local zig_ver="missing"
    if command -v "$ZIG_BIN" >/dev/null 2>&1; then
        zig_ver="$("$ZIG_BIN" version 2>/dev/null | head -1 || echo missing)"
    fi
    fp+="zig_version=${zig_ver}\n"

    # Snapshot models.dev baked en el define KILO_MODELS_DEV del binario → invalidar
    local models_sha="missing"
    [ -f "$MODELS_CACHE" ] && models_sha="$(sha256sum "$MODELS_CACHE" 2>/dev/null | cut -c1-16)"
    fp+="models_cache_sha=${models_sha}\n"

    # Android Bun runtime (el binario embebido en el standalone)
    local bun_sha="missing"
    [ -f "$ANDROID_BUN" ] && bun_sha="$(sha256sum "$ANDROID_BUN" 2>/dev/null | cut -c1-16)"
    fp+="android_bun=${bun_sha}\n"

    # OTUI Android fix presente en el store .bun (mismo patrón acotado del fail-fast).
    # Acotar a @opentui+core*/: recorrer todo el store (~2.6 GB, ~134k archivos) tardaba
    # ~75s por llamada; el patrón acotado tarda <0.2s.
    local otui_fix=0
    if grep -rlq "OTUI Android fix" "$KILO_SRC"/node_modules/.bun/@opentui+core*/ 2>/dev/null; then
        otui_fix=1
    fi
    fp+="otui_fix_present=${otui_fix}\n"

    # Output: path final del binario + hash del binario actual (si existe)
    local out_sha="missing"
    [ -f "$OUTPUT" ] && out_sha="$(sha256sum "$OUTPUT" 2>/dev/null | cut -c1-16)"
    fp+="output_path=${OUTPUT}\n"
    fp+="output_sha=${out_sha}\n"
    fp+="kilo_minify=${KILO_MINIFY:-1}\n"

    echo -e "$fp"
}

# ── Decisión de skip incremental ──
# Punto más temprano con todas las variables definidas (config arriba).
# - Sin fingerprint previo (o difiere) → se borran los markers para forzar fases 3-4.
# - Fingerprint coincide Y binario existe → SKIP total (nunca silencioso).
FINGERPRINT_NOW="$(compute_fingerprint)"
if [ ! -f "$FINGERPRINT_FILE" ]; then
    echo ":: Sin fingerprint previo — forzando build completo"
    rm -f "$MARKERS/kilo-built" "$MARKERS/kilo-deps" "$MARKERS/opentui-kilo-built"
elif [ -f "$OUTPUT" ] && [ "$FINGERPRINT_NOW" = "$(cat "$FINGERPRINT_FILE")" ]; then
    LAST_HEAD="$(grep '^kilo_head=' "$FINGERPRINT_FILE" | cut -d= -f2-)"
    echo ":: SKIP: sin cambios (último HEAD: ${LAST_HEAD:-<n/a>}, binario: $OUTPUT)"
    ls -lh "$OUTPUT" | awk '{print "   " $5 " " $NF}'
    exit 0
else
    echo ":: Cambio detectado en el fingerprint — recompilando:"
    invalidate_deps=0      # deps/manifiestos/fix del store → reinstall [3/4]
    invalidate_opentui=0   # build-opentui.sh → recompilar .so y re-copiar (vive en [3/4])
    while IFS= read -r line; do
        key="${line%%=*}"
        val_now="${line#*=}"
        val_old="$(grep "^${key}=" "$FINGERPRINT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [ "$val_old" != "$val_now" ]; then
            printf '   - %s: %s → %s\n' "$key" "${val_old:-<ausente>}" "$val_now"
            case "$key" in
                kilo_root_bun_lock|kilo_root_package_json|kilo_pkg_bun_lock|kilo_pkg_package_json|otui_fix_present|fingerprint_version|sha_kilocode_build_sh|kilo_version)
                    invalidate_deps=1 ;;
                sha_scripts_build_opentui_sh|kilo_opentui_so_sha|zig_libc_file|zig_version|kilo_opentui_tag)
                    invalidate_deps=1
                    invalidate_opentui=1 ;;
                kilo_opentui_ref)
                    # ref de opentui 0.3.4 cambió → reinstall deps + recompilar .so
                    invalidate_deps=1
                    invalidate_opentui=1 ;;
            esac
        fi
    done <<< "$FINGERPRINT_NOW"
    rm -f "$MARKERS/kilo-built"
    if [ "$invalidate_deps" = "1" ] || [ "$invalidate_opentui" = "1" ]; then
        rm -f "$MARKERS/kilo-deps"
    fi
    if [ "$invalidate_opentui" = "1" ]; then
        rm -f "$MARKERS/opentui-kilo-built"
        echo "   (build-opentui.sh, zig_version o kilo_opentui_ref cambiaron → libopentui.so 0.3.4 se recompilará y re-copiará)"
    fi
    if [ "$invalidate_deps" = "1" ]; then
        echo "   (deps/manifiestos cambiaron → reinstall de dependencias)"
    fi
fi

# ── Workaround: fetch de deps de opentui (build.zig.zon) con curl ──
# zig 0.15.2 en Termux/Android falla el fetch de dependencias del package manager
# (TemporaryNameServerFailure) por un bug del resolver HTTP interno de zig, NO del
# DNS del sistema (curl descarga la misma URL sin problema). Workaround: descargar
# los tarballs del build.zig.zon con curl y entregárselos a zig como file://
# (mismos hash → zig verifica el contenido localmente sin red).
# Uso: fetch_opentui_zig_deps <zon> → descarga deps a ZIG_DEPS_DIR y reescribe el
# zon con URLs file:// en sitio; el CALLER debe restaurar el zon tras el zig build.
fetch_opentui_zig_deps() {
    local zon="$1"
    [ -f "$zon" ] || { echo "   WARN: build.zig.zon no encontrado ($zon)"; return 0; }

    # Backup del zon para restaurar tras el zig build
    ZON_BACKUP="${ZON_BACKUP:-$zon.orig}"
    cp "$zon" "$ZON_BACKUP"

    mkdir -p "$ZIG_DEPS_DIR"
    local fetched=0
    while IFS='|' read -r name url hash; do
        [ -n "$url" ] || continue
        local fname="$(basename "$url")"
        if [ ! -f "$ZIG_DEPS_DIR/$fname" ]; then
            echo "   fetch deps zig: $name -> $ZIG_DEPS_DIR/$fname"
            if ! curl -fsSL --max-time 180 "$url" -o "$ZIG_DEPS_DIR/$fname"; then
                echo "ERROR: no se pudo descargar $name ($url)"
                return 1
            fi
        fi
        # Reescribir url → file:// (hash intacto; zig verifica contenido local)
        sed -i "s|${url}|file://${ZIG_DEPS_DIR}/${fname}|" "$zon"
        fetched=$((fetched+1))
    done <<< "$(awk '
        BEGIN { in_deps=0 }
        /^[[:space:]]*\.dependencies = \.\{/ { in_deps=1; next }
        in_deps && /^[[:space:]]*\.\}/ { in_deps=0; next }
        in_deps && / = \.\{/ { name=$1; gsub(/[.{]/,"",name); next }
        in_deps && /\.url = / { split($0,a,"\""); url=a[2]; next }
        in_deps && /\.hash = / { split($0,a,"\""); hash=a[2]; print name "|" url "|" hash }
    ' "$ZON_BACKUP")"
    echo "   deps zig: $fetched paquete(s) en file:// ($ZIG_DEPS_DIR)"
}

# [1/4] Android Bun
echo ":: [1/4] Verificando Android Bun..."
[ -f "$ANDROID_BUN" ] || { echo "FATAL: falta Android Bun en .bun-artifact/"; exit 1; }
chmod +x "$ANDROID_BUN"
echo "   OK ($(du -h "$ANDROID_BUN" | cut -f1))"

# [2/4] System deps
echo ":: [2/4] Dependencias del sistema..."
command -v git >/dev/null 2>&1 || pkg install -y git
command -v zig >/dev/null 2>&1 || pkg install -y zig
echo "   OK"

# [3/4] Kilo Code source + deps
echo ":: [3/4] Preparando Kilo Code..."
validate_source_checkout "$KILO_SRC" "$KILO_SOURCE_COMMIT" "Kilo"
echo "   Kilo source exists at $KILO_SRC"

if [ ! -f "$MARKERS/kilo-deps" ]; then
    cd "$KILO_SRC"

    # ── Compilar libopentui.so 0.3.4 con Zig 0.15.2 ──
    # ADAPTACIÓN de opencode_build.sh: opencode llama a scripts/build-opentui.sh,
    # pero ese script NO permite configurar OPENTUI_SRC vía env (env.sh lo fija
    # incondicionalmente a build/opentui-src = checkout 0.4.5 de opencode). Por eso
    # replicamos aquí sus pasos esenciales con un src SEPARADO
    # (build/opentui-src-kilo): clonar v0.3.4, zig build -Dtarget=aarch64-linux-android.24
    # con --libc del NDK y validación de NEEDED libc.so/libm.so. Reutilizamos de
    # build-opentui.sh: mismo binario zig, mismas flags (-Doptimize=ReleaseSafe,
    # --prefix ., --cache-dir en $TMPDIR), mismo manejo de JOBS.
    LIBOPENTUI_KILO=""
    echo "   Compilando libopentui.so 0.3.4 (Zig 0.15.2, target $KILO_OPENTUI_TARGET)..."
    if [ ! -f "$MARKERS/opentui-kilo-built" ]; then
        validate_source_checkout "$KILO_OPENTUI_SRC" "$OPENTUI_KILO_SOURCE_COMMIT" "OpenTUI/Kilo"
        echo "   OpenTUI/Kilo source exists at $KILO_OPENTUI_SRC"

        # Argumento --libc para el target Android (libc Bionic del NDK).
        zig_libc_arg() {
            local target="$1"
            case "$target" in
                *android*)
                    if [ -n "$ZIG_LIBC_FILE" ] && [ -f "$ZIG_LIBC_FILE" ]; then
                        echo "--libc $ZIG_LIBC_FILE"
                    fi
                    ;;
            esac
        }
        if [ -n "$ZIG_LIBC_FILE" ] && [ -f "$ZIG_LIBC_FILE" ]; then
            echo "   Usando libc file: $ZIG_LIBC_FILE (solo para targets android)"
        fi

        cd "$KILO_OPENTUI_SRC/packages/core/src/zig"
        [ -f build.zig ] || { echo "ERROR: build.zig no encontrado en $(pwd)"; exit 1; }

        # Workaround fetch de deps de zig (bug del resolver de zig 0.15.2 en
        # Termux/Android: TemporaryNameServerFailure con curl OK). Descarga los
        # tarballs del build.zig.zon con curl y reescribe el zon a file:// en sitio.
        # El zon original se restaura tras el zig build (ZON_BACKUP).
        fetch_opentui_zig_deps "$(pwd)/build.zig.zon"

        # Caches zig en $TMPDIR para evitar AccessDenied en .zig-cache (Termux),
        # exactamente igual que build-opentui.sh.
        export ZIG_LOCAL_CACHE_DIR="${WORK_DIR}/cache/zig-kilo"
        export ZIG_GLOBAL_CACHE_DIR="${WORK_DIR}/cache/zig-global"
        mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

        # La compilación Zig usa todos los CPUs del job mediante -j$JOBS.
        #
        # ── Bionic stubs (dl/pthread/rt/util viven dentro de libc.so en Android) ──
        # El target aarch64-linux-android.24 fallaba SIEMPRE al enlazar porque zig no
        # encontraba las dynamic system libraries dl/pthread (bionic no las expone como
        # .so separadas). El CI lo resuelve en scripts/setup-runner.sh creando stubs
        # 'INPUT(-lc)' en el sysroot del NDK. Replicamos ese patrón AQUÍ para que el
        # build local sea autosuficiente: se derivan los dirs del ZIG_LIBC_FILE (crt_dir
        # = .../sysroot/usr/lib/aarch64-linux-android/24) y se crean los stubs tanto en
        # sysroot/usr/lib (como CI) como en el crt_dir del target (donde zig 0.15 los
        # busca para android.24). Idempotente: solo si faltan.
        if [ -f "$ZIG_LIBC_FILE" ]; then
            ZIG_CRT_DIR="$(sed -n 's/^crt_dir=//p' "$ZIG_LIBC_FILE" | head -1)"
            if [ -n "$ZIG_CRT_DIR" ] && [ -d "$ZIG_CRT_DIR" ]; then
                NDK_SYSROOT_LIB="$(dirname "$(dirname "$ZIG_CRT_DIR")")"
                echo "   Creando stubs bionic (INPUT(-lc)) en sysroot del NDK..."
                for STUB_DIR in "$NDK_SYSROOT_LIB" "$ZIG_CRT_DIR"; do
                    [ -d "$STUB_DIR" ] || continue
                    for lib in libdl.so libpthread.so librt.so libutil.so libdl.a libpthread.a librt.a libutil.a; do
                        if [ ! -f "$STUB_DIR/$lib" ]; then
                            echo 'INPUT(-lc)' > "$STUB_DIR/$lib"
                            echo "     stub: $(basename "$STUB_DIR")/$lib"
                        fi
                    done
                done
            fi
        fi

        # The pinned OpenTUI tree is authoritative. Keep the old transform
        # block unreachable as a migration guard until it can be deleted in a
        # follow-up that drops support for pre-manifest source trees.
        for REQUIRED_MARKER in \
            "abi != .android" \
            "OTUI Android fix (renderer panic)" \
            "OTUI Android fix (ClassPool.get len guard)" \
            "OTUI Android fix (link refcount simétrico)"; do
            if ! grep -Rqs "$REQUIRED_MARKER" "$KILO_OPENTUI_SRC/packages/core/src/zig"; then
                echo "ERROR: versioned OpenTUI source is missing required marker: $REQUIRED_MARKER" >&2
                exit 1
            fi
        done

        # Android adaptations for OpenTUI/Kilo (renderer panic guard, ClassPool
        # and LinkTracker len/refcount guards, char mask, abi != .android link
        # guard) live in the versioned OpenTUI/Kilo source tree. The marker
        # assertion above fails if any is missing, so the build compiles from
        # source and never mutates the checkout with patches.

        if ! "$ZIG_BIN" build \
            -Dtarget="$KILO_OPENTUI_TARGET" \
            -Doptimize=ReleaseSafe \
            --prefix . \
            --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
            --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
            -j"$JOBS" $(zig_libc_arg "$KILO_OPENTUI_TARGET") 2>&1; then
            echo "ERROR: the Android/Bionic OpenTUI build failed; refusing a musl fallback" >&2
            exit 1
        fi

        # Restaurar build.zig.zon original (el checkout queda limpio para el
        # fingerprint). Si no hay backup (fetch_opentui_zig_deps no corrió), no-op.
        if [ -n "${ZON_BACKUP:-}" ] && [ -f "$ZON_BACKUP" ]; then
            mv "$ZON_BACKUP" "$(pwd)/build.zig.zon"
            unset ZON_BACKUP
            echo "   build.zig.zon restaurado (urls originales)"
        fi

        # Resolver exclusivamente el .so Android/Bionic compilado.
        LIBOPENTUI_KILO="$KILO_OPENTUI_SRC/packages/core/src/lib/$KILO_OPENTUI_TARGET/libopentui.so"
        if [ -z "$LIBOPENTUI_KILO" ] || [ ! -f "$LIBOPENTUI_KILO" ]; then
            echo "ERROR: libopentui.so 0.3.4 no encontrado tras el build zig"
            find "$KILO_OPENTUI_SRC" -name "libopentui.so" -type f 2>/dev/null || true
            exit 1
        fi

        # The source-level Android port must produce a Bionic ELF directly.
        readelf -d "$LIBOPENTUI_KILO" | grep -q 'NEEDED.*libc.so' || {
            echo "ERROR: Android OpenTUI artifact lacks NEEDED libc.so" >&2
            exit 1
        }
        readelf -d "$LIBOPENTUI_KILO" | grep -q 'NEEDED.*libm.so' || {
            echo "ERROR: Android OpenTUI artifact lacks NEEDED libm.so" >&2
            exit 1
        }

        cd "$KILO_SRC"
        touch "$MARKERS/opentui-kilo-built"
        echo "   libopentui.so 0.3.4 compilado"
    else
        echo "   SKIP (ya compilado)"
    fi

    # Buscar únicamente el .so Android/Bionic compilado.
    # Si ya se resolvió en la fase zig (LIBOPENTUI_KILO), se reutiliza.
    BUILT_SO="$LIBOPENTUI_KILO"
    if [ -z "$BUILT_SO" ] || [ ! -f "$BUILT_SO" ]; then
        BUILT_SO="${KILO_OPENTUI_SRC}/packages/core/src/lib/${KILO_OPENTUI_TARGET}/libopentui.so"
    fi

    if [ -n "$BUILT_SO" ] && [ -f "$BUILT_SO" ]; then
        mkdir -p "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl"
        cp "$BUILT_SO" "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so"
        echo "   .so copiado: $(du -h "$BUILT_SO" | cut -f1)"
    fi

    # ── Instalar dependencias (ROOT del monorepo — kilo usa workspaces) ──
    echo "   Instalando dependencias (puede tardar)..."
    # NOTA --ignore-scripts intencional: el postinstall del monorepo (fix-node-pty,
    # setup-git, ripgrep, tree-sitter) apunta a node/glibc; en la condition "bun" se
    # usa bun-pty (no node-pty) y ripgrep es opcional. El store .bun/ se crea aquí.
    if ! "$HOST_BUN" install --frozen-lockfile --ignore-scripts; then
        "$HOST_BUN" install --ignore-scripts
    fi

    # ── Copiar libopentui.so (FALLBACK: .bun/ cache) ──
    # bun install puede reemplazar node_modules con el paquete musl descargado.
    # El artefacto compilado contra Bionic siempre debe volver a imponerse después.
    TARGET_SO="$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so"
    if [ -n "$BUILT_SO" ] && [ -f "$BUILT_SO" ]; then
        mkdir -p "$(dirname "$TARGET_SO")"
        cmp -s "$BUILT_SO" "$TARGET_SO" || cp "$BUILT_SO" "$TARGET_SO"
        echo "   .so Bionic restaurado desde OpenTUI compilado con Zig"
    elif [ ! -f "$TARGET_SO" ]; then
        echo "   Preparando libopentui.so (fallback .bun/ cache)..."
        BUN_CACHE=$(find "$KILO_SRC/node_modules/.bun" -path "*/core-linux-arm64-musl/libopentui.so" -type f 2>/dev/null | head -1)
        if [ -z "$BUN_CACHE" ]; then
            BUN_CACHE=$(find "$KILO_SRC/node_modules/.bun" -name "libopentui.so" -type f 2>/dev/null | head -1)
        fi

        if [ -n "$BUN_CACHE" ]; then
            mkdir -p "$(dirname "$TARGET_SO")"
            cp "$BUN_CACHE" "$TARGET_SO"
            # Copiar package.json y metadatos para que el require() funcione
            PKG_DIR="$(dirname "$BUN_CACHE")"
            [ -f "$PKG_DIR/package.json" ] && cp "$PKG_DIR/package.json" "$(dirname "$TARGET_SO")/"
            [ -f "$PKG_DIR/index.js" ] && cp "$PKG_DIR/index.js" "$(dirname "$TARGET_SO")/"
            [ -f "$PKG_DIR/index.bun.js" ] && cp "$PKG_DIR/index.bun.js" "$(dirname "$TARGET_SO")/"
            echo "   .so copiado desde .bun/ cache ($(du -h "$TARGET_SO" | cut -f1))"
        else
            echo "   ⚠️  libopentui.so no encontrado en .bun/ cache"
        fi
    else
        echo "   libopentui.so ya presente (compilado con Zig)"
    fi

    # ── Copiar también al store .bun/ (Bun embebe desde aquí) ──
    # OJO: va DESPUÉS del bun install (arriba) porque el store .bun/ se crea
    # durante el install. Bun embebe el .so desde el store, no desde node_modules/@opentui/.
    if [ -n "$BUILT_SO" ] && [ -f "$BUILT_SO" ]; then
        for BSO in $(find "$KILO_SRC/node_modules/.bun" -name "libopentui.so" -type f 2>/dev/null); do
            cmp -s "$BUILT_SO" "$BSO" || cp "$BUILT_SO" "$BSO"
            echo "   store .bun/ actualizado: $(basename $(dirname $(dirname $(dirname "$BSO"))))"
        done
    fi

    # ── Validate the copied source-built Android .so ──
    SO=""
    for dir in core-linux-arm64-musl core-linux-arm64 core-linux-x64; do
        candidate="$KILO_SRC/node_modules/@opentui/$dir/libopentui.so"
        [ -f "$candidate" ] && { SO="$candidate"; break; }
    done
    if [ -z "$SO" ]; then
        SO=$(find "$KILO_SRC/node_modules/@opentui" -name "libopentui.so" -type f 2>/dev/null | head -1)
    fi

    if [ -n "$SO" ]; then
        if ! readelf -d "$SO" 2>/dev/null | grep -q "NEEDED.*libc.so"; then
            echo "ERROR: copied OpenTUI .so lacks NEEDED libc.so" >&2
            exit 1
        else
            echo "   .so OK (NEEDED libc.so presente)"
        fi
        # Android/bionic: math functions (pow, etc.) están en libm.so, no en libc.so como musl
        if ! readelf -d "$SO" 2>/dev/null | grep -q "NEEDED.*libm.so"; then
            echo "ERROR: copied OpenTUI .so lacks NEEDED libm.so" >&2
            exit 1
        else
            echo "   .so OK (NEEDED libm.so presente)"
        fi
    else
        echo "   ⚠️  libopentui.so no encontrado"
    fi

    touch "$MARKERS/kilo-deps"
    echo "   deps OK"
else
    echo "   SKIP (deps ya instaladas)"
fi

# [4/4] Compilar
# NOTA: el skip incremental lo decide el fingerprint al inicio del script.
# Los markers kilo-built/kilo-deps se borran ahí cuando el fingerprint
# difiere, así que aquí siempre se compila si se llegó hasta este punto.

# Verificar RAM disponible
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
echo "   RAM disponible: ${MEM_AVAIL}MB"
if [ -n "$MEM_AVAIL" ] && [ "$MEM_AVAIL" -lt 400 ] 2>/dev/null; then
    echo "   ⚠️  RAM baja (<400MB), el build puede fallar por OOM"
    echo "   Intenta: cerrar apps, o ejecutar: export JOBS=1"
fi

echo ":: [4/4] Compilando (puede tardar 5-15 min)..."
# Usa scripts/build-kilo-android.ts con createSolidTransformPlugin (el CLI `bun build
# --compile` no aplica plugins). El Android Bun ejecuta el script y embebe SU runtime
# en el standalone (target = host). Contrato de env vars: KILO_SRC, KILO_OUTFILE,
# KILO_MINIFY, MODELS_DEV_API_JSON (ver header de scripts/build-kilo-android.ts).

# ── Cache del fetch models.dev (el snapshot va baked en el binario) ──
# MODELS_CACHE se define arriba (sección Config); aquí solo se refresca si toca.
MODELS_EMPTY=0
if [ ! -f "$MODELS_CACHE" ] || find "$MODELS_CACHE" -mmin +10080 | grep -q .; then
    echo "   Descargando models.dev/api.json al cache ($MODELS_CACHE)..."
    if curl -fsSL --max-time 90 "https://models.dev/api.json" -o "$MODELS_CACHE.tmp"; then
        mv "$MODELS_CACHE.tmp" "$MODELS_CACHE"
        echo "   cache models.dev actualizado"
    else
        rm -f "$MODELS_CACHE.tmp"
        if [ -f "$MODELS_CACHE" ]; then
            echo "   ⚠️  No se pudo refrescar models.dev — usando cache previo"
        else
            echo "   ⚠️  No se pudo descargar models.dev — el snapshot queda vacío {} (cero providers)"
            MODELS_EMPTY=1
        fi
    fi
fi
if [ -f "$MODELS_CACHE" ]; then
    export MODELS_DEV_API_JSON="$MODELS_CACHE"
    echo "   Usando cache models.dev: $MODELS_CACHE"
fi

cd "$REPO_ROOT"
KILO_OUTFILE="$OUTPUT" KILO_SRC="$KILO_SRC" KILO_VERSION="$KILO_VERSION" KILO_MINIFY="${KILO_MINIFY:-1}" \
    MODELS_DEV_API_JSON="${MODELS_DEV_API_JSON:-}" \
    ANDROID_BUN="$ANDROID_BUN" \
    "$HOST_BUN" run "$SCRIPT_DIR/build-kilo-android.ts" 2>&1

echo ""
echo "✅ Build completado: ${OUTPUT}"
echo "   Ejecutable directo (nativo bionic, sin wrapper): ${OUTPUT}"
echo "   Usalo así: ${OUTPUT} <comando>"
echo "   Probá: ${OUTPUT} --version"
echo "   Probá: ${OUTPUT} tui"
ls -lh "$OUTPUT" | awk '{print "   " $5 " " $NF}'
file "$OUTPUT" | awk -F: '{print "   " $2}'

if [ "$MODELS_EMPTY" = "1" ]; then
    echo ""
    echo "   ⚠️  Snapshot de models.dev quedó vacío (falló la descarga): el binario trae 0 providers."
    echo "      Ejecutá con red: ${OUTPUT} models refresh   (o: kilo models refresh) para cargar los providers."
fi

# Cache: marcar como compilado para futuras ejecuciones (borrar manualmente para recompilar)
touch "$MARKERS/kilo-built"

# ── Fingerprint POST-build ──
# Recalcular con el output_sha del binario recién generado. NUNCA antes del éxito:
# un build fallido no debe dejar el fingerprint como válido para futuros skips.
FINGERPRINT_NOW="$(compute_fingerprint)"
printf '%b' "$FINGERPRINT_NOW" > "$FINGERPRINT_FILE"
echo "   fingerprint actualizado: $FINGERPRINT_FILE"
