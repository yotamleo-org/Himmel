#!/usr/bin/env bash
# gh-read.sh — READ-ONLY gh calls on the read-only token.
#
# WHY: every worker and the console share one station token (5000 REST/hour).
# When it hit 0, go.sh and ready-check could not read the PR state and three
# trust GOs waited ~6 minutes. Reads now ride a second, read-only token
# (himmel_github_token_vm2, account B, public repos); every write keeps the main
# token.
#
#   sourced:   defines gh_read <gh args...> and gh_read_rates
#   executed:  gh-read.sh <gh args...>   (for `timeout`, `exec` and TICK_GH_CMD)
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
# the primary checkout's .env, found from this file).
#
# ponytail: one read token, no pool or rotation; the fallback is reactive (a
# refused read retries once on the main token), not a pre-flight budget check.

_GHR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GHR_TOK=""
_GHR_LOADED=0
_GHR_WARNED=0
_GHR_WHY=""

_ghr_warn() {
    [ "$_GHR_WARNED" -eq 0 ] || return 0
    _GHR_WARNED=1
    [ "${GH_READ_QUIET:-}" != 1 ] || return 0
    echo "gh-read: $1; using the main token for reads" >&2
}

# _ghr_load — read the token once per process into the NON-exported _GHR_TOK.
# The loader runs in a subshell: load_dotenv exports what it reads.
_ghr_load() {
    [ "$_GHR_LOADED" -eq 0 ] || return 0
    _GHR_LOADED=1
    _GHR_TOK=$(
        # shellcheck source=scripts/lib/load-dotenv.sh
        . "${_GHR_LOAD_DOTENV:-$_GHR_HERE/load-dotenv.sh}" 2>/dev/null || exit 0
        root="${GH_READ_ENV_ROOT:-$(_load_dotenv_primary_for "$_GHR_HERE/../.." 2>/dev/null)}"
        load_dotenv --root "$root" himmel_github_token_vm2 2>/dev/null
        printf '%s' "${himmel_github_token_vm2:-}"
    ) || _GHR_TOK=""
    case "$_GHR_TOK" in
        '') _GHR_WHY="read token missing or unreadable" ;;
        *[!A-Za-z0-9_]*) _GHR_TOK=""; _GHR_WHY="read token malformed" ;;
    esac
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

gh_read() {
    if ! _ghr_is_read "$@"; then
        gh "$@"
        return $?
    fi
    _ghr_load
    if [ -z "$_GHR_TOK" ]; then
        _ghr_warn "$_GHR_WHY"
        gh "$@"
        return $?
    fi
    local errf outf rc
    errf=$(mktemp "${TMPDIR:-/tmp}/gh-read.XXXXXX") || { gh "$@"; return $?; }
    # a refused call can already have printed pages or an error body: hold stdout so
    # a refused attempt is discarded instead of doubled by the retry
    outf=$(mktemp "${TMPDIR:-/tmp}/gh-read.XXXXXX") || { rm -f "$errf"; gh "$@"; return $?; }
    GH_TOKEN="$_GHR_TOK" gh "$@" >"$outf" 2>"$errf"
    rc=$?
    if [ "$rc" -ne 0 ] && grep -qiE 'rate limit|bad credentials|requires authentication|not accessible by (personal access )?token|HTTP (401|403|404)|Could not resolve to a (Repository|PullRequest)' "$errf"; then
        rm -f "$errf" "$outf"
        _ghr_warn "read token refused"
        gh "$@"
        return $?
    fi
    cat "$outf"; rm -f "$outf"
    cat "$errf" >&2
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
