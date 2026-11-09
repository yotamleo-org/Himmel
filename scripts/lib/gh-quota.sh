#!/usr/bin/env bash
# gh-quota.sh — one quota gate for every GitHub caller. Sourced, never executed.
# bash 3.2-safe: no mapfile, readarray, associative arrays, flock, or GNU-only date.
#
# WHY: the fleet spends one hourly GraphQL budget per token. When it ran out,
# gates named a false cause ("a finding has no valid disposition", "0 free
# tickets") and scans spent main's last points. This file reads the quota once
# per tick, lets scans pause under a floor, and words every refusal the same way.
#
# Three classes of caller:
#   scan   ghq_scan_gate before spending; paused = nothing spent, no fallback to main
#   gate   never pauses on a number; reads quota.tsv only to word a refusal it got
#   write  never pauses
#
#   ghq_is_rate_limited <stderr text>   rc 0 = a rate limit. Give it STDERR only:
#                                       stdout is PR bodies, which can carry the phrase
#   ghq_bucket_of <gh args...>          prints graphql or core
#   ghq_refresh                         probes each token's GraphQL and core buckets
#                                       and rewrites quota.tsv; a no-op under 170 s old.
#                                       Stops at the first timed-out probe (the rest are
#                                       marked timed-out) and after 20 s in all
#   ghq_read <token> <bucket>           no network; sets GHQ_REMAINING GHQ_LIMIT GHQ_RESET
#                                       GHQ_OBSERVED GHQ_STATE; rc 1 = no such row
#   ghq_scan_gate <token> <bucket> <caller>
#                                       rc 0 proceed; rc 75 paused, the line printed on stdout
#   ghq_line <token> <bucket> <caller> rate-limit [<refused-at epoch>]
#   ghq_line <token> <bucket> <caller> stall [<seconds>]
#                                       the one line a caller prints. A gate's line names
#                                       remaining and reset only from a row observed at or
#                                       after the refusal, and never a floor
#   ghq_mark_blocked <key> <ref> <caller> <bucket> <reason>
#                                       blocked/<key>.<ref> for the waiter; keeps first_epoch,
#                                       unions buckets and routes, stores / as %2F, and
#                                       never fails the caller
#   ghq_routes <caller>                 the tokens a caller's reads ride: read,main or main
#
# Numbers, one job each:
#   GH_BUDGET_FLOOR      200   a gate's wait (gh-graphql-budget.sh), and quota return
#   CHECK_CI_API_FLOOR   300   check-ci's rotation between the APIs
#   GHQ_SCAN_FLOOR       500   scans pause under it (10 % of a bucket)
#   1500                       the measure's refusal (gh-graphql-callers.sh run)
#
# Env: HIMMEL_QUOTA_DIR (default ~/.himmel/state/quota), GHQ_SCAN_FLOOR (500),
# GHQ_PROBE_TIMEOUT (10), GHQ_GH_CMD (gh), GHQ_REPO (owner/name for a marker;
# default from the origin remote).
#
# quota.tsv rows, tab-separated: token bucket remaining limit reset observed state
# (state: ok, refused, timed-out, unreadable; - for an unknown field). Probes
# never go through the router (gh-read.sh), which would fall back to main and
# report main's number under the read token's name. Never `gh api rate_limit`:
# it reports the REST core bucket, not GraphQL.
#
# ponytail: two writers can race a refresh; the loser costs one extra probe and the mv keeps the file whole. Upgrade = a lock dir.

_GHQ_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ghb_read >/dev/null 2>&1; then
    # shellcheck source=scripts/lib/gh-graphql-budget.sh
    . "$_GHQ_HERE/gh-graphql-budget.sh"
fi
# shellcheck source=scripts/lib/prim.sh
declare -F atomic_write >/dev/null 2>&1 || . "$_GHQ_HERE/prim.sh"

# shellcheck disable=SC2034  # GHQ_* are the caller-facing results of ghq_read
GHQ_REMAINING=""; GHQ_LIMIT=""; GHQ_RESET=""; GHQ_OBSERVED=""; GHQ_STATE=""

_ghq_dir() { printf '%s' "${HIMMEL_QUOTA_DIR:-$HOME/.himmel/state/quota}"; }

ghq_is_rate_limited() {
    printf '%s' "${1:-}" | grep -i -E 'rate limit|rate_limit|abuse detection|secondary rate' >/dev/null 2>&1
}

