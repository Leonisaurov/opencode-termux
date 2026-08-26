#!/usr/bin/env bash
# kilocode_build.sh - Build Kilo Code CLI for Android/Termux
#
# ADAPTACIÓN 1:1 de opencode_build.sh (mismo proyecto) sustituyendo opencode→kilocode:
#   - Fingerprint incremental con markers prefijados "kilo" (build-fingerprint-kilo)
#   - Fases [1/4]..[4/4]: Android Bun, deps de sistema, source+deps+parches, compile
#   - Parches sed "OTUI Android fix" (doble loop node_modules + store .bun/)
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
KILO_OPENTUI_REF="${KILO_OPENTUI_REF:-9b216a58d974704ae638b3043aece2eb70b5ff19}"
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
    --input "$SCRIPT_DIR/build-kilo-android.ts" --input "$KILO_SRC" \
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
        "$SCRIPT_DIR/build.sh" \
        "$REPO_ROOT/opentui/scripts/build-opentui.sh"; do
        h="missing"
        if [ -f "$SCRIPT_DIR/$script" ]; then
            h="$(sha256sum "$SCRIPT_DIR/$script" 2>/dev/null | cut -c1-16)"
        fi
        fp+="sha_${script//[^a-zA-Z0-9]/_}=${h}\n"
    done

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
                sha_scripts_build_opentui_sh|zig_version)
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

# [3/4] Kilo Code source + deps + parches
echo ":: [3/4] Preparando Kilo Code..."
if [ ! -d "$KILO_SRC/.git" ]; then
    echo "   Clonando kilocode ${KILO_BRANCH}..."
    git clone --depth 1 --branch "$KILO_BRANCH" "$KILO_REPO" "$KILO_SRC"
else
    # Checkout existente: si el HEAD no coincide con la branch esperada, advierte
    # pero usa el existente (igual que opencode). El fingerprint ya detecta el
    # cambio de HEAD y disparará rebuild si hace falta.
    KILO_HEAD="$(git -C "$KILO_SRC" rev-parse HEAD 2>/dev/null || true)"
    KILO_EXPECTED="$(git -C "$KILO_SRC" rev-parse "$KILO_BRANCH" 2>/dev/null || true)"
    if [ -n "$KILO_EXPECTED" ] && [ "$KILO_EXPECTED" != "$KILO_HEAD" ]; then
        echo "   ⚠️  checkout existente HEAD=$KILO_HEAD != $KILO_BRANCH ($KILO_EXPECTED) — usando el existente"
        echo "      (el fingerprint detecta el cambio y forzará rebuild)"
    fi
fi

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
        if [ ! -d "$KILO_OPENTUI_SRC/.git" ]; then
            echo "   Clonando opentui ${KILO_OPENTUI_TAG} (gitHead $KILO_OPENTUI_REF)..."
            git clone --depth 1 --branch "$KILO_OPENTUI_TAG" \
                https://github.com/anomalyco/opentui.git "$KILO_OPENTUI_SRC"
        else
            echo "   opentui-kilo source existe en $KILO_OPENTUI_SRC"
        fi

        # Apply the repository-owned Android/Termux renderer port. Kilo's
        # Android checkout must use the same source-level fixes as the locally
        # validated port; do not replace it with a musl binary.
        KILO_OTUI_PORT_PATCH="$REPO_ROOT/opentui/patches/opentui/android-termux-port-kilo.patch"
        KILO_OTUI_BUILD_PATCH="$REPO_ROOT/opentui/patches/opentui/android-termux-build-kilo.patch"
        cd "$KILO_OPENTUI_SRC"
        if git apply --check "$KILO_OTUI_PORT_PATCH" >/dev/null 2>&1; then
            git apply "$KILO_OTUI_PORT_PATCH"
        elif git apply --reverse --check "$KILO_OTUI_PORT_PATCH" >/dev/null 2>&1; then
            echo "   OpenTUI Kilo Android/Termux source port already applied"
        else
            echo "ERROR: OpenTUI Kilo Android/Termux source port does not apply cleanly" >&2
            exit 1
        fi
        if git apply --check "$KILO_OTUI_BUILD_PATCH" >/dev/null 2>&1; then
            git apply "$KILO_OTUI_BUILD_PATCH"
        elif git apply --reverse --check "$KILO_OTUI_BUILD_PATCH" >/dev/null 2>&1; then
            echo "   OpenTUI Kilo Android build patch already applied"
        else
            echo "ERROR: OpenTUI Kilo Android build patch does not apply cleanly" >&2
            exit 1
        fi

        # Verificar que el checkout coincida con el commit esperado (warning, no abort)
        KILO_OTUI_HEAD="$(git -C "$KILO_OPENTUI_SRC" rev-parse HEAD 2>/dev/null || true)"
        if [ -n "$KILO_OTUI_HEAD" ] && [ "$KILO_OTUI_HEAD" != "$KILO_OPENTUI_REF" ]; then
            echo "   ⚠️  opentui-kilo HEAD=$KILO_OTUI_HEAD != $KILO_OPENTUI_REF — compilando el checkout existente"
        fi

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
        KILO_TMP_ROOT="$(mktemp -d "$TMPDIR/opencode-termux-kilo.XXXXXX")"
        export ZIG_LOCAL_CACHE_DIR="$KILO_TMP_ROOT/zig-local"
        export ZIG_GLOBAL_CACHE_DIR="$KILO_TMP_ROOT/zig-global"
        trap 'rm -rf "$KILO_TMP_ROOT"' EXIT
        rm -rf "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
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

        # ── Guard dl/pthread en build.zig (port del fix de 0.4.5) ──
        # El target aarch64-linux-android.24 cae en el branch ".linux" de
        # addNativeAudioDependencies (zig modela android con os.tag=linux, abi=android)
        # y 0.3.4 linkea -ldl -lpthread como librerías dinámicas separadas → zig falla
        # con "unable to find dynamic system library 'dl'/'pthread'" (bionic no las
        # expone como .so separadas; viven en libc.so). El build.zig de opentui 0.4.5
        # ya lo arregla con el guard "if (target.result.abi != .android)". Lo portamos
        # aquí (idempotente: si el guard ya está presente, no se toca nada).
        BUILD_ZIG="build.zig"
        if grep -q "abi != .android" "$BUILD_ZIG"; then
            echo "   build.zig: guard dl/pthread (abi != .android) ya presente"
        elif grep -q "artifact.linkSystemLibrary(\"dl\");" "$BUILD_ZIG"; then
            echo "   build.zig: aplicando guard dl/pthread (abi != .android)..."
            python3 - "$BUILD_ZIG" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    s = f.read()
old = '''        .linux => {
            artifact.linkSystemLibrary("dl");
            artifact.linkSystemLibrary("pthread");
        },'''
new = '''        .linux => {
            // Android: dl y pthread están fusionados en libc.so (bionic) — no
            // linkearlas como system libraries separadas (no existen como .so).
            // Port del fix de 0.4.5 (build/opentui-src): sin este guard, zig busca
            // libdl.so/libpthread.so dinámicas y falla con "unable to find dynamic
            // system library 'dl'/'pthread'" para aarch64-linux-android.24.
            if (target.result.abi != .android) {
                artifact.linkSystemLibrary("dl");
                artifact.linkSystemLibrary("pthread");
            }
        },'''
assert old in s, f"FIX GUARD: patrón dl/pthread no encontrado en {p}"
s = s.replace(old, new, 1)
with open(p, "w", encoding="utf-8") as f:
    f.write(s)
print("   guard aplicado")
PYEOF
        else
            echo "   ⚠️  WARN: build.zig sin linkSystemLibrary(dl) — el guard no aplica (¿build.zig cambiado?)"
        fi

        # ── OTUI Android fix (renderer panic): catch defensivo en renderer.zig ──
        # kilo-android SIGABRT tras un rato de uso: el renderer nativo de OpenTUI
        # (Zig) panica deliberadamente cuando un gid del GraphemePool ya no existe
        # (slot liberado/reutilizado tras scroll/redibujado → generation mismatch o
        # gid corrupto). std.debug.panic + performShutdownSequence → abort() = crash
        # de un error RECUPERABLE. El MISMO archivo tiene rutas hermanas defensivas
        # (~1106 catch{...continue} y ~1827 catch &[_]u8{}); replicamos la segunda
        # (preserva el syncCell del buffer de diff — un `continue` aquí saltaría el
        # bookkeeping runLength/syncCell y causaría re-render infinito de la celda).
        # Idempotente: si el marcador ya está, no se toca nada. Fail-fast: si el
        # patrón panicking no matchea, aborta (¿renderer zig cambiado upstream?).
        RENDERER_ZIG="$KILO_OPENTUI_SRC/packages/core/src/zig/renderer.zig"
        if grep -q "OTUI Android fix (renderer panic)" "$RENDERER_ZIG"; then
            echo "   renderer.zig: catch defensivo (renderer panic) ya presente"
        elif grep -q "no grapheme bytes in pool for gid" "$RENDERER_ZIG"; then
            echo "   renderer.zig: aplicando catch defensivo (renderer panic)..."
            python3 - "$RENDERER_ZIG" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    s = f.read()
# Patrón del panic en prepareRenderFrameWithWriter (idéntico en 0.3.4 y 0.4.5)
pattern = re.compile(
    r'(const bytes = self\.pool\.get\(gid\) )catch \|err\| \{\n'
    r'(?:[ \t]*)self\.performShutdownSequence\(\);\n'
    r'(?:[ \t]*)std\.debug\.panic\("Fatal: no grapheme bytes in pool for gid \{d\}: \{\}", \.\{ gid, err \}\);\n'
    r'(?:[ \t]*)\};'
)
if not pattern.search(s):
    sys.exit(f"FIX RENDERER PANIC: patrón panicking no encontrado en {p}")
replacement = (
    r'\1catch &[_]u8{};  // OTUI Android fix (renderer panic): gid no está en el GraphemePool'
)
s2, n = pattern.subn(replacement, s, count=1)
if n != 1:
    sys.exit(f"FIX RENDERER PANIC: sustitución falló en {p}")
with open(p, "w", encoding="utf-8") as f:
    f.write(s2)
print("   catch defensivo aplicado")
PYEOF
            grep -q "OTUI Android fix (renderer panic)" "$RENDERER_ZIG" || {
                echo "ERROR: marcador del fix no verificado tras aplicar — abortando"
                exit 1
            }
        else
            echo "   ⚠️  WARN: renderer.zig sin patrón panicking — el fix no aplica (¿renderer zig cambiado?)"
        fi

        # ── OTUI Android fix (pool hardening): len guard + tracker + char mask ──
        # La TUI crasheaba (SIGABRT) por panics de Zig en el GraphemePool/LinkTracker
        # tras un rato de uso (mismo bug de fondo que el renderer panic de arriba: el
        # pool recicla slots mientras un buffer aún referencia su gid → UAF lógico /
        # refcount corrupto en 0.3.4). Estos parches son la red de seguridad — NUNCA
        # abortar el .so por estos fallos:
        #   (a) ClassPool.get valida header_ptr.len (owned ≤ slot_capacity; unowned ≤
        #       MAX_UNOWNED_LEN=4096) → error.InvalidId en vez de devolver un slice con
        #       len gigante que reventaba el Writer de Zig ("integer does not fit...").
        #   (b) GraphemeTracker/LinkTracker: std.debug.panic → degradación (catch {}/
        #       return) + saturación de cuentas en maxInt + decref sin `unreachable`.
        #   (c) renderer.zig: máscara `cell.char & 0x1F_FFFF` antes del @intCast a u21
        #       (un cell.char corrupto >0x10FFFF panica en ReleaseSafe).
        # Idempotente por marcador (cada reemplazo se salta si su texto ya está).
        # Fail-fast: si un patrón original no matchea en un checkout fresco, aborta.
        GRAPHEME_ZIG="$KILO_OPENTUI_SRC/packages/core/src/zig/grapheme.zig"
        LINK_ZIG="$KILO_OPENTUI_SRC/packages/core/src/zig/link.zig"
        if grep -q "OTUI Android fix (ClassPool.get len guard)" "$GRAPHEME_ZIG" \
            && grep -q "OTUI Android fix (degradar panic tracker)" "$GRAPHEME_ZIG" \
            && grep -q "OTUI Android fix (degradar panic tracker)" "$LINK_ZIG" \
            && grep -q "OTUI Android fix (char mask)" "$RENDERER_ZIG"; then
            echo "   pool hardening (len guard + tracker + char mask) ya presente"
        else
            echo "   aplicando pool hardening (len guard + tracker + char mask)..."
            python3 - "$GRAPHEME_ZIG" "$LINK_ZIG" "$RENDERER_ZIG" <<'PYEOF'
