#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
CODEX_SRC="${REPO_ROOT}/codex/codex-rs"
WORK_DIR="${REPO_ROOT}/build"
MARKERS="${WORK_DIR}/.markers"
FINGERPRINT_FILE="$MARKERS/build-fingerprint-codex"
OUTPUT="${REPO_ROOT}/codex-android"
OUTPUT_HOST="${REPO_ROOT}/codex-code-mode-host"
BINARIES=("codex" "codex-tui" "codex-linux-sandbox" "codex-code-mode-host")

# ── Artefacto rusty_v8 (crate v8 = CODEX_V8_VERSION) para codex-code-mode-host ──
# El runtime companion code-mode-host embebe V8 y depende de `v8 = "=150.4.0"`
# (rusty_v8, feature v8_enable_sandbox → ptrcomp_sandbox). No hay prebuilt para
# aarch64-linux-android: el workflow build-rusty-v8-android.yml lo compila desde
# fuente (V8_FROM_SOURCE=1) y publica los 3 artefactos en la Release
# `rusty-v8-v<CODEX_V8_VERSION>` del repo del port. Con RUSTY_V8_ARCHIVE +
# RUSTY_V8_SRC_BINDING_PATH exportados, el build.rs del crate v8 NO descarga ni
# compila V8 (solo linkea el .a) → sin libclang ni NDK extra en Termux.
V8_VERSION="${V8_VERSION:-${CODEX_V8_VERSION:-}}"
if [ -z "$V8_VERSION" ] && [ -f "$SCRIPT_DIR/scripts/env.sh" ]; then
    # Parse tolerante de CODEX_V8_VERSION sin source de env.sh (evita efectos
    # laterales: banner + defaults de JOBS/ANDROID_NDK_HOME/REPO_ROOT). Maneja
    # los dos formatos posibles:
    #   export CODEX_V8_VERSION="${CODEX_V8_VERSION:-150.4.0}"  → param default
    #   export CODEX_V8_VERSION="150.4.0"                        → literal
    v8_env_line="$(grep -E '^[[:space:]]*export[[:space:]]+CODEX_V8_VERSION=' "$SCRIPT_DIR/scripts/env.sh" | head -1 || true)"
    if [ -n "$v8_env_line" ]; then
        v8_env_line="${v8_env_line#*=}"
        v8_env_line="${v8_env_line%\"}"; v8_env_line="${v8_env_line#\"}"
        if [[ "$v8_env_line" =~ ^\$\{.*:-(.*)\}$ ]]; then
            V8_VERSION="${BASH_REMATCH[1]}"
        else
            V8_VERSION="$v8_env_line"
        fi
    fi
fi
V8_VERSION="${V8_VERSION:-150.4.0}"
RUSTY_V8_DIR="${RUSTY_V8_DIR:-${REPO_ROOT}/build/rusty-v8}"
RUSTY_V8_ARCHIVE_NAME="librusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.a.gz"
RUSTY_V8_BINDING_NAME="src_binding_ptrcomp_sandbox_release_aarch64-linux-android.rs"
RUSTY_V8_MANIFEST_NAME="rusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.sha256"

mkdir -p "$MARKERS"

# ── Fuente de codex compartida con CI (mismo ref + mismos parches) ──
# Alinea el checkout local codex/ al mismo mecanismo que el CI
# (scripts/codex-prepare-source.sh): verifica el ref pinneado de env.sh y aplica
# los parches de patches/codex con verify_patched_state. Idempotente: si el
# worktree ya tiene los parches exactos (caso actual), no toca nada.
# Parse tolerante de CODEX_REF sin source de env.sh (evita efectos laterales:
# banner + defaults). Maneja los dos formatos posibles:
#   export CODEX_REF="${CODEX_REF:-50ef7395...}"  → param default
#   export CODEX_REF="50ef7395..."                → literal
CODEX_REF_LOCAL=""
if [ -f "$REPO_ROOT/scripts/env.sh" ]; then
    codex_ref_line="$(grep -E '^[[:space:]]*export[[:space:]]+CODEX_REF=' "$REPO_ROOT/scripts/env.sh" | head -1 || true)"
    if [ -n "$codex_ref_line" ]; then
        codex_ref_line="${codex_ref_line#*=}"
        codex_ref_line="${codex_ref_line%\"}"; codex_ref_line="${codex_ref_line#\"}"
        if [[ "$codex_ref_line" =~ ^\$\{.*:-(.*)\}$ ]]; then
            CODEX_REF_LOCAL="${BASH_REMATCH[1]}"
        else
            CODEX_REF_LOCAL="$codex_ref_line"
        fi
    fi
