#!/usr/bin/env bash
# reap-mcp-orphans.sh — find (and optionally kill) MCP/LSP children that
# outlived their claude session.
#
# WHY. Nothing structurally guarantees a claude session's MCP servers / LSP
# stacks die with it. A crash path can leave them running, each ~130-400 MB.
# This is insurance against that failure mode.
#
# PREDICATE. A process is an ORPHAN when ALL hold:
#   1. its PROGRAM matches an MCP/LSP signature (context7-mcp, graphify-mcp,
#      tsserver, typescript-language-server, typingsInstaller, a claude
#      plugin-cache path). The program is argv0, or the script argument when
#      argv0 is an interpreter (node, bun, python...): a signature that only
#      appears further along the command line (rg context7-mcp, less
#      <plugin-cache file>) never selects the process, and
#   2. it is not a whitelisted intentional daemon (qmd --http, telegram
#      supervisor/poller, hermes gateway, flow-exporter, openrgb-bridge,
#      ggs bridges), and
#   3. every ancestor up to pid 1 is itself an MCP/LSP program match. Any other
#      live ancestor (claude, codex, an editor, a shell, a service manager)
#      may own the child, so the child is left alone. No process name is
#      special-cased: that is what keeps this safe for every harness.
# An orphan is reparented to init, so "parent is dead" is not directly
# observable; "chain of signature matches ending at pid 1" is.
#
# DEFAULT IS REPORT-ONLY: it logs what WOULD be killed. Arm with --kill after a
# report-only soak. Both the SessionEnd hook and a daily cadence invoke this
# same script (wiring is separate from this script). Only the caller's own
# processes are considered.
#
# TEST SEAM. REAP_ORPHANS_INPUT=<file> substitutes a canned table, one record
# per line: pid|ppid|command line. --kill refuses it unless
# REAP_ORPHANS_TEST_KILL=1 (the kill path still re-verifies each live pid).
#
# Usage: bash scripts/cleanup/reap-mcp-orphans.sh [--kill]
# Env:   REAP_ORPHANS_LOG  log file (default ~/.cache/himmel/reap-mcp-orphans.log)
# Exit:  0 done; 1 a kill failed or the log is not writable; 2 usage error /
#        no way to enumerate / --kill on the seam.
set -uo pipefail
set -f

KILL=0
case "${1:-}" in
    "") ;;
    --kill) KILL=1 ;;
    *) echo "Usage: reap-mcp-orphans.sh [--kill]" >&2; exit 2 ;;
esac

if [ "$KILL" -eq 1 ] && [ -n "${REAP_ORPHANS_INPUT:-}" ] && [ -z "${REAP_ORPHANS_TEST_KILL:-}" ]; then
    echo "reap-mcp-orphans: --kill refuses the REAP_ORPHANS_INPUT test seam" >&2
    exit 2
fi

LOG="${REAP_ORPHANS_LOG:-${XDG_CACHE_HOME:-$HOME/.cache}/himmel/reap-mcp-orphans.log}"

if [ -n "${REAP_ORPHANS_INPUT:-}" ]; then
    TABLE=$(cat "$REAP_ORPHANS_INPUT") || exit 2
else
    TABLE=$(ps -u "$(id -u)" -o pid=,ppid=,args= 2>/dev/null | awk '{
        pid=$1; ppid=$2; $1=$2=""; sub(/^ +/,"");
        print pid "|" ppid "|" $0 }') || exit 2
fi
[ -n "$TABLE" ] || { echo "reap-mcp-orphans: empty process table" >&2; exit 2; }

SIG='context7-mcp|graphify-mcp|tsserver|typescript-language-server|typingsInstaller|/\.claude/plugins/cache/'
KEEP='qmd.* --http|telegram.*(supervisor|poller)|hermes.*gateway|flow-exporter|openrgb-bridge|ggs.*bridge'

# Indexed arrays keyed by numeric PID (bash 3.2 has no associative arrays).
PPID_OF=(); CMD_OF=()
while IFS='|' read -r pid ppid cmd; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    PPID_OF[pid]=$ppid
    CMD_OF[pid]=$cmd
done <<< "$TABLE"

