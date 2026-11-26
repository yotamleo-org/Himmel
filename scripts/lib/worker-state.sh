#!/usr/bin/env bash
# worker-state.sh — a worker's lifecycle state: one table, one reducer, one record, one CLI.
#
# The table is scripts/lib/worker-states.tsv. ws_reduce turns the facts about a worker (lock class,
# newest marker, hand-off, sweep text, and the tick's transcript and census reads) into one row of it.
# Source this file for the functions, or run it:
#
#   worker-state.sh --json [--stdin] [<doc>...]
#       one JSON object per doc: {doc, state, tick, reason, source, age, holds_lock, ended,
#       needs_chief, display, remedy}. --stdin reads lines of <doc><TAB><tick label or empty>.
#       exit 0; 2 usage; 3 the table (or jq) does not load.
#
#   ws_reduce doc_present lockless lock tail handoff halt_swept forked nolive_due idle_held census
#       pure: reads only the table. Sets WS_STATE WS_TICK WS_REASON WS_ENDED. rc 2 on an argument
#       outside its set (WS_STATE and WS_TICK then read UNKNOWN), rc 3 when the table does not load.
#   ws_lock_class <queue-lock status text>   FRESH STALE STALE-DEAD UNVERIFIED FREE CORRUPT UNKNOWN
#   ws_inputs_sig lock tail handoff halt_swept   the one signature of the inputs a record is checked against
#   ws_gather <doc> [<tick label>]            the ten ws_reduce inputs, tab-separated
#   ws_record_put <doc> <state> <reason> <sig> <0|1 lockless>, ws_record_prune
#       the per-doc record under <state dir>/worker-lifecycle/. Only the tick writes it.
#
# A record older than 360 s is not used: twice the waiter's default tick interval (CHIEF_WAIT_INTERVAL,
# 180 s). A record or a tick label may only refine the live cheap answer (FREE to NOLIVE, FORKED or
# NOLOCK; FRESH or STALE to IDLE-HELD; WRAPPED to CLOSABLE), never contradict the lock and the marker.
# A lockless doc (a NOLOCK label, or a record under the bound that says so) reads NOLOCK on the cheap state.
#
# Seams: WS_QUEUE_LOCK (the queue-lock script), WS_STATES_TSV (the table), WS_NOW (epoch seconds),
# TICKET_STATUS_STATE_DIR (through ts_state_dir). Sourcing sets no shell option and runs nothing.
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC2034  # WS_STATE, WS_TICK, WS_REASON and WS_ENDED are read by the sourcing caller

_WS_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worker-tail-status.sh
# shellcheck disable=SC1091
. "$_WS_LIB_DIR/worker-tail-status.sh"
# shellcheck source=scripts/lib/worker-successor.sh
# shellcheck disable=SC1091
. "$_WS_LIB_DIR/worker-successor.sh"
# shellcheck source=scripts/lib/ticket-status.sh
# shellcheck disable=SC1091
. "$_WS_LIB_DIR/ticket-status.sh"
# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$_WS_LIB_DIR/canon-path.sh"

_WS_RECORD_BOUND=360
_WS_REDUCER_STATES="FRESH STALE STALE-DEAD IDLE-HELD CLOSABLE WRAPPED FREE HALTED-SWEPT PARKED-USAGE NOLIVE FORKED NOLOCK UNVERIFIED CORRUPT UNKNOWN NOTFOUND"

_WS_T_PATH=""
_WS_T_ROWS=""

_ws_now() { printf '%s' "${WS_NOW:-$(date +%s)}"; }

_ws_sha1() {
    if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1; else shasum -a 1 | cut -d' ' -f1; fi
}

