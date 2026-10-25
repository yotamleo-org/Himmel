#!/usr/bin/env bash
# overnight/stop-marker — graceful-halt marker for /afk-shift sessions.
#
# The marker file is what `/afk-shift`
# (and the overnight-mode runbook Phase 3 impl loop) polls between
# dispatches. When set, the dispatcher finishes the in-flight subagent +
# halts before starting the next one. No subprocess kills — graceful only.
# `/stop --hard` is a Claude-side action handled in the slash command body
# (calls TaskStop on in-flight subagents); this script handles the marker
# lifecycle only.
#
# Marker path: ~/.claude/.overnight-stop in the himmel clone,
# ~/.claude/afk/<project key>/.overnight-stop in an adopted project
# (project-state.sh), so a stop halts only its own project's shift; `check`
# also honours the clone's global marker, so a /stop from the clone halts all. Single
# file, no content needed — existence is the signal. Stored under $HOME so it
# survives worktree pruning.
#
# Subcommands:
#   set     Touch the marker. Idempotent (no-op if already set).
#   check   Exit 0 if the marker (or the global one) exists, 1 otherwise. Silent.
#   clear   Remove the marker. Idempotent. Aliases: reset, rm.
#   status  Print human-readable state to stdout. Always exits 0.
#
# Exit codes:
#   0  command succeeded (or check found marker present)
#   1  check found marker absent
#   2  usage / unknown subcommand
#   3  filesystem error (can't create/remove)
set -uo pipefail

# shellcheck source=project-state.sh
. "$(dirname "${BASH_SOURCE[0]}")/project-state.sh"
MARKER_DIR=$(afk_stop_dir) || exit 3
MARKER_PATH="$MARKER_DIR/.overnight-stop"
# The clone's global marker halts every adopted shift too (a /stop from the clone).
GLOBAL_PATH=""
if [ -z "${AFK_STOP_DIR:-${OVERNIGHT_STOP_DIR:-}}" ] && [ "$MARKER_PATH" != "$HOME/.claude/.overnight-stop" ]; then
    GLOBAL_PATH="$HOME/.claude/.overnight-stop"
fi

usage() {
    cat <<'EOF'
Usage: stop-marker.sh <set|check|clear|status>

Manages the current project's .overnight-stop marker file used by
/afk-shift's dispatch loop. When set, the dispatcher halts
gracefully before the next subagent dispatch.

Subcommands:
  set       Touch the marker (idempotent).
  check     Silent. Exit 0 if marker exists, 1 otherwise.
  clear     Remove the marker (idempotent). Aliases: reset, rm.
  status    Print human-readable state. Always exits 0.

Environment:
  AFK_STOP_DIR          Override marker directory (old name OVERNIGHT_STOP_DIR).
                        Default: $HOME/.claude in the himmel clone,
                        $HOME/.claude/afk/<project key> in an adopted project.
EOF
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
    usage >&2
    exit 2
fi

case "$cmd" in
    set)
        if ! mkdir -p "$MARKER_DIR" 2>/dev/null; then
            echo "ERR stop-marker: cannot create $MARKER_DIR" >&2
            exit 3
        fi
        if ! : > "$MARKER_PATH" 2>/dev/null; then
            echo "ERR stop-marker: cannot write $MARKER_PATH" >&2
            exit 3
        fi
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "$MARKER_PATH" 2>/dev/null || true
        echo "stop-marker: SET at $MARKER_PATH"
        ;;
    check)
        [ -f "$MARKER_PATH" ] && exit 0
        [ -n "$GLOBAL_PATH" ] && [ -f "$GLOBAL_PATH" ] && exit 0
        exit 1
        ;;
    clear|reset|rm)
        if [ -f "$MARKER_PATH" ]; then
            if ! rm -f "$MARKER_PATH" 2>/dev/null; then
                echo "ERR stop-marker: cannot remove $MARKER_PATH" >&2
                exit 3
            fi
            echo "stop-marker: CLEARED $MARKER_PATH"
        else
            echo "stop-marker: already clear (no marker at $MARKER_PATH)"
        fi
        ;;
    status)
        if [ -f "$MARKER_PATH" ]; then
            ts=$(cat "$MARKER_PATH" 2>/dev/null || echo "?")
            echo "stop-marker: SET ($MARKER_PATH; armed at $ts)"
        else
            echo "stop-marker: CLEAR (no marker at $MARKER_PATH)"
        fi
        if [ -n "$GLOBAL_PATH" ] && [ -f "$GLOBAL_PATH" ]; then
            echo "stop-marker: global marker SET at $GLOBAL_PATH (halts every shift)"
        fi
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "ERR stop-marker: unknown subcommand '$cmd'" >&2
        usage >&2
        exit 2
        ;;
esac
exit 0