fi
[ -n "$CODEX_REF_LOCAL" ] || { echo "ERROR: no se pudo extraer CODEX_REF de scripts/env.sh" >&2; exit 1; }
echo ":: preparando fuente de codex en $CODEX_SRC (ref $CODEX_REF_LOCAL)..."
bash "$REPO_ROOT/scripts/codex-prepare-source.sh" "$REPO_ROOT/codex" "$CODEX_REF_LOCAL" "$REPO_ROOT/patches/codex"

start_timer() { START_TS=$(date +%s); }
elapsed() { local end=$(date +%s); echo $((end - START_TS)); }

# tcr: restringe CPUs y prioridad del proceso para builds pesados sin OOM killer
export PATH="$HOME/.local/bin:$PATH"

compute_fingerprint() {
    local fp=""
    fp+="fingerprint_version=3\n"

    local codex_head="" codex_dirty="" st=""
    if git -C "$CODEX_SRC" rev-parse HEAD >/dev/null 2>&1; then
        codex_head="$(git -C "$CODEX_SRC" rev-parse HEAD 2>/dev/null)"
        if st="$(git -C "$CODEX_SRC" status --porcelain 2>/dev/null)"; then
            codex_dirty="$(printf '%s' "$st" | sha256sum | cut -c1-16)"
        else
            codex_dirty="git-err"
        fi
    else
        if [ -d "$CODEX_SRC/src" ]; then
            codex_head="$(find "$CODEX_SRC/src" -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-40)"
        else
            codex_head="src-missing"
        fi
        codex_dirty="git-err"
    fi
    fp+="codex_head=${codex_head}\n"
    fp+="codex_dirty=${codex_dirty}\n"

    local root_lock="missing" root_pkg="missing"
    [ -f "$CODEX_SRC/Cargo.toml" ] && root_pkg="$(sha256sum "$CODEX_SRC/Cargo.toml" | cut -c1-16)"
    [ -f "$CODEX_SRC/Cargo.lock" ] && root_lock="$(sha256sum "$CODEX_SRC/Cargo.lock" | cut -c1-16)"
    fp+="codex_root_package_json=${root_pkg}\n"
    fp+="codex_root_cargo_lock=${root_lock}\n"

    local member_sha="missing"
    if [ -d "$CODEX_SRC" ]; then
        member_sha="$(find "$CODEX_SRC" -name Cargo.toml -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"
    fi
    fp+="codex_workspace_members_sha=${member_sha}\n"

    local cargo_config_sha="missing"
    if [ -f "$CODEX_SRC/.cargo/config.toml" ]; then
        cargo_config_sha="$(sha256sum "$CODEX_SRC/.cargo/config.toml" | cut -c1-16)"
    fi
    fp+="codex_cargo_config_sha=${cargo_config_sha}\n"

    local script="" h="missing"
    for script in codex_build.sh; do
        h="missing"
        if [ -f "$SCRIPT_DIR/$script" ]; then
            h="$(sha256sum "$SCRIPT_DIR/$script" 2>/dev/null | cut -c1-16)"
        fi
        fp+="sha_${script//[^a-zA-Z0-9]/_}=${h}\n"
    done

    local out_sha="missing"
    [ -f "$OUTPUT" ] && out_sha="$(sha256sum "$OUTPUT" 2>/dev/null | cut -c1-16)"
    fp+="output_path=${OUTPUT}\n"
    fp+="output_sha=${out_sha}\n"

    local patch_sha="missing"
    if [ -d "$SCRIPT_DIR/patches/codex" ]; then
        patch_sha="$(find "$SCRIPT_DIR/patches/codex" -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"
    elif [ -d "$SCRIPT_DIR/patches/rust" ]; then
        patch_sha="$(find "$SCRIPT_DIR/patches/rust" -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -c1-16)"
    fi
    fp+="codex_patches_sha=${patch_sha}\n"

    # code_mode_host: integración del runtime companion (crate v8). Refleja la
    # versión del artefacto rusty_v8 + hash del manifest descargado (si existe);
    # un bump de CODEX_V8_VERSION o un artefacto nuevo invalida el rebuild.
    local host_ver="missing"
    host_ver="v8=${V8_VERSION}"
    if [ -f "$RUSTY_V8_DIR/$RUSTY_V8_MANIFEST_NAME" ]; then
        host_ver+=":$(sha256sum "$RUSTY_V8_DIR/$RUSTY_V8_MANIFEST_NAME" | cut -c1-16)"
    fi
    fp+="code_mode_host=${host_ver}\n"

    local host_out_sha="missing"
    [ -f "$OUTPUT_HOST" ] && host_out_sha="$(sha256sum "$OUTPUT_HOST" 2>/dev/null | cut -c1-16)"
    fp+="code_mode_host_output_sha=${host_out_sha}\n"

    # bionic_stubs.c: el link del host (codex-code-mode-host) inyecta estos
    # stubs bionic (scripts/bionic-stubs.c: __clear_cache/aligned_alloc/
    # strtof_l/strtod_l) + compiler-rt del NDK vía el build.rs del crate
    # (parche 16). Un cambio en el stub invalida el rebuild del host.
    local bionic_stubs_sha="missing"
    [ -f "$SCRIPT_DIR/scripts/bionic-stubs.c" ] && bionic_stubs_sha="$(sha256sum "$SCRIPT_DIR/scripts/bionic-stubs.c" | cut -c1-16)"
    fp+="bionic_stubs_sha=${bionic_stubs_sha}\n"

    echo -e "$fp"
}

