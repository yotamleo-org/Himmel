#!/usr/bin/env bash
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows.
#
# result.sh — fail-closed tri-state results for gate and hook scripts.
# Sourced; sets no shell options. A read that cannot answer must not look like
# an answer: `x=$(cmd 2>/dev/null || echo 0)` turns "could not ask" into "0".
#
# Exit-code contract of the command run (the grep/test convention):
#   0 -> ok        a definite yes
#   1 -> fail      a definite no
#   anything else (usage error, 124 timeout, 126/127 not runnable, signal)
#      -> unknown  the question was never answered
#
#   run_or_unknown <cmd> [args...]
#       Runs the command, stdout captured, stderr left on the terminal. Sets
#       RESULT_STATE (ok|fail|unknown), RESULT_RC (the real exit code) and
#       RESULT_OUT (stdout, trailing newlines stripped). Returns 0 ok, 1 fail,
#       2 unknown, so `if run_or_unknown ...` is true only for a definite ok.
#   require_ok <label> <cmd> [args...]
#       run_or_unknown, then print "<label>: FAIL|UNKNOWN (rc=N)" to stderr
#       unless ok. Same return codes; the caller decides, nothing is swallowed.
#   result_render
#       Prints OK, FAIL or UNKNOWN for the last result. unknown is never OK.
#
# shellcheck disable=SC2034  # RESULT_* are the caller-facing outputs
# ponytail: shell only; a node twin is deferred (no gate needs it yet) — add one
# beside scripts/lib/ when the first node gate adopts the tri-state.

RESULT_STATE="unknown"
RESULT_RC=""
RESULT_OUT=""

run_or_unknown() {
    RESULT_STATE="unknown"; RESULT_RC=""; RESULT_OUT=""
    [ $# -ge 1 ] || return 2
    local _out _rc
    _out="$("$@")"
    _rc=$?
    RESULT_RC="$_rc"
    RESULT_OUT="$_out"
    case "$_rc" in
        0) RESULT_STATE="ok";   return 0 ;;
        1) RESULT_STATE="fail"; return 1 ;;
        *) RESULT_STATE="unknown"; return 2 ;;
    esac
}

require_ok() {
    local _label="${1-}"
    shift
    run_or_unknown "$@"
    local _r=$?
    if [ "$_r" -ne 0 ]; then
        printf '%s: %s (rc=%s)\n' "$_label" "$(result_render)" "$RESULT_RC" >&2
    fi
    return "$_r"
}

result_render() {
    case "$RESULT_STATE" in
        ok)   echo "OK" ;;
        fail) echo "FAIL" ;;
        *)    echo "UNKNOWN" ;;
    esac
}