ws_load_table() {
    local IFS=$' \t\n'
    local path="${WS_STATES_TSV:-$_WS_LIB_DIR/worker-states.tsv}"
    local line decl="" hdr=0 n=0 rows="" s h nc t d r tabs names=$'\n' need
    if [ "$_WS_T_PATH" = "$path" ] && [ -n "$_WS_T_ROWS" ]; then return 0; fi
    [ -r "$path" ] || return 3
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '# rows: '*) decl="${line#'# rows: '}"; continue ;;
            '#'*|'') continue ;;
        esac
        if [ "$hdr" -eq 0 ]; then
            [ "$line" = "$(printf 'state\tholds_lock\tneeds_chief\ttick\tdisplay\tremedy')" ] || return 3
            hdr=1
            continue
        fi
        tabs="${line//[!$'\t']/}"
        [ "${#tabs}" -eq 5 ] || return 3
        case "$line" in *$'\t\t'*|$'\t'*|*$'\t') return 3 ;; esac
        IFS=$'\t' read -r s h nc t d r <<< "$line"
        case "$h" in yes|no|unknown) ;; *) return 3 ;; esac
        case "$nc" in yes|no) ;; *) return 3 ;; esac
        case "$names" in *$'\n'"$s"$'\n'*) return 3 ;; esac
        names="$names$s"$'\n'
        rows="$rows$line"$'\n'
        n=$((n + 1))
    done < "$path"
    case "$decl" in ''|*[!0-9]*) return 3 ;; esac
    [ "$n" -eq "$((10#$decl))" ] && [ "$n" -gt 0 ] || return 3
    for need in $_WS_REDUCER_STATES; do
        case "$names" in *$'\n'"$need"$'\n'*) ;; *) return 3 ;; esac
    done
    _WS_T_ROWS="$rows"
    _WS_T_PATH="$path"
    return 0
}

_ws_row() {
    local s h nc t d r
    ws_load_table || return 3
    while IFS=$'\t' read -r s h nc t d r; do
        if [ "$s" = "$1" ]; then
            _WSR_HOLDS="$h"; _WSR_NEEDS="$nc"; _WSR_TICK="$t"; _WSR_DISPLAY="$d"; _WSR_REMEDY="$r"
            return 0
        fi
    done <<< "$_WS_T_ROWS"
    return 1
}

ws_reduce() {
    WS_STATE=UNKNOWN; WS_TICK=UNKNOWN; WS_REASON=""; WS_ENDED=no
    [ "$#" -eq 10 ] || return 2
    local doc_present="$1" lockless="$2" lock="$3" tail="$4" handoff="$5" halt_swept="$6"
    local forked="$7" nolive_due="$8" idle_held="$9" census="${10}"
    local state reason eff_tail held=held
    case "$doc_present" in 0|1) ;; *) return 2 ;; esac
    case "$lockless" in 0|1) ;; *) return 2 ;; esac
    case "$handoff" in 0|1) ;; *) return 2 ;; esac
    case "$halt_swept" in 0|1) ;; *) return 2 ;; esac
    case "$forked" in 0|1|-) ;; *) return 2 ;; esac
    case "$nolive_due" in 0|1|-) ;; *) return 2 ;; esac
    case "$idle_held" in 0|1|-) ;; *) return 2 ;; esac
    case "$census" in hit|miss|-) ;; *) return 2 ;; esac
    case "$lock" in FRESH|STALE|STALE-DEAD|UNVERIFIED|FREE|CORRUPT|UNKNOWN) ;; *) return 2 ;; esac
    ws_load_table || return 3
    [ -n "$tail" ] || tail="?"
    eff_tail="$tail"
    if [ "$doc_present" = 0 ]; then
        state=NOTFOUND; reason="no such doc"
    elif [ "$lockless" = 1 ]; then
        state=NOLOCK; reason="lockless row"
    else
        state="$lock"; reason="lock $lock"
        if [ "$lock" = FREE ]; then
            if [ "$tail" = WRAPPED ]; then
                state=WRAPPED; reason="wrapped, lock released"
            elif [ "$tail" = BLOCKED ] && [ "$handoff" = 1 ]; then
                state=WRAPPED; eff_tail=WRAPPED; reason="hand-off names a successor"
            elif [ "$tail" = "?" ]; then
                if [ "$forked" = 1 ]; then
                    state=FORKED; reason="session continued in another"
                elif [ "$nolive_due" = 1 ]; then
                    state=NOLIVE; reason="no marker bullet since launch"
                fi
            else
                case "$tail" in
                    HALTED)
                        state=HALTED-SWEPT
                        if [ "$halt_swept" = 1 ]; then reason="lock freed by a sweep (swept)"; else reason="halted, lock free"; fi ;;
                    PARKED-USAGE|PARKED-BANK) state=PARKED-USAGE; reason="parked on usage" ;;
                esac
            fi
        fi
        case "$state" in
            FRESH|STALE)
                if [ "$tail" != WRAPPED ] && [ "$idle_held" = 1 ]; then state=IDLE-HELD; reason="idle with the lock held"; fi ;;
            WRAPPED)
                if [ "$census" = hit ]; then state=CLOSABLE; reason="wrapped, session still running"; fi ;;
        esac
    fi
    [ "$lock" = FREE ] && held=free
    if worker_terminal_tail "$eff_tail" "$held"; then WS_ENDED=yes; else WS_ENDED=no; fi
    _ws_row "$state" || return 3
    WS_STATE="$state"; WS_TICK="$_WSR_TICK"; WS_REASON="$reason"
    return 0
}