FINGERPRINT_NOW="$(compute_fingerprint)"
if [ ! -f "$FINGERPRINT_FILE" ]; then
    echo ":: Sin fingerprint previo — forzando build completo"
elif [ -f "$OUTPUT" ] && [ -f "$OUTPUT_HOST" ] && [ "$FINGERPRINT_NOW" = "$(cat "$FINGERPRINT_FILE")" ]; then
    LAST_HEAD="$(grep '^codex_head=' "$FINGERPRINT_FILE" | cut -d= -f2-)"
    echo ":: SKIP: sin cambios (ultimo HEAD: ${LAST_HEAD:-<n/a>}, binario: $OUTPUT)"
    ls -lh "$OUTPUT" | awk '{print "   " $5 " " $NF}'
    exit 0
else
    echo ":: Cambio detectado en el fingerprint — recompilando:"
    while IFS= read -r line; do
        key="${line%%=*}"
        val_now="${line#*=}"
        val_old="$(grep "^${key}=" "$FINGERPRINT_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [ "$val_old" != "$val_now" ]; then
            printf '   - %s: %s -> %s\n' "$key" "${val_old:-<ausente>}" "$val_now"
        fi
    done <<< "$FINGERPRINT_NOW"
fi

# ── Artefacto rusty_v8 para codex-code-mode-host ──
# Descarga los 3 artefactos (archive .a.gz + binding .rs + manifest .sha256) de
# la Release `rusty-v8-v${V8_VERSION}` del repo del port y exporta
# RUSTY_V8_ARCHIVE + RUSTY_V8_SRC_BINDING_PATH para el cargo build del host.
# Patrón análogo al Android Bun en .bun-artifact/bun-downloaded. Fail-fast: si
# el artefacto no está publicado, aborta con mensaje de lanzar primero el
# workflow build-rusty-v8-android.yml. Idempotente: no re-descarga si los 3
# archivos ya existen y el manifest verifica.
setup_rusty_v8() {
    local repo="${RUSTY_V8_REPO:-}"
    if [ -z "$repo" ]; then
        repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    fi
    if [ -z "$repo" ]; then
        repo="Leonisaurov/opencode-termux"
        echo ":: usando fallback de repo $repo (gh no disponible o sin autenticar)" >&2
    fi
    local base="https://github.com/${repo}/releases/download/rusty-v8-v${V8_VERSION}"
    mkdir -p "$RUSTY_V8_DIR"

    local need_download=0 f=""
    for f in "$RUSTY_V8_MANIFEST_NAME" "$RUSTY_V8_ARCHIVE_NAME" "$RUSTY_V8_BINDING_NAME"; do
        [ -f "$RUSTY_V8_DIR/$f" ] || need_download=1
    done
    if [ "$need_download" = "1" ]; then
        echo "   Descargando artefacto rusty_v8 v${V8_VERSION} ($repo)..."
        for f in "$RUSTY_V8_MANIFEST_NAME" "$RUSTY_V8_ARCHIVE_NAME" "$RUSTY_V8_BINDING_NAME"; do
            echo "     - $f"
            if ! curl -fsSL -o "$RUSTY_V8_DIR/$f" "$base/$f"; then
                rm -f "$RUSTY_V8_DIR/$f"
                echo "ERROR: no se pudo descargar $base/$f" >&2
                echo "       El artefacto lo genera el workflow build-rusty-v8-android.yml del repo del port" >&2
                echo "       (compila librusty_v8 desde fuente con V8_FROM_SOURCE=1 y lo publica en la" >&2
                echo "       Release rusty-v8-v${V8_VERSION}). Lánzalo primero:" >&2
                echo "         gh workflow run build-rusty-v8-android.yml -f v8_version=${V8_VERSION}" >&2
                echo "       o descarga los 3 archivos manualmente a $RUSTY_V8_DIR:" >&2
                echo "         $RUSTY_V8_ARCHIVE_NAME" >&2
                echo "         $RUSTY_V8_BINDING_NAME" >&2
                echo "         $RUSTY_V8_MANIFEST_NAME" >&2
                exit 1
            fi
        done
    fi

    # Validación del manifest: exactamente 2 líneas ("sha256  nombre" por archivo)
    # y checksums correctos contra los archivos descargados.
    local lines=""
    lines="$(wc -l < "$RUSTY_V8_DIR/$RUSTY_V8_MANIFEST_NAME" | tr -d ' ')"
    [ "$lines" = "2" ] || {
        echo "ERROR: manifest rusty_v8 inválido: $lines líneas (esperado 2): $RUSTY_V8_DIR/$RUSTY_V8_MANIFEST_NAME" >&2
        exit 1
    }
    ( cd "$RUSTY_V8_DIR" && sha256sum -c "$RUSTY_V8_MANIFEST_NAME" ) || {
        echo "ERROR: checksum rusty_v8 falló (artefacto corrupto); borra $RUSTY_V8_DIR y reintenta" >&2
        exit 1
    }

    export RUSTY_V8_ARCHIVE="$RUSTY_V8_DIR/$RUSTY_V8_ARCHIVE_NAME"
    export RUSTY_V8_SRC_BINDING_PATH="$RUSTY_V8_DIR/$RUSTY_V8_BINDING_NAME"
    echo "   rusty_v8 listo: $RUSTY_V8_ARCHIVE"
}

