#!/usr/bin/env bash
# gh-two-token-stub.sh - a PATH `gh` that stands in for the main token and the read
# token. Put it first on PATH as `gh` (symlink or copy named gh); it
# wraps a suite's own stub, so one caller row can prove "main is spent, the read
# still answers" and "the write still rides main".
#
# env   GHLOG               required: the log file, one line per call
#       GH_STUB_DELEGATE    the suite's own stub (absolute path); unset = exit 0, no output
#       GH_STUB_MAINFAIL    rate|auth: main-token reads are refused
#       GH_STUB_MAINFAIL_BUCKET  core|graphql: only that bucket of main is spent (the 11-10
#                           incident was core 0/5000); unset = every read bucket is spent.
#                           A write on main is refused ONLY when this names its own bucket
#                           (pr merge is graphql); unset, a write is never refused
#       GH_STUB_READFAIL    rate|auth|notfound: a read-token call is refused
#       GH_STUB_READ_TOKEN  the fixture's read token
#       GH_STUB_HANG        seconds to sleep before answering
# log   "tok=read argv=<args>" when GH_TOKEN equals GH_STUB_READ_TOKEN,
#       "tok=main argv=<args>" when GH_TOKEN is empty, "tok=other argv=<args>" otherwise.
#       The token value is never written.
# refuse  main + MAINFAIL + a read shape in a spent bucket: the F1 text on stderr, exit 1.
#       read token + READFAIL: a partial page on stdout, the matching text on stderr, exit 1.
# answer  everything else: exec GH_STUB_DELEGATE "$@".
#
# The read-shape test mirrors scripts/lib/gh-read.sh _ghr_is_read and the bucket rule
# mirrors scripts/lib/gh-quota.sh ghq_bucket_of, kept here on purpose so a broken
# router cannot also break the stub that tests it.
#
# PLATFORM GUARD: the chief kit is Linux-only.
set -u

: "${GHLOG:?gh-two-token-stub: GHLOG is required}"

tok=other
if [ -z "${GH_TOKEN:-}" ]; then
    tok=main
elif [ -n "${GH_STUB_READ_TOKEN:-}" ] && [ "$GH_TOKEN" = "$GH_STUB_READ_TOKEN" ]; then
    tok="read"
fi
printf 'tok=%s argv=%s\n' "$tok" "$*" >> "$GHLOG"

[ -z "${GH_STUB_HANG:-}" ] || sleep "$GH_STUB_HANG"

stub_is_read() {
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
            --input|--input=*|*=@*) return 1 ;;
            graphql) graphql=1 ;;
            -f|-F|--field|--raw-field|-f?*|-F?*|--field=*|--raw-field=*) field=1 ;;
            -XGET|--method=GET) ;;
            -X?*|--method=*) return 1 ;;
            *mutation*) return 1 ;;
        esac
        prev="$a"
    done
    [ "$field" -eq 0 ] || [ "$graphql" -eq 1 ]
}

stub_bucket_of() {
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

main_refuses() {
    [ "$tok" = main ] && [ -n "${GH_STUB_MAINFAIL:-}" ] || return 1
    local b
    b="$(stub_bucket_of "$@")"
    if stub_is_read "$@"; then
        case "${GH_STUB_MAINFAIL_BUCKET:-all}" in all|"$b") return 0 ;; esac
        return 1
    fi
    case "${GH_STUB_MAINFAIL_BUCKET:-all}" in core|graphql) [ "${GH_STUB_MAINFAIL_BUCKET}" = "$b" ] ;; *) return 1 ;; esac
}

if main_refuses "$@"; then
    case "$GH_STUB_MAINFAIL" in
        auth) echo "gh: HTTP 401: Bad credentials" >&2 ;;
        *) echo "GraphQL: API rate limit already exceeded for user ID 1." >&2 ;;
    esac
    exit 1
fi

if [ "$tok" = read ] && [ -n "${GH_STUB_READFAIL:-}" ]; then
    echo "partial-page"
    case "$GH_STUB_READFAIL" in
        auth) echo "gh: HTTP 401: Bad credentials" >&2 ;;
        notfound) echo "gh: HTTP 404: Not Found" >&2 ;;
        *) echo "gh: HTTP 403: API rate limit exceeded for user" >&2 ;;
    esac
    exit 1
fi

if [ -n "${GH_STUB_DELEGATE:-}" ]; then
    exec "$GH_STUB_DELEGATE" "$@"
fi
exit 0
