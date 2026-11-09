# shellcheck shell=bash
# scripts/lib/open-review-threads.sh - the unresolved review threads of one PR,
# named. Read by check-ci.sh on a non-green exit, review-round.sh judge-go and
# write-verdict.sh --delta-noop, so a review posted during a CI wait is seen
# before a GO is signed over it. Sourced, never run. bash 3.2-safe.
#
# open_review_threads <owner> <repo> <pr> <gh command words...>
#   stdout: line 1 is the unresolved-thread count; then one line per unresolved
#   thread, "  <path>:<line> by <login> at <createdAt>".
#   rc 0 = read (count 0 = none open); rc 1 = not read (query failed, malformed
#   page, or more than 50 pages).
#   <owner>/<repo> may be gh's literal '{owner}' / '{repo}' placeholders, which gh
#   fills from the current directory's repo.
open_review_threads() {
    local owner="$1" repo="$2" pr="$3" ofl=-f rfl=-f cursor="" sent pages=0 page head rest n has_next total=0 lines="" cargs
    shift 3
    [ "$#" -gt 0 ] || return 1
    case "$pr" in '' | 0* | *[!0-9]*) return 1 ;; esac
    [ "$owner" = '{owner}' ] && ofl=-F
    [ "$repo" = '{repo}' ] && rfl=-F
    while :; do
        pages=$((pages + 1))
        [ "$pages" -le 50 ] || return 1
        sent="$cursor"
        cargs=()
        [ -z "$cursor" ] || cargs=(-f "c=$cursor")
        # shellcheck disable=SC2016  # $o/$r/$n/$c are GraphQL variables
        page=$("$@" api graphql \
            -f query='query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved path line originalLine comments(first:1){nodes{author{login} createdAt}}}}}}}' \
            "$ofl" o="$owner" "$rfl" r="$repo" -F n="$pr" ${cargs[@]+"${cargs[@]}"} \
            --jq '.data.repository.pullRequest.reviewThreads | "\([.nodes[] | select(.isResolved | not)] | length) \(.pageInfo.hasNextPage) \(.pageInfo.endCursor)", (.nodes[] | select(.isResolved | not) | "  \(.path // "?"):\(.line // .originalLine // "?") by \(.comments.nodes[0].author.login // "?") at \(.comments.nodes[0].createdAt // "?")")' 2>/dev/null) || return 1
        head=${page%%$'\n'*}
        n=${head%% *}
        rest=${head#* }
        has_next=${rest%% *}
        cursor=${rest#* }
        case "$n" in '' | *[!0-9]*) return 1 ;; esac
        case "$has_next" in true | false) ;; *) return 1 ;; esac
        if [ "$has_next" = true ] && { [ -z "$cursor" ] || [ "$cursor" = null ] || [ "$cursor" = "$sent" ]; }; then return 1; fi
        total=$((total + n))
        case "$page" in *$'\n'*) lines="$lines${page#*$'\n'}"$'\n' ;; esac
        [ "$has_next" = true ] || break
    done
    printf '%s\n%s' "$total" "$lines"
}
