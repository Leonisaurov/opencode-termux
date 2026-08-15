#!/usr/bin/env bash
# build-codex-ci.sh - Cross-compila openai/codex (CLI Rust) para Android/Termux (aarch64, bionic) en CI
#
# Port Rust puro: NO usa Bun/Zig/libopentui. Cross-compile con:
#   cargo build --release --target aarch64-linux-android
#
# Dependencias:
#   - openai/codex clonado al pin CODEX_REF (los parches de patches/codex/*.patch se aplican sobre el checkout limpio)
#   - rustup + channel de codex-rs/rust-toolchain.toml (1.95.0) + target aarch64-linux-android
#   - Android NDK con prebuilt para este host (ANDROID_NDK_HOME)
#   - Deps nativas: openssl-sys vendored (perl/make), onig_sys (C), aws-lc-rs (cmake), protoc-bin-vendored (host linux)
#
# Uso:
#   ANDROID_NDK_HOME=/opt/android-ndk ./scripts/build-codex-ci.sh
#
# Variables (todas con default salvo ANDROID_NDK_HOME, que es obligatoria):
#   CODEX_REF  (default: pin 50ef7395...) — commit sha (40 hex) O tag (p.ej. rust-v0.134.0-alpha.3)
#   CODEX_VERSION (vacío por defecto → se deriva con git describe, ver [5/5])
#   JOBS       (default 2)
#   WORK_DIR   (default: $REPO_ROOT/build/codex-ci)
#   CODEX_REPO (default: $WORK_DIR/codex) — raíz del checkout de openai/codex
#   CODEX_SRC  (default: $CODEX_REPO/codex-rs) — workspace Rust (Cargo/rust-toolchain/target)
#   ANDROID_NDK_HOME (obligatoria)
#   REPO_ROOT  (default: raíz de este repo)
#   PATCHES_DIR (default: $REPO_ROOT/patches/codex)
set -euo pipefail

# ── Helpers ──
msg() { echo "$*"; }
start_timer() { START_TS=$(date +%s); }
elapsed() { local end=$(date +%s); echo $((end - START_TS)); }
BUILD_START_TS=$(date +%s)
elapsed_total() { local end=$(date +%s); echo $((end - BUILD_START_TS)); }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── Artefacto rusty_v8 para codex-code-mode-host ──
# Descarga los 3 artefactos (archive .a.gz + binding .rs + manifest .sha256) de
# la Release `rusty-v8-v${V8_VERSION}` del repo del port. Fail-fast: si la
# descarga o la verificación (manifest de EXACTAMENTE 2 líneas + sha256sum -c)
# falla, aborta con mensaje de lanzar primero build-rusty-v8-android.yml.
# Idempotente: si los 3 archivos ya existen y el manifest verifica, no re-descarga.
setup_rusty_v8() {
    local base="$RUSTY_V8_REPO"
    base="https://github.com/${base}/releases/download/rusty-v8-v${V8_VERSION}"
    mkdir -p "$RUSTY_V8_DIR"

    local need_download=0 f=""
    for f in "$RUSTY_V8_MANIFEST_NAME" "$RUSTY_V8_ARCHIVE_NAME" "$RUSTY_V8_BINDING_NAME"; do
        [ -f "$RUSTY_V8_DIR/$f" ] || need_download=1
    done
    if [ "$need_download" = "1" ]; then
        echo "   Descargando artefacto rusty_v8 v${V8_VERSION} (${RUSTY_V8_REPO})..."
        for f in "$RUSTY_V8_MANIFEST_NAME" "$RUSTY_V8_ARCHIVE_NAME" "$RUSTY_V8_BINDING_NAME"; do
            echo "     - $f"
            if ! curl -fsSL -o "$RUSTY_V8_DIR/$f" "$base/$f"; then
                rm -f "$RUSTY_V8_DIR/$f"
                echo "ERROR: no se pudo descargar $base/$f" >&2
                echo "       El artefacto lo genera el workflow build-rusty-v8-android.yml del repo del port" >&2
                echo "       (compila librusty_v8 desde fuente con V8_FROM_SOURCE=1 y lo publica en la" >&2
                echo "       Release rusty-v8-v${V8_VERSION}). Lánzalo primero (gh workflow run" >&2
                echo "       build-rusty-v8-android.yml -f v8_version=${V8_VERSION}) o descarga los 3" >&2
                echo "       archivos manualmente a $RUSTY_V8_DIR:" >&2
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
    [ "$lines" = "2" ] || die "manifest rusty_v8 inválido: $lines líneas (esperado 2): $RUSTY_V8_DIR/$RUSTY_V8_MANIFEST_NAME"
    ( cd "$RUSTY_V8_DIR" && sha256sum -c "$RUSTY_V8_MANIFEST_NAME" ) \
        || die "checksum rusty_v8 falló (artefacto corrupto); borra $RUSTY_V8_DIR y reintenta"

    export RUSTY_V8_ARCHIVE="$RUSTY_V8_DIR/$RUSTY_V8_ARCHIVE_NAME"
    export RUSTY_V8_SRC_BINDING_PATH="$RUSTY_V8_DIR/$RUSTY_V8_BINDING_NAME"
    echo "   rusty_v8 listo: $RUSTY_V8_ARCHIVE"
}

