#!/usr/bin/env bash
# gh-read.sh — READ-ONLY gh calls on the read-only token.
#
# WHY: every worker and the chief share one station token (5000 REST/hour).
# When it hit 0, go.sh and ready-check could not read the PR state and three
# trust GOs waited ~6 minutes. Reads now ride a second, read-only token
# (himmel_github_token_vm2, account B, public repos); every write keeps the main
# token.
#
#   sourced:   defines gh_read <gh args...> and gh_read_rates
#   executed:  gh-read.sh <gh args...>   (for `timeout`, `exec` and TICK_GH_CMD)
#
# The read tokens are a pool, himmel_github_token_vm2 then himmel_github_token_vm (quota.tsv
# names them read and read2). On a REST-core read a token whose quota.tsv core row is under
# the floor with its reset ahead is skipped, a refused one passes the read to the next, and
# main is the last resort: not while main's own core row is under the floor, when the read
# exits 75 with a QUOTA-PAUSE line and calls nothing (GraphQL reads are not gated).
#
# The token is chosen PER CALL and handed to that one gh child as GH_TOKEN. It is
# never exported into the caller, never in argv, never printed. The router is an
# ALLOWLIST of read shapes (_ghr_is_read): anything else, a merge, comment,
# review, create, a non-GET api call, a GraphQL mutation, runs on the main token
# exactly as before. A missing, malformed or refused (rate limit, bad credentials,
# 401/403/404) read token falls back to the main token with ONE warning line per
# process; the fallback is never an error.
#
# Env (optional): GH_READ_ENV_ROOT — directory whose .env holds the token (default:
# the primary checkout's .env, found from this file). When set, that .env is the
# only source: the environment, a credentials dir and the keyring are skipped.
#   GH_READ_TIMEOUT           seconds one read may take (default 120, 0 = none), as
#                             `timeout --foreground` so a caller's outer kill reaches it.
#                             A timed-out read exits 124 and is not retried
#   GH_READ_REFUSED_FILE      a read that finally fails on a rate limit or a timeout
#                             appends "<main|read> <graphql|core> rate-limit|stall"
#   GH_READ_USED_FILE         an EXISTING file: every read attempt that ran appends
#                             "<main|read> <graphql|core>" (a retry on main is a second
#                             row, appended by perl, ending " <why> <what>": why is rl,
#                             auth, notfound or http<code>, what the masked gh argv
#                             without filter, field or query values, max 120 chars); an
#                             absent file is never created
#   GH_READ_NO_MAIN_FALLBACK  1 = a rate-limited read is not retried on main (scans);
#                             a bad, missing or 404 token still falls back
#   GH_READ_OFF               1 = every read fails at once (124) with a stall row;
#                             writes are untouched
#

_GHR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/timeout-bin.sh
. "$_GHR_HERE/timeout-bin.sh" 2>/dev/null
_GHR_TOK=""
_GHR_TOK2=""
_GHR_LOADED=0
_GHR_WARNED=0
_GHR_WHY=""

_ghr_warn() {
    [ "$_GHR_WARNED" -eq 0 ] || return 0
    _GHR_WARNED=1
    [ "${GH_READ_QUIET:-}" != 1 ] || return 0
    echo "gh-read: $1; using the main token for reads" >&2
}

# The loader runs in a subshell: load_dotenv exports what it reads.
_ghr_load() {
    [ "$_GHR_LOADED" -eq 0 ] || return 0
    _GHR_LOADED=1
    local pair a="" b="" bad=""
    pair=$(
        # shellcheck source=scripts/lib/load-dotenv.sh
        . "$_GHR_HERE/load-dotenv.sh" 2>/dev/null || exit 0
        root="${GH_READ_ENV_ROOT:-$(_load_dotenv_primary_for "$_GHR_HERE/../.." 2>/dev/null)}"
        if [ -n "${GH_READ_ENV_ROOT:-}" ]; then
            unset himmel_github_token_vm2 himmel_github_token_vm CREDENTIALS_DIRECTORY
            export HIMMEL_SECRETS_KEYRING=off
        fi
        load_dotenv --root "$root" himmel_github_token_vm2 himmel_github_token_vm 2>/dev/null
        printf '%s\n%s\nend' "${himmel_github_token_vm2:-}" "${himmel_github_token_vm:-}"
    ) || pair=""
    {
        IFS= read -r a
        IFS= read -r b
    } <<EOF
$pair
EOF
    case "$a" in *[!A-Za-z0-9_]*) a=""; bad=1 ;; esac
    case "$b" in *[!A-Za-z0-9_]*) b=""; bad=1 ;; esac
    [ "$b" != "$a" ] || b=""
    if [ -z "$a" ]; then a="$b"; b=""; fi
    _GHR_TOK="$a"
    _GHR_TOK2="$b"
    if [ -z "$_GHR_TOK" ]; then
        if [ -n "$bad" ]; then _GHR_WHY="read token malformed"; else _GHR_WHY="read token missing or unreadable"; fi
    fi
}