import sys

grapheme_p, link_p, renderer_p = sys.argv[1], sys.argv[2], sys.argv[3]

def apply(path, repls):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    changed = False
    for marker, old, new in repls:
        if marker in s:
            continue  # ya aplicado (idempotente)
        if old not in s:
            sys.exit(f"FIX POOL HARDENING: patrón para '{marker}' no encontrado en {path}")
        s = s.replace(old, new)
        changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print(f"   {path}: parcheado")
    else:
        print(f"   {path}: ya parcheado")

M_LEN = "OTUI Android fix (ClassPool.get len guard)"
M_PANIC = "OTUI Android fix (degradar panic tracker)"
M_CHAR = "OTUI Android fix (char mask)"

# (a) MAX_UNOWNED_LEN const antes de ClassPool.get
const_old = (
    "        pub fn get(\n"
    "            self: *ClassPool,\n"
    "            slot_index: u32,\n"
    "            expected_generation: u32,\n"
    "        ) GraphemePoolError![]const u8 {"
)
const_new = (
    "        // OTUI Android fix (ClassPool.get len guard): límite plausible para el len de\n"
    "        // slots unowned. Un slot unowned solo almacena un puntero externo; su len es la\n"
    "        // longitud del texto referenciado y PUEDE superar slot_capacity (el test\n"
    "        // \"allocUnowned large text\" usa 1000 bytes). 4096 es generoso para un fragmento\n"
    "        // de texto/grapheme y acota slices gigantes corruptos (la causa del SIGABRT).\n"
    "        const MAX_UNOWNED_LEN: u16 = 4096;\n"
    "\n" + const_old
)
# (a) len guard dentro de ClassPool.get
guard_old = "            if (header_ptr.is_owned == 1) assert(header_ptr.len <= self.slot_capacity);"
guard_new = (
    "            // OTUI Android fix (ClassPool.get len guard): el bug de fondo es que el\n"
    "            // pool recicla slots mientras un buffer aún referencia su gid (UAF lógico\n"
    "            // / refcount de 0.3.4). Si un header queda corrupto, el assert de abajo\n"
    "            // panica (SIGABRT en ReleaseSafe) y para slots unowned NO había validación\n"
    "            // → pool.get devolvía un slice con len gigante que reventaba el Writer de\n"
    "            // Zig (\"integer does not fit in destination type\" en prepareRenderFrame-\n"
    "            // WithWriter). Esta validación + la degradación del renderer (catch\n"
    "            // &[_]u8{}) son la red de seguridad: header inválido → error.InvalidId.\n"
    "            if (header_ptr.is_owned == 1) {\n"
    "                if (header_ptr.len > self.slot_capacity) return GraphemePoolError.InvalidId;\n"
    "            } else {\n"
    "                if (header_ptr.len > MAX_UNOWNED_LEN) return GraphemePoolError.InvalidId;\n"
    "            }"
)
# (b) decref: quitar `unreachable`
decref_old = (
    "            if (self.classes[class_id].getRefcount(slot_index, generation)) |_| {\n"
    "                unreachable;\n"
    "            } else |err| {\n"
    "                assert(err == GraphemePoolError.InvalidId);\n"
    "            }"
)
decref_new = (
    "            // OTUI Android fix (degradar panic tracker): tras un decref que liberó el\n"
    "            // slot, getRefcount debe fallar con InvalidId. En estado corrupto podía\n"
    "            // devolver un valor → `unreachable` (abort en ReleaseSafe). Degradamos sin\n"
    "            // abortar: el slot puede quedar residual, pero la TUI sigue viva.\n"
    "            _ = self.classes[class_id].getRefcount(slot_index, generation) catch {};"
)
# (b) decRefAll
decrefall_old = (
    "            self.pool.decref(idp.*) catch |err| {\n"
    "                std.debug.panic(\"GraphemeTracker.decRefAll decref failed: {}\\n\", .{err});\n"
    "            };"
)
decrefall_new = (
    "            // OTUI Android fix (degradar panic tracker): decref fallido (slot ya\n"
    "            // liberado/reciclado — refcount/generation corrupto) era SIGABRT.\n"
    "            // Degradamos sin abortar; el refcount del pool puede quedar residual\n"
    "            // pero la TUI sigue viva.\n"
    "            self.pool.decref(idp.*) catch {};"
)
# (b) add: getOrPut
add_gop_old = (
    "        const res = self.used_ids.getOrPut(id) catch |err| {\n"
    "            std.debug.panic(\"GraphemeTracker.add failed: {}\\n\", .{err});\n"
    "        };"
)
add_gop_new = (
    "        // OTUI Android fix (degradar panic tracker): OOM en getOrPut era SIGABRT.\n"
    "        // Degradamos: este id queda sin trackear (no abort).\n"
    "        const res = self.used_ids.getOrPut(id) catch return;"
)
# (b) add: incref + saturar else
add_inc_old = (
    "            res.value_ptr.* = 1;\n"
    "            self.pool.incref(id) catch |err| {\n"
    "                std.debug.panic(\"GraphemeTracker.add incref failed: {}\\n\", .{err});\n"
    "            };\n"
    "        } else {\n"
    "            assert(res.value_ptr.* > 0);\n"
    "            assert(res.value_ptr.* < std.math.maxInt(u32));\n"
    "            res.value_ptr.* += 1;\n"
    "        }"
)
add_inc_new = (
    "            res.value_ptr.* = 1;\n"
    "            self.pool.incref(id) catch {\n"
    "                // OTUI Android fix (degradar panic tracker): incref fallido (slot ya\n"
    "                // reciclado, refcount/generation corrupto) era SIGABRT. Des-tracking\n"
    "                // del id para no dejar ref fantasma (count 0) y seguimos sin abortar.\n"
    "                _ = self.used_ids.remove(id);\n"
    "                return;\n"
    "            };\n"
    "        } else {\n"
    "            // OTUI Android fix (degradar panic tracker): saturar en maxInt en vez de\n"
    "            // abortar por overflow (cuenta corrupta en estado degradado).\n"
    "            if (res.value_ptr.* < std.math.maxInt(u32)) {\n"
    "                res.value_ptr.* += 1;\n"
    "            }\n"
    "        }"
)
# (b) remove: count corrupto + decref
rem_cnt_old = (
    "        assert(count_ptr.* > 0);\n"
    "        if (count_ptr.* > 1) {\n"
    "            count_ptr.* -= 1;\n"
    "            assert(count_ptr.* > 0);\n"
    "            return;\n"
    "        }"
)
rem_cnt_new = (
    "        // OTUI Android fix (degradar panic tracker): cuenta corrupta (0) en estado\n"
    "        // degradado: des-tracking en vez de abortar el assert.\n"
    "        if (count_ptr.* == 0) {\n"
    "            _ = self.used_ids.remove(id);\n"
    "            return;\n"
    "        }\n"
    "        if (count_ptr.* > 1) {\n"
    "            count_ptr.* -= 1;\n"
    "            return;\n"
    "        }"
)
rem_dec_old = (
    "            self.pool.decref(id) catch |err| {\n"
    "                std.debug.panic(\"GraphemeTracker.remove decref failed: {}\\n\", .{err});\n"
    "            };"
)
rem_dec_new = (
    "            // OTUI Android fix (degradar panic tracker): decref fallido (slot ya\n"
    "            // liberado/reciclado) era SIGABRT. El id ya se quitó del tracking; el\n"
    "            // refcount del pool puede quedar residual pero no abortamos.\n"
    "            self.pool.decref(id) catch {};"
)
# (b) getTotalGraphemeBytes
bytes_old = (
    "            } else |err| {\n"
    "                std.debug.panic(\"GraphemeTracker.getTotalGraphemeBytes get failed: {}\\n\", .{err});\n"
    "            }"
)
bytes_new = (
    "            } else |_| {\n"
    "                // OTUI Android fix (degradar panic tracker): get fallido (slot ya\n"
    "                // liberado/reciclado) era SIGABRT. Degradamos: 0 bytes para este id.\n"
    "            }"
)
apply(grapheme_p, [
    ("const MAX_UNOWNED_LEN: u16 = 4096;", const_old, const_new),
    ("if (header_ptr.len > MAX_UNOWNED_LEN) return GraphemePoolError.InvalidId;", guard_old, guard_new),
    ("_ = self.classes[class_id].getRefcount(slot_index, generation) catch {};", decref_old, decref_new),
    ("self.pool.decref(idp.*) catch {};", decrefall_old, decrefall_new),
    ("const res = self.used_ids.getOrPut(id) catch return;", add_gop_old, add_gop_new),
    ("if (res.value_ptr.* < std.math.maxInt(u32)) {", add_inc_old, add_inc_new),
    ("if (count_ptr.* == 0) {", rem_cnt_old, rem_cnt_new),
    ("self.pool.decref(id) catch {};", rem_dec_old, rem_dec_new),
    ("} else |_| {", bytes_old, bytes_new),
])

# link.zig: addCellRef getOrPut + saturar else
link_old = (
    "        const res = self.used_ids.getOrPut(id) catch |err| {\n"
    "            std.debug.panic(\"LinkTracker.addCellRef getOrPut failed: {}\\n\", .{err});\n"
    "        };\n"
    "        if (!res.found_existing) {\n"
    "            // First time seeing this ID - try to incref in pool\n"
    "            self.pool.incref(id) catch {\n"
    "                // Invalid ID (not allocated in pool) - silently ignore\n"
    "                // This can happen with garbage in attribute bits\n"
    "                return;\n"
    "            };\n"
    "            res.value_ptr.* = 1;\n"
    "        } else {\n"
    "            res.value_ptr.* += 1;\n"
    "        }"
)
link_new = (
    "        // OTUI Android fix (degradar panic tracker): OOM en getOrPut era SIGABRT.\n"
    "        // Degradamos: este id queda sin trackear (no abort).\n"
    "        const res = self.used_ids.getOrPut(id) catch return;\n"
    "        if (!res.found_existing) {\n"
    "            // First time seeing this ID - try to incref in pool\n"
    "            self.pool.incref(id) catch {\n"
    "                // Invalid ID (not allocated in pool) - silently ignore\n"
    "                // This can happen with garbage in attribute bits\n"
    "                // OTUI Android fix (degradar panic tracker): des-tracking del id para\n"
    "                // no dejar entrada fantasma (count 0) en el tracker.\n"
    "                _ = self.used_ids.remove(id);\n"
    "                return;\n"
    "            };\n"
    "            res.value_ptr.* = 1;\n"
    "        } else {\n"
    "            // OTUI Android fix (degradar panic tracker): saturar en maxInt en vez de\n"
    "            // abortar por overflow (cuenta corrupta en estado degradado).\n"
    "            if (res.value_ptr.* < std.math.maxInt(u32)) {\n"
    "                res.value_ptr.* += 1;\n"
    "            }\n"
    "        }"
)
apply(link_p, [
    ("const res = self.used_ids.getOrPut(id) catch return;", link_old, link_new),
])

# renderer.zig: máscara char en ambos sitios @intCast(cell.char)
ren_old = (
    "                    const len = std.unicode.utf8Encode(@intCast(cell.char), &utf8Buf) catch 1;\n"
    "                    writer.writeAll(utf8Buf[0..len]) catch {};"
)
ren_new = (
    "                    // OTUI Android fix (char mask): máscara a u21 antes del @intCast —\n"
    "                    // un cell.char corrupto (>0x10FFFF) hacía panic \"integer does not\n"
    "                    // fit in destination type\" (ReleaseSafe) → SIGABRT. Tras la máscara\n"
    "                    // utf8Encode devuelve error para codepoints inválidos y degradamos\n"
    "                    // a un espacio (nunca abort).\n"
    "                    const codepoint: u21 = @intCast(cell.char & 0x1F_FFFF);\n"
    "                    var len: usize = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;\n"
    "                    if (len == 0) {\n"
    "                        utf8Buf[0] = ' ';\n"
    "                        len = 1;\n"
    "                    }\n"
    "                    writer.writeAll(utf8Buf[0..len]) catch {};"
)
apply(renderer_p, [
    ("var len: usize = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;", ren_old, ren_new),
])

