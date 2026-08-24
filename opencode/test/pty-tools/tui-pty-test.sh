#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# tui-pty-test.sh — Testea binarios TUI bajo pty real via tmux
#
# Uso en Termux:
#   tools/tui-pty-test.sh -b opencode-android -t 10 -e "JSC_useJIT=0"
#
# El truco de quoting:
#   - El comando complejo se escribe en un script temporal (heredoc),
#     así bash hace el quoting correcto.
#   - tmux solo ejecuta "bash <ruta>" → cero comillas anidadas.
#   - `send-keys -l` envia el texto literal SIN interpretar claves.
#   - `Enter` va en una llamada SEPARADA: con `-l`, "Enter" se
#     enviaria como texto literal y el comando nunca se ejecuta.
# ─────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
uso: tui-pty-test.sh [opciones]

Opciones:
  -b, --bin <ruta>       Binario TUI a testear (default: ../opencode-android)
  -t, --timeout <seg>    Timeout en segundos (default: 10)
  -e, --env "VAR=valor"  Variables de entorno extra (repetible)
  -a, --args "<args>"    Argumentos extra para el binario
  -o, --out <dir>        Directorio de salida para logs (default: $TMPDIR)
  -h, --help             Muestra ayuda
EOF
}

# ── Config por defecto ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../opencode-android"
TIMEOUT=10
: "${TMPDIR:=${RUNNER_TEMP:-${PWD}/ci-tmp}}"
export TMPDIR
mkdir -p "$TMPDIR"
test -d "$TMPDIR" && test -w "$TMPDIR"
OUT_DIR="$TMPDIR"
ENV_VARS=()
EXTRA_ARGS=""

# ── Parseo de argumentos ──
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bin)
            [ $# -ge 2 ] || { echo "ERROR: $1 requiere un argumento" >&2; exit 1; }
            BIN="$2"; shift 2 ;;
        -t|--timeout)
            [ $# -ge 2 ] || { echo "ERROR: $1 requiere un argumento" >&2; exit 1; }
            TIMEOUT="$2"; shift 2 ;;
        -e|--env)
            [ $# -ge 2 ] || { echo "ERROR: $1 requiere un argumento" >&2; exit 1; }
            ENV_VARS+=("$2"); shift 2 ;;
        -a|--args)
            [ $# -ge 2 ] || { echo "ERROR: $1 requiere un argumento" >&2; exit 1; }
            EXTRA_ARGS="$2"; shift 2 ;;
        -o|--out)
            [ $# -ge 2 ] || { echo "ERROR: $1 requiere un argumento" >&2; exit 1; }
            OUT_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "ERROR: opción desconocida: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

# ── Validaciones ──
case "$TIMEOUT" in
    ''|*[!0-9]*)
        echo "ERROR: timeout debe ser un número entero: '$TIMEOUT'" >&2
        exit 1 ;;
esac

# Normalizar BIN a ruta absoluta (acepta relativa y relativa-al-script)
if [ ! -f "$BIN" ] && [ -f "$SCRIPT_DIR/$BIN" ]; then
    BIN="$SCRIPT_DIR/$BIN"
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

[ -f "$BIN" ] || { echo "ERROR: binario no existe: $BIN" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "ERROR: tmux no instalado" >&2; exit 1; }

# ── Nombres únicos por instancia (no colisionan) ──
SESS="tui-test-$$"
OUT_BASE="$OUT_DIR/tui-test-$$"
mkdir -p "$OUT_DIR"

# Cleanup de sesión aunque algo falle a mitad
trap 'tmux kill-session -t "$SESS" 2>/dev/null || true' EXIT

echo "[*] Testeando $(basename "$BIN") en sesión $SESS (timeout ${TIMEOUT}s)"

# Crear sesión tmux detached (120x40)
tmux new-session -d -s "$SESS" -x 120 -y 40

# Escribir el comando en un script temporal: aqui el heredoc hace
# el quoting correcto de bash. Con delimitador SIN comillas se
# expande ahora: paths, env vars, timeout, args y out_base.
# Solo "\$?" queda literal para expandirse EN el pane, en runtime.
cat > "${OUT_BASE}_cmd.sh" << CMD_EOF
#!/usr/bin/env bash
cd $(dirname "$BIN")
$(for v in "${ENV_VARS[@]}"; do echo "export $v"; done)
timeout -s KILL $TIMEOUT ./$(basename "$BIN") $EXTRA_ARGS > "${OUT_BASE}_out.txt" 2>&1
echo "TUI_EXIT=\$?" >> "${OUT_BASE}_exit.txt"
CMD_EOF
chmod +x "${OUT_BASE}_cmd.sh"