# ── Config ──
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PATCHES_DIR="${PATCHES_DIR:-$REPO_ROOT/patches/codex}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/build/codex-ci}"
# CODEX_REPO = raíz del checkout de openai/codex (operaciones git: fetch/checkout/apply/status/describe).
# CODEX_SRC   = workspace Rust del repo (codex-rs/): rust-toolchain.toml, Cargo.toml y target/.
CODEX_REPO="${CODEX_REPO:-$WORK_DIR/codex}"
CODEX_SRC="${CODEX_SRC:-$CODEX_REPO/codex-rs}"
CODEX_REF="${CODEX_REF:-50ef7395faee1d0e2d01730f9636aa06091c7be3}"
CODEX_VERSION="${CODEX_VERSION:-}"
JOBS="${JOBS:-2}"
# CODEX_BINS: binarios a compilar/empaquetar (el workflow lo pasa como input
# `bins` vía env CODEX_BINS). Nombres de binario separados por espacios →
# crates del workspace: codex→codex-cli, codex-tui, codex-linux-sandbox,
# codex-code-mode-host. Permite builds parciales (p.ej. SOLO el host
# codex-code-mode-host) reutilizando el cache de sccache del CI.
CODEX_BINS="${CODEX_BINS:-codex codex-tui codex-linux-sandbox codex-code-mode-host}"
# API level de bionic objetivo. Política del repo: 24 (mínimo para Termux 64-bit,
# igual que el port kilo, target aarch64-linux-android.24). OJO: NO bajar de 23 —
# `openpty` (portable_pty/codex_utils_pty) solo existe en bionic desde API 23; un
# linker de API 21 produce "undefined symbol: openpty" en el linkeo.
ANDROID_API="${ANDROID_API:-24}"

# ── Artefacto rusty_v8 (crate v8 = 150.4.0) para codex-code-mode-host ──
# El binario `codex-code-mode-host` (runtime companion con V8 embebido) depende
# de `v8 = "=150.4.0"` (rusty_v8, feature v8_enable_sandbox → ptrcomp_sandbox).
# No existe prebuilt para aarch64-linux-android: el workflow
# build-rusty-v8-android.yml lo compila desde fuente (V8_FROM_SOURCE=1, NDK r26c)
# y publica los 3 artefactos en la Release `rusty-v8-v<V8_VERSION>` del repo.
# Con RUSTY_V8_ARCHIVE + RUSTY_V8_SRC_BINDING_PATH exportados, el build.rs del
# crate v8 NO descarga ni compila V8 (solo linkea el .a) → el resto del host
# (tonic/axum/tokio/prost) ya compila para Android con el parche 08 y deps en
# Cargo.lock. Fuente de verdad de la versión: scripts/env.sh (CODEX_V8_VERSION);
# override con V8_VERSION.
V8_VERSION="${V8_VERSION:-${CODEX_V8_VERSION:-}}"
if [ -z "$V8_VERSION" ] && [ -f "$REPO_ROOT/scripts/env.sh" ]; then
    # Parse tolerante de CODEX_V8_VERSION sin source de env.sh (evita efectos
    # laterales: banner + defaults de JOBS/ANDROID_NDK_HOME/REPO_ROOT). Maneja
    # los dos formatos posibles:
    #   export CODEX_V8_VERSION="${CODEX_V8_VERSION:-150.4.0}"  → param default
    #   export CODEX_V8_VERSION="150.4.0"                        → literal
    v8_env_line="$(grep -E '^[[:space:]]*export[[:space:]]+CODEX_V8_VERSION=' "$REPO_ROOT/scripts/env.sh" | head -1 || true)"
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
# Repo que publica la Release del artefacto (en CI = este repo; override local).
RUSTY_V8_REPO="${RUSTY_V8_REPO:-${GITHUB_REPOSITORY:-Leonisaurov/opencode-termux}}"
RUSTY_V8_DIR="${RUSTY_V8_DIR:-${RUNNER_TEMP:-$WORK_DIR}/rusty-v8}"
RUSTY_V8_ARCHIVE_NAME="librusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.a.gz"
RUSTY_V8_BINDING_NAME="src_binding_ptrcomp_sandbox_release_aarch64-linux-android.rs"
RUSTY_V8_MANIFEST_NAME="rusty_v8_ptrcomp_sandbox_release_aarch64-linux-android.sha256"

