#!/usr/bin/env bash
# gh-graphql-budget.sh — shared GitHub GraphQL budget preflight.
#
# Sourced, never executed. bash 3.2-safe.
#
# WHY: the GraphQL budget (5000 points/hour, shared by every worker on the box)
# ran out fleet-wide twice in three hours because ~7 workers each held a
# `gh pr checks --watch` (~30 calls/min each). `gh api rate_limit` MISREPORTS
# it (REST core bucket) — the truth is the X-Ratelimit-* headers of a real
# `gh api -i graphql` call, which is what this reads. The probe query is
# `{rateLimit{remaining}}`: it answers `cost: 1`, so count it as 1 point.
#
#   ghb_read [main|read]
#     One bounded probe (GHQ_PROBE_TIMEOUT, default 10 s, `timeout
#     --foreground`). `main` and `read` name the token and never go through
#     the router, so a refused read token is never reported under main's
#     number; with no argument the probe rides gh-read.sh when the caller has
#     sourced it, run by script path so the bound holds. Sets GHB_REMAINING,
#     GHB_RESET (epoch; a Retry-After wins), GHB_LIMIT and GHB_STATE: ok,
#     refused, timed-out, unreadable, or none (no read token).
#
#   ghb_reset_sane <epoch>   rc 1 when not a number or more than 3700 s away:
#     no GitHub reset is that far, so the caller treats it as absent.
#
#   ghb_wait_for_budget <max_wait_s> [sleep_cmd]
#     Reads the headers ONCE. Healthy (remaining >= floor) -> return 0 at
#     once. Exhausted -> sleep until X-Ratelimit-Reset (+ a small skew and a
#     per-process jitter, both through <sleep_cmd>, so hermetic suites inject
#     `:` and every worker does not wake in the same second) and return 0 with
#     GHB_WAITED=1. If the reset is further away than <max_wait_s> (0 =
#     unbounded) -> print why and return 1 without sleeping. Callers map rc 1
#     onto their own "cannot evaluate" code; no exit code changes meaning.
#
#   Call it ONCE at start and after a rate-limit error — never per poll round:
#   the preflight is itself a request.
#
# Env (all optional):
#   GH_BUDGET_FLOOR        remaining below this counts as exhausted (default 200)
#   GH_BUDGET_JITTER_MAX   max wake-up jitter seconds (default 15; 0 = none)
#   GH_BUDGET_PREFLIGHT=0  skip the call entirely (test harnesses that count gh calls)
#
# ponytail: an unreadable/absent header set means "proceed" — this preflight is
# advisory and fails OPEN. Nothing here is a gate: the caller's own gh calls
# still fail closed if the budget really is gone.

# shellcheck disable=SC2034  # GHB_* are the caller-facing results of the sourced helper
GHB_REMAINING=""
GHB_RESET=""
GHB_LIMIT=""
GHB_STATE=""
GHB_WAITED=0
_GHB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/timeout-bin.sh
. "$_GHB_HERE/timeout-bin.sh" 2>/dev/null

# _ghb_bounded <seconds> <token or empty> <gh args...> — one gh call under the
# probe bound. --foreground keeps it in the caller's process group, so a
# caller's own outer kill reaches it.
# ponytail: no timeout binary (a Mac without coreutils) runs it unbounded; upgrade = a bash watchdog
_ghb_bounded() {
    local t="$1" tok="$2"
    shift 2
    if [ -n "$tok" ]; then
        GH_TOKEN="$tok" ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" --foreground "$t"} "${GHQ_GH_CMD:-gh}" "$@"
    else
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" --foreground "$t"} "${GHQ_GH_CMD:-gh}" "$@"
    fi
}

# _ghb_read_token — the read token on stdout, loaded in a subshell so that
# sourcing the router here never changes the caller's own routing.
_ghb_read_token() {
    if declare -F _ghr_load >/dev/null 2>&1; then
        _ghr_load
        printf '%s' "$_GHR_TOK"
        return 0
    fi
    (
        # shellcheck source=scripts/lib/gh-read.sh
        . "$_GHB_HERE/gh-read.sh" 2>/dev/null || exit 0
        _ghr_load
        printf '%s' "$_GHR_TOK"
    )
}