echo ":: [1/4] Verificando herramientas..."
command -v cargo >/dev/null 2>&1 || { echo "cargo no encontrado. Instala Rust con: pkg install rust" >&2; exit 1; }
command -v rustc >/dev/null 2>&1 || { echo "rustc no encontrado" >&2; exit 1; }
echo "   cargo: $(cargo --version)"
echo "   rustc: $(rustc --version)"

# --- Selección de toolchain NDK (host-aware) ---
case "$(uname -m)" in
    aarch64|arm64) HOST_TAG="linux-aarch64" ;;
    x86_64|amd64)  HOST_TAG="linux-x86_64" ;;
    *) echo "Host no soportado para el prebuilt del NDK: $(uname -m)" >&2; exit 1 ;;
esac
echo "   NDK host tag: $HOST_TAG"

# Un NDK es válido si su prebuilt ${HOST_TAG} tiene al menos un wrapper clang aarch64
# (bare o con sufijo de API). Esto descarta NDKs incompletos o prebuilts de otra arquitectura.
ndk_is_valid() {
    local ndk="$1" dir
    dir="$ndk/toolchains/llvm/prebuilt/${HOST_TAG}/bin"
    [ -d "$dir" ] || return 1
    compgen -G "$dir/aarch64-linux-android*-clang" >/dev/null
}

# ANDROID_NDK_HOME explícito: se respeta solo si es válido para este host
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-}"
if [ -n "$ANDROID_NDK_HOME" ] && ! ndk_is_valid "$ANDROID_NDK_HOME"; then
    echo "   ANDROID_NDK_HOME no sirve para ${HOST_TAG}: $ANDROID_NDK_HOME" >&2
    echo "   (se buscará automáticamente otro NDK)" >&2
    ANDROID_NDK_HOME=""
fi