# Verificación final fail-fast por marcador
for path, markers in (
    (grapheme_p, (M_LEN, M_PANIC)),
    (link_p, (M_PANIC,)),
    (renderer_p, (M_CHAR,)),
):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    for m in markers:
        if m not in s:
            sys.exit(f"FIX POOL HARDENING: marcador '{m}' no verificado en {path}")
print("   pool hardening verificado")
PYEOF
            grep -q "OTUI Android fix (ClassPool.get len guard)" "$GRAPHEME_ZIG" || {
                echo "ERROR: pool hardening no aplicado — abortando"
                exit 1
            }
        fi

        # ── OTUI Android fix (writer len guard + LinkPool.get len guard) ──
        # Blindaje COMPLETO de la clase de crash del Writer de Zig. Tras el pool
        # hardening, el usuario reprodujo OTRO SIGABRT en el MISMO punto que el crash 2:
        #     std/Io/Writer.zig @memcpy(w.buffer[w.end..][0..bytes.len], bytes)
        #     prepareRenderFrameWithWriter (renderer.zig)
        # Causa: prepareRenderFrameWithWriter escribe al Writer NO solo los bytes del
        # grapheme (ya blindados) sino también url_bytes del LinkPool (lp.get(currentLinkId)
        # → writer.print {s}) y otros slices. El LinkPool NO tenía len guard equivalente al
        # ClassPool.get → podía devolver un slice con len corrupto (mismo UAF lógico por
        # reciclado de slots en 0.3.4) → el @memcpy panica "integer does not fit in
        # destination type" → SIGABRT. Este bloque añade la red de seguridad final:
        #   (a) LinkPool.get valida header_ptr.len (len > slot_capacity → InvalidId).
        #   (b) guard url_bytes (OSC 8 sin URL si len<=0 o >512, mantiene estado del link).
        #   (c) guard bytes grapheme (len <= 4096 = MAX_UNOWNED_LEN) SOLO en
        #       prepareRenderFrameWithWriter (ancla el catch &[_]u8{} del fix renderer
        #       panic — único; la ruta hermana de split scrollback usa `catch {`).
        #   (d) clamp utf8Buf (len > utf8Buf.len → 0) en los 2 sitios del char mask.
        # Idempotente por marcador; fail-fast si un patrón original no matchea.
        # El bug de fondo (UAF lógico: pools que reciclan slots mientras un buffer aún
        # referencia su id/gid — refcount/GC de opentui) queda como investigación
        # pendiente; estos guards son la red de seguridad.
        if grep -q "OTUI Android fix (LinkPool.get len guard)" "$LINK_ZIG" \
            && grep -q "OTUI Android fix (writer len guard): red de seguridad final" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (writer len guard): si un slot reciclado" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (writer len guard): clamp defensivo" "$RENDERER_ZIG"; then
            echo "   writer len guard + LinkPool.get len guard ya presentes"
        else
            echo "   aplicando writer len guard + LinkPool.get len guard..."
            python3 - "$LINK_ZIG" "$RENDERER_ZIG" <<'PYEOF'
import re, sys

link_p, renderer_p = sys.argv[1], sys.argv[2]

def apply(path, repls):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    changed = False
    for marker, old, new in repls:
        if marker in s:
            continue  # ya aplicado (idempotente)
        if old not in s:
            sys.exit(f"FIX WRITER GUARD: patrón para '{marker}' no encontrado en {path}")
        s = s.replace(old, new)
        changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print(f"   {path}: parcheado")
    else:
        print(f"   {path}: ya parcheado")

M_LINKLEN = "OTUI Android fix (LinkPool.get len guard)"
M_URL = "OTUI Android fix (writer len guard): red de seguridad final"
M_BYTES = "OTUI Android fix (writer len guard): si un slot reciclado"
M_UTF8 = "OTUI Android fix (writer len guard): clamp defensivo"

# (a) LinkPool.get len guard — patrón idéntico en 0.3.4 y 0.4.5
link_old = (
    "        if (header_ptr.generation != unpacked.generation) return LinkPoolError.WrongGeneration;\n"
    "\n"
    "        const data_ptr = @as([*]u8, @ptrCast(p)) + @sizeOf(SlotHeader);\n"
    "        return data_ptr[0..header_ptr.len];"
)
link_new = (
    "        if (header_ptr.generation != unpacked.generation) return LinkPoolError.WrongGeneration;\n"
    "\n"
    "        // OTUI Android fix (LinkPool.get len guard): mismo patrón que ClassPool.get\n"
    "        // (grapheme.zig). El pool recicla slots mientras un buffer aún referencia su id\n"
    "        // (UAF lógico / refcount de opentui 0.3.4 — causa raíz pendiente de investigación).\n"
    "        // Si un header queda corrupto, header_ptr.len podría ser gigante → el slice\n"
    "        // devuelto reventaba el Writer de Zig (\"integer does not fit in destination type\"\n"
    "        // en prepareRenderFrameWithWriter → SIGABRT). Un link nunca supera slot_capacity\n"
    "        // (MAX_URL_LENGTH=512, validado en alloc); len mayor = header corrupto →\n"
    "        // error.InvalidId (el renderer degrada con `else |_|`).\n"
    "        if (header_ptr.len > self.slot_capacity) return LinkPoolError.InvalidId;\n"
    "\n"
    "        const data_ptr = @as([*]u8, @ptrCast(p)) + @sizeOf(SlotHeader);\n"
    "        return data_ptr[0..header_ptr.len];"
)
apply(link_p, [(M_LINKLEN, link_old, link_new)])

# (b) url_bytes guard en prepareRenderFrameWithWriter (idéntico en 0.3.4 y 0.4.5)
url_old = (
    "                        if (lp.get(currentLinkId)) |url_bytes| {\n"
    "                            writer.print(\"\\x1b]8;id={d};{s}\\x1b\\\\\", .{ currentLinkId, url_bytes }) catch {};\n"
    "                        } else |_| {"
)
url_new = (
    "                        if (lp.get(currentLinkId)) |url_bytes| {\n"
    "                            // OTUI Android fix (writer len guard): red de seguridad final\n"
    "                            // para el @memcpy del Writer. Aunque LinkPool.get ya valida el\n"
    "                            // header (len <= slot_capacity), ningún slice dinámico debe\n"
    "                            // llegar al Writer con len sospechoso (panic \"integer does not\n"
    "                            // fit\" → SIGABRT). URL vacía/corrupta → abrimos el hyperlink\n"
    "                            // OSC 8 sin contenido (mantiene el estado del link para que el\n"
    "                            // cierre `\\x1b]8;;\\x1b\\\\` posterior siga siendo correcto).\n"
    "                            if (url_bytes.len > 0 and url_bytes.len <= 512) {\n"
    "                                writer.print(\"\\x1b]8;id={d};{s}\\x1b\\\\\", .{ currentLinkId, url_bytes }) catch {};\n"
    "                            } else {\n"
    "                                writer.print(\"\\x1b]8;id={d};\\x1b\\\\\", .{currentLinkId}) catch {};\n"
    "                            }\n"
    "                        } else |_| {"
)
apply(renderer_p, [(M_URL, url_old, url_new)])

# (c) bytes grapheme guard — SOLO prepareRenderFrameWithWriter. Ancla tolerante:
# el fix renderer panic (bloque anterior) puede haber dejado el comentario inline
# (`catch &[_]u8{};  // OTUI Android fix (renderer panic)...`) o un comentario en
# bloque encima (checkouts parcheados por versiones previas). La ruta hermana de
# split scrollback usa `catch {` con writeByte(' ') y continue, y la de feed a 24
# espacios usa un `if` inline sin `{` → la única forma `if (bytes.len > 0) {` a 20
# espacios precedida del catch &[_]u8{} es la de prepareRenderFrameWithWriter.
M_BYTES = "OTUI Android fix (writer len guard): si un slot reciclado"
if M_BYTES not in open(renderer_p, encoding="utf-8").read():
    with open(renderer_p, encoding="utf-8") as f:
        rsrc = f.read()
    m = re.search(
        r'(const bytes = self\.pool\.get\(gid\) catch &\[_\]u8\{\};'
        r'(?:  // OTUI Android fix \(renderer panic\): gid no está en el GraphemePool)?\n'
        r'                    if \(bytes\.len > 0\) \{)',
        rsrc,
    )
    if not m:
        sys.exit("FIX WRITER GUARD: patrón bytes.len > 0 (prepareRenderFrameWithWriter) no encontrado")
    new_bytes = (
        "const bytes = self.pool.get(gid) catch &[_]u8{};\n"
        "                    // OTUI Android fix (writer len guard): si un slot reciclado/corrupto\n"
        "                    // devolvió un slice con len sospechoso, NO escribirlo al Writer (panic\n"
        "                    // del @memcpy \"integer does not fit\" → SIGABRT). 4096 = MAX_UNOWNED_LEN\n"
        "                    // del ClassPool: acota cualquier grapheme legítimo. Degradamos a celda\n"
        "                    // vacía sin saltar el syncCell (bookkeeping del diff intacto).\n"
        "                    if (bytes.len > 0 and bytes.len <= 4096) {"
    )
    rsrc = rsrc[: m.start()] + new_bytes + rsrc[m.end():]
    with open(renderer_p, "w", encoding="utf-8") as f:
        f.write(rsrc)
    print(f"   {renderer_p}: parcheado (bytes guard)")
else:
    print(f"   {renderer_p}: bytes guard ya presente")

# (d) clamp utf8Buf — s.replace aplica a TODAS las ocurrencias (2 sitios del char mask)
utf8_old = (
    "                    var len: usize = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;\n"
    "                    if (len == 0) {"
)
utf8_new = (
    "                    var len: usize = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;\n"
    "                    // OTUI Android fix (writer len guard): clamp defensivo — utf8Encode\n"
    "                    // nunca devuelve >4, pero ningún slice dinámico llega al Writer sin\n"
    "                    // validación (panic del @memcpy → SIGABRT).\n"
    "                    if (len > utf8Buf.len) len = 0;\n"
    "                    if (len == 0) {"
)
apply(renderer_p, [(M_UTF8, utf8_old, utf8_new)])

# Verificación final fail-fast por marcador
for path, markers in (
    (link_p, (M_LINKLEN,)),
    (renderer_p, (M_URL, M_BYTES, M_UTF8)),
):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    for m in markers:
        if m not in s:
            sys.exit(f"FIX WRITER GUARD: marcador '{m}' no verificado en {path}")
print("   writer len guard + LinkPool.get len guard verificado")
PYEOF
            grep -q "OTUI Android fix (LinkPool.get len guard)" "$LINK_ZIG" || {
                echo "ERROR: writer len guard no aplicado — abortando"
                exit 1
            }
        fi

        # ── OTUI Android fix (renderer invariantes): invariante 1 (codepoint válido) + invariante 2 (len clamp) ──
        # INVARIANTES del renderer que curan el SIGABRT en el punto de salida, sin depender
        # de la fuente del dato corrupto:
        #   Invariante 1 (codepoint válido): la máscara `cell.char & 0x1F_FFFF` que aplica el
        #     pool hardening permite valores en [0x10FFFF, 0x1FFFFF] — codepoints Unicode
        #     INVÁLIDOS que disparan el `assert(c <= 0x10FFFF)` de std.unicode.utf8Encode
        #     (ReleaseSafe) → SIGABRT. Clamp a 0 (espacio) en el punto de salida: utf8Encode
        #     nunca recibe un codepoint inválido (2 sitios del char mask).
        #   Invariante 2 (len clamp): ningún slice dinámico (url_bytes / bytes grapheme /
        #     utf8Buf[0..len]) llega al Writer con len corrupto (panic del @memcpy "integer
        #     does not fit" → SIGABRT). Los guards de len ya existen (bloque writer len
        #     guard); este bloque los formaliza con el marcador `renderer invariantes` en los
        #     3 puntos de escritura de prepareRenderFrameWithWriter para que el fix sea
        #     verificable y el grep de idempotencia inequívoco.
        # Se ejecuta DESPUÉS del pool hardening (char mask) y del writer len guard: los
        # patrones esperan `codepoint` a u21 ya enmascarado. Idempotente por marcador único
        # por sub-parche; fail-fast (sys.exit) si un patrón original no matchea (fresh).
        if grep -q "OTUI Android fix (codepoint válido)" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (renderer invariantes): invariante 2 (url_bytes)" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes)" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (renderer invariantes): invariante 2 (utf8Buf)" "$RENDERER_ZIG"; then
            echo "   renderer invariantes (codepoint válido + len clamp) ya presentes"
        else
            echo "   aplicando renderer invariantes (codepoint válido + len clamp)..."
            python3 - "$RENDERER_ZIG" <<'PYEOF'
