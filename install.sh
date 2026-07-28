#!/usr/bin/env bash
# Instalador de opencode-termux
# Uso: ./install.sh [--just bun|opencode|all] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"
INSTALL_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
INSTALL_BUN=false
INSTALL_OPENCODE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[✓]${NC} $1" >&2; }
warn()  { echo -e "${YELLOW}[!]${NC} $1" >&2; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; }

check_arch() {
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
    --just bun         Instala solo Bun
    --just opencode    Instala solo OpenCode (futuro)
    --all              Instala todo (default)
    --prefix <path>    Directorio de instalación (default: \$PREFIX)
    --version          Muestra versión
    --help             Muestra esta ayuda

EJEMPLOS:
    ./install.sh --just bun
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
                    all) INSTALL_BUN=true; INSTALL_OPENCODE=true ;;
                    *) error "Opción inválida: $1"; exit 1 ;;
                esac
                shift
                ;;
            --all) INSTALL_BUN=true; INSTALL_OPENCODE=true; shift ;;
            --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
            --version) echo "opencode-termux-installer v$VERSION"; exit 0 ;;
            --help|-h) show_help ;;
            *) error "Opción desconocida: $1"; show_help; exit 1 ;;
        esac
    done

    # Default: instalar todo
    if ! $INSTALL_BUN && ! $INSTALL_OPENCODE; then
        INSTALL_BUN=true
        INSTALL_OPENCODE=true
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

# ── Find or download Bun ────────────────────────────────────────────
find_bun_binary() {
    # 1. Buscar en .bun-artifact/
    local local_bun
    local_bun=$(find "$SCRIPT_DIR/.bun-artifact" -name "bun" -type f 2>/dev/null | head -1)
    if [ -n "$local_bun" ] && [ -x "$local_bun" ]; then
        echo "$local_bun"
        return 0
    fi

    # 2. Buscar en build/
    local_bun=$(find "$SCRIPT_DIR/build" -name "bun" -type f 2>/dev/null | head -1)
    if [ -n "$local_bun" ] && [ -x "$local_bun" ]; then
        echo "$local_bun"
        return 0
    fi

    # 3. Buscar en bun-source/build/
    local_bun=$(find "$SCRIPT_DIR/bun-source" -name "bun" -type f 2>/dev/null | head -1)
    if [ -n "$local_bun" ] && [ -x "$local_bun" ]; then
        echo "$local_bun"
        return 0
    fi

    return 1
}

download_bun() {
    info "Descargando Bun desde GitHub Actions..."

    if ! command -v gh &>/dev/null; then
        error "No se encontró 'gh' (GitHub CLI)."
        warn "Instálalo con: pkg install gh && gh auth login"
        warn "O construye Bun localmente con: ./scripts/apply-patches.sh && ./scripts/build-bun.sh"
        return 1
    fi

    local tmp_dir
    tmp_dir="$(mktemp -d)"

    # Obtener el run ID del último exitoso (solo de nuestra branch)
    local run_id
    run_id=$(gh run list --repo Leonisaurov/opencode-termux \
        --workflow build-bun.yml \
        --status success \
        --branch update-v1.18.6 \
        --limit 1 \
        --json databaseId \
        -q '.[0].databaseId' 2>/dev/null) || true

    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró ningún workflow exitoso reciente de build-bun.yml"
        error "Ejecuta: gh workflow run build-bun.yml --ref update-v1.18.6"
        return 1
    fi

    info "Descargando artifact del run #${run_id}..."
    if ! gh run download "$run_id" \
        --repo Leonisaurov/opencode-termux \
        --dir "$tmp_dir" 2>/dev/null; then
        rm -rf "$tmp_dir"
        error "No se pudo descargar el artifact del run #${run_id}"
        return 1
    fi

    local bun_bin
    bun_bin=$(find "$tmp_dir" -name "bun" -type f 2>/dev/null | head -1)
    if [ -z "$bun_bin" ]; then
        rm -rf "$tmp_dir"
        error "No se encontró el binario 'bun' en el artifact descargado"
        return 1
    fi

    chmod +x "$bun_bin"

    # Verificar nombre del artifact esperado
    local artifact_name
    artifact_name=$(basename "$(find "$tmp_dir" -maxdepth 1 -type d 2>/dev/null | tail -1)" 2>/dev/null || echo "")
    if [ -n "$artifact_name" ] && [[ "$artifact_name" != "bun-android-aarch64"* ]]; then
        warn "Artifact inesperado: '$artifact_name' (se esperaba bun-android-aarch64-*)"
    fi

    # Copiar a ubicación estable antes de limpiar
    local dest="$SCRIPT_DIR/.bun-artifact/bun-downloaded"
    mkdir -p "$(dirname "$dest")"
    cp "$bun_bin" "$dest"
    chmod +x "$dest"
    rm -rf "$tmp_dir"
    echo "$dest"
    return 0
}

# ── Install Bun ─────────────────────────────────────────────────────
install_bun() {
    info "Instalando Bun..."

    local bun_bin
    bun_bin=$(find_bun_binary) || true

    if [ -z "$bun_bin" ]; then
        warn "No se encontró binario local de Bun."
        if command -v gh &>/dev/null; then
            if ! bun_bin=$(download_bun); then
                bun_bin=""
            fi
        else
            error "No hay 'gh' disponible. Opciones:"
            error "  1. Instala gh: pkg install gh && gh auth login"
            error "  2. Construye Bun: gh workflow run build-bun.yml --ref update-v1.18.6"
            error "  3. O usa un binario pre-existente en .bun-artifact/"
            return 1
        fi
    fi

    if [ -z "$bun_bin" ]; then
        return 1
    fi

    if ! check_arch "$bun_bin"; then
        warn "El binario no parece ser ARM64"
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
                info "Instalación cancelada."
                return 0
            fi
        else
            # Modo no interactivo — sobrescribir automáticamente
            info "Reemplazando Bun v$old_version con nueva versión"
        fi
    fi

    cp "$bun_bin" "$INSTALL_PREFIX/bin/bun"
    chmod +x "$INSTALL_PREFIX/bin/bun"
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

# ── Main ────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "==================================="
    echo "  opencode-termux Installer v$VERSION"
    echo "==================================="
    echo ""

    parse_args "$@"
    check_env

    if $INSTALL_BUN; then
        install_bun || {
            error "Fallo la instalación de Bun"
            exit 1
        }
    fi

    if $INSTALL_OPENCODE; then
        info "OpenCode: aún no implementado (futuro)"
    fi

    echo ""
    info "Instalación completada."
    echo ""
}

main "$@"