# Prints the launched program: argv0, or for an interpreter the first
# non-option argument (the script or package it runs). Empty when there is none.
prog_of() {
    local tok first=1
    for tok in $1; do
        if [ "$first" -eq 1 ]; then
            first=0
            case "${tok##*/}" in
                node|nodejs|bun|bunx|deno|npx|tsx|ts-node|uv|python|python3|python3.*) continue ;;
                *) printf '%s' "$tok"; return ;;
            esac
        fi
        case "$tok" in -*|run|exec|x) continue ;; esac
        printf '%s' "$tok"
        return
    done
}

# Succeeds when the launched program matches an MCP/LSP signature.
sig_match() {
    local p
    p=$(prog_of "$1")
    [ -n "$p" ] && grep -Eq "$SIG" <<< "$p"
}

# Succeeds when some ancestor may own the process: any live ancestor that is not
# itself an MCP/LSP program match (claude, codex, an editor, a shell, a service,
# a per-user systemd manager). Only a chain of signature matches ending at
# pid 1 is an orphan. An unfinished walk (hop cap, or a parent missing from the
# table) is "owned".
# ponytail: orphans adopted by a subreaper (systemd --user) are never reaped, add a unit-ownership check to cover them.
has_owner_ancestor() {
    local p=$1 hops=0
    while [ "$hops" -lt 64 ]; do
        [ -n "${PPID_OF[p]:-}" ] || return 0
        p=${PPID_OF[p]}
        [ "$p" = "0" ] && return 1
        [ "$p" = "1" ] && return 1
        grep -Eq "$KEEP" <<< "${CMD_OF[p]:-}" && return 0
        sig_match "${CMD_OF[p]:-}" || return 0
        hops=$((hops+1))
    done
    return 0
}

# Command line with NULs and runs of whitespace folded to single spaces.
fold() { printf '%s' "$1" | tr '\0' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'; }

# Process start time (clock ticks since boot, /proc/<pid>/stat field 22).
# Fails when /proc is unavailable, so an unverifiable process is never signalled.
start_of() {
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    s=${s##*) }
    # shellcheck disable=SC2086
    set -- $s
    [ -n "${20:-}" ] && printf '%s' "${20}"
}

mkdir -p "$(dirname "$LOG")" || { echo "reap-mcp-orphans: cannot create log dir for $LOG" >&2; exit 1; }
verb="would kill"; [ "$KILL" -eq 1 ] && verb="killing"
found=0; killed=0; failed=0; skipped=0
logw() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG" || { echo "reap-mcp-orphans: cannot write $LOG" >&2; exit 1; }; }
while IFS='|' read -r pid ppid cmd; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    sig_match "$cmd" || continue
    grep -Eq "$KEEP" <<< "$cmd" && continue
    has_owner_ancestor "$pid" && continue
    found=$((found+1))
    line="ORPHAN $pid $verb: $cmd"
    echo "$line"
    logw "$line"
    [ "$KILL" -eq 1 ] || continue
    # The table is a snapshot: before signalling, the live process must still
    # have the same command line and the same start time as when it was
    # classified, so a recycled PID is never signalled.
    # ponytail: the start time is read at classification, not at table capture, so a reuse inside that window passes; capture it with the table (pidfd) to close it.
    st0=$(start_of "$pid") || st0=""
    live=$(fold "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)")
    st1=$(start_of "$pid") || st1=""
    if [ -z "$st0" ] || [ "$st0" != "$st1" ] || [ "$live" != "$(fold "$cmd")" ]; then
        skipped=$((skipped+1))
        echo "reap-mcp-orphans: skipped $pid (identity changed or unverifiable)" >&2
        logw "skipped $pid (identity changed or unverifiable)"
    elif kill "$pid" 2>/dev/null; then
        killed=$((killed+1))
    else
        failed=$((failed+1))
        echo "reap-mcp-orphans: kill FAILED for $pid" >&2
        logw "kill FAILED for $pid"
    fi
done <<< "$TABLE"

summary="reap-mcp-orphans: $found orphan(s) ($verb)"
[ "$KILL" -eq 1 ] && summary="$summary, $killed signalled, $skipped skipped, $failed failed"
echo "$summary"
logw "$summary"
[ "$failed" -eq 0 ]