# gh_read_init — a caller that runs many reads (some in $(...) subshells, some as
# child processes) calls this once at top level: the token loads once in the
# caller's shell, the missing-token warning prints once, and children stay quiet.
gh_read_init() {
    _ghr_load
    # only the missing-token case is silenced downstream: a token that loads and is
    # later refused still warns where the refusal happens
    if [ -z "$_GHR_TOK" ]; then
        _ghr_warn "$_GHR_WHY"
        _GHR_WARNED=1
        export GH_READ_QUIET=1
    fi
    return 0
}

# _ghr_is_read <gh args...> — rc 0 only for a known read shape.
_ghr_is_read() {
    case "${1:-} ${2:-}" in
        "pr view"|"pr list"|"pr checks"|"pr status"|"pr diff"|"repo view"|"run list"|"run view"|"issue view"|"issue list") return 0 ;;
        "api "*) ;;
        *) return 1 ;;
    esac
    local a prev="" graphql=0 field=0
    shift
    for a in "$@"; do
        case "$prev" in -X|--method) [ "$a" = GET ] || return 1 ;; esac
        case "$a" in
            # a document or body read from a file cannot be inspected here
            --input|--input=*|*=@*) return 1 ;;
            graphql) graphql=1 ;;
            -f|-F|--field|--raw-field|-f?*|-F?*|--field=*|--raw-field=*) field=1 ;;
            -XGET|--method=GET) ;;
            -X?*|--method=*) return 1 ;;
            *mutation*) return 1 ;;
        esac
        prev="$a"
    done
    # fields on a REST call turn it into a POST; on graphql they are the query
    [ "$field" -eq 0 ] || [ "$graphql" -eq 1 ]
}

_ghr_run() {
    local t="${GH_READ_TIMEOUT:-120}"
    case "$t" in ''|*[!0-9]*) t=120 ;; esac
    if [ "$t" -gt 0 ] && [ -n "${_TIMEOUT_BIN:-}" ]; then
        "$_TIMEOUT_BIN" --foreground "$t" gh "$@"
    else
        gh "$@"
    fi
}

_ghr_rl() {
    ( . "$_GHR_HERE/gh-quota.sh" 2>/dev/null && ghq_is_rate_limited "$(cat "$1" 2>/dev/null)" )  # read-sink-ok: our own mktemp buffer
}

_ghr_park_scan() {
    [ -s "${HIMMEL_QUOTA_DIR:-$HOME/.himmel/state/quota}/quota.tsv" ] || return 0
    (
        . "$_GHR_HERE/gh-quota.sh" 2>/dev/null || exit 0
        [ "$(ghq_bucket_of "$@")" = core ] || exit 0
        floor="${GHQ_SCAN_FLOOR:-500}"
        case "$floor" in ''|*[!0-9]*) floor=500 ;; esac
        now=$(date +%s)
        for name in main read read2; do
            ghq_read "$name" core || continue
            case "$GHQ_STATE" in ok|refused) ;; *) continue ;; esac
            if [ "$GHQ_STATE" != refused ]; then
                [ -n "$GHQ_REMAINING" ] && [ "$GHQ_REMAINING" -lt "$floor" ] || continue
            fi
            r="$GHQ_RESET"
            ghb_reset_sane "$r" || r=$((GHQ_OBSERVED + 60))
            [ "$r" -gt "$now" ] || continue
            printf '\n%s\tQUOTA-PAUSE github core token=%s remaining=%s floor=%s reset=%s caller=gh-read.sh nothing-was-judged' \
                "$name" "$name" "${GHQ_REMAINING:-unknown}" "$floor" "$(_ghq_reset_words "$r")"
        done
    )
}

_ghr_note() {
    local tok="$1" rc="$2" errf="$3" why="" bucket
    shift 3
    [ -n "${GH_READ_REFUSED_FILE:-}" ] || return 0
    case "$rc" in
        0) return 0 ;;
        124|137) why=stall ;;
        *) _ghr_rl "$errf" && why=rate-limit ;;
    esac
    [ -n "$why" ] || return 0
    bucket=$( . "$_GHR_HERE/gh-quota.sh" 2>/dev/null && ghq_bucket_of "$@") || bucket=""
    printf '%s %s %s\n' "$tok" "${bucket:-graphql}" "$why" >> "$GH_READ_REFUSED_FILE" 2>/dev/null
    return 0
}

