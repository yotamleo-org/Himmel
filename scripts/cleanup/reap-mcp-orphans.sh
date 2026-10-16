#!/usr/bin/env bash
# reap-mcp-orphans.sh — find (and optionally kill) MCP/LSP children that
# outlived their claude session.
#
# WHY. Nothing structurally guarantees a claude session's MCP servers / LSP
# stacks die with it. A crash path can leave them running, each ~130-400 MB.
# This is insurance against that failure mode.
#
# PREDICATE. A process is an ORPHAN when ALL hold:
#   1. its command line matches an MCP/LSP signature (context7-mcp,
#      graphify-mcp, tsserver, typescript-language-server, typingsInstaller,
#      a claude plugin-cache path), and
#   2. it is not a whitelisted intentional daemon (qmd --http, telegram
#      supervisor/poller, hermes gateway, flow-exporter, openrgb-bridge,
#      ggs bridges), and
#   3. NO ancestor in its parent chain is a live `claude` process, and every
#      ancestor up to init/systemd is itself an MCP/LSP match (so an editor's
#      language server, owned by a live non-claude process, is never touched).
# Signature + no-live-claude-ancestor is the reliable combination: an orphan is
# reparented to init/systemd, so "parent is dead" is not directly observable.
#
# DEFAULT IS REPORT-ONLY: it logs what WOULD be killed. Arm with --kill after a
# report-only soak. Both the SessionEnd hook and a daily cadence invoke this
# same script (wiring is separate from this script).
#
# TEST SEAM. REAP_ORPHANS_INPUT=<file> substitutes a canned table, one record
# per line: pid|ppid|comm|command line. --kill refuses to run against it.
#
# Usage: bash scripts/cleanup/reap-mcp-orphans.sh [--kill]
# Env:   REAP_ORPHANS_LOG  log file (default ~/.cache/himmel/reap-mcp-orphans.log)
# Exit:  0 done; 1 a kill failed or the log is not writable; 2 usage error /
#        no way to enumerate / --kill on the seam.
set -uo pipefail

KILL=0
case "${1:-}" in
    "") ;;
    --kill) KILL=1 ;;
    *) echo "Usage: reap-mcp-orphans.sh [--kill]" >&2; exit 2 ;;
esac

if [ "$KILL" -eq 1 ] && [ -n "${REAP_ORPHANS_INPUT:-}" ]; then
    echo "reap-mcp-orphans: --kill refuses the REAP_ORPHANS_INPUT test seam" >&2
    exit 2
fi

LOG="${REAP_ORPHANS_LOG:-${XDG_CACHE_HOME:-$HOME/.cache}/himmel/reap-mcp-orphans.log}"

if [ -n "${REAP_ORPHANS_INPUT:-}" ]; then
    TABLE=$(cat "$REAP_ORPHANS_INPUT") || exit 2
else
    TABLE=$(ps -eo pid=,ppid=,comm=,args= 2>/dev/null | awk '{
        pid=$1; ppid=$2; comm=$3; $1=$2=$3=""; sub(/^ +/,"");
        print pid "|" ppid "|" comm "|" $0 }') || exit 2
fi
[ -n "$TABLE" ] || { echo "reap-mcp-orphans: empty process table" >&2; exit 2; }

SIG='context7-mcp|graphify-mcp|tsserver|typescript-language-server|typingsInstaller|/\.claude/plugins/cache/'
KEEP='qmd.* --http|telegram.*(supervisor|poller)|hermes.*gateway|flow-exporter|openrgb-bridge|ggs.*bridge'

# Indexed arrays keyed by numeric PID (bash 3.2 has no associative arrays).
PPID_OF=(); COMM_OF=(); CMD_OF=()
while IFS='|' read -r pid ppid comm cmd; do
    PPID_OF[pid]=$ppid
    COMM_OF[pid]=$comm
    CMD_OF[pid]=$cmd
done <<< "$TABLE"

# Succeeds when the launched program matches a signature: the first words of the
# command line up to the first option, so an unrelated process that merely
# carries an MCP name in an argument (--note=context7-mcp) is not selected.
sig_match() {
    local head="" tok n=0
    for tok in $1; do
        case "$tok" in -*) break ;; esac
        head="$head $tok"
        n=$((n+1))
        [ "$n" -ge 3 ] && break
    done
    grep -Eq "$SIG" <<< "$head"
}

# Succeeds when an ancestor is a live claude, or any ancestor is some other
# live process that is not itself an MCP/LSP signature match (an editor, a
# shell, a service): that process may own the child, so it is never an orphan.
# Only a chain of signature matches ending at pid 1 is an orphan. A per-user
# systemd manager is NOT treated as init: it also owns real user services.
# ponytail: orphans adopted by a subreaper (systemd --user) are never reaped, add a unit-ownership check to cover them.
# An unfinished walk (hop cap, or a parent missing from the table) is "owned".
has_owner_ancestor() {
    local p=$1 hops=0
    while [ "$hops" -lt 64 ]; do
        [ -n "${PPID_OF[p]:-}" ] || return 0
        p=${PPID_OF[p]}
        [ "$p" = "0" ] && return 1
        [ "$p" = "1" ] && return 1
        [ "${COMM_OF[p]:-}" = "claude" ] && return 0
        grep -Eq "$KEEP" <<< "${CMD_OF[p]:-}" && return 0
        sig_match "${CMD_OF[p]:-}" || return 0
        hops=$((hops+1))
    done
    return 0
}

mkdir -p "$(dirname "$LOG")" || { echo "reap-mcp-orphans: cannot create log dir for $LOG" >&2; exit 1; }
verb="would kill"; [ "$KILL" -eq 1 ] && verb="killing"
found=0; killed=0; failed=0
logw() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$LOG" || { echo "reap-mcp-orphans: cannot write $LOG" >&2; exit 1; }; }
while IFS='|' read -r pid ppid comm cmd; do
    [ "$pid" = "$$" ] && continue
    [ "$comm" = "claude" ] && continue
    case "$comm" in bash|sh|zsh|grep|ps|awk|sed) continue ;; esac
    sig_match "$cmd" || continue
    grep -Eq "$KEEP" <<< "$cmd" && continue
    has_owner_ancestor "$pid" && continue
    found=$((found+1))
    line="ORPHAN $pid ($comm) $verb: $cmd"
    echo "$line"
    logw "$line"
    # The table is a snapshot: re-read the live command line, whitespace folded
    # the same way as the snapshot, so a recycled PID is not signalled.
    # ponytail: a replacement with identical args can still pass; a start-time handle (pidfd, /proc starttime) would close it.
    live=$(ps -o args= -p "$pid" 2>/dev/null | tr -s '[:space:]' ' ')
    snap=$(tr -s '[:space:]' ' ' <<< "$cmd")
    if [ "$KILL" -eq 1 ] && [ "${live# }" = "${snap# }" ] && [ -n "$live" ]; then
        if kill "$pid" 2>/dev/null; then
            killed=$((killed+1))
        else
            failed=$((failed+1))
            echo "reap-mcp-orphans: kill FAILED for $pid" >&2
            logw "kill FAILED for $pid"
        fi
    fi
done <<< "$TABLE"

summary="reap-mcp-orphans: $found orphan(s) ($verb)"
[ "$KILL" -eq 1 ] && summary="$summary, $killed signalled, $failed failed"
echo "$summary"
logw "$summary"
[ "$failed" -eq 0 ]