# The same shapes gh-graphql-callers.sh charges: api graphql, pr (but diff),
# issue, repo, project and label spend GraphQL; the rest spend core.
ghq_bucket_of() {
    local a a1="" a2="" graphql=0
    for a in "$@"; do
        [ "$a" = graphql ] && graphql=1
        case "$a" in -*) continue ;; esac
        if [ -z "$a1" ]; then a1="$a"; elif [ -z "$a2" ]; then a2="$a"; fi
    done
    case "$a1" in
        api) [ "$graphql" = 1 ] && { echo graphql; return 0; } ;;
        pr) [ "$a2" = diff ] || { echo graphql; return 0; } ;;
        issue|repo|project|label) echo graphql; return 0 ;;
    esac
    echo core
}

ghq_routes() {
    case "${1##*/}" in
        ready-check|ready-check.sh|check-ci|check-ci.sh|go|go.sh|tick|tick.sh|ready-go|ready-go.sh|shepherd|shepherd.sh) echo read,main ;;
        *) echo main ;;
    esac
}

# _ghq_observed <file> — the oldest observed epoch in quota.tsv; empty when absent or corrupt.
_ghq_observed() {
    [ -s "$1" ] || return 0
    awk -F'\t' '
        NF != 7 || $6 !~ /^[0-9]+$/ { bad = 1; exit }
        { if (!n++ || $6 < lo) lo = $6 }
        END { if (!bad && n) print lo }
    ' "$1" 2>/dev/null
}

_ghq_row() { # <token> <bucket> — one row from the GHB_* the last probe set
    local st="${GHB_STATE:-unreadable}"
    case "$st" in ok|refused|timed-out) ;; *) st=unreadable ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${GHB_REMAINING:--}" "${GHB_LIMIT:--}" \
        "${GHB_RESET:--}" "$(date +%s)" "$st"
}

ghq_refresh() {
    local dir f obs now start tok bucket stop=0 rows=""
    dir=$(_ghq_dir)
    f="$dir/quota.tsv"
    now=$(date +%s)
    obs=$(_ghq_observed "$f")
    if [ -n "$obs" ] && [ $((now - obs)) -ge 0 ] && [ $((now - obs)) -lt 170 ]; then return 0; fi
    start=$SECONDS
    for tok in main read; do
        # a station with no read token keeps main's two rows only
        if [ "$tok" = read ] && [ -z "$(_ghb_read_token)" ]; then break; fi
        for bucket in graphql core; do
            if [ "$stop" -eq 1 ] || [ $((SECONDS - start)) -ge 20 ]; then
                GHB_REMAINING=""; GHB_LIMIT=""; GHB_RESET=""; GHB_STATE=timed-out
            elif [ "$bucket" = graphql ]; then
                ghb_read "$tok"
            else
                _ghb_probe "$tok" api -i user
            fi
            [ "$GHB_STATE" = timed-out ] && stop=1
            rows="$rows$(_ghq_row "$tok" "$bucket")
"
        done
    done
    { mkdir -p "$dir" && printf '%s' "$rows" | atomic_write "$f"; } 2>/dev/null
    return 0
}

ghq_read() {
    local line row_tok row_bucket
    GHQ_REMAINING=""; GHQ_LIMIT=""; GHQ_RESET=""; GHQ_OBSERVED=""; GHQ_STATE=""
    line=$(awk -F'\t' -v t="${1:-}" -v b="${2:-}" 'NF == 7 && $1 == t && $2 == b { print; exit }' "$(_ghq_dir)/quota.tsv" 2>/dev/null)
    [ -n "$line" ] || return 1
    # every field is filled (- for unknown), so tab-as-whitespace never merges two
    # shellcheck disable=SC2034
    IFS="$(printf '\t')" read -r row_tok row_bucket GHQ_REMAINING GHQ_LIMIT GHQ_RESET GHQ_OBSERVED GHQ_STATE <<EOF
$line
EOF
    case "$GHQ_OBSERVED" in ''|*[!0-9]*) GHQ_STATE=""; return 1 ;; esac
    case "$GHQ_STATE" in ok|refused|timed-out|unreadable) ;; *) GHQ_STATE=""; return 1 ;; esac
    case "$GHQ_REMAINING" in ''|-|*[!0-9]*) GHQ_REMAINING="" ;; esac
    case "$GHQ_LIMIT" in ''|-|*[!0-9]*) GHQ_LIMIT="" ;; esac
    case "$GHQ_RESET" in ''|-|*[!0-9]*) GHQ_RESET="" ;; esac
    return 0
}

# _ghq_reset_words <epoch or empty> — "HH:MM:SSZ (in Ns)", or "unknown" when the
# reset is absent, past or absurd: quota has come back well after its printed reset.
_ghq_reset_words() {
    local r="${1:-}" now when
    now=$(date +%s)
    if [ -z "$r" ] || ! ghb_reset_sane "$r" || [ "$r" -le "$now" ]; then
        printf 'unknown'
        return 0
    fi
    when=$(date -u -d "@$r" +%H:%M:%SZ 2>/dev/null || date -u -r "$r" +%H:%M:%SZ 2>/dev/null) || when=""
    if [ -n "$when" ]; then printf '%s (in %ss)' "$when" "$((r - now))"; else printf 'unknown'; fi
}