_ghr_used() {
    _ghr_used_row "$1" "" "${@:2}"
}

_ghr_used_row() {
    local tok="$1" extra="$2" bucket
    shift 2
    [ -n "${GH_READ_USED_FILE:-}" ] && [ -f "$GH_READ_USED_FILE" ] || return 0
    bucket=$( . "$_GHR_HERE/gh-quota.sh" 2>/dev/null && ghq_bucket_of "$@") || bucket=""
    perl -MFcntl -e 'sysopen(my $f, $ARGV[0], O_WRONLY | O_APPEND) or exit 0; syswrite($f, "$ARGV[1]\n")' \
        "$GH_READ_USED_FILE" "$tok ${bucket:-graphql}${extra:+ $extra}" 2>/dev/null
    return 0
}

_ghr_reason() {
    if _ghr_rl "$1"; then echo rl; return 0; fi
    if grep -qiE 'bad credentials|requires authentication|not accessible by (personal access )?token' "$1"; then echo auth; return 0; fi
    if grep -qiE 'Could not resolve to a (Repository|PullRequest)' "$1"; then echo notfound; return 0; fi
    local code
    code=$(grep -oiE 'HTTP (401|403|404)' "$1" | head -n 1 | grep -oE '[0-9]+')
    echo "http${code:-?}"
}

_ghr_summary() {
    local a out="" skip=0
    for a in "$@"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$a" in
            --json|--jq|-q|--template|-t|-f|-F|--field|--raw-field|-H|--header) skip=1 ;;
            --json=*|--jq=*|--template=*|--field=*|--raw-field=*|--header=*|-f?*|-F?*|-q?*|-t?*|-H?*) ;;
            *) out="$out ${a%%\?*}" ;;
        esac
    done
    out="${out# }"
    out=$(printf '%s' "$out" | tr '\n\t' '  ' | sed -E 's/(gh[opsur]_|github_pat_)[A-Za-z0-9_]+/<redacted>/g')
    printf '%s' "${out:0:120}"
}

