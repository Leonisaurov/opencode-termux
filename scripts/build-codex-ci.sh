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
start_timer() { START_TS=$(date +%s); }
elapsed() { local end=$(date +%s); echo $((end - START_TS)); }
BUILD_START_TS=$(date +%s)
elapsed_total() { local end=$(date +%s); echo $((end - BUILD_START_TS)); }
die() { echo "ERROR: $*" >&2; exit 1; }

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
# API level de bionic objetivo. Política del repo: 24 (mínimo para Termux 64-bit,
# igual que el port kilo, target aarch64-linux-android.24). OJO: NO bajar de 23 —
# `openpty` (portable_pty/codex_utils_pty) solo existe en bionic desde API 23; un
# linker de API 21 produce "undefined symbol: openpty" en el linkeo.
ANDROID_API="${ANDROID_API:-24}"

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

# ── [1/5] Clonar openai/codex al ref (raíz del checkout: CODEX_REPO) ──
start_timer
if [ -d "$CODEX_REPO/.git" ]; then
    echo ":: [1/5] Checkout existe, reutilizando (idempotente)..."
    local_head="$(git -C "$CODEX_REPO" rev-parse HEAD 2>/dev/null || true)"
    if [ -z "$local_head" ]; then
        die "HEAD de $CODEX_REPO está vacío (repo sin commits); borra $CODEX_REPO para re-clonar"
    fi
    # Resolver el ref (sha O tag) a sha antes de comparar: con un tag, rev-parse
    # local devuelve el commit exacto del tag; con un sha sin ref local (fetch
    # shallow de un commit) rev-parse falla → se usa el literal (ya es un sha).
    ref_sha="$(git -C "$CODEX_REPO" rev-parse "$CODEX_REF" 2>/dev/null || true)"
    [ -n "$ref_sha" ] || ref_sha="$CODEX_REF"
    if [ "$local_head" != "$ref_sha" ]; then
        die "HEAD de $CODEX_REPO ($local_head) != ref $CODEX_REF (sha $ref_sha); borra $CODEX_REPO para re-clonar"
    fi
else
    [ -e "$CODEX_REPO" ] && die "$CODEX_REPO existe pero no es un repo git válido"
    echo ":: [1/5] Clonando openai/codex@$CODEX_REF..."
    mkdir -p "$(dirname "$CODEX_REPO")"
    git init -q "$CODEX_REPO"
    git -C "$CODEX_REPO" remote add origin https://github.com/openai/codex
    if ! git -C "$CODEX_REPO" fetch -q --depth 1 origin "$CODEX_REF"; then
        die "fetch de openai/codex@'$CODEX_REF' falló: ¿existe ese commit o tag en openai/codex? (o error de red)"
    fi
    git -C "$CODEX_REPO" checkout -q FETCH_HEAD
fi
echo "   checkout listo ($(elapsed)s): $(git -C "$CODEX_REPO" rev-parse --short=8 HEAD)"