# CODEX_REF acepta commit sha (40 hex) O tag (los parches de openai/codex usan
# tags rust-v* / codex-rs-v*). Si el ref no existe, el fetch de [1/5] falla con
# mensaje claro; aquí solo se descartan caracteres que romperían los comandos git.
[[ -n "$CODEX_REF" ]] || die "CODEX_REF no puede estar vacío"
[[ "$CODEX_REF" =~ ^[0-9A-Za-z._/-]+$ ]] \
    || die "CODEX_REF debe ser un commit sha de 40 hex o un tag (recibido: '$CODEX_REF')"
[[ "$JOBS" =~ ^[0-9]+$ ]] || die "JOBS debe ser un entero positivo (recibido: '$JOBS')"

# ── Validación: ANDROID_NDK_HOME obligatoria ──
# El config.toml parcheado (01-cargo-config.patch) referencia el linker y ar POR NOMBRE
# ("aarch64-linux-android-clang", "llvm-ar"), NO por ruta absoluta → el bin del NDK
# debe ir en PATH en la fase [4/5].
[ -n "${ANDROID_NDK_HOME:-}" ] || die "ANDROID_NDK_HOME es obligatoria (ruta del NDK con prebuilt para este host)"
[ -d "$ANDROID_NDK_HOME" ] || die "ANDROID_NDK_HOME no existe: $ANDROID_NDK_HOME"

NDK_BIN=""
for dir in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin; do
    [ -d "$dir" ] || continue
    if ls "$dir"/aarch64-linux-android*-clang >/dev/null 2>&1; then
        NDK_BIN="$dir"
        break
    fi
done
[ -n "$NDK_BIN" ] || die "no se encontró toolchains/llvm/prebuilt/*/bin con aarch64-linux-android*-clang en $ANDROID_NDK_HOME"

# El config.toml parcheado usa el nombre SIN sufijo API ("aarch64-linux-android-clang").
# El NDK solo trae los sufijados (aarch64-linux-androidNN-clang) → creamos/forzamos el
# symlink al clang del API correcto (ANDROID_API). BUG histórico: el glob alfabético
# `aarch64-linux-android[0-9]*-clang | head -1` elegía el API más bajo (21), y bionic de
# API 21 no exporta `openpty` (≥23) → "undefined symbol: openpty" en el linkeo (CI run #4).
api_clang="$NDK_BIN/aarch64-linux-android${ANDROID_API}-clang"
if [ ! -x "$api_clang" ]; then
    echo "ERROR: no existe $api_clang (API $ANDROID_API, política del repo)" >&2
    echo "  clangs aarch64 disponibles en $NDK_BIN:" >&2
    ls "$NDK_BIN"/aarch64-linux-android*-clang 2>/dev/null >&2 || true
    die "el NDK en $ANDROID_NDK_HOME no incluye aarch64-linux-android${ANDROID_API}-clang"
fi
# ln -sf: idempotente y corrige symlinks previos que apunten a otro API.
ln -sf "$(basename "$api_clang")" "$NDK_BIN/aarch64-linux-android-clang"

# Verificación de API (fail-fast): el symlink debe resolver al clang del API correcto.
link_target="$(readlink "$NDK_BIN/aarch64-linux-android-clang" 2>/dev/null || true)"
case "$link_target" in
    "aarch64-linux-android${ANDROID_API}-clang"|"$api_clang")
        echo "   symlink OK: aarch64-linux-android-clang -> $link_target (API $ANDROID_API)"
        ;;
    *)
        die "el symlink aarch64-linux-android-clang apunta a '$link_target' (esperado aarch64-linux-android${ANDROID_API}-clang)"
        ;;
esac

