#!/usr/bin/env bash
# Run a TUI in a detached tmux session and print the rendered pane.
#
# This lets an agent or a headless Termux session drive a full-screen TUI
# without blocking on it: the session runs in the background while the caller
# only reads the captured pane.
#
# Usage:
#   tui-smoke.sh [options] -- CMD [ARG...]
#
# Options:
#   --size WxH      terminal size for the session (default: 120x32)
#   --wait SECONDS  time to let the TUI render before capturing (default: 8)
#   --session NAME  tmux session name (default: tui-smoke-$$)
#   --send STRING   send literal keys after the wait (repeatable)
#   --grep REGEX    fail if the captured pane does not match the regex
#   --reject REGEX  fail if the captured pane matches the regex
#   --keep          leave the session running after capture
#
# The captured pane is always written to stdout. The session is killed unless
# --keep is given.
set -euo pipefail

SIZE="120x32"
WAIT=8
SESSION="tui-smoke-$$"
KEEP=0
GREP=""
REJECT=""
SENDS=()

usage() {
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --session) SESSION="$2"; shift 2 ;;
        --send) SENDS+=("$2"); shift 2 ;;
        --grep) GREP="$2"; shift 2 ;;
        --reject) REJECT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --) shift; break ;;
        -h|--help) usage; exit 0 ;;
        *) break ;;
    esac
done

if [ $# -eq 0 ]; then
    usage >&2
    exit 2
fi

if ! command -v tmux >/dev/null 2>&1; then
    echo "tui-smoke: tmux is required" >&2
    exit 2
fi

WIDTH="${SIZE%x*}"
HEIGHT="${SIZE#*x}"

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x "$WIDTH" -y "$HEIGHT"

command_line="$(printf '%q ' "$@")"
tmux send-keys -t "$SESSION" "$command_line" Enter
sleep "$WAIT"

for send in "${SENDS[@]:-}"; do
    [ -n "$send" ] || continue
    tmux send-keys -t "$SESSION" "$send"
done
if [ "${#SENDS[@]}" -gt 0 ]; then
    sleep 1
fi

pane="$(tmux capture-pane -t "$SESSION" -p)"

if [ "$KEEP" != 1 ]; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
fi

printf '%s\n' "$pane"

if [ -n "$GREP" ] && ! printf '%s\n' "$pane" | grep -Eq "$GREP"; then
    echo "tui-smoke: pane did not match: $GREP" >&2
    exit 1
fi
if [ -n "$REJECT" ] && printf '%s\n' "$pane" | grep -Eq "$REJECT"; then
    echo "tui-smoke: pane matched rejected pattern: $REJECT" >&2
    exit 1
fi
