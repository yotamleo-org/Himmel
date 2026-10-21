#!/usr/bin/env bash
# scripts/lib/ticket-status.sh — SOURCED. A ticket's Jira status DERIVED from
# its current ship-flow state, plus the per-ticket worker record and the outcome
# log. The funnel (scripts/handover/console-kit/leg-jira-status.sh) is the only
# writer of the status and of the record; everything here reads, except
# ts_record_write and status_event, which the funnel calls under its per-key
# flock.
#
#   ticket_key_from_title <title>   the FIRST [KEY] in a PR title; rc 1 = none.
#                                   Every caller associates a PR with a ticket
#                                   through this one function.
#   ts_derive <KEY>                 reads the inputs fresh and sets:
#     TS_DERIVED   a ladder status, or "no-write"
#     TS_RULE      D0..D7 (D0e = Epic, D4b = done-pending)
#     TS_RESULT    for no-write: skip | miss
#     TS_STAGE     for a miss: the input that could not be read
#     TS_J_STATUS  the Jira status the derive saw; TS_HEADS the "<pr>:<head>" list
#     TS_PR_STATE  "<pr>\t<head>\t<class>\t<red latch>" per open PR
#     TS_WORKER_STATE  live | idle | IDLE-HELD | wrapped | unknown | none
#   status_event <k=v>...           one JSON row in status-events.jsonl
#
# Rules (first match wins; an unreadable input is no-write + miss, never a move):
#   D0  Jira Done or off the ladder              no-write (only merge-on-green writes Done)
#   D0e an Epic                                  no-write (merge-on-green never touches one)
#   D1  a PR's required check red, or its latch  In Progress
#   D2  CHANGES_REQUESTED or unresolved threads  In Review
#   D3  required checks running or green         IN CI
#   D4  no required check started                In Review
#       (several open PRs: the least advanced wins)
#   D4b no PR, a completes=yes merge row         no-write + miss stage=done-pending
#   D5  no PR, an owner not provably ended       In Progress
#   D6  no PR, the owner WRAPPED or HALTED       To Do (the resume state)
#   D7  no PR, never owned                       no-write
#
# Env: TICKET_STATUS_STATE_DIR (default ~/.himmel/state), LEG_JIRA_CLI (the Jira
# CLI; an executable or a .js run under node), TICKET_STATUS_QUEUE_LOCK (an
# executable standing in for queue-lock.sh), TICKET_STATUS_PR_LIMIT (default 50),
# QUEUE_LOCK_IDLE_WARN_SECONDS (default 2700). Needs jq and gh.
#
# bash 3.2-safe.
# shellcheck disable=SC2034  # the TS_* globals are this lib's outputs, read by the caller

_TS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/required-checks.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$_TS_LIB_DIR/required-checks.sh"
# shellcheck source=scripts/lib/prim.sh
# shellcheck disable=SC1091
. "$_TS_LIB_DIR/prim.sh"

ts_state_dir() { printf '%s' "${TICKET_STATUS_STATE_DIR:-${HOME:-/tmp}/.himmel/state}"; }

ts_rank() {
    case "$1" in
        "To Do") echo 0 ;;
        "In Progress") echo 1 ;;
        "In Review") echo 2 ;;
        "IN CI") echo 3 ;;
        *) echo -1 ;;
    esac
}