mkdir -p "$WORK_DIR"
echo "== Codex Android Build (CI) =="
echo "   Ref:        $CODEX_REF"
echo "   Work dir:   $WORK_DIR"
echo "   NDK bin:    $NDK_BIN"
echo "   API:        $ANDROID_API"
echo "   JOBS:       $JOBS"

# ── [1/5]-[2/5] Preparación del código fuente (compartida con el build local) ──
# Clona/verifica el checkout en CODEX_REF y aplica los parches de PATCHES_DIR con
# verify_patched_state (fail-fast de reproducibilidad). La lógica vive en
# scripts/codex-prepare-source.sh para que el build local (codex_build.sh) use
# EXACTAMENTE el mismo mecanismo de obtención del fuente. Idempotente: si el
# checkout ya está en el ref y el worktree ya tiene los parches exactos, no toca
# nada. Variables que deja listas para [3/5]: CODEX_SRC (derivada de CODEX_REPO
# arriba), PATCHES_DIR (definido arriba).
msg ":: [1/5]+[2/5] preparando fuente de codex ($CODEX_REF)..."
bash "$REPO_ROOT/scripts/codex-prepare-source.sh" "$CODEX_REPO" "$CODEX_REF" "$PATCHES_DIR"

# ── [3/5] Toolchain Rust ──
start_timer
TOOLCHAIN_FILE="$CODEX_SRC/rust-toolchain.toml"
[ -f "$TOOLCHAIN_FILE" ] || die "no existe rust-toolchain.toml en el workspace Rust: $CODEX_SRC"
RUST_CHANNEL="$(grep -E '^[[:space:]]*channel[[:space:]]*=' "$TOOLCHAIN_FILE" | sed -E 's/^[^"]*"([^"]*)".*/\1/' | head -1)"
[ -n "$RUST_CHANNEL" ] || die "no se pudo parsear channel= de $TOOLCHAIN_FILE"

echo ":: [3/5] Toolchain Rust: $RUST_CHANNEL..."
command -v rustup >/dev/null 2>&1 \
    || die "rustup no está en PATH; instálalo con: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
rustup toolchain install "$RUST_CHANNEL" --profile minimal
rustup target add --toolchain "$RUST_CHANNEL" aarch64-linux-android
# RUSTUP_TOOLCHAIN fuerza el channel de este build e impide que rustup auto-instale
# los components extra del toml (clippy/rustfmt/rust-src).
export RUSTUP_TOOLCHAIN="$RUST_CHANNEL"
cargo --version
rustc --version
echo "   toolchain lista ($(elapsed)s)"

# ── [4/5] Cross-compile ──
# El config.toml parcheado ya define target-feature=-crt-static (link-self-contained=no se
# eliminó: NO soportado en targets *-linux-android con rustc 1.95.0 → error al linkear bins)
# → NO exportar RUSTFLAGS (evitaría el config.toml o duplicaría flags).
export PATH="$NDK_BIN:$PATH"
export CARGO_INCREMENTAL=0
# Retries/tiempos de red para cargo (patrón de codex_build.sh): los fallos de
# descarga del registry suelen ser transitorios; 3 reintentos + timeout corto.
export CARGO_NET_RETRY=3
export CARGO_HTTP_TIMEOUT=30
cd "$CODEX_SRC"

echo ":: [4/5] cargo fetch (lockfile, target aarch64-linux-android)..."
start_timer
# sin --locked: los parches del port modifican Cargo.tomls del checkout y el
# Cargo.lock de upstream queda desincronizado; cargo lo regenera (hay red).
cargo fetch --target aarch64-linux-android
echo "   fetch completo ($(elapsed)s)"

# Artefacto librusty_v8 para codex-code-mode-host (fail-fast si no está publicado)
echo ":: [4/5] setup_rusty_v8 (artefacto librusty_v8 para codex-code-mode-host)..."
setup_rusty_v8

# ── Stubs bionic + compiler-rt del NDK para el link del host ──
# codex-code-mode-host (crate v8, use_custom_libcxx) referencia símbolos que
# bionic API 24 no exporta: __clear_cache (compiler-rt del NDK), aligned_alloc,
# strtof_l y strtod_l. Se compila scripts/bionic-stubs.c contra el clang del NDK
# ($api_clang, API $ANDROID_API) a $CODEX_SRC/target/bionic-stubs.o (target/ está
# gitignored → no rompe verify_patched_state) y se localiza
# libclang_rt.builtins-aarch64-android.a del NDK. Las rutas llegan al link vía el
# build.rs del crate host (parche 16) leyendo las env vars — NO vía RUSTFLAGS
# (reemplazaría los rustflags del .cargo/config.toml parcheado).
echo ":: [4/5] Stubs bionic + compiler-rt del NDK (link del host)..."
mkdir -p "$CODEX_SRC/target"
"$api_clang" -c -O2 -Wall -Wextra "$REPO_ROOT/scripts/bionic-stubs.c" -o "$CODEX_SRC/target/bionic-stubs.o" \
    || die "falló la compilación de scripts/bionic-stubs.c con $api_clang (API $ANDROID_API)"