ghq_line() {
    local tok="${1:-}" bucket="${2:-}" caller="${3:-}" reason="${4:-}" extra="${5:-}" s detail=""
    caller="${caller##*/}"
    if [ "$reason" = stall ]; then
        s="$extra"
        case "$s" in ''|*[!0-9]*) s="${GH_READ_TIMEOUT:-120}" ;; esac
        printf 'GH-STALL github read timed out after %ss token=%s caller=%s nothing-was-judged\n' "$s" "$tok" "$caller"
        return 0
    fi
    case "$extra" in ''|*[!0-9]*) extra=$(date +%s) ;; esac
    if ghq_read "$tok" "$bucket" && [ "$GHQ_OBSERVED" -ge "$extra" ]; then
        [ -z "$GHQ_REMAINING" ] || detail=" remaining=$GHQ_REMAINING"
        detail="$detail reset=$(_ghq_reset_words "$GHQ_RESET")"
    fi
    printf 'QUOTA-PAUSE github %s token=%s%s caller=%s nothing-was-judged\n' "$bucket" "$tok" "$detail" "$caller"
}

ghq_scan_gate() {
    local tok="${1:-}" bucket="${2:-}" caller="${3:-}" floor="${GHQ_SCAN_FLOOR:-500}"
    case "$floor" in ''|*[!0-9]*) floor=500 ;; esac
    caller="${caller##*/}"
    ghq_refresh
    # no row (no read token, an unwritable dir): nothing says stop
    ghq_read "$tok" "$bucket" || return 0
    case "$GHQ_STATE" in
        timed-out)
            ghq_line "$tok" "$bucket" "$caller" stall "${GHQ_PROBE_TIMEOUT:-10}"
            return 75 ;;
        unreadable) return 0 ;;
    esac
    if [ -z "$GHQ_REMAINING" ] || [ "$GHQ_REMAINING" -lt "$floor" ]; then
        printf 'QUOTA-PAUSE github %s token=%s remaining=%s floor=%s reset=%s caller=%s nothing-was-judged\n' \
            "$bucket" "$tok" "${GHQ_REMAINING:-unknown}" "$floor" "$(_ghq_reset_words "$GHQ_RESET")" "$caller"
        return 75
    fi
    return 0
}

_ghq_union() { # <comma list> <comma list> — sorted, no repeats
    printf '%s,%s' "${1:-}" "${2:-}" | tr ',' '\n' | grep . | sort -u | paste -sd, -
}

_ghq_field() { # <file> <name>
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

ghq_mark_blocked() {
    (
        key="${1:-}" ref="${2:-}" caller="${3:-}" bucket="${4:-}" reason="${5:-}"
        case "$reason" in rate-limit|stall) ;; *) exit 0 ;; esac
        case "$bucket" in graphql|core) ;; *) exit 0 ;; esac
        [ -n "$key" ] || exit 0
        caller="${caller##*/}"
        dir="$(_ghq_dir)/blocked"
        mkdir -p "$dir" || exit 0
        key=$(printf '%s' "$key" | sed 's#/#%2F#g')
        ref=$(printf '%s' "${ref:-unknown}" | sed 's#/#%2F#g')
        f="$dir/$key.$ref"
        now=$(date +%s)
        first="$now" buckets="$bucket" routes="$(_ghq_union "" "$(ghq_routes "$caller")")"
        if [ -f "$f" ]; then
            old=$(_ghq_field "$f" first_epoch)
            case "$old" in ''|*[!0-9]*) ;; *) first="$old" ;; esac
            buckets=$(_ghq_union "$(_ghq_field "$f" buckets)" "$buckets")
            routes=$(_ghq_union "$(_ghq_field "$f" routes)" "$routes")
            [ "$(_ghq_field "$f" reason)" = rate-limit ] && reason=rate-limit
        fi
        repo="${GHQ_REPO:-}"
        if [ -z "$repo" ]; then
            repo=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
        fi
        # a new refusal means quota is not back: no back_epoch is carried over
        printf 'repo=%s\ncaller=%s\nbuckets=%s\nroutes=%s\nreason=%s\nfirst_epoch=%s\n' \
            "$repo" "$caller" "$buckets" "$routes" "$reason" "$first" | atomic_write "$f"
    ) >/dev/null 2>&1
    return 0
}