import sys

renderer_p = sys.argv[1]

def apply(path, repls):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    changed = False
    for marker, old, new in repls:
        if marker in s:
            continue  # ya aplicado (idempotente)
        if old not in s:
            sys.exit(f"FIX RENDERER INVARIANTES: patrón para '{marker}' no encontrado en {path}")
        s = s.replace(old, new)
        changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print(f"   {path}: parcheado")
    else:
        print(f"   {path}: ya parcheado")

M_CP = "OTUI Android fix (codepoint válido)"
M_INV_URL = "OTUI Android fix (renderer invariantes): invariante 2 (url_bytes)"
M_INV_GLY = "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes)"
M_INV_UTF8 = "OTUI Android fix (renderer invariantes): invariante 2 (utf8Buf)"

# Invariante 1 — clamp de codepoint a <= 0x10FFFF tras la máscara & 0x1F_FFFF.
# s.replace aplica a TODAS las ocurrencias (2 sitios del char mask: split scrollback
# y prepareRenderFrameWithWriter).
cp_old = (
    "                    const codepoint: u21 = @intCast(cell.char & 0x1F_FFFF);\n"
    "                    var len: usize = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;"
)
cp_new = (
    "                    // OTUI Android fix (codepoint válido): la máscara & 0x1F_FFFF permite\n"
    "                    // valores en [0x10FFFF, 0x1FFFFF] — codepoints Unicode INVÁLIDOS que\n"
    "                    // disparan el assert(c <= 0x10FFFF) de std.unicode.utf8Encode\n"
    "                    // (ReleaseSafe) → SIGABRT. Clamp a 0 (espacio) en el punto de salida:\n"
    "                    // utf8Encode nunca recibe un codepoint inválido.\n"
    "                    var codepoint: u21 = @intCast(cell.char & 0x1F_FFFF);\n"
    "                    if (codepoint > 0x10FFFF) codepoint = 0;\n"
    "                    var len: usize = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;"
)
apply(renderer_p, [(M_CP, cp_old, cp_new)])

# Invariante 2 — formaliza con marcador los guards de len en los 3 puntos de
# escritura dinámica de prepareRenderFrameWithWriter.
# (a) links url_bytes (guard len 1..512).
inv_url_old = (
    "                            // cierre `\\x1b]8;;\\x1b\\\\` posterior siga siendo correcto).\n"
    "                            if (url_bytes.len > 0 and url_bytes.len <= 512) {"
)
inv_url_new = (
    "                            // cierre `\\x1b]8;;\\x1b\\\\` posterior siga siendo correcto).\n"
    "                            // OTUI Android fix (renderer invariantes): invariante 2 (url_bytes) —\n"
    "                            // clamp de bytes.len (1..512): ningún slice con len corrupto llega al\n"
    "                            // Writer (panic del @memcpy → SIGABRT).\n"
    "                            if (url_bytes.len > 0 and url_bytes.len <= 512) {"
)
apply(renderer_p, [(M_INV_URL, inv_url_old, inv_url_new)])

# (b) bytes grapheme (guard len 1..4096).
inv_gly_old = (
    "                    // vacía sin saltar el syncCell (bookkeeping del diff intacto).\n"
    "                    if (bytes.len > 0 and bytes.len <= 4096) {"
)
inv_gly_new = (
    "                    // vacía sin saltar el syncCell (bookkeeping del diff intacto).\n"
    "                    // OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes) —\n"
    "                    // clamp de bytes.len (1..4096): ningún slice con len corrupto llega al\n"
    "                    // Writer (panic del @memcpy → SIGABRT).\n"
    "                    if (bytes.len > 0 and bytes.len <= 4096) {"
)
apply(renderer_p, [(M_INV_GLY, inv_gly_old, inv_gly_new)])

# (c) utf8Buf[0..len] — s.replace aplica a TODAS las ocurrencias (2 sitios del char mask).
inv_utf8_old = (
    "                    writer.writeAll(utf8Buf[0..len]) catch {};"
)
inv_utf8_new = (
    "                    // OTUI Android fix (renderer invariantes): invariante 2 (utf8Buf) —\n"
    "                    // utf8Buf[0..len] con len ∈ [1, utf8Buf.len] (≤4): ningún slice con len\n"
    "                    // corrupto llega al Writer (panic del @memcpy → SIGABRT).\n"
    "                    writer.writeAll(utf8Buf[0..len]) catch {};"
)
apply(renderer_p, [(M_INV_UTF8, inv_utf8_old, inv_utf8_new)])

# Verificación final fail-fast por marcador
with open(renderer_p, encoding="utf-8") as f:
    s = f.read()
for m in (M_CP, M_INV_URL, M_INV_GLY, M_INV_UTF8):
    if m not in s:
        sys.exit(f"FIX RENDERER INVARIANTES: marcador '{m}' no verificado en {renderer_p}")
if s.count(M_INV_UTF8) < 2:
    sys.exit(f"FIX RENDERER INVARIANTES: esperaba 2 marcadores '{M_INV_UTF8}', hay {s.count(M_INV_UTF8)}")
print("   renderer invariantes verificado")
PYEOF
            grep -q "OTUI Android fix (codepoint válido)" "$RENDERER_ZIG" || {
                echo "ERROR: renderer invariantes no aplicado — abortando"
                exit 1
            }
        fi

        # ── OTUI Android fix (renderer invariantes split/dump): invariante 1 (codepoint dump) + invariante 2 (len clamp) ──
        # CIERRE del barrido de higiene del Writer: los 3 puntos de escritura dinámica que
        # quedaban SIN clamp/validación en el renderer:
        #   (a) writeSnapshotCommit (split-scrollback): `if (bytes.len > 0) {` → clamp 1..4096.
        #       La ruta del crash: el usuario estaba en modo split-scrollback (scroll/resumir)
        #       al reproducir el SIGABRT (Writer.zig:521 "integer does not fit"). Mismo clamp
        #       que prepareRenderFrameWithWriter.
        #   (b) dumpSingleBuffer grapheme: `if (bytes.len > 0) writer.writeAll(bytes)` → clamp 1..4096.
        #   (c) dumpSingleBuffer utf8: `@intCast(c.char)` sin máscara + `catch 1` (utf8Buf[0]
        #       indefinido) → máscara & 0x1F_FFFF + clamp ≤0x10FFFF + `catch 0` a espacio.
        # Marcadores DISTINTOS a los del bloque "renderer invariantes" (sufijos split/dump) para
        # que el grep de idempotencia y la verificación fail-fast sean inequívocos.
        # Idempotente por marcador; fail-fast (sys.exit) si un patrón original no matchea (fresh).
        if grep -q "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes split)" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes dump)" "$RENDERER_ZIG" \
            && grep -q "OTUI Android fix (renderer invariantes): invariante 1 (codepoint dump)" "$RENDERER_ZIG"; then
            echo "   renderer invariantes split/dump (codepoint + len clamp) ya presentes"
        else
            echo "   aplicando renderer invariantes split/dump (codepoint + len clamp)..."
            python3 - "$RENDERER_ZIG" <<'PYEOF'
import sys

renderer_p = sys.argv[1]

def apply(path, repls):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    changed = False
    for marker, old, new in repls:
        if marker in s:
            continue  # ya aplicado (idempotente)
        if old not in s:
            sys.exit(f"FIX RENDERER INVARIANTES SPLIT/DUMP: patrón para '{marker}' no encontrado en {path}")
        s = s.replace(old, new)
        changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print(f"   {path}: parcheado")
    else:
        print(f"   {path}: ya parcheado")

M_SPLIT_GLY = "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes split)"
M_DUMP_GLY = "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes dump)"
M_DUMP_UTF8 = "OTUI Android fix (renderer invariantes): invariante 1 (codepoint dump)"

# (a) writeSnapshotCommit (split-scrollback) — grapheme bytes. Ancla única por el
# bloque `catch {` (writeByte + continue) que solo existe en esta función.
split_old = (
    "                    const bytes = self.pool.get(gid) catch {\n"
    "                        writer.writeByte(' ') catch {};\n"
    "                        continue;\n"
    "                    };\n"
    "\n"
    "                    if (bytes.len > 0) {\n"
    "                        const capabilities = self.terminal.getCapabilities();"
)
split_new = (
    "                    const bytes = self.pool.get(gid) catch {\n"
    "                        writer.writeByte(' ') catch {};\n"
    "                        continue;\n"
    "                    };\n"
    "\n"
    "                    // OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes split) —\n"
    "                    // clamp de bytes.len (1..4096): ningún slice con len corrupto llega al\n"
    "                    // Writer (panic del @memcpy → SIGABRT). Ruta split-scrollback (writeSnapshotCommit):\n"
    "                    // mismo clamp que prepareRenderFrameWithWriter.\n"
    "                    if (bytes.len > 0 and bytes.len <= 4096) {\n"
    "                        const capabilities = self.terminal.getCapabilities();"
)
apply(renderer_p, [(M_SPLIT_GLY, split_old, split_new)])

# (b) dumpSingleBuffer grapheme — clamp inline (único, solo existe en esta función).
dump_gly_old = (
    "                        const bytes = self.pool.get(gid) catch &[_]u8{};\n"
    "                        if (bytes.len > 0) writer.writeAll(bytes) catch return;"
)
dump_gly_new = (
    "                        const bytes = self.pool.get(gid) catch &[_]u8{};\n"
    "                        // OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes dump) —\n"
    "                        // clamp de bytes.len (1..4096): dump a fichero, pero el Writer usa el\n"
    "                        // mismo @memcpy (panic \"integer does not fit\" → SIGABRT).\n"
    "                        if (bytes.len > 0 and bytes.len <= 4096) writer.writeAll(bytes) catch return;"
)
apply(renderer_p, [(M_DUMP_GLY, dump_gly_old, dump_gly_new)])

# (c) dumpSingleBuffer utf8 — máscara + clamp + catch 0 (único, solo existe en esta función).
dump_utf8_old = (
    "                        var utf8Buf: [4]u8 = undefined;\n"
    "                        const len = std.unicode.utf8Encode(@intCast(c.char), &utf8Buf) catch 1;\n"
    "                        writer.writeAll(utf8Buf[0..len]) catch return;"
)
dump_utf8_new = (
    "                        var utf8Buf: [4]u8 = undefined;\n"
    "                        // OTUI Android fix (renderer invariantes): invariante 1 (codepoint dump) —\n"
    "                        // máscara + clamp ≤ 0x10FFFF como en las rutas de render: un cell.char\n"
    "                        // corrupto (>0x1FFFFF) hacía panic en el @intCast a u21 (ReleaseSafe)\n"
    "                        // → SIGABRT. En error, utf8Buf[0] queda indefinido con `catch 1` →\n"
    "                        // degradamos a espacio (nunca bytes basura al fichero).\n"
    "                        var codepoint: u21 = @intCast(c.char & 0x1F_FFFF);\n"
    "                        if (codepoint > 0x10FFFF) codepoint = 0;\n"
    "                        var len = std.unicode.utf8Encode(codepoint, &utf8Buf) catch 0;\n"
    "                        if (len == 0) {\n"
    "                            utf8Buf[0] = ' ';\n"
    "                            len = 1;\n"
    "                        }\n"
    "                        writer.writeAll(utf8Buf[0..len]) catch return;"
)
apply(renderer_p, [(M_DUMP_UTF8, dump_utf8_old, dump_utf8_new)])