# Enviar comando SIMPLE al pane (sin comillas anidadas):
#   - `-l` envia el texto literal, tmux no interpreta claves
#   - `Enter` en llamada SEPARADA (con `-l` se enviaria como texto)
tmux send-keys -t "$SESS" -l "bash ${OUT_BASE}_cmd.sh"
tmux send-keys -t "$SESS" Enter

# Esperar a que termine, con margen max = timeout + 4.
# Si crashea al instante, el archivo de exit aparece en <1s
# (sin esperar el timeout completo).
START=$SECONDS
END=$((START + TIMEOUT + 4))
while [ ! -f "${OUT_BASE}_exit.txt" ] && [ "$SECONDS" -lt "$END" ]; do
    sleep 1
done

# Capturar pane y limpiar sesión
tmux capture-pane -t "$SESS" -p > "${OUT_BASE}_pane.txt" 2>&1 || true
tmux kill-session -t "$SESS" 2>/dev/null || true

# ── Obtener exit code REAL (escrito por el script temporal) ──
EXIT_CODE="timeout"
if [ -f "${OUT_BASE}_exit.txt" ]; then
    EXIT_CODE=$(grep -oP 'TUI_EXIT=\K[0-9]+' "${OUT_BASE}_exit.txt" | tail -1 || true)
    [ -n "$EXIT_CODE" ] || EXIT_CODE="timeout"
fi

# ── Análisis de errores nativos ──
# Nota: `|| true`, NO `|| echo 0` — grep -c imprime "0" Y sale con 1,
#      asi que `|| echo 0` duplicaria la salida ("0\n0").
NATIVE_ERRORS=0
if [ -f "${OUT_BASE}_out.txt" ]; then
    NATIVE_ERRORS=$(grep -icE "panic|segfault|Segmentation fault|abort|SIGTRAP|Scudo ERROR|crashed|SIGSEGV|SIGABRT" "${OUT_BASE}_out.txt" || true)
fi

# ── Resultado ──
echo ""
echo "════════════════════════════════════════"
echo " TUI Test: $(basename "$BIN")"
echo " Sesión:   $SESS"
echo " Timeout:  ${TIMEOUT}s"
echo "════════════════════════════════════════"
# IMPORTANTE (verificado en Termux, coreutils 9.11):
#   timeout -s KILL devuelve 137 (SIGKILL), NO 124.
#   124 solo ocurre con la señal por defecto (SIGTERM).
echo " Exit:     ${EXIT_CODE}  (124/137 = timeout = TUI VIVO; 139=SIGSEGV 134=SIGABRT 133=SIGTRAP 132=SIGILL)"
echo " Errores nativos: $NATIVE_ERRORS"
echo ""
echo "--- Logs ---"
echo " Output:  ${OUT_BASE}_out.txt"
echo " Pane:    ${OUT_BASE}_pane.txt"
echo " Exit:    ${OUT_BASE}_exit.txt"
echo " Cmd:     ${OUT_BASE}_cmd.sh"
echo ""
echo "--- Últimas 5 líneas del output ---"
tail -5 "${OUT_BASE}_out.txt" 2>/dev/null || echo "(sin output)"
echo ""

# ── Interpretación ──
# VIVO = timeout lo mató (124/137) o nunca terminó ("timeout")
ALIVE=0
case "$EXIT_CODE" in
    124|137|timeout) ALIVE=1 ;;
esac

if [ "$ALIVE" = "1" ] && [ "$NATIVE_ERRORS" = "0" ]; then
    echo "✅ TUI VIVO: sobrevivió el timeout sin errores nativos"
    exit 0
elif [ "$ALIVE" = "1" ]; then
    echo "⚠️  TUI vivo pero con $NATIVE_ERRORS errores nativos en el log"
    exit 1
else
    echo "❌ TUI CRASH: exit=$EXIT_CODE, $NATIVE_ERRORS errores nativos"
    exit 1
fi