# _ghb_probe <main|read|''> <gh api -i args...> — one header read; sets GHB_*.
# rc 0 = remaining parsed (GHB_STATE ok or refused); rc 1 otherwise.
# An exhausted budget makes gh exit non-zero yet still print the headers, so
# the headers decide, and the exit status only marks a timeout.
_ghb_probe() {
    local who="$1" out rc t tok="" now ra
    shift
    GHB_REMAINING=""; GHB_RESET=""; GHB_LIMIT=""; GHB_STATE=unreadable
    t="${GHQ_PROBE_TIMEOUT:-10}"
    case "$t" in ''|*[!0-9]*) t=10 ;; esac
    case "$who" in
        read)
            tok=$(_ghb_read_token)
            if [ -z "$tok" ]; then GHB_STATE=none; return 1; fi
            out=$(_ghb_bounded "$t" "$tok" "$@" 2>&1); rc=$? ;;
        main)
            out=$(_ghb_bounded "$t" "" "$@" 2>&1); rc=$? ;;
        *)
            # the token the reads ride: through the router when the caller has
            # sourced it, by script path so the bound holds; its one-line warning
            # would land in the parsed text, hence QUIET
            if declare -F gh_read >/dev/null 2>&1; then
                out=$(GH_READ_QUIET=1 GH_READ_TIMEOUT="$t" bash "$_GHB_HERE/gh-read.sh" "$@" 2>&1); rc=$?
            else
                out=$(_ghb_bounded "$t" "" "$@" 2>&1); rc=$?
            fi ;;
    esac
    out=$(printf '%s\n' "$out" | tr -d '\r')
    GHB_REMAINING=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="x-ratelimit-remaining" {print $2; exit}')
    GHB_RESET=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="x-ratelimit-reset" {print $2; exit}')
    GHB_LIMIT=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="x-ratelimit-limit" {print $2; exit}')
    ra=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1)=="retry-after" {print $2; exit}')
    case "$GHB_LIMIT" in *[!0-9]*) GHB_LIMIT="" ;; esac
    case "$GHB_REMAINING" in
        ''|*[!0-9]*)
            GHB_REMAINING=""; GHB_RESET=""; GHB_LIMIT=""
            case "$rc" in 124|137) GHB_STATE=timed-out ;; esac
            return 1 ;;
    esac
    case "$GHB_RESET" in *[!0-9]*) GHB_RESET="" ;; esac
    case "$ra" in
        ''|*[!0-9]*) ;;
        *) now=$(date +%s); GHB_RESET=$((now + ra)) ;;
    esac
    GHB_STATE=ok
    if [ "$GHB_REMAINING" -eq 0 ] || { [ "$rc" -ne 0 ] && [ -n "$ra" ]; }; then GHB_STATE=refused; fi
    return 0
}

# ghb_read [main|read] — ONE real `gh api -i graphql` call (see the header).
ghb_read() {
    _ghb_probe "${1:-}" api -i graphql -f query='{rateLimit{remaining}}'
}

ghb_reset_sane() {
    local now
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s)
    [ $(($1 - now)) -le 3700 ]
}

# ghb_is_rate_limited <stderr text> — does a gh error read as budget exhaustion?
# The rule lives in gh-quota.sh (ghq_is_rate_limited); sourced on first use.
ghb_is_rate_limited() {
    if ! declare -F ghq_is_rate_limited >/dev/null 2>&1; then
        # shellcheck source=scripts/lib/gh-quota.sh
        . "$_GHB_HERE/gh-quota.sh" || return 1
    fi
    ghq_is_rate_limited "${1:-}"
}

ghb_wait_for_budget() {
    local max_wait="${1:-0}" sleep_cmd="${2:-sleep}"
    local floor="${GH_BUDGET_FLOOR:-200}" jmax="${GH_BUDGET_JITTER_MAX:-15}"
    local now wait_s jitter human
    GHB_WAITED=0
    [ "${GH_BUDGET_PREFLIGHT:-1}" = 0 ] && return 0
    case "$max_wait" in ''|*[!0-9]*) max_wait=0 ;; esac
    case "$floor" in ''|*[!0-9]*) floor=200 ;; esac
    case "$jmax" in ''|*[!0-9]*) jmax=15 ;; esac

    ghb_read || return 0
    [ "$GHB_REMAINING" -ge "$floor" ] && return 0

    now=$(date +%s)
    if [ -n "$GHB_RESET" ] && ghb_reset_sane "$GHB_RESET"; then
        wait_s=$((GHB_RESET - now + 2))       # +2 s clock-skew margin
    else
        GHB_RESET=""
        wait_s=60                             # exhausted, reset header missing or absurd
    fi
    [ "$wait_s" -lt 2 ] && wait_s=2

    human=$(date -d "@${GHB_RESET:-$((now + wait_s))}" +%H:%M:%S 2>/dev/null \
        || date -r "${GHB_RESET:-$((now + wait_s))}" +%H:%M:%S 2>/dev/null \
        || echo "epoch ${GHB_RESET:-?}")
    if [ "$max_wait" -gt 0 ] && [ "$wait_s" -gt "$max_wait" ]; then
        echo "gh-budget: GitHub GraphQL budget exhausted (remaining=$GHB_REMAINING, floor=$floor), resets at $human (in ${wait_s}s) — longer than the ${max_wait}s bound; not waiting" >&2
        return 1
    fi

    jitter=0
    [ "$jmax" -gt 0 ] && jitter=$((RANDOM % (jmax + 1)))
    # never let the jitter push the total past the caller's bound
    if [ "$max_wait" -gt 0 ] && [ $((wait_s + jitter)) -gt "$max_wait" ]; then
        jitter=$((max_wait - wait_s))
    fi

    echo "gh-budget: GitHub GraphQL budget exhausted (remaining=$GHB_REMAINING, floor=$floor); sleeping ${wait_s}s + ${jitter}s jitter until the reset at $human" >&2
    "$sleep_cmd" "$wait_s"
    [ "$jitter" -gt 0 ] && "$sleep_cmd" "$jitter"
    GHB_WAITED=1
    return 0
}
