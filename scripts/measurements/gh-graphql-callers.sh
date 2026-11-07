#!/usr/bin/env bash
# gh-graphql-callers.sh — which script spends the shared GitHub GraphQL budget.
# Read-only: it never changes gh for anyone else.
#
#   watch [--log F] [--seconds S] [--interval I]
#       Changes nothing: polls /proc for live gh processes of the whole fleet
#       for S seconds (default 3600) and charges each, once, to its nearest .sh
#       ancestor. A gh shorter-lived than I (default 0.2 s) is missed. The bucket
#       line printed at the end is the probe's own reading, shared with the fleet.
#
#   run [--log F] [--floor N] -- <cmd...>
#       Runs ONE command with a counting `gh` shim first on PATH for that child
#       tree only (nothing else sees it). Same log. Refuses (rc 2) before
#       running anything when the GraphQL bucket has fewer than N points left
#       (default 1500) or cannot be read.
#
#   report [--log F] [--hours H] [--top N]
#       Aggregates a log: calls, points and points per hour by caller, largest
#       first. H is the observation window in hours; without it the window is the
#       log's own first-to-last epoch span, or 1 h when that span is under a
#       minute. The first output line states the estimate and the window used.
#
# Log line: epoch <TAB> calling-script <TAB> points <TAB> first gh args. The
# calling script is the nearest .sh ancestor process, so tick.sh calling
# check-ci.sh is charged to check-ci.sh.
#
# Points are an ESTIMATE: 1 per GraphQL-bound gh call (the 10-07 watcher
# audit's costing). It under-counts a query with a 200-row files connection and
# any call `watch` polls too late to see, and it over-counts a `gh api graphql`
# rateLimit probe (0 points, charged 1) and any process named gh, such as a
# suite stub. REST-only shapes (api without graphql, pr diff, run, workflow) are
# not logged. Env: GH_CALLERS_LOG default log.
#
# ponytail: a per-call estimate and a polling sample, not the fleet's true
# bill; upgrade path = read the cost/remaining headers per call inside a shim
# the fleet launcher installs, once that is approved.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DEFAULT="${GH_CALLERS_LOG:-${TMPDIR:-/tmp}/gh-graphql-callers.log}"

usage() { sed -n '2,36p' "$0" >&2; exit 64; }

# gqlc_cost <gh args...> — GraphQL points one gh call spends (estimate: 1, or 0).
gqlc_cost() {
    local a a1="" a2="" graphql=0
    for a in "$@"; do
        [ "$a" = graphql ] && graphql=1
        case "$a" in -*) continue ;; esac
        if [ -z "$a1" ]; then a1="$a"; elif [ -z "$a2" ]; then a2="$a"; fi
    done
    case "$a1" in
        api) [ "$graphql" = 1 ] && { echo 1; return; } ;;
        pr) [ "$a2" = diff ] || { echo 1; return; } ;;
        issue|repo|project|label) echo 1; return ;;
    esac
    echo 0
}

# gqlc_caller <pid> — the nearest .sh ancestor of <pid> (gh-read.sh and this
# script are transparent wrappers), else (direct).
gqlc_caller() {
    local p="$1" n=0 words w found
    while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 20 ]; do
        words=$({ tr '\0' ' ' <"/proc/$p/cmdline"; } 2>/dev/null)
        found=""
        for w in $words; do
            case "$w" in
                *gh-read.sh|*gh-graphql-callers.sh) ;;
                *.sh) found="${w##*/}"; break ;;
            esac
        done
        if [ -n "$found" ]; then echo "$found"; return; fi
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        n=$((n + 1))
    done
    echo "(direct)"
}

cmd_report() {
    local log="$LOG_DEFAULT" hours="" top=5 basis="from --hours"
    while [ $# -gt 0 ]; do
        [ "$1" = -- ] || [ $# -ge 2 ] || usage  # an option with no value would never shift
        case "$1" in
            --log) log="${2:-}"; shift 2 ;;
            --hours) hours="${2:-}"; shift 2 ;;
            --top) top="${2:-}"; shift 2 ;;
            *) usage ;;
        esac
    done
    [ -r "$log" ] || { echo "gh-graphql-callers: cannot read log '$log'" >&2; exit 2; }
    case "$top" in ''|*[!0-9]*) usage ;; esac
    if [ -z "$hours" ]; then
        hours=$(awk -F'\t' 'NF >= 3 { e = $1 + 0; if (!n++ || e < lo) lo = e; if (e > hi) hi = e }
            END { s = hi - lo; if (s >= 60) printf "%.4f\n", s / 3600; else print 1 }' "$log")
        basis="from the log epochs, 1 h when the span is under a minute"
    fi
    awk -v h="$hours" 'BEGIN { exit !(h ~ /^[0-9]*\.?[0-9]+$/ && h + 0 > 0) }' || usage
    printf '# estimate: 1 point per GraphQL gh call; window %s h (%s)\n' "$hours" "$basis"
    printf 'rank\tcaller\tcalls\tpoints\tpoints/hour\n'
    awk -F'\t' -v hours="$hours" '
        NF >= 3 && $3 ~ /^[0-9]+$/ { calls[$2]++; pts[$2] += $3 }
        END { for (c in pts) printf "%s\t%d\t%d\t%.1f\n", c, calls[c], pts[c], pts[c] / hours }
    ' "$log" | sort -t "$(printf '\t')" -k3,3nr -k1,1 | head -n "$top" \
        | awk -F'\t' '{ printf "%d\t%s\t%s\t%s\t%s\n", NR, $1, $2, $3, $4 }'
}