export CODEX_BIONIC_STUBS_O="$CODEX_SRC/target/bionic-stubs.o"
CODEX_CLANG_RT_BUILTINS="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" \
    -name 'libclang_rt.builtins-aarch64-android.a' 2>/dev/null | head -1 || true)"
[ -n "$CODEX_CLANG_RT_BUILTINS" ] || die "no se encontró libclang_rt.builtins-aarch64-android.a en $ANDROID_NDK_HOME/toolchains/llvm/prebuilt"
export CODEX_CLANG_RT_BUILTINS
echo "   stubs bionic: $CODEX_BIONIC_STUBS_O"
echo "   compiler-rt:  $CODEX_CLANG_RT_BUILTINS"

# CODEX_BINS → crates (-p). Mapa nombre de binario → crate del workspace.
bin_to_crate() {
    case "$1" in
        codex)                echo "codex-cli" ;;
        codex-tui)            echo "codex-tui" ;;
        codex-linux-sandbox)  echo "codex-linux-sandbox" ;;
        codex-code-mode-host) echo "codex-code-mode-host" ;;
        *) echo "" ;;
    esac
}
PACKAGES_ARGS=()
for bin in $CODEX_BINS; do
    crate="$(bin_to_crate "$bin")"
    [ -n "$crate" ] || die "CODEX_BINS contiene un binario desconocido: '$bin' (válidos: codex, codex-tui, codex-linux-sandbox, codex-code-mode-host)"
    PACKAGES_ARGS+=("-p" "$crate")
done
echo ":: [4/5] bins a compilar: $CODEX_BINS"
echo ":: [4/5] cargo build --release --target aarch64-linux-android (JOBS=$JOBS)..."
start_timer
# sin --locked (misma razón que el cargo fetch de arriba): cargo regenera el
# Cargo.lock desincronizado por los parches del port (hay red).
cargo build --release --target aarch64-linux-android -j "$JOBS" "${PACKAGES_ARGS[@]}"
echo "   build completo ($(elapsed)s)"

# ── [5/5] Empaquetar ──
# Solo se copian/verifican/empaquetan los binarios de CODEX_BINS. Un binario
# listado pero no compilado se omite (p.ej. build SOLO del host no produce
# codex-android y eso no es un error); si NO se empaqueta nada, fail-fast.
start_timer
echo ":: [5/5] Empaquetando..."
ZIP_FILES=()
for bin in $CODEX_BINS; do
    bin_src="$CODEX_SRC/target/aarch64-linux-android/release/$bin"
    if [ -f "$bin_src" ] && [ -x "$bin_src" ]; then
        dst="$WORK_DIR/$bin"
        [ "$bin" = "codex" ] && dst="$WORK_DIR/codex-android"   # renombre histórico en el zip
        cp "$bin_src" "$dst"
        chmod +x "$dst"
        ZIP_FILES+=("$(basename "$dst")")
        echo "   binario: $dst ($(du -h "$dst" | cut -f1))"
        echo "   file: $(file "$dst")"
    else
        echo "   binario no presente (omitido): $bin"
    fi
done
[ "${#ZIP_FILES[@]}" -gt 0 ] || die "ningún binario de CODEX_BINS ($CODEX_BINS) se compiló en $CODEX_SRC/target/aarch64-linux-android/release"

# Verificación de arquitectura de los binarios empaquetados (readelf si está
# disponible; fallback file).
if command -v readelf >/dev/null 2>&1; then
    for f in "${ZIP_FILES[@]}"; do
        readelf -h "$WORK_DIR/$f" | grep -q 'Machine:.*AArch64' \
            || die "readelf -h $f: Machine no es AArch64 (¿build host por error?)"
    done
    echo "   readelf: Machine AArch64 OK (${#ZIP_FILES[@]} binarios)"
else
    for f in "${ZIP_FILES[@]}"; do
        file "$WORK_DIR/$f" | grep -q 'aarch64' \
            || die "file $f: no parece binario aarch64"
    done
    echo "   file: aarch64 OK (readelf no disponible)"
