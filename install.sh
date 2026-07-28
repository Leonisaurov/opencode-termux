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

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

# ── Help ────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
opencode-termux Installer v$VERSION

USO:
    ./install.sh [OPCIONES]

OPCIONES:
    --just bun         Instala solo Bun
    --just opencode    Instala solo OpenCode (futuro)
    --all              Instala todo (default)
    --prefix <path>    Directorio de instalación (default: $PREFIX)
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

    cd "$SCRIPT_DIR"
    if ! gh run download --repo Leonisaurov/opencode-termux \
        --workflow build-bun.yml \
        --limit 1 \
        --dir "$tmp_dir" 2>/dev/null; then
        rm -rf "$tmp_dir"
        error "No se pudo descargar el artifact. ¿Hay un workflow exitoso reciente?"
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
    echo "$bun_bin"
    rm -rf "$tmp_dir"
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
            bun_bin=$(download_bun) || true
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

    # Verificar que es ARM64
    local file_info
    file_info=$(file "$bun_bin" 2>/dev/null || echo "")
    if ! echo "$file_info" | grep -q "ARM aarch64\|AArch64"; then
        warn "El binario no parece ser ARM64: $file_info"
    fi

    # Preguntar antes de sobrescribir
    if [ -f "$INSTALL_PREFIX/bin/bun" ]; then
        local old_version
        old_version=$("$INSTALL_PREFIX/bin/bun" --version 2>/dev/null || echo "?")
        warn "Ya existe Bun v$old_version en $INSTALL_PREFIX/bin/bun"
        echo -n "¿Sobrescribir? [s/N] "
        read -r resp
        if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
            info "Instalación cancelada."
            return 0
        fi
    fi

    cp "$bun_bin" "$INSTALL_PREFIX/bin/bun"
    chmod +x "$INSTALL_PREFIX/bin/bun"

    # Verificar
    if command -v bun &>/dev/null; then
        local version
        version=$(bun --version 2>/dev/null)
        info "Bun v$version instalado correctamente en $INSTALL_PREFIX/bin/bun"
    else
        warn "Bun instalado pero no encontrado en PATH. ¿Está $INSTALL_PREFIX/bin en tu PATH?"
    fi

    # Limpiar binario temporal (solo si fue descargado, no si era local)
    # (el binario local queda donde estaba)
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