write_shim() {
    {
        printf '#!/usr/bin/env bash\n# counting gh shim, installed by gh-graphql-callers.sh run (child tree only)\n'
        declare -f gqlc_cost gqlc_caller
        cat <<'SHIM'
real=""
IFS=:
for d in $PATH; do
    [ "$d" = "$GQLC_SHIM_DIR" ] && continue
    if [ -x "$d/gh" ]; then real="$d/gh"; break; fi
done
unset IFS
[ -n "$real" ] || { echo "gh-graphql-callers shim: no real gh on PATH" >&2; exit 127; }
cost=$(gqlc_cost "$@")
if [ "$cost" -gt 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$(gqlc_caller "$PPID")" "$cost" "$*" | cut -c1-200 >>"$GQLC_LOG"
fi
exec "$real" "$@"
SHIM
    } >"$1/gh"
    chmod +x "$1/gh"
}

# budget_gate <floor> — sets GHB_* ; exits 2 unless the bucket is readable and >= floor.
budget_gate() {
    # shellcheck source=scripts/lib/gh-graphql-budget.sh
    . "$HERE/../lib/gh-graphql-budget.sh"
    ghb_read || { echo "gh-graphql-callers: GraphQL budget unreadable; refusing to run" >&2; exit 2; }
    if [ "$GHB_REMAINING" -lt "$1" ]; then
        echo "gh-graphql-callers: GraphQL remaining $GHB_REMAINING is under $1; refusing to run" >&2
        exit 2
    fi
}

cmd_watch() {
    local log="$LOG_DEFAULT" seconds=3600 interval=0.2 floor=1500
    while [ $# -gt 0 ]; do
        [ "$1" = -- ] || [ $# -ge 2 ] || usage  # an option with no value would never shift
        case "$1" in
            --log) log="${2:-}"; shift 2 ;;
            --seconds) seconds="${2:-}"; shift 2 ;;
            --interval) interval="${2:-}"; shift 2 ;;
            *) usage ;;
        esac
    done
    case "$seconds" in ''|*[!0-9]*) usage ;; esac
    budget_gate "$floor"
    set -f  # cmdline words carry jq globs; never expand them
    local before="$GHB_REMAINING" reset0="$GHB_RESET" end=$((SECONDS + 10#$seconds))
    local seen=" " pid st key args w cost n=0 after="?" reset1=""
    { mkdir -p "$(dirname "$log")" && : >>"$log"; } || { echo "gh-graphql-callers: cannot write log '$log'; nothing was watched" >&2; exit 2; }
    while [ "$SECONDS" -lt "$end" ]; do
        for pid in $(pgrep -x gh 2>/dev/null); do
            st=$(cut -d' ' -f22 "/proc/$pid/stat" 2>/dev/null) || continue
            key="$pid.$st"
            case "$seen" in *" $key "*) continue ;; esac
            seen="$seen$key "
            # the args after the word named gh (a script stub shows its interpreter first)
            args=""
            for w in $({ tr '\0' ' ' <"/proc/$pid/cmdline"; } 2>/dev/null); do
                if [ -n "$args" ]; then args="$args $w"; elif [ "${w##*/}" = gh ]; then args="gh"; fi
            done
            args="${args#gh}"
            # shellcheck disable=SC2086
            cost=$(gqlc_cost $args)
            [ "$cost" -gt 0 ] || continue
            printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$(gqlc_caller "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')")" "$cost" "${args# }" | cut -c1-200 >>"$log"
            n=$((n + 1))
        done
        [ "${#seen}" -lt 200000 ] || seen=" "
        sleep "$interval"
    done
    ghb_read && { after="$GHB_REMAINING"; reset1="$GHB_RESET"; }
    echo "gh-graphql-callers: watched ${seconds}s, saw $n GraphQL calls (estimate, 1 point each); bucket remaining $before -> $after, reset $reset0 -> $reset1 (one window only if equal); log $log" >&2
}

cmd_run() {
    local log="$LOG_DEFAULT" floor=1500
    while [ $# -gt 0 ]; do
        [ "$1" = -- ] || [ $# -ge 2 ] || usage  # an option with no value would never shift
        case "$1" in
            --log) log="${2:-}"; shift 2 ;;
            --floor) floor="${2:-}"; shift 2 ;;
            --) shift; break ;;
            *) usage ;;
        esac
    done
    [ $# -gt 0 ] || usage
    case "$floor" in ''|*[!0-9]*) usage ;; esac
    budget_gate "$floor"
    local before="$GHB_REMAINING" shimdir rc lines_before lines_after after="?"
    shimdir=$(mktemp -d "${TMPDIR:-/tmp}/gqlc-shim.XXXXXX") || exit 2  # prim-ok: Linux-only measurement, one throwaway dir removed on exit
    # shellcheck disable=SC2064
    trap "rm -rf '$shimdir'" EXIT
    case "$log" in /*) ;; *) log="$PWD/$log" ;; esac  # the child may change directory
    write_shim "$shimdir" || { echo "gh-graphql-callers: cannot build the counting shim; nothing was run" >&2; exit 2; }
    { mkdir -p "$(dirname "$log")" && : >>"$log"; } || { echo "gh-graphql-callers: cannot write log '$log'; nothing was run" >&2; exit 2; }
    lines_before=$(wc -l <"$log" | tr -d ' ')
    GQLC_SHIM_DIR="$shimdir" GQLC_LOG="$log" PATH="$shimdir:$PATH" "$@"
    rc=$?
    lines_after=$(wc -l <"$log" | tr -d ' ')
    ghb_read && after="$GHB_REMAINING"
    echo "gh-graphql-callers: counted $((lines_after - lines_before)) GraphQL calls (estimate 1 point each); bucket remaining $before -> $after (shared with the fleet); log $log" >&2
    return "$rc"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
    report) cmd_report "$@" ;;
    run) cmd_run "$@" ;;
    watch) cmd_watch "$@" ;;
    *) usage ;;
esac