# Verificación final fail-fast por marcador
with open(renderer_p, encoding="utf-8") as f:
    s = f.read()
for m in (M_SPLIT_GLY, M_DUMP_GLY, M_DUMP_UTF8):
    if m not in s:
        sys.exit(f"FIX RENDERER INVARIANTES SPLIT/DUMP: marcador '{m}' no verificado en {renderer_p}")
print("   renderer invariantes split/dump verificado")
PYEOF
            grep -q "OTUI Android fix (renderer invariantes): invariante 2 (grapheme bytes split)" "$RENDERER_ZIG" || {
                echo "ERROR: renderer invariantes split/dump no aplicado — abortando"
                exit 1
            }
        fi

        # ── OTUI Android fix (RETIRED_GENERATION no-wrap) ──
        # CAUSA RAÍZ del SIGABRT en la TUI: los pools de opentui reciclaban slots con
        # generación que WRAPPEABA (& GENERATION_MASK en grapheme.zig, 7 bits; & GEN_MASK
        # en link.zig, 8 bits). Tras 128/256 reusos del mismo slot la generación volvía
        # a coincidir con un gid/id viejo → un id stale leía un slot reasignado (len
        # corrupto → panic Writer.zig:521 → SIGABRT). Fix de raíz (patrón que link.zig
        # 0.4.5 ya trae UPSTREAM): generación MONOTÓNICA sin wrap + retiro PERMANENTE del
        # slot al agotar el rango (nunca más se reasigna). Este bloque porta el patrón a
        # grapheme.zig (ambos checkouts) y link.zig 0.3.4; link.zig 0.4.5 se detecta por
        # contenido y se salta. Idempotente por sub-patrón (probe = contenido del estado
        # objetivo); fail-fast sys.exit si un patrón ORIGINAL no matchea en un checkout
        # fresco. Probes anclados con '\n' delimitado (Python `in` no respeta líneas:
        # una indentación mayor de un probe es substring de una línea con más espacios).
        if grep -q "retired_slot_count += 1" "$GRAPHEME_ZIG" \
            && grep -q "header_ptr.generation = RETIRED_GENERATION;" "$LINK_ZIG"; then
            echo "   RETIRED_GENERATION (no-wrap) ya presente"
        else
            echo "   aplicando RETIRED_GENERATION (no-wrap)..."
            python3 - "$GRAPHEME_ZIG" "$LINK_ZIG" <<'PYEOF'
import sys


def apply_retired(path, fully_patched, repls, label):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    probes_fp = fully_patched if isinstance(fully_patched, tuple) else (fully_patched,)
    if all(p in s for p in probes_fp):
        print(f"   {path}: ya parcheado ({label})")
        return
    changed = False
    for name, probe, old, new in repls:
        if probe in s:
            continue  # sub-parche ya aplicado (idempotente)
        if old not in s:
            sys.exit(f"FIX RETIRED_GENERATION: patrón para '{name}' no encontrado en {path}")
        if s.count(old) != 1:
            sys.exit(f"FIX RETIRED_GENERATION: patrón para '{name}' ambiguo ({s.count(old)} ocurrencias) en {path}")
        s = s.replace(old, new)
        changed = True
    if not changed:
        print(f"   {path}: sin cambios ({label})")
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print(f"   {path}: parcheado ({label})")


# ── grapheme.zig (patrón idéntico en 0.3.4 y 0.4.5) ──
G_CONST_OLD = (
    "pub const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1; // 0xFFFF\n"
    "\n"
    "comptime {"
)
G_CONST_NEW = (
    "pub const SLOT_MASK: u32 = (@as(u32, 1) << SLOT_BITS) - 1; // 0xFFFF\n"
    "// OTUI Android fix (RETIRED_GENERATION no-wrap): generación fuera de rango que marca\n"
    "// un slot como retirado permanentemente (patrón de link.zig 0.4.5). Un slot con esta\n"
    "// generación nunca vuelve a free_list y su id antiguo ya no puede revalidar.\n"
    "pub const RETIRED_GENERATION: u32 = GENERATION_MASK + 1;\n"
    "\n"
    "comptime {"
)
G_FIELD_OLD = "        num_slots: u32,\n\n        pub fn init("
G_FIELD_NEW = (
    "        num_slots: u32,\n"
    "        // OTUI Android fix (RETIRED_GENERATION no-wrap): slots retirados\n"
    "        // permanentemente al agotar el rango de generación (patrón de link.zig 0.4.5).\n"
    "        retired_slot_count: u32,\n"
    "\n"
    "        pub fn init("
)
G_INIT_OLD = "                .free_list = .{},\n                .num_slots = 0,\n            };"
G_INIT_NEW = (
    "                .free_list = .{},\n"
    "                .num_slots = 0,\n"
    "                .retired_slot_count = 0,\n"
    "            };"
)
G_ALLOC_OLD = (
    "            // Increment generation when reusing a slot, wrapping at 7 bits (128 values)\n"
    "            const new_generation = (header_ptr.generation + 1) & GENERATION_MASK;"
)
G_ALLOC_NEW = (
    "            // OTUI Android fix (RETIRED_GENERATION no-wrap): generación monotónica sin\n"
    "            // wrap (patrón de link.zig 0.4.5). El wrap (& GENERATION_MASK) permitía que\n"
    "            // tras 128 reusos del mismo slot la generación volviera a coincidir con un\n"
    "            // gid viejo → un gid stale leía un slot reasignado (slice len corrupto →\n"
    "            // SIGABRT). El assert garantiza que un slot retirado jamás se reasigna.\n"
    "            assert(header_ptr.generation < GENERATION_MASK);\n"
    "            const new_generation = header_ptr.generation + 1;"
)
G_DECREF_OLD = (
    "            if (header_ptr.refcount == 0) {\n"
    "                header_ptr.is_allocated = 0;\n"
    "                const free_slots_before = self.free_list.items.len;\n"
    "                assert(self.free_list.capacity > self.free_list.items.len);\n"
    "                self.free_list.appendAssumeCapacity(slot_index);\n"
    "                assert(self.free_list.items.len == free_slots_before + 1);\n"
    "            }\n"
    "            self.assertInvariants();"
)
G_DECREF_NEW = (
    "            if (header_ptr.refcount == 0) {\n"
    "                header_ptr.is_allocated = 0;\n"
    "                // OTUI Android fix (RETIRED_GENERATION no-wrap): al agotar el rango de\n"
    "                // generación (GENERATION_MASK) el slot se retira PERMANENTEMENTE (patrón\n"
    "                // de link.zig 0.4.5): no vuelve a free_list ni se reasigna jamás, así su\n"
    "                // id antiguo ya no puede revalidar contra un slot reciclado.\n"
    "                if (header_ptr.generation == GENERATION_MASK) {\n"
    "                    header_ptr.generation = RETIRED_GENERATION;\n"
    "                    self.retired_slot_count += 1;\n"
    "                } else {\n"
    "                    const free_slots_before = self.free_list.items.len;\n"
    "                    assert(self.free_list.capacity > self.free_list.items.len);\n"
    "                    self.free_list.appendAssumeCapacity(slot_index);\n"
    "                    assert(self.free_list.items.len == free_slots_before + 1);\n"
    "                }\n"
    "            }\n"
    "            self.assertInvariants();"
)
G_FREE_OLD = (
    "            header_ptr.is_allocated = 0;\n"
    "            const free_slots_before = self.free_list.items.len;\n"
    "            assert(self.free_list.capacity > self.free_list.items.len);\n"
    "            self.free_list.appendAssumeCapacity(slot_index);\n"
    "            assert(self.free_list.items.len == free_slots_before + 1);\n"
    "            self.assertInvariants();"
)
G_FREE_NEW = (
    "            header_ptr.is_allocated = 0;\n"
    "            // OTUI Android fix (RETIRED_GENERATION no-wrap): mismo manejo que decref —\n"
    "            // al agotar el rango de generación el slot se retira permanentemente.\n"
    "            if (header_ptr.generation == GENERATION_MASK) {\n"
    "                header_ptr.generation = RETIRED_GENERATION;\n"
    "                self.retired_slot_count += 1;\n"
    "            } else {\n"
    "                const free_slots_before = self.free_list.items.len;\n"
    "                assert(self.free_list.capacity > self.free_list.items.len);\n"
    "                self.free_list.appendAssumeCapacity(slot_index);\n"
    "                assert(self.free_list.items.len == free_slots_before + 1);\n"
    "            }\n"
    "            self.assertInvariants();"
)
# OJO: los probes de decref/freeUnreferenced se distinguen por indentación (el
# contenido nuevo de uno satisface el probe del otro si usaran la misma cadena).
# Además, "X espacios + texto" es substring de una línea con MÁS espacios (Python
# `in` no respeta límites de línea) → anclamos con '\n' delimitado para que el probe
# solo matchee la LÍNEA COMPLETA con su indentación exacta.
G_DECREF_PROBE = "\n                    self.retired_slot_count += 1;"  # 20 espacios (decref)
G_FREE_PROBE = "\n                self.retired_slot_count += 1;"  # 16 espacios (freeUnreferenced)
grapheme_repls = [
    ("grapheme const RETIRED_GENERATION", "pub const RETIRED_GENERATION: u32 = GENERATION_MASK + 1;", G_CONST_OLD, G_CONST_NEW),
    ("grapheme campo retired_slot_count", "retired_slot_count: u32,", G_FIELD_OLD, G_FIELD_NEW),
    ("grapheme init retired_slot_count", ".retired_slot_count = 0,", G_INIT_OLD, G_INIT_NEW),
    ("grapheme alloc no-wrap", "assert(header_ptr.generation < GENERATION_MASK);", G_ALLOC_OLD, G_ALLOC_NEW),
    ("grapheme decref retire", G_DECREF_PROBE, G_DECREF_OLD, G_DECREF_NEW),
    ("grapheme freeUnreferenced retire", G_FREE_PROBE, G_FREE_OLD, G_FREE_NEW),
]