# Autodetección: elige el NDK de mayor versión cuyo prebuilt ${HOST_TAG} sea válido
if [ -z "$ANDROID_NDK_HOME" ]; then
    BEST_NDK=""
    for ndk in "$HOME/Android/ndk"/* "$PREFIX/opt/android-ndk" "$HOME/android-ndk"; do
        [ -d "$ndk" ] || continue
        ndk_is_valid "$ndk" || continue
        if [ -z "$BEST_NDK" ] ||
           [ "$(printf '%s\n' "$(basename "$BEST_NDK")" "$(basename "$ndk")" | sort -V | tail -1)" = "$(basename "$ndk")" ]; then
            BEST_NDK="$ndk"
        fi
    done
    ANDROID_NDK_HOME="$BEST_NDK"
fi

if [ -z "$ANDROID_NDK_HOME" ] || ! ndk_is_valid "$ANDROID_NDK_HOME"; then
    echo "NDK con prebuilt ${HOST_TAG} no encontrado en ANDROID_NDK_HOME ni rutas comunes." >&2
    echo "Rutas buscadas:" >&2
    for ndk in "$HOME/Android/ndk"/* "$PREFIX/opt/android-ndk" "$HOME/android-ndk"; do
        printf '   - %s\n' "$ndk" >&2
    done
    echo "Instala un NDK que incluya toolchains/llvm/prebuilt/${HOST_TAG} (ej. r29-termux)" >&2
    echo "o define ANDROID_NDK_HOME, por ejemplo:" >&2
    echo "  export ANDROID_NDK_HOME=\$HOME/Android/ndk/r29-termux" >&2
    exit 1
fi

NDK_TOOLCHAIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_TAG}"
echo "   NDK: $ANDROID_NDK_HOME"
echo "   Toolchain: $NDK_TOOLCHAIN"

# Nombre del wrapper clang: bare si existe; si no, el de API 24 (convención del repo,
# ver build/libc-android.txt). El NDK r29-termux solo expone wrappers con sufijo.
if [ -x "$NDK_TOOLCHAIN/bin/aarch64-linux-android-clang" ]; then
    NDK_CLANG_PREFIX="aarch64-linux-android"
elif [ -x "$NDK_TOOLCHAIN/bin/aarch64-linux-android24-clang" ]; then
    NDK_CLANG_PREFIX="aarch64-linux-android24"
else
    echo "No se encontró wrapper clang aarch64 en: $NDK_TOOLCHAIN/bin" >&2
    exit 1
fi
echo "   Clang wrapper: ${NDK_CLANG_PREFIX}-clang"

# --- Check defensivo libdl.so (idempotente) ---
# En bionic los símbolos dl* los exporta libdl.so (NO libc). Un stub roto con
# contenido "INPUT(-lc)" (texto ASCII, 11 bytes, no ELF) hace que rustc/std
# (backtrace-gimli vía -lunwind del NDK) falle con "undefined symbol:
# dl_iterate_phdr". Si el libdl.so del API level activo es inválido, se restaura
# desde un stub ELF válido de un dir hermano del mismo sysroot (21..35).
libdl_api_is_valid() {
    local lib="$1"
    [ -f "$lib" ] || return 1
    "$NDK_TOOLCHAIN/bin/llvm-nm" -D "$lib" 2>/dev/null | grep -q dl_iterate_phdr
}

# Extraer el API level del prefijo del wrapper (ej. aarch64-linux-android24 -> 24).
# Si el prefijo es el bare aarch64-linux-android (wrapper sin sufijo), el wrapper
# usa el API mínimo del NDK; aquí convenimos 24 por convención del repo
# (ver build/libc-android.txt y el fallback de la línea 168).
if [[ "$NDK_CLANG_PREFIX" == *-android[0-9]* ]]; then
    API="${NDK_CLANG_PREFIX##*-android}"
else
    API="24"
fi
SYSROOT_LIB="$NDK_TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/$API"

if ! libdl_api_is_valid "$SYSROOT_LIB/libdl.so"; then
    echo ":: [toolchain] libdl.so API ${API} inválido en $SYSROOT_LIB/libdl.so, buscando stub válido..."
    RESTORED=""
    # Probar hermanos válidos: 25 primero, luego 35..21 en orden descendente.
    for cand in 25 {35..21}; do
        [ "$cand" = "$API" ] && continue
        cand_lib="$NDK_TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/$cand/libdl.so"
        if libdl_api_is_valid "$cand_lib"; then
            cp "$cand_lib" "$SYSROOT_LIB/libdl.so"
            RESTORED="$cand"
            break
        fi
    done
    if [ -n "$RESTORED" ]; then
        echo ":: [toolchain] libdl.so API ${API} corrupto, restaurado desde API ${RESTORED}"
    else
        echo "ERROR: libdl.so inválido en $SYSROOT_LIB y sin fuente válida entre APIs 21-35" >&2
        exit 1
    fi
fi

# JOBS efectivo lo controla tcr (-j 1); este export solo cubre comandos fuera de tcr y respeta el entorno si JOBS ya está definido.
export JOBS="${JOBS:-1}"
export CARGO_NET_RETRY=3
export CARGO_HTTP_TIMEOUT=30
export TMPDIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}"

# --- Overrides de perfil release para reducir el pico de RAM del build ---
# El perfil release del workspace usa lto="thin", codegen-units=4 y
# debug="line-tables-only". En este dispositivo (MemAvailable real ~4 GiB)
# el pico ocurre en codex-core: compile ~2-2.5 GB y el LINK con LTO thin puede
# superar el techo y morir por el RAM guard de tcr (rc 137). Estos overrides
# vía CARGO_PROFILE_<perfil>_<clave> (convención oficial de cargo, ver
# `cargo build --help` -> "Profile Selection") anulan ese perfil por entorno
# SIN tocar Cargo.toml ni el fingerprint:
#   - LTO=false        → elimina el pico del link (binario algo mayor/runtime algo más lento; aceptable en device)
#   - codegen-units=1  → mínimo pico de rustc (compila algo más lento, mucho menos RAM)
#   - debug=0          → NO aplica a este target: .cargo/config.toml inyecta
#                       -C debuginfo=line-tables-only en los rustflags del target
#                       (tienen precedencia sobre CARGO_PROFILE_*_DEBUG). El ahorro
#                       real de RAM viene de LTO=false y codegen-units=1.
# Para revertir al perfil original (lto=thin, codegen-units=4) exporta:
#   CODEX_PROFILE_LTO=thin CODEX_PROFILE_CODEGEN_UNITS=4 CODEX_PROFILE_DEBUG="line-tables-only"
export CODEX_PROFILE_LTO="${CODEX_PROFILE_LTO:-false}"
export CODEX_PROFILE_CODEGEN_UNITS="${CODEX_PROFILE_CODEGEN_UNITS:-1}"
export CODEX_PROFILE_DEBUG="${CODEX_PROFILE_DEBUG:-0}"
export CARGO_PROFILE_RELEASE_LTO="$CODEX_PROFILE_LTO"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$CODEX_PROFILE_CODEGEN_UNITS"
export CARGO_PROFILE_RELEASE_DEBUG="$CODEX_PROFILE_DEBUG"

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_CLANG_PREFIX}-clang"
export AR="llvm-ar"
export CC_aarch64_linux_android="${NDK_CLANG_PREFIX}-clang"
export CXX_aarch64_linux_android="${NDK_CLANG_PREFIX}-clang++"
export PATH="$NDK_TOOLCHAIN/bin:$PATH"

# ── Stubs bionic + compiler-rt del NDK para el link del host ──
# codex-code-mode-host (crate v8, use_custom_libcxx) referencia símbolos que
# bionic API 24 no exporta: __clear_cache (compiler-rt del NDK), aligned_alloc,
# strtof_l y strtod_l. Se compila scripts/bionic-stubs.c contra el clang del NDK
# local a $CODEX_SRC/target/bionic-stubs.o (target/ está gitignored → no toca
# el fingerprint del checkout) y se localiza libclang_rt.builtins del NDK (en
# Termux el prebuilt es linux-aarch64; el find cubre cualquier prebuilt/*). Las
# rutas llegan al link vía el build.rs del crate host (parche 16) leyendo las
# env vars — NO vía RUSTFLAGS: un RUSTFLAGS global reemplazaría los rustflags
# del .cargo/config.toml parcheado (que ya incluyen target-feature=-crt-static).
mkdir -p "$CODEX_SRC/target"
"$NDK_TOOLCHAIN/bin/${NDK_CLANG_PREFIX}-clang" -c -O2 -Wall -Wextra \
    "$SCRIPT_DIR/scripts/bionic-stubs.c" -o "$CODEX_SRC/target/bionic-stubs.o" \
    || { echo "ERROR: falló la compilación de scripts/bionic-stubs.c (API $API)" >&2; exit 1; }
export CODEX_BIONIC_STUBS_O="$CODEX_SRC/target/bionic-stubs.o"
CODEX_CLANG_RT_BUILTINS="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
    -name 'libclang_rt.builtins-aarch64-android.a' 2>/dev/null | head -1 || true)"
[ -n "$CODEX_CLANG_RT_BUILTINS" ] || {
    echo "ERROR: no se encontró libclang_rt.builtins-aarch64-android.a en $ANDROID_NDK_HOME/toolchains/llvm/prebuilt" >&2
    exit 1
}
export CODEX_CLANG_RT_BUILTINS
echo "   stubs bionic: $CODEX_BIONIC_STUBS_O"
echo "   compiler-rt:  $CODEX_CLANG_RT_BUILTINS"

echo ":: [2/4] Preparando target Rust, artefacto rusty_v8 y fetching deps..."
start_timer
cd "$CODEX_SRC"
setup_rusty_v8
if [ ! -f "$MARKERS/codex-fetched" ]; then
    echo "   cargo fetch (puede tardar en la primera run)..."
    tcr cargo fetch --target aarch64-linux-android 2>&1
    touch "$MARKERS/codex-fetched"
    echo "   deps fetcheadas ($(elapsed)s)"
else
    echo "   deps ya fetcheadas (skip)"
fi

echo ":: [3/4] Compilando binarios auxiliares..."
start_timer
AUX_BINS=("codex-tui" "codex-linux-sandbox")

# RAM disponible del sistema en MB (MemAvailable, fallback MemFree: mismo
# criterio que tcr). Devuelve 0 si no se puede leer (nunca reportar vacío).
mem_avail_mb() {
    local kb=""
    kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || true)"
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        kb="$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null || true)"
    fi
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        echo 0
        return 1
    fi
    echo $(( kb / 1024 ))
}

# Envuelve un build tcr+cargo con reintentos anti-OOM. El RAM guard de tcr
# (-r 1024) y el LMKD pueden matar el proceso con rc 137 (128+SIGKILL) si el
# pico de memoria supera el MemAvailable real (~4 GiB en este dispositivo).
# cargo resumen incrementalmente desde target/, así que cada reintento avanza:
# el build puede completarse en varias sesiones sin descartarse definitivamente.
# El rc real del comando se captura en la rama else del if: el exit status de
# un `if cmd; then ... fi` sin else es SIEMPRE 0, así que NO se puede capturar
# tras el fi. Dentro de `else`, $? conserva el rc real del comando fallido.
# Reintenta hasta CODEX_BUILD_MAX_RETRIES (default 4) esperando
# CODEX_RETRY_DELAY (default 30) segundos entre intentos.
build_with_retry() {
    local max="${CODEX_BUILD_MAX_RETRIES:-4}"
    if [[ ! "$max" =~ ^[0-9]+$ ]]; then
        echo "WARN: CODEX_BUILD_MAX_RETRIES='${max}' no es numérico; usando default 4." >&2
        max=4
    fi
    local delay="${CODEX_RETRY_DELAY:-30}"
    local attempt=1 rc=0
    while :; do
        echo "   [retry] intento $attempt/$max (MemAvailable: $(mem_avail_mb) MB)..."
        if "$@"; then
            echo "   [retry] OK en intento $attempt/$max (MemAvailable restante: $(mem_avail_mb) MB)"
            return 0
        else
            rc=$?
        fi
        if [ "$rc" -ne 137 ]; then
            echo "ERROR: build falló con rc=$rc (no es OOM/SIGKILL 137); no se reintenta." >&2
            echo "       El error real de cargo/tcr está justo encima; no es un problema de RAM." >&2
            exit 1
        fi
        if [ "$attempt" -ge "$max" ]; then
            echo "ERROR: build muerto por OOM (rc=137) tras $max intentos. MemAvailable actual: $(mem_avail_mb) MB." >&2
            echo "       Cierra apps pesadas (navegador, juegos, Android Studio) y reintenta." >&2
            echo "       O sube tolerancia: export CODEX_BUILD_MAX_RETRIES=<n> (default 4)." >&2
            echo "       Para bajar el pico de RAM: CODEX_PROFILE_LTO=${CODEX_PROFILE_LTO}, CODEX_PROFILE_CODEGEN_UNITS=${CODEX_PROFILE_CODEGEN_UNITS}, CODEX_PROFILE_DEBUG=${CODEX_PROFILE_DEBUG}." >&2
            exit 1
        fi
        echo "   [tcr] build muerto por OOM (rc=137), quedan $(( max - attempt )) reintentos. MemAvailable $(mem_avail_mb) MB. Esperando ${delay}s..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}
# tcr flags (protección anti-OOM en Android):
#   -o 1000  → oom_score_adj máximo: si LMKD tiene que matar algo, mata el build, NO la app de Termux (en background adj ~940)
#   -r 1024  → RAM guard: mata el build si quedan <1024 MB libres en el sistema (evita que PSI/LMKD dispare)
#   -j 1     → limita jobs de cargo a 1: con -j 2, codex-core (opt-level=3 + LTO)
#             dispara picos de ~5-6 GB que hunden la RAM disponible bajo el umbral
#             del RAM guard (-r 1024) y el build muere; con -j 1 el pico baja a
#             ~2-2.5 GB y el build completa.
for bin in "${AUX_BINS[@]}"; do
    echo "   Compilando $bin... (MemAvailable: $(mem_avail_mb) MB)"
    build_with_retry tcr -o 1000 -r 1024 -j 1 cargo build --release --target aarch64-linux-android -p "$bin"
    echo "   $bin compilado ($(elapsed)s) — MemAvailable restante: $(mem_avail_mb) MB"
done

echo ":: [4/4] Compilando codex-cli + codex-code-mode-host (workspace principal)..."
start_timer

# Check de RAM propio con umbral alineado al flag -r 1024 de tcr: si el check
# abortara antes (p. ej. 400 MB), el build moriría igualmente por el RAM guard
# de tcr con mensajes contradictorios. Usa mem_avail_mb() (MemAvailable con
# fallback MemFree, mismo criterio que tcr); 0 = error de lectura, nunca "0 MB".
MEM_AVAIL="$(mem_avail_mb)" || {
    echo "ERROR: no se pudo leer /proc/meminfo para verificar la RAM disponible; el build de codex no puede continuar." >&2
    exit 1
}
if [ "$MEM_AVAIL" -lt 1024 ]; then
    echo "ERROR: RAM disponible ($MEM_AVAIL MB) por debajo del umbral de 1024 MB (flag tcr -r 1024); el build de codex no puede continuar." >&2
    echo "Cierra apps pesadas y reintenta. (La protección tcr -r 1024 evitaría el OOM, pero sin margen inicial el build aborta.)" >&2
    echo "Si el margen se agota a mitad del build, build_with_retry reintentará hasta CODEX_BUILD_MAX_RETRIES." >&2
    echo "Para bajar aún más el pico de RAM: CODEX_PROFILE_LTO=false, CODEX_PROFILE_CODEGEN_UNITS=1 (ya activos por defecto)." >&2
    exit 1
fi
echo "INFO: RAM disponible $MEM_AVAIL MB; tcr usará -o 1000 -r 1024 -j 1 (protección anti-OOM) con reintentos (CODEX_BUILD_MAX_RETRIES=${CODEX_BUILD_MAX_RETRIES:-4})." >&2

# -p codex-code-mode-host: runtime companion (V8 embebido) que el CLI busca como
# binario hermano. Comparte el workspace con codex-cli (mismas deps tonic/axum/
# tokio/prost); el crate v8 solo LINKEA el .a prebuilt (RUSTY_V8_ARCHIVE) — sin
# libclang ni NDK extra. Mismo patrón anti-OOM: tcr -j 1 + build_with_retry.
build_with_retry tcr -o 1000 -r 1024 -j 1 cargo build --release --target aarch64-linux-android -p codex-cli -p codex-code-mode-host
echo "   codex-cli + codex-code-mode-host compilados ($(elapsed)s) — MemAvailable restante: $(mem_avail_mb) MB"

CODEX_BIN=""
for candidate in \
    "$CODEX_SRC/target/aarch64-linux-android/release/codex" \
    "$CODEX_SRC/cli/target/aarch64-linux-android/release/codex"; do
    if [ -f "$candidate" ]; then
        CODEX_BIN="$candidate"
        break
    fi
done

if [ -z "$CODEX_BIN" ] || [ ! -f "$CODEX_BIN" ]; then
    echo "Binario codex no encontrado tras el build"
    find "$CODEX_SRC" -path "*/aarch64-linux-android/release/codex" -type f 2>/dev/null || true
    exit 1
