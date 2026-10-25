#!/usr/bin/env bash
# action-zero.sh — The incoming console's mechanical ACTION ZERO
# probes (console-template.md steps 2-6 and 8) in ONE command that prints one
# summary, instead of six or seven Bash turns that each re-read the context.
#
#   action-zero.sh --doc <this console doc> --root <handover root> [--repo <path>]
#                  [--prefix <P>] [--acquire] [--render-legs] [--lock-only]
#
#   LOCKS   queue-lock.sh status --sweep at the ROOT (never the bucket); a
#           flagged lock (sweep exit 20) is listed, not read as a failure
#   HEAD    primary head sha + remote
#   BANK    usage-preflight.sh output
#   PROCS   the leg processes (pgrep -af 'claude .*-n <prefix>-'), one
#           `<pid> <command> <session name>` row each, never the full argv
#   C29     himmel-doctor.sh --only C29 (a session that inherited CHILD_SESSION=1)
#   LOAD    uptime
#   DOC     read-only Live state digest via live-state.sh --digest (under 60 lines),
#           status and open ruling titles only, never the full document body
#   LOCK    this document's lock state; with --acquire and state `free`, acquires
#           it, prints the release token and writes it over the doc's
#           `none yet — acquire your own` line. `held` is never taken over.
#   LEGS    only with --render-legs: rewrites the doc's `## Live state` legs: line
#           from the fleet manifest through live-state.sh (lock tokens from the
#           held locks, nonces kept) instead of a hand edit, bounded by
#           ACTION_ZERO_LEGS_TIMEOUT (default 60s); `unavailable` and exit 1 when
#           it cannot render (no manifest next to the doc, a failure or a timeout) and
#           when this document's lock is held (by this or another session): the legs: line is not
#           rewritten. A console already holding its lock re-renders with live-state.sh.
#
# --lock-only runs the LOCK section alone: the successor's one call once
# `console.sh next` has pre-computed the other sections into its doc.
#
# Everything is read-only except --acquire and --render-legs. What it leaves to the console, on
# purpose (they need its own turn and its own authority): ListAgents (step 1),
# the relays and each leg's quote-back (step 9), sending LIVE, and starting the
# waiter (step 10). A section that fails prints `unavailable` and the rest run.
#
# Seams (tests): ACTION_ZERO_BANK, ACTION_ZERO_DOCTOR replace those commands.
# BANK and C29 run under a timeout (ACTION_ZERO_BANK_TIMEOUT,
# default 60s; ACTION_ZERO_DOCTOR_TIMEOUT, default 120s). A hung probe prints
# `TIMEOUT <bank|doctor> after <n>s` in its section and the summary carries on.
# No timeout binary: the probes run unbounded, with a WARN line.
# Exit: 0; 1 if --render-legs could not render; 2 usage. PLATFORM GUARD: Linux-only kit, bash 3.2-safe.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$HERE/../../.." && pwd)"
doc=""; root=""; prefix=""; acquire=0; render=0; render_rc=0; lockonly=0
usage() { echo "usage: action-zero.sh --doc <console doc> --root <handover root> [--repo <path>] [--prefix <P>] [--acquire] [--render-legs] [--lock-only]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --root) [ "$#" -ge 2 ] || usage; root="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --prefix) [ "$#" -ge 2 ] || usage; prefix="$2"; shift 2 ;;
        --acquire) acquire=1; shift ;;
        --render-legs) render=1; shift ;;
        --lock-only) lockonly=1; shift ;;
        *) usage ;;
    esac
done
if [ -z "$doc" ] || [ -z "$root" ]; then usage; fi
ql="$repo/scripts/handover/queue-lock.sh"

# Resolved in a subshell so no source edge makes shellcheck-pr-range lint
# timeout-bin.sh's consumers (check-ci-watch.sh) without their own sources.
tb_lib="$repo/scripts/lib/timeout-bin.sh"
_TIMEOUT_BIN="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "$_TIMEOUT_BIN"' _ "$tb_lib" 2>/dev/null)"
bank_t="${ACTION_ZERO_BANK_TIMEOUT:-60}"; doctor_t="${ACTION_ZERO_DOCTOR_TIMEOUT:-120}"; legs_t="${ACTION_ZERO_LEGS_TIMEOUT:-60}"
# bounded <name> <secs> <cmd...>: output on stdout; a timeout prints the TIMEOUT line.
bounded() {
    local name="$1" secs="$2" brc; shift 2
    if [ -z "${_TIMEOUT_BIN:-}" ]; then
        echo "WARN no timeout binary: $name probe runs unbounded"
        "$@" 2>&1; return $?
    fi
    "$_TIMEOUT_BIN" -k 2 "$secs" "$@" 2>&1; brc=$?
    if [ "$brc" -eq 124 ] || [ "$brc" -eq 137 ]; then echo "TIMEOUT $name after ${secs}s"; fi
    return "$brc"
}