ticket_key_from_title() {
    local re='\[([A-Za-z][A-Za-z0-9]*-[0-9]+)\]'
    [[ "$1" =~ $re ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

status_event() {
    # shellcheck disable=SC2016  # $ts and $<k> are jq variables
    local dir log kv k line obj='{ts:$ts'
    local args=(--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    for kv in "$@"; do
        k=${kv%%=*}
        args+=(--arg "$k" "${kv#*=}")
        obj="$obj,$k:\$$k"
    done
    dir=$(ts_state_dir)
    log="$dir/status-events.jsonl"
    mkdir -p "$dir" 2>/dev/null
    if ! line=$(jq -nc "${args[@]}" "$obj}") || ! printf '%s\n' "$line" >> "$log" 2>/dev/null; then
        echo "WARN status-log-unwritable: $log" >&2
    fi
}

ts_jira() {
    local cli="${LEG_JIRA_CLI:-}" common
    if [ -z "$cli" ]; then
        common="$(git -C "$_TS_LIB_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 127
        cli="$(dirname "$common")/scripts/jira/dist/index.js"
    fi
    [ -e "$cli" ] || return 127
    case "$cli" in
        *.js) node "$cli" "$@" ;;
        *) "$cli" "$@" ;;
    esac
}

# ts_read_jira <KEY> — TS_J_STATUS; rc 1 = unreadable.
ts_read_jira() {
    local json
    TS_J_STATUS=""; TS_J_TYPE=""
    json=$(ts_jira get "$1" --json 2>/dev/null) || return 1
    TS_J_STATUS=$(jq -r '.fields.status.name // empty' <<<"$json" 2>/dev/null)
    TS_J_TYPE=$(jq -r '.fields.issuetype.name // empty' <<<"$json" 2>/dev/null)
    [ -n "$TS_J_STATUS" ]
}

# ts_read_prs <KEY> — the open PRs whose title's first [KEY] is <KEY>:
# TS_PRS = "<pr>\t<head>\t<base>\t<reviewDecision>" lines, TS_HEADS = "<pr>:<head>,...".
# rc 1 = unreadable (TS_STAGE gh) or the list hit its limit (TS_STAGE pr-limit).
ts_read_prs() {
    local limit="${TICKET_STATUS_PR_LIMIT:-50}" json n rows num title head base rd k
    TS_PRS=""
    TS_HEADS=""
    json=$(gh pr list --state open --search "$1 in:title" --limit "$limit" \
        --json number,title,headRefOid,baseRefName,reviewDecision 2>/dev/null) || { TS_STAGE=gh; return 1; }
    n=$(jq 'length' <<<"$json" 2>/dev/null) || { TS_STAGE=gh; return 1; }
    case "$n" in ''|*[!0-9]*) TS_STAGE=gh; return 1 ;; esac
    [ "$n" -lt "$limit" ] || { TS_STAGE=pr-limit; return 1; }
    rows=$(jq -r 'sort_by(.number) | .[] | [.number, .title, .headRefOid, .baseRefName, (.reviewDecision // "")] | @tsv' <<<"$json" 2>/dev/null) \
        || { TS_STAGE=gh; return 1; }
    while IFS=$'\t' read -r num title head base rd; do
        [ -n "$num" ] || continue
        k=$(ticket_key_from_title "$title") || continue
        [ "$k" = "$1" ] || continue
        TS_PRS="$TS_PRS$num"$'\t'"$head"$'\t'"$base"$'\t'"$rd"$'\n'
        TS_HEADS="${TS_HEADS:+$TS_HEADS,}$num:$head"
    done <<<"$rows"
    return 0
}

# ts_required_set <base> — check-ci's effective required set, read through the
# same rules + classic-protection endpoints. rc 1 = unreadable (a 403 included).
ts_required_set() {
    local rules classic
    rules=$(gh api "repos/{owner}/{repo}/rules/branches/$1" 2>/dev/null) || return 1
    rules=$(jq -r '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | "\(.context)\t\(.integration_id // "")"' <<<"$rules" 2>/dev/null) || return 1
    if classic=$(gh api "repos/{owner}/{repo}/branches/$1/protection/required_status_checks" 2>&1); then
        classic=$(jq -r '((.contexts // [])[] | "\(.)\t"), ((.checks // [])[]? | "\(.context)\t\(.app_id // "")")' <<<"$classic" 2>/dev/null) || return 1
    else
        case "$classic" in *"(HTTP 404)"*) classic="" ;; *) return 1 ;; esac
    fi
    printf '%s\n%s\n' "$rules" "$classic" | sed '/^$/d' | sort -u | _required_normalize
}

