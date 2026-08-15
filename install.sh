#!/usr/bin/env bash
# Instalador de opencode-termux
#
# Descarga los 3 componentes (bun, opencode, libopentui.so) desde las
# GitHub Releases del repo $GITHUB_REPO (assets publicados por el workflow
# build-opencode.yml, paso "Package release assets").
#
# Uso: ./install.sh [--just bun|opencode|opentui] [--release <tag>] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.1.0"
GITHUB_REPO="Leonisaurov/opencode-termux"
BUN_VERSION="1.3.14"
RELEASE_TAG="latest"          # "latest" o un tag concreto (ej: v1.18.11) vía --release
INSTALL_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
INSTALL_BUN=false
INSTALL_OPENCODE=false
INSTALL_OPENTUI=false
INSTALL_CODEX=false
FIX_GLOBAL_BINS=false
RELEASE_JSON=""

# Patrones (grep -E) de los nombres de assets publicados por los workflows de
# build. Los assets llevan la versión del componente (variable en cada release),
# por eso se matchean por patrón en vez de hardcodear el nombre completo.
BUN_ASSET_PATTERN='bun-v[0-9.]+-android-aarch64\.tar\.gz'
OPENCODE_ASSET_PATTERN='opencode-v[0-9.]+-android-aarch64\.zip'
OPENTUI_ASSET_PATTERN='libopentui-android-aarch64\.tar\.gz'
# El patrón de codex acepta prereleases: la versión real lleva sufijo
# `-alpha.N-` entre la versión y `-android` (ej: codex-v0.134.0-alpha.10-...).
CODEX_ASSET_PATTERN='codex-v[0-9][0-9A-Za-z._+-]*-android-aarch64\.zip'

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[✓]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[!]${NC} $1" >&2; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; }

check_arch() {
    # file puede no estar instalado en Termux; en ese caso no se puede
    # verificar la arquitectura (se advierte, no se aborta).
    if ! command -v file &>/dev/null; then
        warn "'file' no está instalado (pkg install file) — no se pudo verificar la arquitectura"
        return 0
    fi
    local file_info
    file_info=$(file "$1" 2>/dev/null || echo "")
    if ! echo "$file_info" | grep -q "ARM aarch64\|AArch64\|aarch64"; then
        return 1
    fi
    return 0
}

# ── Help ────────────────────────────────────────────────────────────
show_help() {
    cat << EOF
opencode-termux Installer v$VERSION

USO:
    ./install.sh [OPCIONES]

OPCIONES:
    --just <comp>      Instala solo un componente: bun, opencode, opentui o codex
    --all              Instala todo (default)
    --release <tag>    Descarga de un tag concreto (ej: v1.18.11) en vez de latest
    --prefix <path>    Directorio de instalación (default: \$PREFIX)
    --fix-global-bins  Repara binarios globales (reemplaza symlinks por wrappers)
    --version          Muestra versión
    --help             Muestra esta ayuda

COMPONENTES (descargados de GitHub Releases de $GITHUB_REPO):
    bun               Bun Android parchado (aarch64)      → \$PREFIX/bin/bun
    opencode          OpenCode standalone (aarch64)        → \$PREFIX/bin/opencode
    opentui           libopentui.so (aarch64-linux-musl)   → \$PREFIX/lib/libopentui.so
                      (opencode standalone lleva el .so embebido; este asset
                       es solo para builds/desarrollo custom)
    codex             Codex CLI (aarch64)                  → \$PREFIX/bin/codex
                      + codex-code-mode-host               → \$PREFIX/bin/codex-code-mode-host
                      (libc++ estático embebido del crate v8 — NO requiere
                       libc++_shared.so; verifícalo con:
                       readelf -d \$PREFIX/bin/codex-code-mode-host | grep NEEDED)

EJEMPLOS:
    ./install.sh                        # instala bun + opencode + opentui + codex
    ./install.sh --just bun
    ./install.sh --just opencode
    ./install.sh --just opentui
    ./install.sh --just codex
    ./install.sh --release v1.18.11     # tag específico
    ./install.sh --just bun --prefix /custom/path
EOF
    exit 0
}

