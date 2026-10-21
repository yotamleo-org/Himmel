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
#   ts_worker_comment <KEY> <status> <move>
#                                   keeps the WORKER Jira comment current: edited in
#                                   place by id, one new post when it has no id or the
#                                   edit 404s, nothing written for an unchanged class.
#                                   Sets TS_CID and TS_CHASH for the record.
#
# A caller that holds one batched snapshot sets TS_SNAPSHOT_DIR (the status sweep,
# console-kit/status-sweep.sh): the readers then take Jira, the open PRs, their
# checks and their review threads from files in it (jira.tsv, prs.json,
# rows-<pr>.tsv, prows-<pr>.tsv, threads.tsv), so a derive over many keys makes no
# per-key Jira or PR call. TS_EVENT=sweep lets a derive project the lock-gone count.
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

# ts_read_jira <KEY> — TS_J_STATUS, TS_J_TYPE; rc 1 = unreadable or either empty.
ts_read_jira() {
    local json row
    TS_J_STATUS=""; TS_J_TYPE=""
    if [ -n "${TS_SNAPSHOT_DIR:-}" ]; then
        row=$(awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3; exit }' "$TS_SNAPSHOT_DIR/jira.tsv" 2>/dev/null)
        TS_J_TYPE=${row%%$'\t'*}
        TS_J_STATUS=${row#*$'\t'}
        [ -n "$row" ] && [ -n "$TS_J_STATUS" ] && [ -n "$TS_J_TYPE" ]
        return
    fi
    json=$(ts_jira get "$1" --json 2>/dev/null) || return 1
    TS_J_STATUS=$(jq -r '.fields.status.name // empty' <<<"$json" 2>/dev/null)
    TS_J_TYPE=$(jq -r '.fields.issuetype.name // empty' <<<"$json" 2>/dev/null)
    [ -n "$TS_J_STATUS" ] && [ -n "$TS_J_TYPE" ]
}

# ts_read_prs <KEY> — the open PRs whose title's first [KEY] is <KEY>:
# TS_PRS = "<pr>\t<head>\t<base>\t<reviewDecision>" lines, TS_HEADS = "<pr>:<head>,...".
# rc 1 = unreadable (TS_STAGE gh) or the list hit its limit (TS_STAGE pr-limit).
ts_read_prs() {
    local limit="${TICKET_STATUS_PR_LIMIT:-50}" json n rows num title head base rd k
    TS_PRS=""
    TS_HEADS=""
    if [ -n "${TS_SNAPSHOT_DIR:-}" ]; then
        limit=300
        json=$(cat "$TS_SNAPSHOT_DIR/prs.json" 2>/dev/null) || { TS_STAGE=gh; return 1; }
    else
        json=$(gh pr list --state open --search "$1 in:title" --limit "$limit" \
            --json number,title,headRefOid,baseRefName,reviewDecision 2>/dev/null) || { TS_STAGE=gh; return 1; }
    fi
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

# _ts_snap_required_set <base> — ts_required_set, read once per base per snapshot.
_ts_snap_required_set() {
    local f="$TS_SNAPSHOT_DIR/req-${1//\//_}"
    if [ ! -e "$f" ] && [ ! -e "$f.fail" ]; then
        if ts_required_set "$1" >"$f.t" 2>/dev/null; then mv "$f.t" "$f"; else rm -f "$f.t"; : >"$f.fail"; fi
    fi
    [ -e "$f" ] || return 1
    # read-sink-ok: $f is under the sweep's own snapshot dir, built from a base ref name, never from argv or a record
    cat "$f"
}

# ts_pr_class <pr> <head> <base> — red | pending | green | none (no required
# check started), judged on the REQUIRED checks only, so an optional red never
# pins D1. Prints "!<stage>" and returns 1 when an input is unreadable.
ts_pr_class() {
    local reqs out rows prows="" st
    if [ -n "${TS_SNAPSHOT_DIR:-}" ]; then
        reqs=$(_ts_snap_required_set "$3") || { echo "!required-set"; return 1; }
        [ -e "$TS_SNAPSHOT_DIR/rows-$1.tsv" ] || { echo "!gh"; return 1; }
        rows=$(cat "$TS_SNAPSHOT_DIR/rows-$1.tsv")
        prows=$(cat "$TS_SNAPSHOT_DIR/prows-$1.tsv" 2>/dev/null)
    else
        reqs=$(ts_required_set "$3") || { echo "!required-set"; return 1; }
        out=$(gh pr checks "$1" --json bucket,name 2>&1)
        if rows=$(jq -r '.[] | "\(.bucket)\t\(.name)"' <<<"$out" 2>/dev/null); then
            :
        else
            case "$out" in *"no checks reported"*) rows="" ;; *) echo "!gh"; return 1 ;; esac
        fi
    fi
    if [ -z "$reqs" ]; then
        if [ -z "$rows" ]; then echo none
        elif grep -q '^pending' <<<"$rows"; then echo pending
        else echo green
        fi
        return 0
    fi
    if [ -z "${TS_SNAPSHOT_DIR:-}" ] && _has_producer_ids "$reqs"; then
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
    if [ -n "${TS_SNAPSHOT_DIR:-}" ]; then
        awk -F'\t' -v n="$1" '$1 == n { print $2; f = 1; exit } END { exit !f }' "$TS_SNAPSHOT_DIR/threads.tsv" 2>/dev/null
        return
    fi
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
    _ts_worker_state "$1"
    echo "$TS_WORKER_STATE"
}