# ── link.zig 0.3.4 (0.4.5 ya trae el patrón upstream → se detecta y salta) ──
L_CONST_OLD = "pub const MAX_URL_LENGTH: usize = 512;\n\npub const IdPayload = u32;"
L_CONST_NEW = (
    "pub const MAX_URL_LENGTH: usize = 512;\n"
    "// OTUI Android fix (RETIRED_GENERATION no-wrap): port de link.zig 0.4.5. Generación\n"
    "// fuera de rango que marca un slot retirado permanentemente (nunca se reasigna).\n"
    "const RETIRED_GENERATION = GEN_MASK + 1;\n"
    "\n"
    "pub const IdPayload = u32;"
)
L_FIELD_OLD = "    num_slots: u32,\n    interned_live_ids: std.StringHashMapUnmanaged(IdPayload),"
L_FIELD_NEW = (
    "    num_slots: u32,\n"
    "    // OTUI Android fix (RETIRED_GENERATION no-wrap): slots retirados permanentemente\n"
    "    // al agotar el rango de generación (patrón de link.zig 0.4.5).\n"
    "    retired_slot_count: u32,\n"
    "    interned_live_ids: std.StringHashMapUnmanaged(IdPayload),"
)
L_INIT_OLD = "            .num_slots = 0,\n            .interned_live_ids = .{},"
L_INIT_NEW = (
    "            .num_slots = 0,\n"
    "            .retired_slot_count = 0,\n"
    "            .interned_live_ids = .{},"
)
L_ALLOC_OLD = (
    "        // Increment generation when reusing a slot; reserve generation 0 so ID 0 remains an error sentinel in FFI.\n"
    "        var new_generation = (header_ptr.generation + 1) & GEN_MASK;\n"
    "        if (new_generation == 0) new_generation = 1;"
)
L_ALLOC_NEW = (
    "        // OTUI Android fix (RETIRED_GENERATION no-wrap): generación monotónica sin wrap\n"
    "        // (port de link.zig 0.4.5). El wrap (& GEN_MASK) permitía que tras 256 reusos la\n"
    "        // generación volviera a coincidir con un id viejo → un id stale leía un slot\n"
    "        // reasignado. El sentinel gen-0 se preserva: los slots frescos nacen en 0 y\n"
    "        // suben monotónicamente, nunca vuelven a 0.\n"
    "        std.debug.assert(header_ptr.generation < GEN_MASK);\n"
    "        const new_generation = header_ptr.generation + 1;"
)
L_DECREF_OLD = (
    "        if (header_ptr.refcount == 0) {\n"
    "            try self.free_list.append(self.allocator, unpacked.slot_index);\n"
    "        }"
)
L_DECREF_NEW = (
    "        if (header_ptr.refcount == 0) {\n"
    "            // OTUI Android fix (RETIRED_GENERATION no-wrap): al agotar el rango de\n"
    "            // generación (GEN_MASK) el slot se retira PERMANENTEMENTE (port de link.zig\n"
    "            // 0.4.5): no vuelve a free_list ni se reasigna jamás, así su id antiguo ya\n"
    "            // no puede revalidar contra un slot reciclado.\n"
    "            if (header_ptr.generation == GEN_MASK) {\n"
    "                header_ptr.generation = RETIRED_GENERATION;\n"
    "                self.retired_slot_count += 1;\n"
    "            } else {\n"
    "                try self.free_list.append(self.allocator, unpacked.slot_index);\n"
    "            }\n"
    "        }"
)
L_LIVE_OLD = "        return self.num_slots - @as(u32, @intCast(self.free_list.items.len));"
L_LIVE_NEW = (
    "        // OTUI Android fix (RETIRED_GENERATION no-wrap): los slots retirados no están en\n"
    "        // free_list pero tampoco están vivos (patrón de link.zig 0.4.5).\n"
    "        return self.num_slots - @as(u32, @intCast(self.free_list.items.len)) - self.retired_slot_count;"
)
link_repls = [
    ("link const RETIRED_GENERATION", "const RETIRED_GENERATION = GEN_MASK + 1;", L_CONST_OLD, L_CONST_NEW),
    ("link campo retired_slot_count", "retired_slot_count: u32,", L_FIELD_OLD, L_FIELD_NEW),
    ("link init retired_slot_count", ".retired_slot_count = 0,", L_INIT_OLD, L_INIT_NEW),
    ("link alloc no-wrap", "std.debug.assert(header_ptr.generation < GEN_MASK);", L_ALLOC_OLD, L_ALLOC_NEW),
    ("link decref retire", "header_ptr.generation = RETIRED_GENERATION;", L_DECREF_OLD, L_DECREF_NEW),
    ("link getLiveSlotCount", "- self.retired_slot_count;", L_LIVE_OLD, L_LIVE_NEW),
]

apply_retired(sys.argv[1], (G_DECREF_PROBE, G_FREE_PROBE), grapheme_repls, "grapheme")
apply_retired(sys.argv[2], "header_ptr.generation = RETIRED_GENERATION;", link_repls, "link")

# Verificación final fail-fast por marcador
with open(sys.argv[1], encoding="utf-8") as f:
    g = f.read()
with open(sys.argv[2], encoding="utf-8") as f:
    l = f.read()
if "OTUI Android fix (RETIRED_GENERATION no-wrap)" not in g or "retired_slot_count += 1" not in g:
    sys.exit("FIX RETIRED_GENERATION: marcador no verificado en grapheme.zig")
if "header_ptr.generation = RETIRED_GENERATION;" not in l:
    sys.exit("FIX RETIRED_GENERATION: marcador no verificado en link.zig")
print("   RETIRED_GENERATION (no-wrap) verificado")
PYEOF
            grep -q "retired_slot_count += 1" "$GRAPHEME_ZIG" || {
                echo "ERROR: RETIRED_GENERATION no aplicado en grapheme.zig — abortando"
                exit 1
            }
        fi

        # ── OTUI Android fix (no reciclar slots): FIX ESTRUCTURAL DEFINITIVO ──
        # CAUSA RAÍZ del panic "integer does not fit" en Writer.zig:521 (SIGABRT): los
        # pools de opentui RECICLABAN slots. Al llegar el refcount de un slot a 0,
        # decref/freeUnreferenced lo devolvía a free_list y allocInternal lo REASIGNABA
        # con generación+1. Un gid/id stale (de una celda cuyo refcount se desincronizó
        # en alguna ruta) podía leer un slot REASIGNADO → slice con len/puntero del OTRO
        # grapheme/link → el Writer del renderer panica. Los fixes previos (len guards,
        # no-wrap, retiro solo al agotar el rango, refcount simétrico) REDUCÍAN la
        # probabilidad pero NO eliminaban la clase: el reciclado seguía permitiendo que
        # un id stale leyera un slot de OTRO objeto. ESTE bloque elimina la clase
        # completa: NUNCA reciclar. En decref/freeUnreferenced, al llegar el refcount a
        # 0 el slot se retira PERMANENTEMENTE (generation = RETIRED_GENERATION,
        # is_allocated=0 en grapheme.zig, retired_slot_count += 1) — nunca vuelve a
        # free_list. Ningún id stale lee jamás un slot reasignado → get/incref/decref
        # dan InvalidId/WrongGeneration (degradación limpia; el pool crece con grow(),
        # free_list solo recibe slots NUEVOS). Los guards previos quedan como red de
        # seguridad. Idempotente por marcador; fail-fast sys.exit si un patrón ORIGINAL
        # (estado previo a este bloque: forma condicional del bloque RETIRED_GENERATION)
        # no matchea. link.zig soporta las DOS formas: comentada (0.3.4 tras el bloque
        # RETIRED_GENERATION) y bare (0.4.5 upstream, que ya trae el retiro condicional).
        if grep -q "OTUI Android fix (no reciclar slots)" "$GRAPHEME_ZIG" \
            && grep -q "OTUI Android fix (no reciclar slots)" "$LINK_ZIG"; then
            echo "   no reciclar slots (estructural) ya presente"
        else
            echo "   aplicando no reciclar slots (estructural)..."
            python3 - "$GRAPHEME_ZIG" "$LINK_ZIG" <<'PYEOF'
import sys


M = "OTUI Android fix (no reciclar slots)"


def apply_pool(path, repls, label):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    changed = False
    for name, old, new in repls:
        if old not in s:
            continue  # sub-parche ya aplicado (idempotente por patrón) o forma no presente
        if s.count(old) != 1:
            sys.exit(f"FIX NO-RECICLAR: patrón para '{name}' ambiguo ({s.count(old)} ocurrencias) en {path}")
        s = s.replace(old, new)
        changed = True
    if M not in s:
        sys.exit(f"FIX NO-RECICLAR: marcador no verificado en {path}")
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
    print(f"   {path}: {'parcheado' if changed else 'ya aplicado'} ({label})")


# ── grapheme.zig (forma condicional comentada, idéntica en 0.3.4 y 0.4.5) ──
G_DECREF_OLD = (
    "            if (header_ptr.refcount == 0) {\n"
    "                header_ptr.is_allocated = 0;\n"
    "                // OTUI Android fix (RETIRED_GENERATION no-wrap): al agotar el rango de\n"
    "                // generación (GENERATION_MASK) el slot se retira PERMANENTEMENTE (patrón\n"
    "                // de link.zig 0.4.5): no vuelve a free_list ni se reasigna jamás, así su\n"
    "                // id antiguo ya no puede revalidar contra un slot reciclado.\n"
    "                if (header_ptr.generation == GENERATION_MASK) {\n"
    "                    header_ptr.generation = RETIRED_GENERATION;\n"
    "                    self.retired_slot_count += 1;\n"
    "                } else {\n"
    "                    const free_slots_before = self.free_list.items.len;\n"
    "                    assert(self.free_list.capacity > self.free_list.items.len);\n"
    "                    self.free_list.appendAssumeCapacity(slot_index);\n"
    "                    assert(self.free_list.items.len == free_slots_before + 1);\n"
    "                }\n"
    "            }\n"
)
G_DECREF_NEW = (
    "            if (header_ptr.refcount == 0) {\n"
    "                header_ptr.is_allocated = 0;\n"
    "                // OTUI Android fix (no reciclar slots): FIX ESTRUCTURAL DEFINITIVO. El\n"
    "                // slot se retira PERMANENTEMENTE al llegar a refcount 0, SIEMPRE (antes\n"
    "                // solo al agotar GENERATION_MASK). Nunca vuelve a free_list ni se\n"
    "                // reasigna jamás → ningún gid stale puede leer un slot reasignado (se\n"
    "                // elimina la clase completa de UAF: slice con len/puntero del OTRO\n"
    "                // grapheme que reventaba el Writer \"integer does not fit in destination\n"
    "                // type\"). generation = RETIRED_GENERATION (GENERATION_MASK+1) no puede\n"
    "                // revalidar contra ningún gid (la generación va & GENERATION_MASK).\n"
    "                header_ptr.generation = RETIRED_GENERATION;\n"
    "                self.retired_slot_count += 1;\n"
    "            }\n"
)
G_FREE_OLD = (
    "            header_ptr.is_allocated = 0;\n"
    "            // OTUI Android fix (RETIRED_GENERATION no-wrap): mismo manejo que decref —\n"
    "            // al agotar el rango de generación el slot se retira permanentemente.\n"
    "            if (header_ptr.generation == GENERATION_MASK) {\n"
    "                header_ptr.generation = RETIRED_GENERATION;\n"
    "                self.retired_slot_count += 1;\n"
    "            } else {\n"
    "                const free_slots_before = self.free_list.items.len;\n"
    "                assert(self.free_list.capacity > self.free_list.items.len);\n"
    "                self.free_list.appendAssumeCapacity(slot_index);\n"
    "                assert(self.free_list.items.len == free_slots_before + 1);\n"
    "            }\n"
)
G_FREE_NEW = (
    "            header_ptr.is_allocated = 0;\n"
    "            // OTUI Android fix (no reciclar slots): mismo tratamiento que decref — el\n"
    "            // slot se retira SIEMPRE al liberarse, nunca vuelve a free_list.\n"
    "            header_ptr.generation = RETIRED_GENERATION;\n"
    "            self.retired_slot_count += 1;\n"
)

# ── link.zig: dos formas posibles ──
# Comentada = 0.3.4 tras el bloque RETIRED_GENERATION; bare = 0.4.5 upstream.
L_DECREF_COM_OLD = (
    "        if (header_ptr.refcount == 0) {\n"
    "            // OTUI Android fix (RETIRED_GENERATION no-wrap): al agotar el rango de\n"
    "            // generación (GEN_MASK) el slot se retira PERMANENTEMENTE (port de link.zig\n"
    "            // 0.4.5): no vuelve a free_list ni se reasigna jamás, así su id antiguo ya\n"
    "            // no puede revalidar contra un slot reciclado.\n"
    "            if (header_ptr.generation == GEN_MASK) {\n"
    "                header_ptr.generation = RETIRED_GENERATION;\n"
    "                self.retired_slot_count += 1;\n"
    "            } else {\n"
    "                try self.free_list.append(self.allocator, unpacked.slot_index);\n"
    "            }\n"
    "        }\n"
)
L_DECREF_BARE_OLD = (
    "        if (header_ptr.refcount == 0) {\n"
    "            if (header_ptr.generation == GEN_MASK) {\n"
    "                header_ptr.generation = RETIRED_GENERATION;\n"
    "                self.retired_slot_count += 1;\n"
    "            } else {\n"
    "                try self.free_list.append(self.allocator, unpacked.slot_index);\n"
    "            }\n"
    "        }\n"
)
L_DECREF_NEW = (
    "        if (header_ptr.refcount == 0) {\n"
    "            // OTUI Android fix (no reciclar slots): FIX ESTRUCTURAL DEFINITIVO. El slot\n"
    "            // se retira PERMANENTEMENTE al llegar a refcount 0, SIEMPRE (antes solo al\n"
    "            // agotar GEN_MASK). Nunca vuelve a free_list ni se reasigna jamás → ningún\n"
    "            // id stale puede leer un slot reasignado (UAF lógico: link de otro slot →\n"
    "            // slice len corrupto que reventaba el Writer). generation =\n"
    "            // RETIRED_GENERATION (GEN_MASK+1) no puede revalidar contra ningún id\n"
    "            // empaquetado (la generación va & GEN_MASK).\n"
    "            header_ptr.generation = RETIRED_GENERATION;\n"
    "            self.retired_slot_count += 1;\n"
    "        }\n"
)

