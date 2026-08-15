#!/usr/bin/env bash
# codex-prepare-source.sh - Prepara el código fuente de openai/codex (mismo mecanismo en CI y local):
#   - verifica/clona el checkout en el ref pinneado (CODEX_REF)
#   - aplica los parches de patches/codex (orden 01..19) con verify_patched_state
#
# Comparte la lógica que antes vivía en build-codex-ci.sh ([1/5]+[2/5]) con el
# build local (codex_build.sh): ambos deben compilar EXACTAMENTE el mismo fuente
# (mismo ref, mismos parches, misma verificación de reproducibilidad).
#
# Idempotente: si el checkout ya está en el ref y el worktree ya tiene los
# parches exactos aplicados (verify_patched_state), no toca nada → EXIT=0 con
# mensaje de skip (caso del checkout local de Termux).
#
# Uso: codex-prepare-source.sh <CODEX_REPO> <CODEX_REF> <PATCHES_DIR>
#   CODEX_REPO   raíz del checkout de openai/codex (operaciones git: fetch/checkout/apply/status)
#   CODEX_REF    commit sha (40 hex) O tag (p.ej. rust-v0.134.0-alpha.3) pinneado en scripts/env.sh
#   PATCHES_DIR  directorio con los parches del port (patches/codex), aplicados en orden alfabético
set -euo pipefail

# ── Helpers ──
msg() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
start_timer() { START_TS=$(date +%s); }
elapsed() { local end=$(date +%s); echo $((end - START_TS)); }

# ── Args ──
[ "$#" -eq 3 ] || die "uso: $0 <CODEX_REPO> <CODEX_REF> <PATCHES_DIR> (recibidos $# args)"
CODEX_REPO="$1"
CODEX_REF="$2"
PATCHES_DIR="$3"

[[ -n "$CODEX_REPO" ]] || die "CODEX_REPO no puede estar vacío"
[[ -n "$CODEX_REF" ]] || die "CODEX_REF no puede estar vacío"
# CODEX_REF acepta commit sha (40 hex) O tag (los parches de openai/codex usan
# tags rust-v* / codex-rs-v*). Si el ref no existe, el fetch falla con mensaje
# claro; aquí solo se descartan caracteres que romperían los comandos git.
[[ "$CODEX_REF" =~ ^[0-9A-Za-z._/-]+$ ]] \
    || die "CODEX_REF debe ser un commit sha de 40 hex o un tag (recibido: '$CODEX_REF')"
[ -d "$PATCHES_DIR" ] || die "no existe el directorio de parches: $PATCHES_DIR"

# ── [1/2] Clonar openai/codex al ref (raíz del checkout: CODEX_REPO) ──
start_timer
if [ -d "$CODEX_REPO/.git" ]; then
    msg ":: checkout existe, reutilizando (idempotente)..."
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
        die "HEAD de $CODEX_REPO ($local_head) != ref $CODEX_REF (sha $ref_sha)." \
            "Alinea el checkout con:" \
            "  git -C $CODEX_REPO fetch origin && git -C $CODEX_REPO checkout $CODEX_REF" \
            "(el working tree debe estar limpio o con los parches exactos aplicados; borra $CODEX_REPO para re-clonar)"
    fi
else
    [ -e "$CODEX_REPO" ] && die "$CODEX_REPO existe pero no es un repo git válido"
    msg ":: clonando openai/codex@$CODEX_REF..."
    mkdir -p "$(dirname "$CODEX_REPO")"
    git init -q "$CODEX_REPO"
    git -C "$CODEX_REPO" remote add origin https://github.com/openai/codex
    if ! git -C "$CODEX_REPO" fetch -q --depth 1 origin "$CODEX_REF"; then
        die "fetch de openai/codex@'$CODEX_REF' falló: ¿existe ese commit o tag en openai/codex? (o error de red)"
    fi
    git -C "$CODEX_REPO" checkout -q FETCH_HEAD
fi
msg "   checkout listo ($(elapsed)s): $(git -C "$CODEX_REPO" rev-parse --short=8 HEAD)"

# ── [2/2] Aplicar parches con fail-fast ──
start_timer
shopt -s nullglob
PATCH_FILES=( "$PATCHES_DIR"/*.patch )
shopt -u nullglob
[ "${#PATCH_FILES[@]}" -gt 0 ] || die "no hay *.patch en $PATCHES_DIR"

# Archivos que DEBEN quedar modificados tras aplicar los parches (extraídos del diff)
mapfile -t EXPECTED_FILES < <(grep -h '^diff --git a/' "${PATCH_FILES[@]}" | sed -E 's/^diff --git a\///; s/ b\/.*$//')
[ "${#EXPECTED_FILES[@]}" -eq "${#PATCH_FILES[@]}" ] || die "los parches no tocan exactamente un archivo cada uno (revisa $PATCHES_DIR)"

# Verifica que el worktree tenga EXACTAMENTE los archivos de los parches modificados
# (o creados) y nada más (ni staged, ni otros cambios).
# Los parches solo tocan archivos ya existentes salvo 16-bionic-stubs-build.patch,
# que CREA codex-rs/code-mode-host/build.rs: `git apply` deja los archivos nuevos
# como untracked (`?? ` en --porcelain), no como ` M ` → se aceptan ambos para
# los archivos esperados. Los demás untracked (target/ etc.) están gitignored y
# no aparecen en --porcelain.
verify_patched_state() {
    local line=""
    local -a actual=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ M\ (.*)$ ]]; then
            actual+=("${BASH_REMATCH[1]}")
        elif [[ "$line" =~ ^\?\?\ (.*)$ ]]; then
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

msg ":: aplicando parches ($(basename "$PATCHES_DIR"), ${#PATCH_FILES[@]} parches)..."
local_st="$(git -C "$CODEX_REPO" status --porcelain)"
if [ -n "$local_st" ]; then
    if verify_patched_state; then
        msg "   parches ya aplicados (skip)"
    else
        die "checkout de $CODEX_REPO no está limpio ni con los parches exactos aplicados; borra $CODEX_REPO y reintenta"
    fi
else
    git -C "$CODEX_REPO" apply --check "${PATCH_FILES[@]}" \
        || die "los parches no aplican sobre openai/codex@$CODEX_REF; ¿cambió el ref? (git apply --check falló)"
    git -C "$CODEX_REPO" apply "${PATCH_FILES[@]}"
    msg "   parches aplicados ($(elapsed)s)"
fi
verify_patched_state || die "reproducibilidad fallida: el worktree tras aplicar no coincide byte-por-byte con los parches"
msg "   reproducibilidad OK: exactamente los ${#EXPECTED_FILES[@]} archivos esperados"
msg ":: fuente lista: $CODEX_REPO @ $CODEX_REF"