# ── Parse args ──────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --just)
                shift
                case "$1" in
                    bun) INSTALL_BUN=true ;;
                    opencode) INSTALL_OPENCODE=true ;;
                    opentui) INSTALL_OPENTUI=true ;;
                    codex) INSTALL_CODEX=true ;;
                    all) INSTALL_BUN=true; INSTALL_OPENCODE=true; INSTALL_OPENTUI=true; INSTALL_CODEX=true ;;
                    *) error "Opción inválida: $1"; exit 1 ;;
                esac
                shift
                ;;
            --all) INSTALL_BUN=true; INSTALL_OPENCODE=true; INSTALL_OPENTUI=true; INSTALL_CODEX=true; shift ;;
            --release) RELEASE_TAG="$2"; shift 2 ;;
            --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
            --fix-global-bins) FIX_GLOBAL_BINS=true; shift ;;
            --version) echo "opencode-termux-installer v$VERSION"; exit 0 ;;
            --help|-h) show_help ;;
            *) error "Opción desconocida: $1"; show_help; exit 1 ;;
        esac
    done

    # Default: instalar todo
    if ! $INSTALL_BUN && ! $INSTALL_OPENCODE && ! $INSTALL_OPENTUI && ! $INSTALL_CODEX; then
        INSTALL_BUN=true
        INSTALL_OPENCODE=true
        INSTALL_OPENTUI=true
        INSTALL_CODEX=true
    fi
}

# ── Checks ──────────────────────────────────────────────────────────
check_env() {
    if [ ! -d "/data/data/com.termux" ]; then
        error "Este script está diseñado para Termux en Android"
        exit 1
    fi

    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        error "Solo aarch64 está soportado (deteectado: $arch)"
        exit 1
    fi

    if [ ! -d "$INSTALL_PREFIX/bin" ]; then
        warn "Directorio $INSTALL_PREFIX/bin no existe, creándolo..."
        mkdir -p "$INSTALL_PREFIX/bin"
    fi
}