gh_read() {
    if ! _ghr_is_read "$@"; then
        gh "$@"
        return $?
    fi
    _ghr_load
    local errf outf rc tok=main
    [ -z "$_GHR_TOK" ] || tok="read"
    if [ "${GH_READ_OFF:-}" = 1 ]; then
        echo "gh-read: reads are off (GH_READ_OFF=1); nothing was read" >&2
        [ -z "${GH_READ_REFUSED_FILE:-}" ] || printf '%s %s stall\n' "$tok" \
            "$( . "$_GHR_HERE/gh-quota.sh" 2>/dev/null && ghq_bucket_of "$@")" >> "$GH_READ_REFUSED_FILE" 2>/dev/null
        return 124
    fi
    if [ -z "$_GHR_TOK" ]; then
        _ghr_warn "$_GHR_WHY"
        errf=$(mktemp "${TMPDIR:-/tmp}/gh-read.XXXXXX") || { _ghr_used main "$@"; _ghr_run "$@"; return $?; }
        _ghr_used main "$@"
        _ghr_run "$@" 2>"$errf"
        rc=$?
        cat "$errf" >&2  # read-sink-ok: our own mktemp buffer
        _ghr_note main "$rc" "$errf" "$@"
        rm -f "$errf"
        return "$rc"
    fi
    errf=$(mktemp "${TMPDIR:-/tmp}/gh-read.XXXXXX") || { _ghr_used main "$@"; _ghr_run "$@"; return $?; }
    # a refused call can already have printed pages or an error body: hold stdout so
    # a refused attempt is discarded instead of doubled by the retry
    outf=$(mktemp "${TMPDIR:-/tmp}/gh-read.XXXXXX") || { rm -f "$errf"; _ghr_used main "$@"; _ghr_run "$@"; return $?; }
    local parked name stok rlseen="" last="" why="" skipped=""
    parked=$(_ghr_park_scan "$@")
    for name in read read2; do
        if [ "$name" = read ]; then stok="$_GHR_TOK"; else stok="$_GHR_TOK2"; fi
        [ -n "$stok" ] || continue
        case "$parked" in *$'\n'"$name"$'\t'*) why=rl; [ -n "$skipped" ] || skipped="$name"; [ "${GH_READ_NO_MAIN_FALLBACK:-}" != 1 ] || rlseen=1; continue ;; esac
        _ghr_used "$name" "$@"
        GH_TOKEN="$stok" _ghr_run "$@" >"$outf" 2>"$errf"
        rc=$?
        last="$name"
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] \
            && { _ghr_rl "$errf" || grep -qiE 'bad credentials|requires authentication|not accessible by (personal access )?token|HTTP (401|403|404)|Could not resolve to a (Repository|PullRequest)' "$errf"; }; then
            why=$(_ghr_reason "$errf")
            if [ "${GH_READ_NO_MAIN_FALLBACK:-}" = 1 ] && [ "$why" = rl ]; then rlseen=1; fi
            continue
        fi
        cat "$outf"; rm -f "$outf"  # read-sink-ok: our own mktemp buffer
        cat "$errf" >&2  # read-sink-ok: our own mktemp buffer
        _ghr_note "$name" "$rc" "$errf" "$@"
        rm -f "$errf"
        return "$rc"
    done
    if [ -n "$rlseen" ] && [ -n "$last" ]; then
        cat "$outf"; rm -f "$outf"  # read-sink-ok: our own mktemp buffer
        cat "$errf" >&2  # read-sink-ok: our own mktemp buffer
        _ghr_note "$last" "$rc" "$errf" "$@"
        rm -f "$errf"
        return "$rc"
    fi
    rm -f "$outf"
    if [ -n "$rlseen" ] && [ -z "$last" ]; then
        printf '%s\n' "$(printf '%s' "$parked" | awk -F'\t' -v n="$skipped" '$1 == n { print $2; exit }')" >&2
        [ -z "${GH_READ_REFUSED_FILE:-}" ] || printf '%s core rate-limit\n' "$skipped" >> "$GH_READ_REFUSED_FILE" 2>/dev/null
        rm -f "$errf"
        return 75
    fi
    case "$parked" in
        *$'\n'main$'\t'*)
            printf '%s\n' "$(printf '%s' "$parked" | awk -F'\t' '$1 == "main" { print $2; exit }')" >&2
            [ -z "${GH_READ_REFUSED_FILE:-}" ] || printf 'main core rate-limit\n' >> "$GH_READ_REFUSED_FILE" 2>/dev/null
            rm -f "$errf"
            return 75 ;;
    esac
    if [ -n "$last" ]; then
        _ghr_warn "read token refused"
        _ghr_used_row main "$why $(_ghr_summary "$@")" "$@"
    else
        _ghr_warn "read tokens are under the REST floor"
        _ghr_used_row main "rl $(_ghr_summary "$@")" "$@"
    fi
    _ghr_run "$@" 2>"$errf"
    rc=$?
    cat "$errf" >&2  # read-sink-ok: our own mktemp buffer
    _ghr_note main "$rc" "$errf" "$@"
    rm -f "$errf"
    return "$rc"
}

# gh_read_rates — one line per token: "<main|read>: <remaining>/<limit> reset HH:MM[ LOW]".
# LOW when under 10 %. `gh api rate_limit` costs no budget. Never fails the caller.
gh_read_rates() {
    local name out rem lim reset when low
    for name in main read; do
        out=""
        if [ "$name" = main ]; then
            out=$(gh api rate_limit --jq '.resources.core | "\(.remaining) \(.limit) \(.reset)"' 2>/dev/null) || out=""
        else
            _ghr_load
            if [ -z "$_GHR_TOK" ]; then
                printf 'read: n/a (%s)\n' "$_GHR_WHY"
                continue
            fi
            out=$(GH_TOKEN="$_GHR_TOK" gh api rate_limit --jq '.resources.core | "\(.remaining) \(.limit) \(.reset)"' 2>/dev/null) || out=""
        fi
        rem=""; lim=""; reset=""
        read -r rem lim reset <<< "$out"
        case "$rem$lim" in ''|*[!0-9]*) printf '%s: ?\n' "$name"; continue ;; esac
        when=$(date -d "@$reset" +%H:%M 2>/dev/null || date -r "$reset" +%H:%M 2>/dev/null) || when=""
        [ -n "$when" ] || when='?'
        low=""
        if [ "$lim" -gt 0 ] && [ $((rem * 100)) -lt $((lim * 10)) ]; then low=" LOW"; fi
        printf '%s: %s/%s reset %s%s\n' "$name" "$rem" "$lim" "$when" "$low"
    done
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    gh_read "$@"
    exit $?
fi