# ── [2/5] Aplicar parches con fail-fast ──
start_timer
[ -d "$PATCHES_DIR" ] || die "no existe el directorio de parches: $PATCHES_DIR"
shopt -s nullglob
PATCH_FILES=( "$PATCHES_DIR"/*.patch )
shopt -u nullglob
[ "${#PATCH_FILES[@]}" -gt 0 ] || die "no hay *.patch en $PATCHES_DIR"

# Archivos que DEBEN quedar modificados tras aplicar los parches (extraídos del diff)
mapfile -t EXPECTED_FILES < <(grep -h '^diff --git a/' "${PATCH_FILES[@]}" | sed -E 's/^diff --git a\///; s/ b\/.*$//')
[ "${#EXPECTED_FILES[@]}" -eq "${#PATCH_FILES[@]}" ] || die "los parches no tocan exactamente un archivo cada uno (revisa patches/codex)"

# Verifica que el worktree tenga EXACTAMENTE los archivos de los parches modificados
# y nada más (ni untracked, ni staged, ni otros cambios).
verify_patched_state() {
    local line=""
    local -a actual=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ M\ (.*)$ ]]; then
            actual+=("${BASH_REMATCH[1]}")
        else
            echo "ERROR: estado inesperado en $CODEX_REPO: '$line'" >&2
            return 1
        fi
    done < <(git -C "$CODEX_REPO" status --porcelain)
    local expected_sorted actual_sorted
    expected_sorted="$(printf '%s\n' "${EXPECTED_FILES[@]}" | sort)"
    actual_sorted="$(printf '%s\n' "${actual[@]}" | sort)"
    if [ "$expected_sorted" != "$actual_sorted" ]; then
        echo "ERROR: el estado del worktree no coincide con los archivos de los parches:" >&2
        echo "  esperado: ${EXPECTED_FILES[*]}" >&2
        echo "  actual:   ${actual[*]}" >&2
        return 1
    fi
}

echo ":: [2/5] Aplicando parches ($(basename "$PATCHES_DIR"), ${#PATCH_FILES[@]} parches)..."
local_st="$(git -C "$CODEX_REPO" status --porcelain)"
if [ -n "$local_st" ]; then
    if verify_patched_state; then
        echo "   parches ya aplicados (skip)"
    else
        die "checkout de $CODEX_REPO no está limpio ni con los parches exactos aplicados; borra $CODEX_REPO y reintenta"
    fi
else
    git -C "$CODEX_REPO" apply --check "${PATCH_FILES[@]}" \
        || die "los parches no aplican sobre openai/codex@$CODEX_REF; ¿cambió el ref? (git apply --check falló)"
    git -C "$CODEX_REPO" apply "${PATCH_FILES[@]}"
    echo "   parches aplicados ($(elapsed)s)"
fi
verify_patched_state || die "reproducibilidad fallida: el worktree tras aplicar no coincide byte-por-byte con los parches"
echo "   reproducibilidad OK: exactamente los ${#EXPECTED_FILES[@]} archivos esperados"

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
cargo fetch --locked --target aarch64-linux-android
echo "   fetch completo ($(elapsed)s)"

echo ":: [4/5] cargo build --release --locked --target aarch64-linux-android (JOBS=$JOBS)..."
start_timer
cargo build --release --locked --target aarch64-linux-android -j "$JOBS" -p codex-tui -p codex-linux-sandbox -p codex-cli
echo "   build completo ($(elapsed)s)"

# ── [5/5] Empaquetar ──
start_timer
CODEX_BIN="$CODEX_SRC/target/aarch64-linux-android/release/codex"
[ -f "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] || die "binario no encontrado o no ejecutable: $CODEX_BIN"

echo ":: [5/5] Empaquetando..."
cp "$CODEX_BIN" "$WORK_DIR/codex-android"
chmod +x "$WORK_DIR/codex-android"

echo "   file: $(file "$WORK_DIR/codex-android")"
if command -v readelf >/dev/null 2>&1; then
    readelf -h "$WORK_DIR/codex-android" | grep -q 'Machine:.*AArch64' \
        || die "readelf -h: Machine no es AArch64 (¿build host por error?)"
    echo "   readelf: Machine AArch64 OK"
else
    file "$WORK_DIR/codex-android" | grep -q 'aarch64' \
        || die "file: no parece binario aarch64"
    echo "   file: aarch64 OK (readelf no disponible)"
fi

# Versión: CODEX_VERSION explícita o derivada con git describe sobre la raíz del
# checkout (CODEX_REPO). Fallback documentado: si describe --always devuelve un
# sha puro (checkout sin tag), se usa el short-sha como versión.
if [ -z "$CODEX_VERSION" ]; then
    raw_ver="$(git -C "$CODEX_REPO" describe --tags --always 2>/dev/null || true)"
    [ -n "$raw_ver" ] || raw_ver="$(git -C "$CODEX_REPO" rev-parse --short=8 HEAD 2>/dev/null || true)"
    [ -n "$raw_ver" ] || die "no se pudo derivar versión del checkout $CODEX_REPO"
    CODEX_VERSION="$raw_ver"
    # Normalización: quitar prefijos rust-v / codex-rs-v / v inicial
    case "$CODEX_VERSION" in
        codex-rs-v*) CODEX_VERSION="${CODEX_VERSION#codex-rs-v}" ;;
        rust-v*)     CODEX_VERSION="${CODEX_VERSION#rust-v}" ;;
        v*)          CODEX_VERSION="${CODEX_VERSION#v}" ;;
    esac
    # Si el resultado es un sha puro (describe --always sin tags), acortar a 8 chars
    if [ -z "$CODEX_VERSION" ] || [[ "$CODEX_VERSION" =~ ^[0-9a-f]{7,40}$ ]]; then
        CODEX_VERSION="$(git -C "$CODEX_REPO" rev-parse --short=8 HEAD)"
    fi
fi
[[ "$CODEX_VERSION" != v* ]] || CODEX_VERSION="${CODEX_VERSION#v}"
[ -n "$CODEX_VERSION" ] || die "versión final vacía tras normalizar"
# Validación del nombre del zip: solo [A-Za-z0-9._-], primer char alfanumérico.
[[ "$CODEX_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] \
    || die "versión normalizada no es segura para el nombre del zip: '$CODEX_VERSION'"

ZIP_NAME="codex-v${CODEX_VERSION}-android-aarch64.zip"
command -v zip >/dev/null 2>&1 || die "zip no está instalado (apt install zip)"
( cd "$WORK_DIR" && zip -q -j "$ZIP_NAME" codex-android )

# Emitir la versión para los pasos siguientes del workflow (GITHUB_OUTPUT / GITHUB_ENV)
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "version=$CODEX_VERSION" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "CODEX_VERSION=$CODEX_VERSION" >> "$GITHUB_ENV"
fi

echo ""
echo ":: Build completado ($(elapsed_total)s total)"
echo "   Binario:  $WORK_DIR/codex-android ($(du -h "$WORK_DIR/codex-android" | cut -f1))"
echo "   Versión:  $CODEX_VERSION"
echo "   Zip:      $WORK_DIR/$ZIP_NAME"
ls -lh "$WORK_DIR/$ZIP_NAME" | awk '{print "   " $5 " " $NF}'