fi

# Log informativo de los NEEDED reales del host (libc++ estático embebido del
# crate v8 vs libc++_shared.so dinámico). NO fail-fast: solo diagnóstico para
# el output del build (ver Codex-port.md "Requisito runtime").
if [ -f "$WORK_DIR/codex-code-mode-host" ]; then
    if command -v readelf >/dev/null 2>&1; then
        echo "   [NEEDED] codex-code-mode-host:"
        readelf -d "$WORK_DIR/codex-code-mode-host" | grep NEEDED || echo "   [NEEDED] <sin entradas NEEDED>"
    else
        echo "   [NEEDED] readelf no disponible; file: $(file "$WORK_DIR/codex-code-mode-host" | cut -d: -f2-)"
    fi
fi

# Versión: CODEX_VERSION explícita o derivada con git describe sobre la raíz del
# checkout (CODEX_REPO). Fallback documentado: si describe --always devuelve un
# sha puro (checkout sin tag), se usa el short-sha como versión.
if [ -z "$CODEX_VERSION" ]; then
    raw_ver="$(git -C "$CODEX_REPO" describe --tags --always 2>/dev/null || true)"
    [ -n "$raw_ver" ] || raw_ver="$(git -C "$CODEX_REPO" rev-parse --short=8 HEAD 2>/dev/null || true)"
    [ -n "$raw_ver" ] || die "no se pudo derivar versión del checkout $CODEX_REPO"
    CODEX_VERSION="$raw_ver"
    # Normalización: quitar prefijos rust-v / codex-rs-v / codex-v / v inicial
    case "$CODEX_VERSION" in
        codex-rs-v*) CODEX_VERSION="${CODEX_VERSION#codex-rs-v}" ;;
        codex-v*)    CODEX_VERSION="${CODEX_VERSION#codex-v}" ;;
        rust-v*)     CODEX_VERSION="${CODEX_VERSION#rust-v}" ;;
        v*)          CODEX_VERSION="${CODEX_VERSION#v}" ;;
    esac
    # Si el resultado es un sha puro (describe --always sin tags), acortar a 8 chars
    if [ -z "$CODEX_VERSION" ] || [[ "$CODEX_VERSION" =~ ^[0-9a-f]{7,40}$ ]]; then
        CODEX_VERSION="$(git -C "$CODEX_REPO" rev-parse --short=8 HEAD)"
    fi
fi
# Normalización también para CODEX_VERSION explícita (input del workflow o
# github.ref_name en push de tag codex-v*): quitar prefijos codex-rs-v /
# codex-v / rust-v / v inicial.
case "$CODEX_VERSION" in
    codex-rs-v*) CODEX_VERSION="${CODEX_VERSION#codex-rs-v}" ;;
    codex-v*)    CODEX_VERSION="${CODEX_VERSION#codex-v}" ;;
    rust-v*)     CODEX_VERSION="${CODEX_VERSION#rust-v}" ;;
    v*)          CODEX_VERSION="${CODEX_VERSION#v}" ;;
esac
[ -n "$CODEX_VERSION" ] || die "versión final vacía tras normalizar"
# Validación del nombre del zip: solo [A-Za-z0-9._-], primer char alfanumérico.
[[ "$CODEX_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] \
    || die "versión normalizada no es segura para el nombre del zip: '$CODEX_VERSION'"

ZIP_NAME="codex-v${CODEX_VERSION}-android-aarch64.zip"
command -v zip >/dev/null 2>&1 || die "zip no está instalado (apt install zip)"
( cd "$WORK_DIR" && zip -q -j "$ZIP_NAME" "${ZIP_FILES[@]}" )

# Emitir la versión para los pasos siguientes del workflow (GITHUB_OUTPUT / GITHUB_ENV)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "version=$CODEX_VERSION" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CODEX_VERSION=$CODEX_VERSION" >> "$GITHUB_ENV"
fi

echo ""
echo ":: Build completado ($(elapsed_total)s total)"
for f in "${ZIP_FILES[@]}"; do
    echo "   $f: $WORK_DIR/$f ($(du -h "$WORK_DIR/$f" | cut -f1))"
done
echo "   Versión:  $CODEX_VERSION"
echo "   Zip:      $WORK_DIR/$ZIP_NAME"
ls -lh "$WORK_DIR/$ZIP_NAME" | awk '{print "   " $5 " " $NF}'