fi

cp "$CODEX_BIN" "$OUTPUT"
chmod +x "$OUTPUT"
echo "   Binario copiado: $OUTPUT"

# codex-code-mode-host: copiar junto a codex-android (binario hermano que busca
# el CLI). Fail-fast: si el build pasó pero el binario no está, hay un problema.
CODE_MODE_HOST_BIN=""
for candidate in \
    "$CODEX_SRC/target/aarch64-linux-android/release/codex-code-mode-host" \
    "$CODEX_SRC/code-mode-host/target/aarch64-linux-android/release/codex-code-mode-host"; do
    if [ -f "$candidate" ]; then
        CODE_MODE_HOST_BIN="$candidate"
        break
    fi
done
if [ -z "$CODE_MODE_HOST_BIN" ] || [ ! -f "$CODE_MODE_HOST_BIN" ]; then
    echo "ERROR: codex-code-mode-host no encontrado tras el build" >&2
    find "$CODEX_SRC" -path "*/aarch64-linux-android/release/codex-code-mode-host" -type f 2>/dev/null || true
    exit 1
fi
cp "$CODE_MODE_HOST_BIN" "$OUTPUT_HOST"
chmod +x "$OUTPUT_HOST"
echo "   Host copiado: $OUTPUT_HOST"

# Log informativo de los NEEDED reales del host (libc++ estático embebido del
# crate v8 vs libc++_shared.so dinámico). NO fail-fast: solo diagnóstico para
# el output del build (ver Codex-port.md "Requisito runtime").
if command -v readelf >/dev/null 2>&1; then
    echo "   [NEEDED] codex-code-mode-host:"
    readelf -d "$OUTPUT_HOST" | grep NEEDED || echo "   [NEEDED] <sin entradas NEEDED>"
