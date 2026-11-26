#!/usr/bin/env bash
# gh-core-per-token.sh — how many REST/core calls an hour each GitHub token spends.
# Read-only and free: `gh api rate_limit` is not charged against the limit.
#
#   sample [--log F]
#       Appends one row per token ("main" and "read") from rate_limit. A token
#       whose read fails writes no row and the exit is 1; the other token's row
#       is kept.
#
#   loop [--log F] [--interval S] [--samples N]
#       Runs sample every S seconds (default 300). N samples then stops
#       (default 0 = until killed).
#
#   report [--log F] [--from EPOCH] [--to EPOCH]
#       Prints, per token, the core calls an hour over the samples inside the
#       window. Calls are the growth of "used" between two consecutive samples of
#       the SAME reset; an interval that crosses a reset cannot be told apart from
#       the calls made before the reset, so it is left out of both calls and seconds.
#
# Log row: epoch <TAB> token <TAB> used <TAB> limit <TAB> reset.
# "main" is plain gh (the station's main token); "read" goes through
# scripts/lib/gh-read.sh, the router that picks the read-only token.
#
# Env: GHCT_LOG default log; GHCT_MAIN_CMD / GHCT_READ_CMD a single command word
# that prints the rate_limit JSON (test seams); GHCT_SLEEP_CMD (default sleep);
# GHCT_NOW a fixed epoch for the row (test seam).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DEFAULT="${GHCT_LOG:-${TMPDIR:-/tmp}/gh-core-per-token.log}"

usage() { sed -n '2,23p' "$0" >&2; exit 64; }

_rate_limit() {
    case "$1" in
        main) if [ -n "${GHCT_MAIN_CMD:-}" ]; then "$GHCT_MAIN_CMD"; else gh api rate_limit; fi ;;
        read) if [ -n "${GHCT_READ_CMD:-}" ]; then "$GHCT_READ_CMD"; else GH_READ_QUIET=1 bash "$HERE/../lib/gh-read.sh" api rate_limit; fi ;;
    esac
}

do_sample() {
    local log="$1" tok body row now rc=0
    now="${GHCT_NOW:-$(date +%s)}"
    for tok in main read; do
        if ! body=$(_rate_limit "$tok" 2>/dev/null); then
            echo "gh-core-per-token: cannot read rate_limit for the $tok token" >&2
            rc=1; continue
        fi
        row=$(printf '%s\n' "$body" | jq -r '.resources.core | [.used, .limit, .reset] | map(tostring) | join("\t")' 2>/dev/null)
        case "$row" in
            *[!0-9[:space:]]*|'') echo "gh-core-per-token: unreadable rate_limit body for the $tok token" >&2; rc=1; continue ;;
        esac
        printf '%s\t%s\t%s\n' "$now" "$tok" "$row" >> "$log" 2>/dev/null || { echo "gh-core-per-token: cannot write the $tok row to $log" >&2; rc=1; }
    done
    return "$rc"
}

do_loop() {
    local log="$1" interval="$2" samples="$3" n=0
    while :; do
        do_sample "$log" || true
        n=$((n + 1))
        [ "$samples" -eq 0 ] || [ "$n" -lt "$samples" ] || break
        "${GHCT_SLEEP_CMD:-sleep}" "$interval"
    done
}

do_report() {
    local log="$1" from="$2" to="$3"
    [ -f "$log" ] || { echo "gh-core-per-token: no log at $log" >&2; return 2; }
    awk -F'\t' -v from="$from" -v to="$to" '
        BEGIN { OFS = "\t"; print "token", "samples", "seconds", "calls", "calls/hour" }
        $1 + 0 >= from && $1 + 0 <= to {
            t = $2
            if (!(t in seen)) { seen[t] = 1; order[++n] = t }
            samples[t]++
            if ((t in last_epoch) && last_reset[t] == $5) {
                secs[t] += $1 - last_epoch[t]
                calls[t] += $3 - last_used[t]
            }
            last_epoch[t] = $1; last_used[t] = $3; last_reset[t] = $5
        }
        END {
            for (i = 1; i <= n; i++) {
                t = order[i]
                rate = (secs[t] > 0) ? calls[t] * 3600 / secs[t] : 0
                printf "%s\t%d\t%d\t%d\t%.1f\n", t, samples[t], secs[t], calls[t], rate
            }
        }' "$log"
}

cmd="${1:-}"; [ -z "$cmd" ] || shift
log="$LOG_DEFAULT"; interval=300; samples=0; from=0; to=99999999999
while [ $# -gt 0 ]; do
    case "$1" in
        --log) [ $# -ge 2 ] || usage; log="$2"; shift 2 ;;
        --interval) [ $# -ge 2 ] || usage; interval="$2"; shift 2 ;;
        --samples) [ $# -ge 2 ] || usage; samples="$2"; shift 2 ;;
        --from) [ $# -ge 2 ] || usage; from="$2"; shift 2 ;;
        --to) [ $# -ge 2 ] || usage; to="$2"; shift 2 ;;
        *) usage ;;
    esac
done
for v in "$interval" "$samples" "$from" "$to"; do
    case "$v" in ''|*[!0-9]*) usage ;; esac
done
[ "$interval" -gt 0 ] || usage

case "$cmd" in
    sample) do_sample "$log" ;;
    loop) do_loop "$log" "$interval" "$samples" ;;
    report) do_report "$log" "$from" "$to" ;;
    *) usage ;;
esac