if [ "$lockonly" -eq 0 ]; then
    echo "== LOCKS (swept at the root)"
    env HANDOVER_DIR="$root" bash "$ql" status --sweep "$root" 2>&1; swrc=$?
    # Exit 20 means locks were flagged: the listing above is the result.
    [ "$swrc" -eq 0 ] || [ "$swrc" -eq 20 ] || echo "unavailable"

    echo "== HEAD"
    git -C "$repo" log -1 --format=%H 2>&1 || echo "unavailable"
    git -C "$repo" remote -v 2>&1 | head -n 2

    echo "== BANK"
    bank_cmd="${ACTION_ZERO_BANK:-$repo/scripts/lib/usage-preflight.sh}"
    bout="$(bounded bank "$bank_t" bash "$bank_cmd")"; brc=$?
    printf '%s\n' "$bout"
    if [ "$brc" -ne 0 ]; then
        case "$bout" in
            *"TIMEOUT bank after"*) ;;
            *) echo "unavailable" ;;
        esac
    fi

    echo "== PROCS"
    if [ -n "$prefix" ]; then
        pgrep -af "claude .*-n ${prefix}-" 2>/dev/null \
            | awk '{ for (i = 2; i < NF; i++) if ($i == "-n") { b = $2; sub(/.*\//, "", b); print $1, b, $(i + 1); next }
                     print $1, substr($0, length($1) + 2, 80) }' || echo "none"
    else echo "skipped (no --prefix)"; fi

    echo "== C29"
    doctor_cmd="${ACTION_ZERO_DOCTOR:-$repo/scripts/himmel-doctor.sh}"
    out="$(bounded doctor "$doctor_t" bash "$doctor_cmd" --only C29)"; drc=$?
    dwarn="$(printf '%s\n' "$out" | grep '^WARN no timeout')"
    [ -z "$dwarn" ] || printf '%s\n' "$dwarn"
    c29="$(printf '%s\n' "$out" | grep -E 'C29|^TIMEOUT doctor')"
    if [ -n "$c29" ]; then printf '%s\n' "$c29"
    elif [ "$drc" -ne 0 ]; then echo "unavailable (doctor exited $drc)"
    else echo "none"; fi

    echo "== LOAD"
    uptime 2>&1 || echo "unavailable"

    if [ "$render" -eq 1 ]; then
        echo "== LEGS"
        pre_state="$(env HANDOVER_DIR="$root" bash "$ql" status "$doc" 2>&1)"; pre_rc=$?
        if [ "$pre_rc" -ne 0 ] || [ "$pre_state" != free ]; then
            render_rc=1; echo "unavailable (this document's lock is not free: held by this or another session, legs: left unchanged)"
        elif [ -f "${doc%.md}.fleet.json" ]; then
            if bounded legs "$legs_t" env HANDOVER_DIR="$root" bash "$HERE/live-state.sh" "$doc"; then echo "legs: line rendered"; else render_rc=1; echo "unavailable"; fi
        else
            render_rc=1; echo "unavailable (no fleet manifest next to the doc)"
        fi
    fi

    echo "== DOC"
    if digest_out="$(bash "$HERE/live-state.sh" "$doc" --digest)"; then
        printf '%s\n' "$digest_out"
    else
        echo "DOC unavailable"
    fi
fi

echo "== LOCK (this document)"
state="$(env HANDOVER_DIR="$root" bash "$ql" status "$doc" 2>&1)"; src=$?
printf '%s\n' "$state"
if [ "$acquire" -eq 1 ]; then
    if [ "$src" -eq 0 ] && [ "$state" = free ]; then
        aout="$(env HANDOVER_DIR="$root" bash "$ql" acquire "$doc" 2>&1)"
        printf '%s\n' "$aout"
        # shellcheck disable=SC2016 # the backticks are literal in the token line
        tok="$(printf '%s\n' "$aout" | sed -n 's/^release-token: `\(.*\)`$/\1/p' | tail -n 1)"
        if [ -n "$tok" ] && grep -q '^   none yet — acquire your own' "$doc"; then
            rec="$(awk -v t="   $tok" '!d && /^   none yet — acquire your own/ { print t; d = 1; next } { print }' "$doc")" \
                && printf '%s\n' "$rec" > "$doc.tok" && mv "$doc.tok" "$doc" && echo "token recorded in the doc"
        elif [ -n "$tok" ]; then
            echo "token not recorded: the doc has no none-yet line, write it in step 8"
        fi
    else
        echo "NOT ACQUIRED — the lock is not free: find its holder, do not take it over"
    fi
fi
exit "$render_rc"