else
    echo "   [NEEDED] readelf no disponible; file: $(file "$OUTPUT_HOST" | cut -d: -f2-)"
fi

for bin in "${BINARIES[@]}"; do
    bin_path=""
    for candidate in \
        "$CODEX_SRC/target/aarch64-linux-android/release/$bin" \
        "$CODEX_SRC/${bin/codex-/}/target/aarch64-linux-android/release/$bin" \
        "$CODEX_SRC/cli/target/aarch64-linux-android/release/$bin" \
        "$CODEX_SRC/tui/target/aarch64-linux-android/release/$bin" \
        "$CODEX_SRC/linux-sandbox/target/aarch64-linux-android/release/$bin"; do
        if [ -f "$candidate" ]; then
            bin_path="$candidate"
            break
        fi
    done
    if [ -n "$bin_path" ] && [ -f "$bin_path" ]; then
        echo "   Auxiliar presente: $bin ($(du -h "$bin_path" | cut -f1))"
    else
        echo "   Auxiliar no hallado: $bin (puede no ser necesario en runtime)"
    fi
done

# Idempotencia del checkout: cargo (sin --locked) puede reescribir Cargo.lock;
# se restaura para que el siguiente run del helper verifique parches exactos.
git -C "$CODEX_SRC" checkout -- Cargo.lock 2>/dev/null || true

echo ""
echo ":: Build completado:"
echo "   CLI:  ${OUTPUT}"
ls -lh "$OUTPUT" | awk '{print "   " $5 " " $NF}'
file "$OUTPUT" | awk -F: '{print "   " $2}'
echo "   Host: ${OUTPUT_HOST} (codex-code-mode-host, V8 embebido)"
ls -lh "$OUTPUT_HOST" | awk '{print "   " $5 " " $NF}'
file "$OUTPUT_HOST" | awk -F: '{print "   " $2}'

FINGERPRINT_NOW="$(compute_fingerprint)"
printf '%b' "$FINGERPRINT_NOW" > "$FINGERPRINT_FILE"
echo ":: fingerprint actualizado: $FINGERPRINT_FILE"