ws_lock_class() {
    case "${1-}" in
        *'status: FRESH'*) printf '%s\n' FRESH ;;
        *'status: STALE-DEAD'*) printf '%s\n' STALE-DEAD ;;
        *'status: STALE'*) printf '%s\n' STALE ;;
        *UNVERIFIED*) printf '%s\n' UNVERIFIED ;;
        free*) printf '%s\n' FREE ;;
        *CORRUPT*) printf '%s\n' CORRUPT ;;
        *) printf '%s\n' UNKNOWN ;;
    esac
}

ws_inputs_sig() {
    printf '%s|%s|%s|%s' "${1-}" "${2-}" "${3-}" "${4-}" | _ws_sha1
}

ws_halt_swept() {
    local b
    b="$(sed -nE '/^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?HALTED([^A-Za-z0-9_]|$)/p' "$1" 2>/dev/null | tail -n 1)" || b=""  # pipefail-ok: tail reads sed to EOF; swallow-ok: an unreadable doc has no sweep text
    case "$b" in *'was freed by'*) printf '1' ;; *) printf '0' ;; esac
}

_ws_realpath() {
    local dir
    dir="$(canon_path "$(dirname "$1")")" || return 1
    printf '%s/%s' "${dir%/}" "$(basename "$1")"
}

ws_record_dir() { printf '%s/worker-lifecycle' "$(ts_state_dir)"; }

ws_record_path() {
    local real
    real="$(_ws_realpath "$1")" || real="$1"
    printf '%s/%s.json' "$(ws_record_dir)" "$(printf '%s' "$real" | _ws_sha1)"
}

ws_record_put() {
    [ "$#" -eq 5 ] || return 2
    local doc="$1" ll real dir
    [ -f "$doc" ] || return 1
    case "$5" in 1) ll=true ;; 0) ll=false ;; *) return 2 ;; esac
    command -v jq >/dev/null 2>&1 || return 1
    real="$(_ws_realpath "$doc")" || return 1
    dir="$(ws_record_dir)"
    mkdir -p "$dir" || return 1
    jq -nc --arg doc "$real" --arg state "$2" --arg reason "$3" --arg sig "$4" --argjson seen "$(_ws_now)" --argjson ll "$ll" \
        '{doc: $doc, state: $state, reason: $reason, inputs_sig: $sig, seen: $seen, lockless: $ll}' \
        | atomic_write "$(ws_record_path "$doc")"
}

ws_record_prune() {
    local dir f seen now
    dir="$(ws_record_dir)"
    [ -d "$dir" ] || return 0
    now="$(_ws_now)"
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        seen="$(jq -r '.seen // empty | floor' "$f" 2>/dev/null)" || seen=""  # swallow-ok: an unparsable record is deleted below
        case "$seen" in
            ''|*[!0-9]*) rm -f -- "$f" ;;
            *) [ $((now - seen)) -lt "$_WS_RECORD_BOUND" ] || rm -f -- "$f" ;;
        esac
    done
    return 0
}