# _ts_worker_state <doc> — ts_worker_state without the subshell: sets
# TS_WORKER_STATE and TS_LOCK_HELD (yes | no | "" when the lock was not read).
_ts_worker_state() {
    local marker out rc hb hb_epoch age=0 warn
    TS_LOCK_HELD=""
    [ -n "$1" ] || { TS_WORKER_STATE=unknown; return 0; }
    marker=$(ts_marker_newest "$1")
    case "$marker" in WRAPPED|HALTED) TS_WORKER_STATE=wrapped; return 0 ;; esac
    if [ -n "${TICKET_STATUS_QUEUE_LOCK:-}" ]; then
        out=$("$TICKET_STATUS_QUEUE_LOCK" status "$1" 2>/dev/null); rc=$?
    else
        out=$(bash "$_TS_LIB_DIR/../handover/queue-lock.sh" status "$1" 2>/dev/null); rc=$?
    fi
    case "$rc" in
        11|12) TS_LOCK_HELD=yes ;;
        0) TS_LOCK_HELD=no; TS_WORKER_STATE=unknown; return 0 ;;
        *) TS_WORKER_STATE=unknown; return 0 ;;
    esac
    hb=$(printf '%s\n' "$out" | sed -n 's/.*"heartbeat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -n "$hb" ] && hb_epoch=$(_ts_epoch_of_iso "$hb"); then
        age=$(( $(date -u +%s) - hb_epoch ))
    fi
    warn="${QUEUE_LOCK_IDLE_WARN_SECONDS:-2700}"
    case "$warn" in ''|*[!0-9]*) warn=2700 ;; esac
    if [ "$rc" -eq 12 ] || [ "$age" -ge "$warn" ]; then TS_WORKER_STATE=IDLE-HELD; return 0; fi
    case "$marker" in
        READY|BLOCKED) TS_WORKER_STATE=idle ;;
        LIVE|FINDING|RESOLVED|RESUMED|SUCCESSION) TS_WORKER_STATE=live ;;
        *) TS_WORKER_STATE=unknown ;;
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
    TS_LOCK_HELD=""; TS_LOCK_SEEN=false; TS_GONE=0
    ts_read_jira "$key" || { _ts_no_write miss "" get; return 0; }
    [ "$(ts_rank "$TS_J_STATUS")" -ge 0 ] || { _ts_no_write skip D0; return 0; }
    [ "$TS_J_TYPE" != Epic ] || { _ts_no_write skip D0e; return 0; }
    ts_record_read "$key" || { _ts_no_write miss "" record; return 0; }
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    TS_LOCK_SEEN=$(jq -r '.lock_seen // false' <<<"$TS_REC")
    TS_GONE=$(jq -r '.lock_gone_sweeps // 0' <<<"$TS_REC")
    case "$TS_GONE" in ''|*[!0-9]*) TS_GONE=0 ;; esac
    if [ -n "$doc" ]; then
        _ts_worker_state "$doc"
        # A held lock is seen and resets the count; only a sweep counts a gone lock,
        # and only for a lock this station saw held, so a cloud leg never reaches D6.
        if [ "$TS_LOCK_HELD" = yes ]; then
            TS_LOCK_SEEN=true; TS_GONE=0
        elif [ "$TS_LOCK_HELD" = no ] && [ "$TS_LOCK_SEEN" = true ]; then
            [ "${TS_EVENT:-}" != sweep ] || TS_GONE=$((TS_GONE + 1))
            [ "$TS_GONE" -lt 2 ] || TS_WORKER_STATE=wrapped
        fi
    fi
    ts_read_prs "$key" || { _ts_no_write miss "" "$TS_STAGE"; return 0; }
    if [ -n "$TS_PRS" ]; then
        while IFS=$'\t' read -r num head base rd; do
            [ -n "$num" ] || continue
            class=$(ts_pr_class "$num" "$head" "$base") || { _ts_no_write miss "" "${class#!}"; return 0; }
            threads=$(ts_unresolved_threads "$num") || { _ts_no_write miss "" gh; return 0; }
            latch=$(jq -r --arg n "$num" '.prs[$n].red_latch // false' <<<"$TS_REC")
            [ "$class" = red ] && latch=true
            [ "$class" = green ] && latch=false
            # A PR the record closed and GitHub shows open again starts clean.
            [ "$(jq -r --arg n "$num" '.prs[$n].open' <<<"$TS_REC")" != false ] || [ "$class" = red ] || latch=false
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