apply_pool(
    sys.argv[1],
    [
        ("grapheme decref no-recycle", G_DECREF_OLD, G_DECREF_NEW),
        ("grapheme freeUnreferenced no-recycle", G_FREE_OLD, G_FREE_NEW),
    ],
    "grapheme",
)

# link.zig: probar la forma presente (comentada o bare); ambas terminan en L_DECREF_NEW.
for name, old in (("comentada", L_DECREF_COM_OLD), ("bare 0.4.5", L_DECREF_BARE_OLD)):
    with open(sys.argv[2], encoding="utf-8") as f:
        s = f.read()
    if M in s:
        break  # ya aplicado
    if old in s:
        if s.count(old) != 1:
            sys.exit(f"FIX NO-RECICLAR: patrón link '{name}' ambiguo ({s.count(old)}) en {sys.argv[2]}")
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            f.write(s.replace(old, L_DECREF_NEW))
        print(f"   {sys.argv[2]}: parcheado ({M}, forma {name})")
        break
else:
    s = open(sys.argv[2], encoding="utf-8").read()
    if M not in s:
        sys.exit(f"FIX NO-RECICLAR: ninguna forma de link.zig matcheó en {sys.argv[2]}")

# Verificación final fail-fast por marcador
for path in (sys.argv[1], sys.argv[2]):
    if M not in open(path, encoding="utf-8").read():
        sys.exit(f"FIX NO-RECICLAR: marcador no verificado en {path}")
print("   no reciclar slots (estructural) verificado")
PYEOF
            grep -q "OTUI Android fix (no reciclar slots)" "$GRAPHEME_ZIG" || {
                echo "ERROR: no reciclar slots no aplicado en grapheme.zig — abortando"
                exit 1
            }
            grep -q "OTUI Android fix (no reciclar slots)" "$LINK_ZIG" || {
                echo "ERROR: no reciclar slots no aplicado en link.zig — abortando"
                exit 1
            }
        fi

        # ── OTUI Android fix (link refcount simétrico): fix de raíz del crash Writer ──
        # CAUSA RAÍZ del panic "integer does not fit" en Writer.zig:521 (SIGABRT): asimetría
        # de refcount de links en OptimizedBuffer.setInternal con span_cleanup=true. Al
        # sobrescribir una celda de un grapheme span que conserva el MISMO link (new == prev):
        #   (a) el bucle de cleanup del span hacía removeCellRef(span_link_id) TAMBIÉN para la
        #       celda inicio (span_i == index, span_link_id == prev_link_id) → 1er remove;
        #   (b) el path principal re-escribía la celda con el mismo link y, como new == prev,
        #       NO hacía add de compensación → el refcount del LinkPool caía a 0 → pool.decref
        #       liberaba el slot a la free_list mientras la celda recién escrita SIGUE
        #       referenciando el link en sus attributes → gid stale → el renderer leía un slot
        #       reasignado (len corrupto) → panic. Fix de raíz (patrón GraphemeTracker.replace,
        #       grapheme.zig:845): el bucle de span excluye la celda inicio
        #       (`if (span_i == index) continue;`) y el path principal usa replaceLinkRef(prev,
        #       new) ATOMICO (0 ops si prev==new, 1 remove si prev!=0 y prev!=new, 1 add si
        #       new!=0 y new!=prev). Además porta a la ruta split-scrollback (writeSnapshotCommit)
        #       el mismo writer len guard de prepareRenderFrameWithWriter. Los guards previos
        #       (len guard + degrado de trackers) quedan como red de seguridad.
        # Idempotente por marcador; fail-fast sys.exit si un patrón original no matchea.
        BUFFER_ZIG="$KILO_OPENTUI_SRC/packages/core/src/zig/buffer.zig"
        if grep -q "OTUI Android fix (link refcount simétrico)" "$BUFFER_ZIG" \
            && grep -q "OTUI Android fix (writer len guard): mismo guard" "$RENDERER_ZIG"; then
            echo "   link refcount simétrico + writer guard split-scrollback ya presentes"
        else
            echo "   aplicando link refcount simétrico + writer guard split-scrollback..."
            python3 - "$BUFFER_ZIG" "$RENDERER_ZIG" <<'PYEOF'
import sys

buffer_p, renderer_p = sys.argv[1], sys.argv[2]

M_REFCOUNT = "OTUI Android fix (link refcount simétrico)"
M_SPLIT = "OTUI Android fix (writer len guard): mismo guard"


def apply(path, repls):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    changed = False
    for name, probe, old, new in repls:
        if probe in s:
            continue  # ya aplicado (idempotente)
        if old not in s:
            sys.exit(f"FIX LINK REFCOUNT: patrón para '{name}' no encontrado en {path}")
        if s.count(old) != 1:
            sys.exit(f"FIX LINK REFCOUNT: patrón para '{name}' ambiguo ({s.count(old)} ocurrencias) en {path}")
        s = s.replace(old, new)
        changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(s)
        print(f"   {path}: parcheado")
    else:
        print(f"   {path}: ya parcheado")


# (a) bucle de span_cleanup: excluir la celda inicio del remove de links
span_old = (
    "                    const span_link_id = ansi.TextAttributes.getLinkId(self.buffer.attributes[span_i]);\n"
    "                    if (span_link_id != 0) {\n"
    "                        self.link_tracker.removeCellRef(span_link_id);\n"
    "                    }\n"
    "\n"
    "                    self.buffer.char[span_i] = @intCast(DEFAULT_SPACE_CHAR);\n"
    "                    self.buffer.attributes[span_i] = 0;\n"
    "                }"
)
span_new = (
    "                    // OTUI Android fix (link refcount simétrico): la celda inicio del span\n"
    "                    // (span_i == index) NO se libera aquí. El path principal la reescribe y\n"
    "                    // gestiona su transición de links UNA sola vez con replaceLinkRef.\n"
    "                    // Liberarla aquí y re-reescribirla con el mismo link (new == prev) dejaba\n"
    "                    // el refcount del LinkPool descompensado (0 refs con la celda aún\n"
    "                    // referenciando el link) → gid stale → panic Writer.zig (@memcpy).\n"
    "                    if (span_i == index) continue;\n"
    "\n"
    "                    const span_link_id = ansi.TextAttributes.getLinkId(self.buffer.attributes[span_i]);\n"
    "                    if (span_link_id != 0) {\n"
    "                        self.link_tracker.removeCellRef(span_link_id);\n"
    "                    }\n"
    "\n"
    "                    self.buffer.char[span_i] = @intCast(DEFAULT_SPACE_CHAR);\n"
    "                    self.buffer.attributes[span_i] = 0;\n"
    "                }"
)

# (b) path principal: if remove + if add separados → replaceLinkRef atómico
main_old = (
    "            const new_link_id = ansi.TextAttributes.getLinkId(cell.attributes);\n"
    "            if (prev_link_id != 0 and prev_link_id != new_link_id) {\n"
    "                self.link_tracker.removeCellRef(prev_link_id);\n"
    "            }\n"
    "            if (new_link_id != 0 and new_link_id != prev_link_id) {\n"
    "                self.link_tracker.addCellRef(new_link_id);\n"
    "            }"
)
main_new = (
    "            const new_link_id = ansi.TextAttributes.getLinkId(cell.attributes);\n"
    "            // OTUI Android fix (link refcount simétrico): transición atómica del link de la\n"
    "            // celda (patrón de GraphemeTracker.replace). El bucle de span_cleanup ya no toca\n"
    "            // la celda inicio, así que aquí el refcount debe reflejar EXACTAMENTE el nº de\n"
    "            // celdas que referencian el link: 1 remove si prev != 0 y prev != new, 1 add si\n"
    "            // new != 0 y new != prev, y 0 operaciones si prev == new. El refcount del pool\n"
    "            // NUNCA cae a 0 mientras la celda escrita conserva el link en sus attributes.\n"
    "            self.replaceLinkRef(prev_link_id, new_link_id);"
)

# (c) helper replaceLinkRef antes de validateAndIndex
helper_anchor = (
    "    /// Validate coordinates and return buffer index, or null if out of bounds / scissor.\n"
    "    fn validateAndIndex(self: *OptimizedBuffer, x: u32, y: u32) ?u32 {"
)
helper_new = (
    "    /// OTUI Android fix (link refcount simétrico): transición atómica del refcount de links\n"
    "    /// de una celda. Invariante: refcount del tracker == nº de celdas que referencian el link.\n"
    "    /// - 0 ops si prev == new (la celda conserva el mismo link)\n"
    "    /// - 1 remove si prev != 0 y prev != new\n"
    "    /// - 1 add si new != 0 y new != prev\n"
    "    fn replaceLinkRef(self: *OptimizedBuffer, prev_link_id: u32, new_link_id: u32) void {\n"
    "        if (prev_link_id != 0 and prev_link_id != new_link_id) {\n"
    "            self.link_tracker.removeCellRef(prev_link_id);\n"
    "        }\n"
    "        if (new_link_id != 0 and new_link_id != prev_link_id) {\n"
    "            self.link_tracker.addCellRef(new_link_id);\n"
    "        }\n"
    "    }\n"
    "\n" + helper_anchor
)

# (d) writer guard en la ruta split-scrollback (writeSnapshotCommit)
split_old = (
    "                    currentLinkId = linkId;\n"
    "                    if (currentLinkId != 0) {\n"
    "                        const lp = link.initGlobalLinkPool(self.allocator);\n"
    "                        if (lp.get(currentLinkId)) |url_bytes| {\n"
    "                            writer.print(\"\\x1b]8;id={d};{s}\\x1b\\\\\", .{ currentLinkId, url_bytes }) catch {};\n"
    "                        } else |_| {\n"
    "                            currentLinkId = 0;\n"
    "                        }\n"
    "                    }"
)
split_new = (
    "                    currentLinkId = linkId;\n"
    "                    if (currentLinkId != 0) {\n"
    "                        const lp = link.initGlobalLinkPool(self.allocator);\n"
    "                        if (lp.get(currentLinkId)) |url_bytes| {\n"
    "                            // OTUI Android fix (writer len guard): mismo guard que\n"
    "                            // prepareRenderFrameWithWriter. Ningún slice dinámico debe llegar\n"
    "                            // al Writer con len sospechoso (panic \"integer does not fit\" →\n"
    "                            // SIGABRT). URL vacía/corrupta → OSC 8 sin contenido (mantiene el\n"
    "                            // estado del link para el cierre `\\x1b]8;;\\x1b\\\\` posterior).\n"
    "                            if (url_bytes.len > 0 and url_bytes.len <= 512) {\n"
    "                                writer.print(\"\\x1b]8;id={d};{s}\\x1b\\\\\", .{ currentLinkId, url_bytes }) catch {};\n"
    "                            } else {\n"
    "                                writer.print(\"\\x1b]8;id={d};\\x1b\\\\\", .{currentLinkId}) catch {};\n"
    "                            }\n"
    "                        } else |_| {\n"
    "                            currentLinkId = 0;\n"
    "                        }\n"
    "                    }"
)

# OJO orden: (a) y (b) son bloques disjuntos. La cadena main_old (12 espacios) es única —
# writeCellAndLinks usa la misma estructura pero con 8 espacios de indentación.
apply(buffer_p, [
    ("bucle span excluir celda inicio", "if (span_i == index) continue;", span_old, span_new),
    ("path principal replaceLinkRef", "self.replaceLinkRef(prev_link_id, new_link_id);", main_old, main_new),
    ("helper replaceLinkRef", "fn replaceLinkRef(self: *OptimizedBuffer", helper_anchor, helper_new),
])