# ── Release helpers (GitHub Releases, sin gh) ───────────────────────
# Consulta la release (latest o un tag concreto) vía la API de GitHub y
# guarda el JSON completo en RELEASE_JSON. Con curl no se necesita gh ni auth.
fetch_release_json() {
    local url
    if [ "$RELEASE_TAG" = "latest" ]; then
        url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    else
        url="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${RELEASE_TAG}"
    fi

    info "Consultando release ${RELEASE_TAG} de ${GITHUB_REPO}..."

    RELEASE_JSON=$(curl -fsSL "$url" 2>/dev/null) || {
        error "No hay release ${RELEASE_TAG} disponible en ${GITHUB_REPO}."
        error "Los assets se publican desde el workflow de build. Para crearla:"
        error "  gh workflow run build-opencode.yml --ref update-v1.18.6 -f release=true"
        error "  # o pushea un tag v*:  git tag v1.18.11 && git push origin v1.18.11"
        exit 1
    }

    # Respuesta de error de la API (ej: repo inexistente o respuesta no-JSON)
    if echo "$RELEASE_JSON" | grep -q '"message"'; then
        error "La API de GitHub respondió con un error:"
        echo "$RELEASE_JSON" | grep -m1 '"message"' | sed -E 's/.*"message": *"([^"]+)".*/\1/'
        exit 1
    fi

    # Si era "latest", quedarse con el tag real para los mensajes
    local resolved_tag
    resolved_tag=$(echo "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
    if [ -n "$resolved_tag" ] && [ "$resolved_tag" != "null" ]; then
        RELEASE_TAG="$resolved_tag"
        info "Release encontrada: $RELEASE_TAG"
    fi
}

# Devuelve la URL de descarga del asset cuyo nombre matchea el patrón $1.
asset_url() {
    echo "$RELEASE_JSON" \
        | grep -oE 'https://[^"]+' \
        | grep -E "$1" \
        | head -n 1 \
        || true
}

download_asset() {
    # $1: nombre descriptivo; $2: URL; $3: archivo destino
    info "Descargando $1..."
    if ! curl -fsSL -o "$3" "$2" 2>/dev/null; then
        rm -f "$3"
        error "No se pudo descargar $1 desde la release ${RELEASE_TAG}"
        return 1
    fi
    return 0
}

# ── Install Bun ─────────────────────────────────────────────────────
install_bun() {
    local url
    url=$(asset_url "$BUN_ASSET_PATTERN")
    if [ -z "$url" ]; then
        error "La release ${RELEASE_TAG} no contiene el asset de bun ($BUN_ASSET_PATTERN)"
        return 1
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/installer-bun.XXXXXX")"

    local asset="$tmp_dir/bun-android.tar.gz"
    download_asset "Bun Android (aarch64)" "$url" "$asset" || { rm -rf "$tmp_dir"; return 1; }

    if ! tar tzf "$asset" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        error "El asset de bun no es un tar.gz válido (descarga corrupta o response de error de la API)"
        return 1
    fi

    mkdir -p "$tmp_dir/x"
    tar xzf "$asset" -C "$tmp_dir/x"
    local bun_bin="$tmp_dir/x/bun"
    if [ ! -f "$bun_bin" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró el binario 'bun' dentro del asset descargado"
        return 1
    fi

    chmod +x "$bun_bin"
    if ! check_arch "$bun_bin"; then
        warn "El binario de bun no parece ser ARM64"
    fi

    if [ -f "$INSTALL_PREFIX/bin/bun" ]; then
        local old_version
        old_version=$("$INSTALL_PREFIX/bin/bun" --version 2>/dev/null || echo "?")
        if [ -t 0 ]; then
            # Modo interactivo — preguntar
            warn "Ya existe Bun v$old_version en $INSTALL_PREFIX/bin/bun"
            echo -n "¿Sobrescribir? [s/N] " >&2
            read -r resp
            if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
                info "Instalación de bun cancelada."
                rm -rf "$tmp_dir"
                return 0
            fi
        else
            # Modo no interactivo — sobrescribir automáticamente
            info "Reemplazando Bun v$old_version con nueva versión"
        fi
    fi

    cp "$bun_bin" "$INSTALL_PREFIX/bin/bun"
    chmod +x "$INSTALL_PREFIX/bin/bun"
    rm -rf "$tmp_dir"

    # ── Install target runtime cache ──
    install_bun_target || true

    # ── Install @oven/bun-linux-aarch64-android stub ──
    install_bun_stub || true

    # Verificar
    if command -v bun &>/dev/null; then
        local version
        version=$(bun --version 2>/dev/null)
        info "Bun v$version instalado correctamente en $INSTALL_PREFIX/bin/bun"
    else
        warn "Bun instalado pero no encontrado en PATH. ¿Está $INSTALL_PREFIX/bin en tu PATH?"
    fi

    # Config global: backend copyfile para Android
    setup_bun_config

    # Reparar binarios globales existentes (si los hay)
    fix_global_bins
}

# ── Install Bun target runtime (for --compile --target) ──
install_bun_target() {
    local bun_bin="$INSTALL_PREFIX/bin/bun"

    if [ ! -f "$bun_bin" ]; then
        warn "Bun binary not found at $bun_bin, skipping target runtime install"
        return 1
    fi

    local target_name="bun-linux-arm64-android-v${BUN_VERSION:-1.3.14}"
    local cache_dir="${HOME}/.bun/install/cache/${target_name}"
    local package_bin_dir="${cache_dir}/package/bin"

    info "Instalando target runtime para --target=bun-linux-arm64-android..."

    mkdir -p "$package_bin_dir"
    cp "$bun_bin" "$package_bin_dir/bun"
    chmod +x "$package_bin_dir/bun"

    if check_arch "$package_bin_dir/bun"; then
        info "Target runtime instalado en: $cache_dir"
        info "Usa: bun build --compile --target=bun-linux-arm64-android ..."
    else
        warn "El target runtime no parece ser ARM64"
    fi
}

# ── Install @oven/bun-linux-aarch64-android stub ──
# The 'bun' npm package's postinstall script (install.js) runs from
# ~/.bun/install/cache/bun@1.3.14@@@1/install.js. It does:
#   1. require.resolve("@oven/bun-linux-aarch64-android/bin/bun")
#      which walks UP parent directories from the script location
#      looking in node_modules/
#   2. Falls to npm install (registry) if not found
#   3. Falls to direct download if npm install fails
#
# We put the stub in cache/node_modules/ so step 1 finds it
# via standard Node.js module resolution walking up from
# cache/bun@1.3.14@@@1/ → cache/node_modules/
install_bun_stub() {
    info "Instalando stub npm para @oven/bun-linux-aarch64-android..."

    local bun_bin="$INSTALL_PREFIX/bin/bun"
    if [ ! -f "$bun_bin" ]; then
        warn "Bun binary not found at $bun_bin, skipping stub creation"
        return 1
    fi

    local cache_node_modules="${HOME}/.bun/install/cache/node_modules"
    local stub_dir="${cache_node_modules}/@oven/bun-linux-aarch64-android"
    local pkg_version="${BUN_VERSION:-1.3.14}"

    # Create directory structure
    mkdir -p "${stub_dir}/bin"

    # Create package.json
    cat > "${stub_dir}/package.json" << STUBEOF
{
  "name": "@oven/bun-linux-aarch64-android",
  "version": "${pkg_version}",
  "os": ["android"],
  "cpu": ["arm64"],
  "bin": {
    "bun": "bin/bun"
  }
}
STUBEOF

    # Copy bun binary (not symlink - require() needs real file)
    cp "$bun_bin" "${stub_dir}/bin/bun"
    chmod +x "${stub_dir}/bin/bun"

    # Create a symlink from cache/bun.lock -> ../global/bun.lock
    # This allows Bun's module resolution to find the global lockfile
    # when running globally installed scripts from the cache directory.
    # Without this, scripts in cache/bunli@*/dist/cli.js walk up looking
    # for bun.lock but never reach install/global/bun.lock.
    local cache_bunlock="${HOME}/.bun/install/cache/bun.lock"
    local global_bunlock="${HOME}/.bun/install/global/bun.lock"
    if [ -f "$global_bunlock" ] && [ ! -f "$cache_bunlock" ] && [ ! -L "$cache_bunlock" ]; then
        ln -s "../global/bun.lock" "$cache_bunlock" 2>/dev/null && \
            info "  Symlink cache/bun.lock -> ../global/bun.lock creado"
    fi

    info "Stub @oven/bun-linux-aarch64-android instalado en: ${stub_dir}"
    info "  require.resolve() desde cache/bun@*@@@1/ lo encontrará via node_modules/ walking up"
}

setup_bun_config() {
    local config_file="$HOME/.bunfig.toml"
    if [ -f "$config_file" ]; then
        info ".bunfig.toml ya existe, no se modifica"
        return 0
    fi
    cat > "$config_file" << 'EOF'
# Configuración global de Bun para Android/Termux
# El backend "copyfile" es necesario porque hardlink falla
# en el filesystem de Android (EACCES)
[install]
backend = "copyfile"
EOF
    info ".bunfig.toml creado con backend=copyfile"
}

# ── Fix global bin wrappers ──
# Globally installed packages via 'bun add -g' create symlinks in
# ~/.bun/bin/ that point to the cache via a chain:
#   ~/.bun/bin/<cmd> → global/node_modules/.bin/<cmd> → global/node_modules/<pkg>/<bin> → cache/...
#
# When executed, Bun follows all symlinks and __filename becomes
# the cache path. Module resolution from the cache fails because
# require() walks up from cache/ instead of global/node_modules/.
#
# The fix: replace symlinks with bash wrappers that call 'bunx <pkg>'.
# bunx resolves the package from global install and runs it with
# correct module resolution.
fix_global_bins() {
    local bun_bin="$INSTALL_PREFIX/bin/bun"
    local global_bin_dir="${HOME}/.bun/bin"
    
    if [ ! -d "$global_bin_dir" ]; then
        return 0
    fi
    
    local fixed=0
    for entry in "$global_bin_dir"/*; do
        [ -L "$entry" ] || continue
        local name
        name=$(basename "$entry")
        
        # Replace symlink with bunx wrapper
        rm "$entry"
        cat > "$entry" << WRAPPER
#!/data/data/com.termux/files/usr/bin/bash
exec "$bun_bin" x "$name" "\$@"
WRAPPER
        chmod +x "$entry"
        fixed=$((fixed + 1))
    done
    
    if [ "$fixed" -gt 0 ]; then
        info "Arreglados $fixed binarios globales para usar bunx"
    fi
}

# ── Install OpenCode ────────────────────────────────────────────────
install_opencode() {
    local url
    url=$(asset_url "$OPENCODE_ASSET_PATTERN")
    if [ -z "$url" ]; then
        error "La release ${RELEASE_TAG} no contiene el asset de opencode ($OPENCODE_ASSET_PATTERN)"
        return 1
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/installer-opencode.XXXXXX")"

    local asset="$tmp_dir/opencode.zip"
    download_asset "OpenCode standalone (aarch64)" "$url" "$asset" || { rm -rf "$tmp_dir"; return 1; }

    if ! unzip -t "$asset" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        error "El asset de opencode no es un zip válido (descarga corrupta o response de error de la API)"
        return 1
    fi

    mkdir -p "$tmp_dir/x"
    if ! unzip -q "$asset" -d "$tmp_dir/x" 2>/dev/null; then
        rm -rf "$tmp_dir"
        error "No se pudo descomprimir el asset (¿instalaste unzip? → pkg install unzip)"
        return 1
    fi

    local opencode_bin="$tmp_dir/x/opencode"
    if [ ! -f "$opencode_bin" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró el binario 'opencode' dentro del zip"
        return 1
    fi

    chmod +x "$opencode_bin"
    if ! check_arch "$opencode_bin"; then
        warn "El binario de opencode no parece ser ARM64"
    fi

    cp "$opencode_bin" "$INSTALL_PREFIX/bin/opencode"
    chmod +x "$INSTALL_PREFIX/bin/opencode"
    rm -rf "$tmp_dir"

    info "OpenCode instalado en $INSTALL_PREFIX/bin/opencode"
    info "  (el binario standalone incluye el runtime Bun Android y libopentui.so embebidos)"
}

# ── Install libopentui.so ───────────────────────────────────────────
# Solo para builds/desarrollo custom: opencode standalone lleva el .so
# embebido. El tar.gz del workflow contiene aarch64-linux-musl/libopentui.so,
# por eso se extrae con --strip-components=1.
install_opentui() {
    local url
    url=$(asset_url "$OPENTUI_ASSET_PATTERN")
    if [ -z "$url" ]; then
        error "La release ${RELEASE_TAG} no contiene el asset de libopentui.so ($OPENTUI_ASSET_PATTERN)"
        return 1
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/installer-opentui.XXXXXX")"

    local asset="$tmp_dir/opentui.tar.gz"
    download_asset "libopentui.so (aarch64)" "$url" "$asset" || { rm -rf "$tmp_dir"; return 1; }

    if ! tar tzf "$asset" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        error "El asset de libopentui.so no es un tar.gz válido (descarga corrupta o response de error de la API)"
        return 1
    fi

    mkdir -p "$tmp_dir/x"
    tar xzf "$asset" --strip-components=1 -C "$tmp_dir/x"
    local so_file="$tmp_dir/x/libopentui.so"
    if [ ! -f "$so_file" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró libopentui.so dentro del asset descargado"
        return 1
    fi

    if ! check_arch "$so_file"; then
        warn "libopentui.so no parece ser ARM64"
    fi

    mkdir -p "$INSTALL_PREFIX/lib"
    cp "$so_file" "$INSTALL_PREFIX/lib/libopentui.so"
    rm -rf "$tmp_dir"

    info "libopentui.so instalado en $INSTALL_PREFIX/lib/libopentui.so"
    info "  (para desarrollo/build local; opencode standalone lo lleva embebido)"
}

# ── Install Codex CLI ────────────────────────────────────────────────
# El zip de la release contiene `codex-android` (binario principal) y
# `codex-code-mode-host` (runtime companion con V8 embebido para el modo code).
# codex-android se renombra a `codex` al instalar; codex-code-mode-host debe
# quedar como binario hermano en $PREFIX/bin (el CLI lo busca como
# current_exe.parent()/codex-code-mode-host).
install_codex() {
    local url
    url=$(asset_url "$CODEX_ASSET_PATTERN")
    if [ -z "$url" ]; then
        # Fallback (solo codex): la release "latest" puede ser de otro componente
        # (ej: opencode) y no llevar el asset de codex. Recorrer todas las releases
        # (más recientes primero) y usar el primer asset que matchee el patrón.
        local releases releases_url
        releases_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=100"
        info "Asset de codex no encontrado en la release ${RELEASE_TAG}; buscando en releases anteriores..."
        releases=$(curl -fsSL "$releases_url" 2>/dev/null || true)
        if [ -n "$releases" ]; then
            url=$(echo "$releases" \
                | grep -oE 'https://[^"]+' \
                | grep -E "$CODEX_ASSET_PATTERN" \
                | head -n 1 \
                || true)
        fi
        if [ -z "$url" ]; then
            error "La release ${RELEASE_TAG} no contiene el asset de codex ($CODEX_ASSET_PATTERN)"
            return 1
        fi
        info "Usando el asset de codex más reciente disponible en releases anteriores"
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/installer-codex.XXXXXX")"

    local asset="$tmp_dir/codex.zip"
    download_asset "Codex CLI (aarch64)" "$url" "$asset" || { rm -rf "$tmp_dir"; return 1; }

    if ! unzip -t "$asset" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        error "El asset de codex no es un zip válido (descarga corrupta o response de error de la API)"
        return 1
    fi

    mkdir -p "$tmp_dir/x"
    if ! unzip -q "$asset" -d "$tmp_dir/x" 2>/dev/null; then
        rm -rf "$tmp_dir"
        error "No se pudo descomprimir el asset (¿instalaste unzip? → pkg install unzip)"
        return 1
    fi

    local codex_bin="$tmp_dir/x/codex-android"
    if [ ! -f "$codex_bin" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró el binario 'codex-android' dentro del zip"
        return 1
    fi

    chmod +x "$codex_bin"
    if ! check_arch "$codex_bin"; then
        warn "El binario de codex no parece ser ARM64"
    fi

    cp "$codex_bin" "$INSTALL_PREFIX/bin/codex"
    chmod +x "$INSTALL_PREFIX/bin/codex"

    # codex-code-mode-host: runtime companion (V8 embebido); sin él el modo code
    # falla cerrado ("Code Mode is unavailable"). Va junto a codex en $PREFIX/bin.
    local host_bin="$tmp_dir/x/codex-code-mode-host"
    if [ ! -f "$host_bin" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró 'codex-code-mode-host' dentro del zip (el zip de release debe incluirlo)"
        return 1
    fi

    chmod +x "$host_bin"
    if ! check_arch "$host_bin"; then
        warn "El binario de codex-code-mode-host no parece ser ARM64"
    fi

    cp "$host_bin" "$INSTALL_PREFIX/bin/codex-code-mode-host"
    chmod +x "$INSTALL_PREFIX/bin/codex-code-mode-host"

    # Sandbox de codex vía proot (aislamiento de filesystem sin root): con los parches
    # 19/20 el runtime de codex resuelve codex_linux_sandbox_exe desde
    # $CODEX_LINUX_SANDBOX_EXE o PATH y usa la ruta LinuxSeccomp → spawna este wrapper,
    # que ejecuta las tools bajo proot (todo read-only salvo workspace y TMPDIR).
    # El wrapper es OBLIGATORIO si se usa sandbox_mode restrictivo: con los parches
    # 19/20, si el exe del sandbox no se resuelve, codex falla cerrado (por diseño).
    if [ -f "$SCRIPT_DIR/scripts/codex-linux-sandbox" ]; then
        cp "$SCRIPT_DIR/scripts/codex-linux-sandbox" "$INSTALL_PREFIX/bin/codex-linux-sandbox"
        chmod +x "$INSTALL_PREFIX/bin/codex-linux-sandbox"
        info "Sandbox de codex activado vía proot: $INSTALL_PREFIX/bin/codex-linux-sandbox"
        warn "  El wrapper es OBLIGATORIO si usas sandbox_mode restrictivo (read-only o"
        warn "  workspace-write): con los parches 19/20, sin él las tools fallan cerrado"
        warn "  (por diseño). Aislamiento de FILESYSTEM (todo read-only salvo workspace y"
        warn "  TMPDIR); la RED no queda aislada sin root (proot no tiene netns). Requisitos:"
        warn "    - pkg install proot        (el wrapper usa \$PREFIX/bin/proot)"
        warn "    - sandbox_mode = \"read-only\" o \"workspace-write\" en la config de codex"
        warn "    - si proot está en otra ruta: export CODEX_SANDBOX_PROOT=<ruta>"
    else
        warn "No se encontró scripts/codex-linux-sandbox en este repo; el sandbox de codex"
        warn "  NO estará disponible: con sandbox_mode restrictivo las tools fallan cerrado"
        warn "  (por diseño). Usa sandbox_mode = \"disabled\" o instala este repo completo"
        warn "  (el wrapper vive en scripts/ y install.sh lo copia a \$PREFIX/bin)."
    fi
    rm -rf "$tmp_dir"

    info "Codex instalado en $INSTALL_PREFIX/bin/codex"
    info "  codex-code-mode-host instalado en $INSTALL_PREFIX/bin/codex-code-mode-host"
    warn "  codex-code-mode-host usa libc++ estático embebido (use_custom_libcxx del crate v8):"
    warn "  NO debería requerir libc++_shared.so. Verifícalo con:"
    warn "    readelf -d $INSTALL_PREFIX/bin/codex-code-mode-host | grep NEEDED"
    warn "  (si apareciera libc++_shared.so, instala el paquete Termux libc++: pkg install libc++)"
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "==================================="
    echo "  opencode-termux Installer v$VERSION"
    echo "==================================="
    echo ""

    parse_args "$@"

    if $FIX_GLOBAL_BINS; then
        check_env
        fix_global_bins
        exit $?
    fi

    check_env

    # Resolver la release una sola vez (la comparten todos los componentes)
    fetch_release_json

    if $INSTALL_BUN; then
        install_bun || {
            error "Fallo la instalación de Bun"
            exit 1
        }
    fi

    if $INSTALL_OPENCODE; then
        install_opencode || {
            error "Fallo la instalación de OpenCode"
            exit 1
        }
    fi

    if $INSTALL_OPENTUI; then
        install_opentui || {
            error "Fallo la instalación de libopentui.so"
            exit 1
        }
    fi

    if $INSTALL_CODEX; then
        install_codex || {
            error "Fallo la instalación de Codex"
            exit 1
        }
    fi

    echo ""
    info "Instalación completada."
    echo ""
}

main "$@"