# ts_worker_comment <KEY> <status> <move> — the WORKER comment shows the owner,
# its state, the open PRs and the status. Reads TS_REC (the record) and the TS_
# outputs of the last derive; sets TS_CID and TS_CHASH. An unchanged class
# (owner, state, PR heads, status) writes nothing; a changed one edits the
# stored comment in place, and a 404 or a missing id posts one new comment.
# rc 1 = the Jira write failed (TS_CID, TS_CHASH unchanged, so the next event retries).
ts_worker_comment() {
    local key=$1 status=$2 move=$3 leg heads hash cid body out rc=1
    TS_CID=$(jq -r '.comment_id // ""' <<<"$TS_REC")
    TS_CHASH=$(jq -r '.comment_hash // ""' <<<"$TS_REC")
    leg=$(jq -r '.leg // ""' <<<"$TS_REC")
    [ -n "$leg$(jq -r '.doc // ""' <<<"$TS_REC")" ] || return 0
    heads=$(printf '%s' "$TS_PR_STATE" | awk -F'\t' 'NF { printf "%s#%s@%s", (n++ ? "," : ""), $1, substr($2, 1, 9) }')
    hash=$(printf '%s|%s|%s|%s' "$leg" "$TS_WORKER_STATE" "$heads" "$status" | cksum | awk '{ print $1 }')
    [ "$hash" != "$TS_CHASH" ] || return 0
    body=$(mktemp "${TMPDIR:-/tmp}/ts-worker-comment.XXXXXX") || return 1
    printf 'WORKER %s (%s)\n\nPRs: %s\n\nJira status: %s\n\nlast move: %s\n' \
        "${leg:-?}" "$TS_WORKER_STATE" "${heads:-none}" "$status" "${move:-none}" > "$body"
    if [ -n "$TS_CID" ]; then
        out=$(ts_jira comment "$key" --edit "$TS_CID" --comment-file "$body" --print-id 2>&1) && rc=0
        case "$out" in *"HTTP 404:"*) [ "$rc" -eq 0 ] || TS_CID="" ;; esac
    fi
    if [ -z "$TS_CID" ]; then
        # The id is the last stdout line; stderr carries the success line.
        out=$(ts_jira comment "$key" --comment-file "$body" --print-id 2>/dev/null) && rc=0
        [ "$rc" -ne 0 ] || TS_CID=$(printf '%s\n' "$out" | tail -n 1 | tr -cd '0-9')
    fi
    rm -f "$body"
    [ "$rc" -eq 0 ] && TS_CHASH=$hash
    return "$rc"
}