# ts_pr_class <pr> <head> <base> — red | pending | green | none (no required
# check started), judged on the REQUIRED checks only, so an optional red never
# pins D1. Prints "!<stage>" and returns 1 when an input is unreadable.
ts_pr_class() {
    local reqs out rows prows="" st
    reqs=$(ts_required_set "$3") || { echo "!required-set"; return 1; }
    out=$(gh pr checks "$1" --json bucket,name 2>&1)
    if rows=$(jq -r '.[] | "\(.bucket)\t\(.name)"' <<<"$out" 2>/dev/null); then
        :
    else
        case "$out" in *"no checks reported"*) rows="" ;; *) echo "!gh"; return 1 ;; esac
    fi
    if [ -z "$reqs" ]; then
        if [ -z "$rows" ]; then echo none
        elif grep -q '^pending' <<<"$rows"; then echo pending
        else echo green
        fi
        return 0
    fi
    if _has_producer_ids "$reqs"; then
        out=$(gh api "repos/{owner}/{repo}/commits/$2/check-runs?per_page=100" --paginate 2>/dev/null) || { echo "!gh"; return 1; }
        prows=$(jq -r '.check_runs[] | if .id == null then error("check-run with no id") else "\(if .status != "completed" then "pending" elif (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") then "pass" elif .conclusion == "cancelled" then "cancel" else "fail" end)\t\(.name)\t\(.app.id // "")\t\(.started_at // "")\t\(.id)" end' <<<"$out" 2>/dev/null) || { echo "!gh"; return 1; }
    fi
    st=$(_required_status "$reqs" "$rows" "$prows")
    if grep -q '^fail' <<<"$st"; then echo red; return 0; fi
    if ! grep -qv '^missing' <<<"$st"; then echo none; return 0; fi
    if grep -q '^missing\|^pending' <<<"$st"; then echo pending; return 0; fi
    # "seen" on a name-only requirement still covers a running check.
    if awk -F'\t' 'NR == FNR { if ($2 == "") n[$1] = 1; next } $1 == "pending" && ($2 in n) { f = 1 } END { exit !f }' \
        <(printf '%s\n' "$reqs") <(printf '%s\n' "$rows"); then
        echo pending
    else
        echo green
    fi
}

# ts_unresolved_threads <pr> — the unresolved review-thread count; rc 1 =
# unreadable, a further page included (a partial count could miss one).
ts_unresolved_threads() {
    local out n
    # shellcheck disable=SC2016  # $owner/$name/$number are GraphQL variables
    out=$(gh api graphql -F owner='{owner}' -F name='{repo}' -F number="$1" \
        -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}}}}}' 2>/dev/null) || return 1
    n=$(jq -r '.data.repository.pullRequest.reviewThreads
        | if .pageInfo.hasNextPage != false then error("more threads") else .nodes | map(select(.isResolved | not)) | length end' <<<"$out" 2>/dev/null) || return 1
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    echo "$n"
}

ts_record_path() { printf '%s/workers/%s.json' "$(ts_state_dir)" "$1"; }

# ts_record_read <KEY> — TS_REC (the record, "{}" when absent); rc 1 = it does not parse.
ts_record_read() {
    local p
    p=$(ts_record_path "$1")
    TS_REC='{}'
    [ -e "$p" ] || return 0
    TS_REC=$(jq -ce 'if type == "object" then . else error("not an object") end' "$p" 2>/dev/null) || { TS_REC='{}'; return 1; }
}

ts_record_write() {
    local p
    p=$(ts_record_path "$1")
    mkdir -p "${p%/*}" 2>/dev/null || return 1
    printf '%s\n' "$2" | atomic_write "$p" 2>/dev/null
}

# ts_marker_newest <doc> — the newest Results marker in a leg doc.
ts_marker_newest() {
    [ -r "$1" ] || return 0
    grep -oE '^- [0-9]{1,2}:[0-9]{2} (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|RESUMED|SUCCESSION)([^A-Za-z0-9-]|$)' "$1" 2>/dev/null \
        | tail -n 1 | awk '{ print $3 }'
}

_ts_epoch_of_iso() {
    date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# ts_worker_state <doc> — live | idle | IDLE-HELD | wrapped | unknown, from the
# doc's newest marker and its queue lock. Only an end marker is positive end
# evidence: a free lock with no end marker (a hand-off, a cloud or
# other-station leg) is unknown, which still counts as an owner.
ts_worker_state() {
    local marker out rc hb hb_epoch age=0 warn
    [ -n "$1" ] || { echo unknown; return 0; }
    marker=$(ts_marker_newest "$1")
    case "$marker" in WRAPPED|HALTED) echo wrapped; return 0 ;; esac
    if [ -n "${TICKET_STATUS_QUEUE_LOCK:-}" ]; then
        out=$("$TICKET_STATUS_QUEUE_LOCK" status "$1" 2>/dev/null); rc=$?
    else
        out=$(bash "$_TS_LIB_DIR/../handover/queue-lock.sh" status "$1" 2>/dev/null); rc=$?
    fi
    case "$rc" in
        11|12) ;;
        *) echo unknown; return 0 ;;
    esac
    hb=$(printf '%s\n' "$out" | sed -n 's/.*"heartbeat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -n "$hb" ] && hb_epoch=$(_ts_epoch_of_iso "$hb"); then
        age=$(( $(date -u +%s) - hb_epoch ))
    fi
    warn="${QUEUE_LOCK_IDLE_WARN_SECONDS:-2700}"
    case "$warn" in ''|*[!0-9]*) warn=2700 ;; esac
    if [ "$rc" -eq 12 ] || [ "$age" -ge "$warn" ]; then echo IDLE-HELD; return 0; fi
    case "$marker" in
        READY|BLOCKED) echo idle ;;
        LIVE|FINDING|RESOLVED|RESUMED|SUCCESSION) echo live ;;
        *) echo unknown ;;
    esac
}