ws_record_read() {
    local f line seen
    f="$(ws_record_path "$1")"
    [ -f "$f" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    line="$(jq -r 'select((.state | type) == "string" and (.inputs_sig | type) == "string" and (.seen | type) == "number")
        | [.state, .inputs_sig, (.seen | floor | tostring), ((.lockless // false) | tostring), (.reason // "")] | @tsv' "$f" 2>/dev/null)" || return 1
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r WS_REC_STATE WS_REC_SIG seen WS_REC_LOCKLESS WS_REC_REASON <<< "$line"
    case "$seen" in ''|*[!0-9]*) return 1 ;; esac
    WS_REC_AGE=$(($(_ws_now) - seen))
    [ "$WS_REC_AGE" -lt "$_WS_RECORD_BOUND" ] || return 1
    return 0
}

ws_gather() {
    local doc="$1" label="${2-}" present=0 lockless=0 lock=UNKNOWN tail="?" handoff=0 swept=0 out
    if [ -f "$doc" ]; then
        present=1
        if [ "$label" = NOLOCK ]; then
            lockless=1
        elif ws_record_read "$doc" && [ "$WS_REC_LOCKLESS" = true ]; then
            lockless=1
        fi
        if [ "$lockless" = 1 ]; then
            lock=FREE
        else
            out="$(bash "${WS_QUEUE_LOCK:-$_WS_LIB_DIR/../handover/queue-lock.sh}" status "$doc" 2>&1)" || true  # swallow-ok: queue-lock status exits non-zero for a held lock; the text carries the class
            lock="$(ws_lock_class "$out")"
        fi
        tail="$(worker_tail_status "$doc")"
        [ -n "$tail" ] || tail="?"
        if worker_handoff_tail "$doc"; then handoff=1; fi
        if [ "$tail" = HALTED ]; then swept="$(ws_halt_swept "$doc")"; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\n' "$present" "$lockless" "$lock" "$tail" "$handoff" "$swept"
}

_ws_refines() {
    [ "$1" = "$2" ] && return 0
    case "$1:$2" in
        FREE:NOLIVE|FREE:FORKED|FREE:NOLOCK|FRESH:IDLE-HELD|STALE:IDLE-HELD|WRAPPED:CLOSABLE) return 0 ;;
    esac
    return 1
}

_ws_cli_one() {
    local doc="$1" label="${2-}" real g present lockless lock tail handoff swept forked nolive idle census
    local cheap cheap_reason ended sig state source age reason ls
    real="$(_ws_realpath "$doc")" || real="$doc"
    g="$(ws_gather "$doc" "$label")"
    IFS=$'\t' read -r present lockless lock tail handoff swept forked nolive idle census <<< "$g"
    ws_reduce "$present" "$lockless" "$lock" "$tail" "$handoff" "$swept" "$forked" "$nolive" "$idle" "$census" || return 3
    cheap="$WS_STATE"; cheap_reason="$WS_REASON"; ended="$WS_ENDED"
    sig="$(ws_inputs_sig "$lock" "$tail" "$handoff" "$swept")"
    state="$cheap"; source=live; age=0; reason="$cheap_reason"
    if ws_record_read "$doc" && [ "$WS_REC_SIG" = "$sig" ] && _ws_row "$WS_REC_STATE" && _ws_refines "$cheap" "$WS_REC_STATE"; then
        state="$WS_REC_STATE"; source=record; age="$WS_REC_AGE"; reason="$WS_REC_REASON"
    elif [ -n "$label" ]; then
        ls="$label"
        _ws_row "$ls" || ls=UNKNOWN
        if _ws_refines "$cheap" "$ls"; then state="$ls"; source=label; reason="tick label $label"; fi
    fi
    _ws_row "$state" || return 3
    jq -nc --arg doc "$real" --arg state "$state" --arg tick "$_WSR_TICK" --arg reason "$reason" --arg source "$source" \
        --argjson age "$age" --arg holds "$_WSR_HOLDS" --arg ended "$ended" --arg needs "$_WSR_NEEDS" \
        --arg display "$_WSR_DISPLAY" --arg remedy "$_WSR_REMEDY" \
        '{doc: $doc, state: $state, tick: $tick, reason: $reason, source: $source, age: $age, holds_lock: $holds,
          ended: $ended, needs_chief: $needs, display: $display, remedy: ($remedy | split("<doc>") | join($doc))}'
}

ws_main() {
    set -uo pipefail
    local json=0 use_stdin=0 docs="" a d l
    while [ "$#" -gt 0 ]; do
        a="$1"; shift
        case "$a" in
            --json) json=1 ;;
            --stdin) use_stdin=1 ;;
            -*) printf 'worker-state.sh: unknown flag %s\n' "$a" >&2; return 2 ;;
            *) docs="$docs$a"$'\n' ;;
        esac
    done
    if [ "$json" -ne 1 ] || { [ "$use_stdin" -eq 0 ] && [ -z "$docs" ]; }; then
        printf 'usage: worker-state.sh --json [--stdin] [<doc>...]\n' >&2
        return 2
    fi
    command -v jq >/dev/null 2>&1 || { printf 'worker-state.sh: jq is required\n' >&2; return 3; }
    ws_load_table || { printf 'worker-state.sh: the states table does not load\n' >&2; return 3; }
    if [ "$use_stdin" -eq 1 ]; then
        while IFS=$'\t' read -r d l || [ -n "$d" ]; do
            [ -n "$d" ] || continue
            _ws_cli_one "$d" "$l" || return 3
        done
    fi
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        _ws_cli_one "$d" "" || return 3
    done <<< "$docs"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ws_main "$@"
    exit $?
fi