# (d) writer guard en writeSnapshotCommit (ruta split-scrollback). TOLERANTE a tres
# estados: ya parcheado por este bloque (M_SPLIT); ya cubierto por el bloque previo
# "writer len guard" (fresh-path: su s.replace() aplica url_old→url_new a TODAS las
# ocurrencias, incluida writeSnapshotCommit, dejando el guard M_URL con `currentLinkId
# = 0;` INMEDIATO tras `} else |_| {`); o aún sin guard (split_old presente). La ruta
# writeSnapshotCommit se distingue de prepareRenderFrameWithWriter porque esta última
# tiene `// Link not found, treat as no link` entre `} else |_| {` y `currentLinkId`.
M_SPLIT = "OTUI Android fix (writer len guard): mismo guard"
M_URL = "OTUI Android fix (writer len guard): red de seguridad final"
SPLIT_TAIL_MURL = (
    "                            } else {\n"
    "                                writer.print(\"\\x1b]8;id={d};\\x1b\\\\\", .{currentLinkId}) catch {};\n"
    "                            }\n"
    "                        } else |_| {\n"
    "                            currentLinkId = 0;"
)
with open(renderer_p, encoding="utf-8") as f:
    rsrc = f.read()
if M_SPLIT in rsrc:
    print(f"   {renderer_p}: writer guard split-scrollback ya presente")
elif M_URL in rsrc and SPLIT_TAIL_MURL in rsrc:
    print(f"   {renderer_p}: split-scrollback ya cubierta por el guard previo (M_URL)")
elif split_old in rsrc:
    if rsrc.count(split_old) != 1:
        sys.exit(f"FIX LINK REFCOUNT: patrón split-scrollback ambiguo ({rsrc.count(split_old)} ocurrencias) en {renderer_p}")
    rsrc = rsrc.replace(split_old, split_new)
    with open(renderer_p, "w", encoding="utf-8") as f:
        f.write(rsrc)
    print(f"   {renderer_p}: parcheado (split-scrollback guard)")
else:
    sys.exit(f"FIX LINK REFCOUNT: patrón split-scrollback no encontrado en {renderer_p}")

# Verificación final fail-fast por marcador
with open(buffer_p, encoding="utf-8") as f:
    b = f.read()
with open(renderer_p, encoding="utf-8") as f:
    r = f.read()
if "fn replaceLinkRef(self: *OptimizedBuffer" not in b or "if (span_i == index) continue;" not in b:
    sys.exit("FIX LINK REFCOUNT: marcador no verificado en buffer.zig")
if M_SPLIT not in r and not (M_URL in r and SPLIT_TAIL_MURL in r):
    sys.exit("FIX LINK REFCOUNT: split-scrollback sin writer guard en renderer.zig")
print("   link refcount simétrico + writer guard split-scrollback verificado")
PYEOF
            grep -q "OTUI Android fix (link refcount simétrico)" "$BUFFER_ZIG" || {
                echo "ERROR: link refcount simétrico no aplicado en buffer.zig — abortando"
                exit 1
            }
            grep -qE "OTUI Android fix \(writer len guard\): (mismo guard|red de seguridad final)" "$RENDERER_ZIG" || {
                echo "ERROR: writer guard split-scrollback no aplicado en renderer.zig — abortando"
                exit 1
            }
        fi

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
    "$ANDROID_BUN" install --frozen-lockfile --ignore-scripts || \
    "$ANDROID_BUN" install --ignore-scripts

    # ── Copiar libopentui.so (FALLBACK: .bun/ cache) ──
    # Método principal: .so compilado con Zig (paso anterior).
    # Este bloque solo se usa si el compilado no llegó a node_modules/.
    # Bun descarga @opentui/core-linux-arm64-musl en .bun/ cache pero no lo copia
    # a node_modules/ porque Android Bun no resuelve optionalDependencies
    # para android-arm64 (busca core-android-arm64 que no existe en npm).
    if [ ! -f "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so" ]; then
        echo "   Preparando libopentui.so (fallback .bun/ cache)..."
        BUN_CACHE=$(find "$KILO_SRC/node_modules/.bun" -path "*/core-linux-arm64-musl/libopentui.so" -type f 2>/dev/null | head -1)
        if [ -z "$BUN_CACHE" ]; then
            BUN_CACHE=$(find "$KILO_SRC/node_modules/.bun" -name "libopentui.so" -type f 2>/dev/null | head -1)
        fi

        if [ -n "$BUN_CACHE" ]; then
            mkdir -p "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl"
            cp "$BUN_CACHE" "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so"
            # Copiar package.json y metadatos para que el require() funcione
            PKG_DIR="$(dirname "$BUN_CACHE")"
            [ -f "$PKG_DIR/package.json" ] && cp "$PKG_DIR/package.json" "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/"
            [ -f "$PKG_DIR/index.js" ] && cp "$PKG_DIR/index.js" "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/"
            [ -f "$PKG_DIR/index.bun.js" ] && cp "$PKG_DIR/index.bun.js" "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/"
            echo "   .so copiado desde .bun/ cache ($(du -h "$KILO_SRC/node_modules/@opentui/core-linux-arm64-musl/libopentui.so" | cut -f1))"
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

    # ── Parchear bundle de @opentui/core 0.3.4 para mapear android → linux-musl ──
    # @opentui/core detecta process.platform y busca @opentui/core-android-arm64
    # que no existe. Parcheamos resolveNativeLibraryPath() (Fix2: linux → linux|android),
    # el chequeo OPENTUI_LIBC === "musl" (Fix3: android || musl) y la materialización
    # del .so del bunfs a disco real antes del dlopen (Fix4).
    # OJO 0.3.4: NO tiene chunks chunk-bun-*.js (eso es de 0.4.5). El bundle con el
    # resolver nativo es index-54s7pk0d.js (además de index.js + 3 hashed chunks más).
    echo "   Parcheando @opentui/core para android..."
    OTUI_PATCHED=0
    for CHUNK in $(find "$KILO_SRC/node_modules/@opentui/core" -name "index-*.js" -type f ! -name "*.js.map" 2>/dev/null); do
        # Idempotencia: saltar chunks ya parcheados COMPLETOS (con Fix4). No basta el
        # marcador "OTUI Android fix" (Fix2/Fix3 de un build anterior): Fix4 es nuevo y
        # debe aplicarse aunque Fix2/Fix3 ya estén. Fix2/Fix3 son naturalmente idempotentes
        # (sus patrones fuente dejan de existir tras aplicarse).
        grep -q "OTUI Android fix (Fix4)" "$CHUNK" && continue
        # Fix 2: resolveNativeLibraryPath() acepta android como linux.
        # NOTA: usa \n en el reemplazo de sed — requiere GNU sed (funciona en Termux).
        # El patrón con "{" respeta la 2ª ocurrencia de "process.platform === \"linux\""
        # (config.useThread = false) que NO tiene "{" y no debe tocarse.
        sed -i 's/if (process\.platform === "linux") {/\/\/ OTUI Android fix\n  if (process.platform === "linux" || process.platform === "android") {/g' "$CHUNK"
        # Fix 3: el chequeo OPENTUI_LIBC === "musl" también aplica en android
        sed -i 's/if (process\.env\.OPENTUI_LIBC === "musl") {/if (process.platform === "android" || process.env.OPENTUI_LIBC === "musl") {/g' "$CHUNK"
        # Fix 4: materializa libopentui.so del bunfs a $TMPDIR antes del dlopen.
        # Port del comportamiento de #opentui/runtime-assets de 0.4.5: bun.dlopen no
        # puede abrir paths virtuales $bunfs; el .so embebido ($bunfs/root/libopentui-<hash>.so)
        # se extrae a disco real con Bun.file()+writeFileSync y dlopen usa ESE path.
        # Usa importaciones REALES del bundle: writeFileSync/existsSync2 (import de "fs"),
        # join/basename (import de "path"), Bun.file (globalThis.Bun). Está en contexto
        # async (await resolveNativePackage() arriba) → await válido.
        sed -i 's~if (!existsSync2(targetLibPath)) {~// OTUI Android fix (Fix4): materializar libopentui.so del bunfs a $TMPDIR antes del dlopen\n// Port de #opentui/runtime-assets de 0.4.5: bun.dlopen no puede abrir paths virtuales $bunfs\nif (isBunfsPath(targetLibPath)) {\n  if (!process.env.TMPDIR) throw new Error("TMPDIR must be configured before materializing OpenTUI runtime assets");\n  var _otuiRealDir = process.env.TMPDIR;\n  var _otuiRealPath = join(_otuiRealDir, basename(targetLibPath));\n  if (!existsSync2(_otuiRealPath)) {\n    writeFileSync(_otuiRealPath, new Uint8Array(await Bun.file(targetLibPath).arrayBuffer()));\n  }\n  targetLibPath = _otuiRealPath;\n}\nif (!existsSync2(targetLibPath)) {~' "$CHUNK"
        OTUI_PATCHED=$((OTUI_PATCHED+1))
        echo "   bundle parcheado: $(basename "$CHUNK")"
    done
    # También buscar en .bun/ cache por si no está en node_modules directo
    # OJO: el dir del store es @opentui+core@0.3.4+<hash>/node_modules/@opentui/core/.
    # El bug del patrón viejo: el segmento del scoped package comienza con '@' y
    # '*/opentui+core*' nunca matchea (de ahí "@opentui+core*"). Glob index-*.js y NO
    # chunk-bun-*: 0.3.4 no tiene esos chunks (verificado contra el tarball npm).
    for CHUNK in $(find "$KILO_SRC/node_modules/.bun" -path "*/@opentui+core*/index-*.js" -type f ! -name "*.js.map" 2>/dev/null); do
        # Idempotencia: ver Fix4 (no "OTUI Android fix" solo) en el comentario del loop 1.
        grep -q "OTUI Android fix (Fix4)" "$CHUNK" && continue
        sed -i 's/if (process\.platform === "linux") {/\/\/ OTUI Android fix\n  if (process.platform === "linux" || process.platform === "android") {/g' "$CHUNK"
        sed -i 's/if (process\.env\.OPENTUI_LIBC === "musl") {/if (process.platform === "android" || process.env.OPENTUI_LIBC === "musl") {/g' "$CHUNK"
        # Fix 4: materializa libopentui.so del bunfs a $TMPDIR antes del dlopen (mismo que loop 1)
        sed -i 's~if (!existsSync2(targetLibPath)) {~// OTUI Android fix (Fix4): materializar libopentui.so del bunfs a $TMPDIR antes del dlopen\n// Port de #opentui/runtime-assets de 0.4.5: bun.dlopen no puede abrir paths virtuales $bunfs\nif (isBunfsPath(targetLibPath)) {\n  if (!process.env.TMPDIR) throw new Error("TMPDIR must be configured before materializing OpenTUI runtime assets");\n  var _otuiRealDir = process.env.TMPDIR;\n  var _otuiRealPath = join(_otuiRealDir, basename(targetLibPath));\n  if (!existsSync2(_otuiRealPath)) {\n    writeFileSync(_otuiRealPath, new Uint8Array(await Bun.file(targetLibPath).arrayBuffer()));\n  }\n  targetLibPath = _otuiRealPath;\n}\nif (!existsSync2(targetLibPath)) {~' "$CHUNK"
        OTUI_PATCHED=$((OTUI_PATCHED+1))
        echo "   bundle parcheado (.bun): $(basename "$CHUNK")"
    done

    # Verificación fail-fast: el marcador Fix4 real debe existir en el store.
    # (El contador mide archivos procesados, no sustituciones — no es fiable.)
    OTUI_PATCHED_FILES=$(grep -rl "OTUI Android fix (Fix4)" "$KILO_SRC/node_modules/.bun" 2>/dev/null | wc -l)
    if [ "$OTUI_PATCHED_FILES" -eq 0 ]; then
        echo "ERROR: OTUI Android fix (Fix4) no se aplicó a ningún bundle — abortando (dlopen no puede abrir $bunfs)"
        exit 1
    fi
    echo "   OTUI Android fix (Fix4) verificado en $OTUI_PATCHED_FILES archivo(s) del store"

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
    "$ANDROID_BUN" run "$SCRIPT_DIR/build-kilo-android.ts" 2>&1

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