# ts_done_pending <KEY> — the key's latest merge row is completes=yes and its
# Done did not land (result neither moved nor noop).
# rc 0 = pending, 1 = none, 2 = the log is unreadable.
ts_done_pending() {
    local log
    log="$(ts_state_dir)/status-events.jsonl"
    [ -e "$log" ] || return 1
    [ -r "$log" ] || return 2
    [ -n "$(jq -R -n --arg k "$1" '[inputs | fromjson? | select(.key == $k and .event == "merge")] | last
        | select(. != null and .contract == "yes" and .result != "moved" and .result != "noop") | 1' "$log" 2>/dev/null)" ]
}

_ts_no_write() { TS_DERIVED="no-write"; TS_RESULT="$1"; TS_RULE="$2"; TS_STAGE="${3:-}"; }

ts_derive() {
    local key="$1" num head base rd class latch threads s rule best=9 r doc rc
    TS_DERIVED=""; TS_RULE=""; TS_RESULT=""; TS_STAGE=""; TS_PR_STATE=""; TS_HEADS=""; TS_WORKER_STATE=none
    ts_read_jira "$key" || { _ts_no_write miss "" get; return 0; }
    [ "$(ts_rank "$TS_J_STATUS")" -ge 0 ] || { _ts_no_write skip D0; return 0; }
    [ "$TS_J_TYPE" != Epic ] || { _ts_no_write skip D0e; return 0; }
    ts_record_read "$key" || { _ts_no_write miss "" record; return 0; }
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    [ -z "$doc" ] || TS_WORKER_STATE=$(ts_worker_state "$doc")
    ts_read_prs "$key" || { _ts_no_write miss "" "$TS_STAGE"; return 0; }
    if [ -n "$TS_PRS" ]; then
        while IFS=$'\t' read -r num head base rd; do
            [ -n "$num" ] || continue
            class=$(ts_pr_class "$num" "$head" "$base") || { _ts_no_write miss "" "${class#!}"; return 0; }
            threads=$(ts_unresolved_threads "$num") || { _ts_no_write miss "" gh; return 0; }
            latch=$(jq -r --arg n "$num" '.prs[$n].red_latch // false' <<<"$TS_REC")
            [ "$class" = red ] && latch=true
            [ "$class" = green ] && latch=false
            if [ "$latch" = true ]; then s="In Progress"; rule=D1
            elif [ "$rd" = CHANGES_REQUESTED ] || [ "$threads" -gt 0 ]; then s="In Review"; rule=D2
            elif [ "$class" = pending ] || [ "$class" = green ]; then s="IN CI"; rule=D3
            else s="In Review"; rule=D4
            fi
            r=$(ts_rank "$s")
            if [ "$r" -lt "$best" ]; then best=$r; TS_DERIVED=$s; TS_RULE=$rule; fi
            TS_PR_STATE="$TS_PR_STATE$num"$'\t'"$head"$'\t'"$class"$'\t'"$latch"$'\n'
        done <<<"$TS_PRS"
        return 0
    fi
    ts_done_pending "$key"; rc=$?
    [ "$rc" -ne 0 ] || { _ts_no_write miss D4b done-pending; return 0; }
    [ "$rc" -ne 2 ] || { _ts_no_write miss "" log; return 0; }
    if [ -z "$doc" ] && [ "$(jq -r '(.prs // {}) | length' <<<"$TS_REC")" = 0 ]; then
        _ts_no_write skip D7
        return 0
    fi
    if [ "$TS_WORKER_STATE" = wrapped ]; then TS_DERIVED="To Do"; TS_RULE=D6
    else TS_DERIVED="In Progress"; TS_RULE=D5
    fi
}
