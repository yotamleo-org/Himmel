#!/usr/bin/env bash
# scripts/lib/chief-owed.sh — what a worker's chief owes it, read from the worker
# doc's `## Results` bullets. One rule, used by chief-duty-sweep.sh and by
# chief-wait.sh's 30-minute re-nudge.
#
#   chief_owed_state <doc> [--gen]
#       prints at most `ready <id> <sha>[ <gen>]` and `ask <BLOCKED|FINDING>[ <gen>]`,
#       rc 0, or nothing and rc 1 when the doc cannot be read.
#       READY is read by parse_ready_line (go-gate.sh). A doc with no Results
#       heading is scanned whole. With --gen each line ends in the cksum of the
#       bullet that opened the item: a repeat READY of the same id and sha keeps it,
#       and a READY after a clear takes a new one.
#   chief_owed_go_root <repo>
#       prints the GO root (go_resolve_root), rc 1 when none resolves. Seam, only
#       under HIMMEL_TEST_FIXTURE=1: CHIEF_OWED_GO_ROOT (even set to empty).
#
# PLATFORM GUARD: bash 3.2-safe (no associative arrays, no ${v,,}).
case "${BASH_SOURCE[0]}" in */*) _co_d="${BASH_SOURCE[0]%/*}" ;; *) _co_d=. ;; esac
# shellcheck source=handover-path.sh
. "$_co_d/handover-path.sh" || return 2
# shellcheck source=go-gate.sh
. "$_co_d/go-gate.sh" || return 2

chief_owed_state() {
    local doc="$1" want_gen="${2:-}" body rec m line rest parsed id sha
    local ready_id="" ready_sha="" ready_line="" ask="" ask_line="" out
    body=$(sed -n '/^## Results/,$p' "$doc" 2>/dev/null) || return 1
    [ -n "$body" ] || body=$(sed -n 'p' "$doc" 2>/dev/null) || return 1
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        m="${rec%% *}"; line="${rec#* }"
        case "$m" in
            READY|LIVE)
                if [ "$m" = READY ]; then
                    rest="READY${line#*READY}"
                    ask=""; ask_line=""
                elif [[ $line =~ holding\ at\ READY ]]; then
                    if grep -qiE "((^|[^[:alnum:]_])(no longer|not|never|without|cannot)([^[:alnum:]_]|$)|n't)[^;.]{0,30}READY" <<<"$line"; then
                        ready_id=""; ready_sha=""; ready_line=""; continue
                    fi
                    rest="READY${line#*holding at READY}"
                else
                    continue
                fi
                if parsed="$(parse_ready_line "$rest")"; then
                    IFS=$'\t' read -r _ id sha <<EOF
$parsed
EOF
                    [ "$id $sha" = "$ready_id $ready_sha" ] || { ready_id="$id"; ready_sha="$sha"; ready_line="$line"; }
                elif [ "$m" = READY ]; then
                    ready_id=""; ready_sha=""; ready_line=""
                fi ;;
            BLOCKED|FINDING) ask="$m"; ask_line="$line"; ready_id=""; ready_sha=""; ready_line="" ;;
            HALTED|WRAPPED|MERGED) ask=""; ask_line=""; ready_id=""; ready_sha=""; ready_line="" ;;
            PARKED*) ready_id=""; ready_sha=""; ready_line="" ;;
            RESOLVED) ask=""; ask_line="" ;;
        esac
    done <<EOF
$(printf '%s\n' "$body" | sed -nE '/^- /p' | awk '
    match($0, /^- ([0-9]{1,2}:[0-9]{2}[ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|PARKED-[A-Z]+|RESUMED|MERGED)([^A-Za-z0-9_]|$)/) {
        m = substr($0, RSTART, RLENGTH); sub(/^- ([0-9]{1,2}:[0-9]{2}[ \t]+)?(\*\*)?/, "", m); sub(/[^A-Za-z0-9-].*$/, "", m)
        print m " " $0
    }')
EOF
    if [ -n "$ready_id" ]; then
        out="ready $ready_id $ready_sha"
        [ "$want_gen" != --gen ] || out="$out $(printf '%s\n' "$ready_line" | cksum | cut -d' ' -f1)"
        printf '%s\n' "$out"
    fi
    if [ -n "$ask" ]; then
        out="ask $ask"
        [ "$want_gen" != --gen ] || out="$out $(printf '%s\n' "$ask_line" | cksum | cut -d' ' -f1)"
        printf '%s\n' "$out"
    fi
    return 0
}

chief_owed_go_root() {
    local root=""
    if [ "${HIMMEL_TEST_FIXTURE:-}" = 1 ] && [ "${CHIEF_OWED_GO_ROOT+set}" = set ]; then
        root="$CHIEF_OWED_GO_ROOT"
    else
        root="$(go_resolve_root "$1" 2>/dev/null)" || root=""
    fi
    [ -n "$root" ] || return 1
    printf '%s\n' "$root"
}
