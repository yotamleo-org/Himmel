#!/usr/bin/env bash
# scripts/lib/ticket-status.sh — SOURCED. A ticket's Jira status DERIVED from
# its current ship-flow state, plus the per-ticket worker record and the outcome
# log. The funnel (scripts/handover/chief-kit/worker-jira-status.sh) is the only
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
#     TS_WORKER_STATE  live | idle | IDLE-HELD | parked | wrapped | unknown | none
#     TS_OWNER_DOC the doc of another recorded worker that holds its lock while the
#                  recorded owner has ended; "" otherwise
#   status_event <k=v>...           one JSON row in status-events.jsonl
#   ts_worker_comment <KEY> <status> <move>
#                                   keeps the WORKER Jira comment current: edited in
#                                   place by id, one new post when it has no id or the
#                                   edit 404s, nothing written for an unchanged class.
#                                   Sets TS_CID and TS_CHASH for the record.
#   ts_scan_gate <caller> <bucket>...
#                                   the scan gate (gh-quota.sh ghq_scan_gate, main token) on
#                                   each GitHub bucket the caller spends; rc 0 proceed, rc 75
#                                   paused with its QUOTA-PAUSE or GH-STALL line on stderr. Its
#                                   readings live in HIMMEL_QUOTA_DIR, else <state dir>/quota:
#                                   the same ~/.himmel/state/quota on a station, and a suite's
#                                   own dir when it pins TICKET_STATUS_STATE_DIR.
#
# A live derive (no TS_SNAPSHOT_DIR) that the gate pauses reads no PR: no-write + miss
# stage=gh, so the funnel warns and moves nothing.
#
# A caller that holds one batched snapshot sets TS_SNAPSHOT_DIR (the status sweep,
# chief-kit/status-sweep.sh): the readers then take Jira, the open PRs, their
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
#   D5d as D5c, but the merged PR's remainder names its owner (a deferred -> KEY line, or a Remaining:
#       line with `owner: KEY` or an arrow to KEY, or naming a chief step): To Do, the owner in TS_D5D_OWNER
#   D5c no PR, the latest merge row contract=no  In Progress (a partial: work remains)
#       or, a wrapped owner and no merge row at all, a merged PR whose first [KEY] is the
#       ticket (TS_STAGE=merged-no-row, TS_MERGED_PR); an unreadable merged list or merge-row
#       filter is no-write + miss
#   D6  no PR, the owner WRAPPED or HALTED       To Do (the resume state)
#       and no other recorded worker holds its lock
#   D6n as D6, but the ticket is In Progress and the owner's brief says Completes ticket: no
#       above ## Results: derived equals current, so no move
#   D7  no PR, never owned                       no-write
#
# Env: TICKET_STATUS_STATE_DIR (default ~/.himmel/state), WORKER_SESSION_JIRA_CLI (the Jira
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
# shellcheck source=scripts/lib/status-marker.sh
# shellcheck disable=SC1091
. "$_TS_LIB_DIR/status-marker.sh"

ts_state_dir() { printf '%s' "${TICKET_STATUS_STATE_DIR:-${HOME:-/tmp}/.himmel/state}"; }

ts_scan_gate() {
    local who="$1" bucket line rc
    shift
    if ! declare -F ghq_scan_gate >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        . "$_TS_LIB_DIR/gh-quota.sh"
    fi
    for bucket in "$@"; do
        rc=0
        line=$(HIMMEL_QUOTA_DIR="${HIMMEL_QUOTA_DIR:-$(ts_state_dir)/quota}" ghq_scan_gate main "$bucket" "$who") || rc=$?
        [ "$rc" -eq 75 ] || continue
        printf '%s\n' "$line" >&2
        return 75
    done
    return 0
}

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
    local cli="${WORKER_SESSION_JIRA_CLI:-}" common
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

# ts_marker_newest <doc> — the newest Results marker in a worker doc.
ts_marker_newest() {
    local line newest=""
    local succession_re='^- [0-9]{1,2}:[0-9]{2} SUCCESSION([^A-Za-z0-9-]|$)'
    [ -r "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        if status_marker_parse "$line" >/dev/null; then
            newest=${BASH_REMATCH[3]}
            if status_marker_is_parked "$newest"; then newest=PARKED-USAGE; fi
        elif [[ "$line" =~ $succession_re ]]; then
            newest=SUCCESSION
        fi
    done < <(grep '^-' "$1" 2>/dev/null)
    printf '%s\n' "$newest"
}

_ts_epoch_of_iso() {
    date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# ts_now — the clock: TICKET_STATUS_NOW (epoch) when it is digits, else the wall clock.
ts_now() {
    case "${TICKET_STATUS_NOW:-}" in
        ''|*[!0-9]*) date -u +%s ;;
        *) printf '%s\n' "$TICKET_STATUS_NOW" ;;
    esac
}

# _ts_date_ok <YYYY-MM-DD> — rc 0 when it is a real calendar day: parsed, formatted back, and equal to the input.
# Run on the bare date, before any time of day is added, because the ISO parse alone rolls 2026-02-30 over on BSD.
_ts_date_ok() {
    local e
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    e=$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$1" +%s 2>/dev/null) || return 1 # swallow-ok: the BSD form follows
    [ "$(date -u -d "@$e" +%Y-%m-%d 2>/dev/null || date -u -r "$e" +%Y-%m-%d 2>/dev/null)" = "$1" ] # swallow-ok: the BSD form follows
}

# _ts_await_secs <ENV NAME> <default secs> <cap secs> — TS_AWAIT_SECS is the env value as seconds, else the default;
# rc 1 when the variable is set and is not <n>h or <n>d (n 1 to 9999) within the cap.
_ts_await_secs() {
    local v n
    TS_AWAIT_SECS=$2
    v="${!1:-}"
    [ -n "$v" ] || return 0
    if [[ "$v" =~ ^[1-9][0-9]{0,3}[hd]$ ]]; then
        n=${v%[hd]}
        case "$v" in *h) n=$((n * 3600)) ;; *) n=$((n * 86400)) ;; esac
        if [ "$n" -le "$3" ]; then TS_AWAIT_SECS=$n; return 0; fi
    fi
    return 1
}

# ts_await_env_bad — the name of each TICKET_STATUS_AWAIT_* variable that is set and unusable (never its value).
ts_await_env_bad() {
    _ts_await_secs TICKET_STATUS_AWAIT_MAX 1209600 1209600 || echo TICKET_STATUS_AWAIT_MAX
    _ts_await_secs TICKET_STATUS_AWAIT_TTL_CHIEF 86400 1000000000 || echo TICKET_STATUS_AWAIT_TTL_CHIEF
    _ts_await_secs TICKET_STATUS_AWAIT_TTL_OPERATOR 259200 1000000000 || echo TICKET_STATUS_AWAIT_TTL_OPERATOR
    _ts_await_secs TICKET_STATUS_AWAIT_TTL_OTHER 259200 1000000000 || echo TICKET_STATUS_AWAIT_TTL_OTHER
    _ts_await_secs TICKET_STATUS_AWAIT_TTL_RESUME 21600 1000000000 || echo TICKET_STATUS_AWAIT_TTL_RESUME
    return 0
}

# ts_await_due <since ISO> <chief|operator|resume|<other owner>> [<YYYY-MM-DD>] — the ISO time a wait ends: the date's
# 23:59:59Z, else since plus the owner's TTL, never past since plus TICKET_STATUS_AWAIT_MAX (default 14 d).
# rc 1 and nothing printed when since does not parse or the date is not a real day.
ts_await_due() {
    local since=$1 who=$2 day=${3:-} se due max ttl
    se=$(_ts_epoch_of_iso "$since") || return 1
    _ts_await_secs TICKET_STATUS_AWAIT_MAX 1209600 1209600; max=$TS_AWAIT_SECS
    case "$who" in
        chief) _ts_await_secs TICKET_STATUS_AWAIT_TTL_CHIEF 86400 1000000000 ;;
        resume) _ts_await_secs TICKET_STATUS_AWAIT_TTL_RESUME 21600 1000000000 ;;
        operator) _ts_await_secs TICKET_STATUS_AWAIT_TTL_OPERATOR 259200 1000000000 ;;
        *) _ts_await_secs TICKET_STATUS_AWAIT_TTL_OTHER 259200 1000000000 ;;
    esac
    ttl=$TS_AWAIT_SECS
    if [ -n "$day" ]; then
        _ts_date_ok "$day" || return 1
        due=$(TZ=UTC LC_ALL=C _ts_epoch_of_iso "${day}T23:59:59Z") || return 1
    else
        due=$((se + ttl))
    fi
    [ "$due" -le $((se + max)) ] || due=$((se + max))
    TZ=UTC LC_ALL=C date -u -d "@$due" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC LC_ALL=C date -u -r "$due" +%Y-%m-%dT%H:%M:%SZ # swallow-ok: the BSD form follows
}

# ts_worker_state <doc> — live | idle | IDLE-HELD | parked | wrapped | unknown, from the
# doc's newest marker and its queue lock. Only an end marker is positive end
# evidence: a free lock with no end marker (a hand-off, a cloud or
# other-station worker) is unknown, which still counts as an owner.
ts_worker_state() {
    _ts_worker_state "$1"
    echo "$TS_WORKER_STATE"
}

# _ts_worker_state <doc> — ts_worker_state without the subshell: sets
# TS_WORKER_STATE and TS_LOCK_HELD (yes | no | "" when the lock was not read) and TS_LOCK_DEAD
# (yes: the lock answered rc 12 with status STALE-DEAD; no: rc 12 with any other status; "" otherwise).
_ts_worker_state() {
    local marker out rc hb hb_epoch age=0 warn
    TS_LOCK_HELD="" TS_LOCK_DEAD=""
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
        0) TS_LOCK_HELD=no ;;
        *) TS_WORKER_STATE=unknown; return 0 ;;
    esac
    if [ "$rc" -eq 12 ]; then
        if grep -q '^status: STALE-DEAD' <<<"$out"; then TS_LOCK_DEAD=yes; else TS_LOCK_DEAD=no; fi
    fi
    if status_marker_is_parked "$marker"; then TS_WORKER_STATE=parked; return 0; fi
    if [ "$TS_LOCK_HELD" = no ]; then TS_WORKER_STATE=unknown; return 0; fi
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

# ts_merge_rows [<log>] — the status-events log (stdin without a file) minus every pre-merge row whose PR did
# not merge; see merge-rows-effective.py. Every reader of the merge rows reads this.
ts_merge_rows() {
    python3 -I "$_TS_LIB_DIR/merge-rows-effective.py" "$@"
}

# ts_owner_rows — stdin: ts_merge_rows output. Prints the rows ts_owner reads, one per line, fields split by US (\037):
#   hold  KEY event ts owner until reason    a hold or hold-release row that moved
#   merge KEY remainder owed owed_due ts     the key's newest contract-carrying merge row, when its contract is no
#   park  KEY rule since                     the key's park start for D6n and for D5c: the first row of the rule at or after
#                                            its newest anchor (a moved row that is not a hold, a contract-carrying merge row,
#                                            or an event=live row that is neither skip nor disabled); with no anchor, the first
#                                            row of the rule in the key's log
# Every value from the log is re-checked on the way out: a field that fails its pattern is empty.
ts_owner_rows() {
    jq -Rrs 'def ok($re): if type == "string" and test($re) then . else "" end;
        def tsre: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z";
        def whore: "\\A(chief|operator|[a-z][a-z0-9-]{0,31})\\z";
        def datere: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z";
        [split("\n")[] | fromjson? | select(type == "object" and (.key | type) == "string" and (.key | test("^[A-Za-z][A-Za-z0-9]*-[0-9]+$")))] as $all
        | ($all[] | select((.event == "hold" or .event == "hold-release") and .result == "moved")
            | ["hold", .key, .event, (.ts | ok(tsre)), (.owner | ok(whore)), (.until | ok(datere)),
                ((.reason // "") | if type == "string" then gsub("[|\t\r\n\u001f]"; "") else "" end)] | join("\u001f")),
          ([$all[] | select(.event == "merge" and has("contract") and .contract != "")] | group_by(.key)[] | select(last.contract == "no") | last as $l
            | ["merge", .[0].key, ($l.remainder | ok("\\A[a-z-]{1,20}\\z")), (if $l.remainder == "owed" then ($l.owed | ok(whore)) else "" end),
                ($l.owed_due | ok(datere)), ($l.ts | ok(tsre))] | join("\u001f")),
          ([$all[] | select((.ts | type) == "string")] | group_by(.key)[] | . as $g
            | ([range(0; length) | select($g[.] | (.event == "merge" and has("contract") and .contract != "") or (.result == "moved" and .event != "hold" and .event != "hold-release") or (.event == "live" and .result != "skip" and .result != "disabled"))] | last // 0) as $a
            | ("D6n", "D5c") as $r
            | ([$g[$a:][] | select(.rule == $r)] | first) as $f
            | select($f != null)
            | ["park", $g[0].key, $r, ($f.ts | ok(tsre))] | join("\u001f"))' 2>/dev/null # swallow-ok: unreadable rows are no rows, so no wait is named
}

# ts_park_since_rows <log> — key<TAB>rule<TAB>since for each key's D6n and D5c park start, from one pass over ts_merge_rows.
ts_park_since_rows() {
    ts_merge_rows "$1" 2>/dev/null | ts_owner_rows | awk -F'\037' '$1 == "park" && $4 != "" { print $2 "\t" $3 "\t" $4 }' # swallow-ok: an unreadable log has no park start
}

# ts_owner <KEY> — who owns the ticket's next step; run after ts_derive <KEY> on the same key. Prints one line and
# sets TS_OWNER_ANS to it:
#   worker<TAB><state>                                       a worker owns it (HELD-STALE and a never-seen lock included)
#   awaiting<TAB>who<TAB>since<TAB>due<TAB>source<TAB>what   a named wait; source is hold, owed, d6n or resume
#   none                                                     nobody does
# No worker: TS_WORKER_STATE none or wrapped, or IDLE-HELD or parked over a lock proven dead (TS_LOCK_DEAD=yes). With no
# worker the newest of the hold (only with TS_OWNER_HELD=yes), the owed merge row and the park start (D6n for rule D6n,
# D5c for rule D5c when the newest merge row's remainder is remaining) is the wait; on a tie hold, then owed, then park.
# TS_OWNER_HOLD_VALID is yes or no after a call with TS_OWNER_HELD=yes. The rows come from the TS_OWNER_ROWS file
# (ts_owner_rows output, pre-read once) when it is set, else from the log.
ts_owner() {
    local key=$1 rows hold merge log tw who since due src what
    local h_ev="" h_since="" h_who="" h_until="" h_reason="" m_rem="" o_who="" o_due="" o_ts="" p_rule="" p_src="" p_since=""
    local h_sec=-1 o_sec=-1 p_sec=-1
    TS_OWNER_ANS=none TS_OWNER_HOLD_VALID=""
    case "${TS_WORKER_STATE:-none}" in
        none|wrapped) ;;
        IDLE-HELD|parked)
            if [ "${TS_LOCK_DEAD:-}" != yes ]; then
                TS_OWNER_ANS=$(printf 'worker\t%s' "$TS_WORKER_STATE"); printf '%s\n' "$TS_OWNER_ANS"; return 0
            fi ;;
        *) TS_OWNER_ANS=$(printf 'worker\t%s' "$TS_WORKER_STATE"); printf '%s\n' "$TS_OWNER_ANS"; return 0 ;;
    esac
    if [ -n "${TS_OWNER_ROWS:-}" ]; then
        rows=$(awk -F'\037' -v k="$key" '$2 == k' "$TS_OWNER_ROWS" 2>/dev/null) # swallow-ok: an unreadable rows file names no wait
    else
        rows=""
        log="$(ts_state_dir)/status-events.jsonl"
        if [ -r "$log" ]; then rows=$(ts_merge_rows "$log" 2>/dev/null | ts_owner_rows | awk -F'\037' -v k="$key" '$2 == k'); fi
    fi
    if [ "${TS_OWNER_HELD:-no}" = yes ]; then
        TS_OWNER_HOLD_VALID=no
        hold=$(awk -F'\037' '$1 == "hold" { l = $0 } END { if (l != "") print l }' <<<"$rows")
        if [ -n "$hold" ]; then
            IFS=$'\037' read -r _ _ h_ev h_since h_who h_until h_reason <<<"$hold"
            if [ "$h_ev" = hold ] && [ -n "$h_who" ] && [ -n "$h_since" ] && h_sec=$(_ts_epoch_of_iso "$h_since"); then
                TS_OWNER_HOLD_VALID=yes
                _ts_date_ok "$h_until" || h_until=""
            else
                h_sec=-1
            fi
        fi
    fi
    merge=$(awk -F'\037' '$1 == "merge" { l = $0 } END { if (l != "") print l }' <<<"$rows")
    if [ -n "$merge" ]; then
        IFS=$'\037' read -r _ _ m_rem o_who o_due o_ts <<<"$merge"
        if [ "$m_rem" = owed ] && [ -n "$o_who" ] && [ -n "$o_ts" ] && _ts_date_ok "$o_due" \
            && o_sec=$(_ts_epoch_of_iso "$o_ts") && _ts_epoch_of_iso "${o_due}T23:59:59Z" >/dev/null; then
            :
        else
            o_sec=-1
        fi
    fi
    case "${TS_RULE:-}" in
        D6n) p_rule=D6n p_src=d6n ;;
        D5c) [ "$m_rem" != remaining ] || { p_rule=D5c; p_src=resume; } ;;
    esac
    if [ -n "$p_rule" ]; then
        p_since=$(awk -F'\037' -v r="$p_rule" '$1 == "park" && $3 == r { print $4; exit }' <<<"$rows")
        if [[ "$p_since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && p_sec=$(_ts_epoch_of_iso "$p_since"); then
            :
        else
            p_sec=-1
        fi
    fi
    if [ "$h_sec" -ge 0 ] && [ "$h_sec" -ge "$o_sec" ] && [ "$h_sec" -ge "$p_sec" ]; then
        who=$h_who since=$h_since src=hold what=$h_reason
        tw=$who; [ "$tw" != resume ] || tw=other
        due=$(ts_await_due "$since" "$tw" "$h_until") || due=""
    elif [ "$o_sec" -ge 0 ] && [ "$o_sec" -ge "$p_sec" ]; then
        who=$o_who since=$o_ts src=owed what="the partial merge left a step owed by $o_who"
        tw=$who; [ "$tw" != resume ] || tw=other
        due=$(ts_await_due "$since" "$tw" "$o_due") || due=""
    elif [ "$p_sec" -ge 0 ]; then
        who=chief since=$p_since src=$p_src
        if [ "$src" = d6n ]; then
            what="the worker wrapped and the brief says Completes ticket: no, so the chief decides the remainder"
            due=$(ts_await_due "$since" chief) || due=""
        else
            what="the partial merge left a remainder for a RESUME worker"
            due=$(ts_await_due "$since" resume) || due=""
        fi
    else
        printf '%s\n' "$TS_OWNER_ANS"
        return 0
    fi
    if [ -z "$due" ]; then
        printf '%s\n' "$TS_OWNER_ANS"
        return 0
    fi
    what=$(printf '%s' "$what" | tr -d '|\t\r\n')
    TS_OWNER_ANS=$(printf 'awaiting\t%s\t%s\t%s\t%s\t%s' "$who" "$since" "$due" "$src" "$what")
    printf '%s\n' "$TS_OWNER_ANS"
}

# ts_partial_merge <KEY> — rc 0 when the key's latest merge row that carries a contract is completes=no
# (a funnel row written under event merge by an older worker-jira-status.sh has none).
# rc 0 = partial, 1 = none, 2 = the filter failed (not read as "none").
ts_partial_merge() {
    local log rc=0
    log="$(ts_state_dir)/status-events.jsonl"
    [ -r "$log" ] || return 1
    _ts_merge_last "$log" "$1" || rc=$?
    [ "$rc" -ne 2 ] || return 2
    [ "$rc" -eq 0 ] && [ "$TS_ML_CONTRACT" = no ]
}

# _ts_merge_last <log> <KEY> — the key's latest merge row that carries a contract: TS_ML_CONTRACT and TS_ML_RESULT.
# rc 0 = found, 1 = none, 2 = the filter failed (not read as "none"). The filter (merge-rows-effective.py, which may
# ask GitHub) and the jq over its rows run once per state of the log, not once per key and question: the answer is
# kept as one `key<TAB>contract<TAB>result` line per row, and a log that grew or moved since is read again
# (the traced drift pass spent 31 s on whole-log reads). A call inside `$( )` keeps no cache.
_TS_MI="" _TS_MI_SIG=""
_ts_merge_last() {
    local sig line rows
    TS_ML_CONTRACT="" TS_ML_RESULT="" TS_ML_PR="" TS_ML_REPO=""
    sig="$1|$_TS_LIB_DIR|$(stat -c '%s:%y:%i' "$1" 2>/dev/null || stat -f '%z:%m:%i' "$1" 2>/dev/null)" # gnu-ok: the BSD form follows; size, mtime and inode, so a replaced log of the same size is read again (GNU stat gives the mtime to the nanosecond, BSD stat to the second: there a same-size rewrite in place inside one second is not seen)
    if [ "$_TS_MI_SIG" != "$sig" ]; then
        _TS_MI_SIG=""
        rows=$(ts_merge_rows "$1" 2>/dev/null) || return 2
        _TS_MI=$(jq -R -r 'fromjson? | select(type == "object" and .event == "merge" and has("contract")) | [.key, .contract, (.result // ""), (.pr // "" | tostring), (.repo // "")] | @tsv' <<<"$rows" 2>/dev/null) || return 2
        _TS_MI_SIG=$sig
    fi
    line=$(awk -F'\t' -v k="$2" '$1 == k { l = $0 } END { if (l != "") print l }' <<<"$_TS_MI")
    [ -n "$line" ] || return 1
    TS_ML_CONTRACT=$(cut -f2 <<<"$line")
    TS_ML_RESULT=$(cut -f3 <<<"$line")
    TS_ML_PR=$(cut -f4 <<<"$line")
    TS_ML_REPO=$(cut -f5 <<<"$line")
}

# ts_has_merge_row <KEY> — rc 0 when the key has any merge row that carries a contract
# (merge-on-green.sh and pr-merge.sh write one per merge). rc 1 = none, 2 = the filter failed.
ts_has_merge_row() {
    local log rc=0
    log="$(ts_state_dir)/status-events.jsonl"
    [ -r "$log" ] || return 1
    _ts_merge_last "$log" "$1" || rc=$?
    return "$rc"
}

# ts_merged_no_row <KEY> — rc 0 when a PR whose title's first [KEY] is <KEY> merged and no merge row
# records it (the caller has checked ts_has_merge_row): TS_MERGED_PR = its number. The funnel logs
# the find as stage=merged-no-row, and a logged find answers without a gh call, so the sweep's
# snapshot (open PRs only) needs no merged-PR read. rc 0 = found, 1 = none (or a snapshot
# derive with nothing logged), 2 = the merged list is unreadable (no-write + miss, never a move).
ts_merged_no_row() {
    local log json rows num title k
    TS_MERGED_PR=""
    log="$(ts_state_dir)/status-events.jsonl"
    if [ -r "$log" ]; then
        num=$(jq -Rr --arg k "$1" 'fromjson? | select(.key == $k and .stage == "merged-no-row") | .merged_pr // empty' "$log" 2>/dev/null | tail -n 1)
        case "$num" in ''|*[!0-9]*) ;; *) TS_MERGED_PR=$num; return 0 ;; esac
    fi
    [ -z "${TS_SNAPSHOT_DIR:-}" ] || return 1
    json=$(gh pr list --state merged --search "$1 in:title" --limit "${TICKET_STATUS_PR_LIMIT:-50}" \
        --json number,title 2>/dev/null) || return 2
    rows=$(jq -r 'sort_by(.number) | reverse | .[] | [.number, .title] | @tsv' <<<"$json" 2>/dev/null) || return 2
    while IFS=$'\t' read -r num title; do
        [ -n "$num" ] || continue
        k=$(ticket_key_from_title "$title") || continue
        [ "$k" = "$1" ] || continue
        TS_MERGED_PR=$num
        return 0
    done <<<"$rows"
    return 1
}

# ts_done_pending <KEY> — the key's latest merge row with a contract is completes=yes and its
# Done did not land (result neither moved nor noop).
# rc 0 = pending, 1 = none, 2 = the log is unreadable.
ts_done_pending() {
    local log rc=0
    log="$(ts_state_dir)/status-events.jsonl"
    [ -e "$log" ] || return 1
    [ -r "$log" ] || return 2
    _ts_merge_last "$log" "$1" || rc=$?
    [ "$rc" -ne 2 ] || return 2
    [ "$rc" -eq 0 ] && [ "$TS_ML_CONTRACT" = yes ] && [ "$TS_ML_RESULT" != moved ] && [ "$TS_ML_RESULT" != noop ]
}

_ts_no_write() { TS_DERIVED="no-write"; TS_RESULT="$1"; TS_RULE="$2"; TS_STAGE="${3:-}"; }

_ts_remainder_owner() {
    local keys
    keys=$(printf '%s\n' "$2" | grep -oE '([Oo]wner:[[:space:]]*|→[[:space:]]*|->[[:space:]]*)[A-Z][A-Z0-9]*-[0-9]+([^[:alnum:]-]|$)' | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | grep -vxF "$1" | sort -u | paste -sd, - | sed 's/,/, /g') || keys=""  # swallow-ok: no key in the text is the empty answer
    if [ -n "$keys" ]; then printf '%s' "$keys"; return 0; fi
    if grep -qiE 'chief[ -](step|run)' <<<"$2"; then printf 'chief step'; return 0; fi
    return 1
}

_ts_d5d() {
    local key=$1 mpr=$2 repo=${3:-} log body ans kind rest owner
    TS_D5D_OWNER=""
    case "$mpr" in ''|*[!0-9]*) return 1 ;; esac
    log="$(ts_state_dir)/status-events.jsonl"
    if [ -r "$log" ]; then
        owner=$(jq -Rr --arg k "$key" --arg p "$mpr" 'fromjson? | select(.key == $k and .rule == "D5d" and .merged_pr == $p) | .owner // empty' "$log" 2>/dev/null | tail -n 1)  # swallow-ok: an unreadable log is no logged answer
        if [ -n "$owner" ]; then TS_D5D_OWNER=$owner TS_MERGED_PR=$mpr; return 0; fi
    fi
    [ -z "${TS_SNAPSHOT_DIR:-}" ] || return 1
    body=$(gh pr view "$mpr" ${repo:+--repo "$repo"} --json body -q .body 2>/dev/null) || return 1
    ans=$(printf '%s' "$body" | python3 -I "$_TS_LIB_DIR/pr_remainder.py" "$key" 2>/dev/null) || return 1
    kind=${ans%%$'\t'*}
    case "$kind" in
        handed-off) rest=${ans#*$'\t'}; owner=${rest%%$'\t'*} ;;
        remaining) rest=$(grep -iE '^[[:space:]]*remaining:' <<<"$body") || return 1; owner=$(_ts_remainder_owner "$key" "$rest") || return 1 ;;
        *) return 1 ;;
    esac
    [ -n "$owner" ] || return 1
    TS_D5D_OWNER=$owner TS_MERGED_PR=$mpr
}

# _ts_brief_completes_no <doc> — rc 0 when the owner's brief (the doc, else the record's resume_brief) says
# `> **Completes ticket:** no` above `## Results`. Same read as merge-on-green.sh; a missing or unreadable
# brief or flag line is rc 1, never read as "no".
_ts_brief_completes_no() {
    local brief=$1 flag
    [ -r "$brief" ] || brief=$(jq -r '.resume_brief // ""' <<<"$TS_REC")
    [ -n "$brief" ] && [ -r "$brief" ] || return 1
    flag=$(sed -nE '/^## Results/q; s/^> \*\*Completes ticket:\*\* (yes|no)[[:space:]]*$/\1/p' "$brief" | sort | head -n 1)
    [ "$flag" = no ]
}

# _ts_derive_d6 <doc> — the wrapped worker with nothing else to hold the ticket: To Do (D6), except that
# an In Progress ticket whose brief says Completes ticket: no stays where it is (D6n, a noop).
_ts_derive_d6() {
    if [ "$TS_J_STATUS" = "In Progress" ] && _ts_brief_completes_no "$1"; then
        TS_DERIVED="In Progress"; TS_RULE=D6n
    else
        TS_DERIVED="To Do"; TS_RULE=D6
    fi
}

ts_derive() {
    local key="$1" num head base rd class latch threads s rule best=9 r doc rc other owner=""
    TS_DERIVED=""; TS_RULE=""; TS_RESULT=""; TS_STAGE=""; TS_PR_STATE=""; TS_HEADS=""; TS_WORKER_STATE=none; TS_MERGED_PR=""; TS_D5D_OWNER=""
    TS_LOCK_HELD=""; TS_LOCK_DEAD=""; TS_LOCK_SEEN=false; TS_GONE=0; TS_OWNER_DOC=""
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
        # and only for a lock this station saw held, so a cloud worker never reaches D6.
        if [ "$TS_LOCK_HELD" = yes ]; then
            TS_LOCK_SEEN=true; TS_GONE=0
        elif [ "$TS_LOCK_HELD" = no ] && [ "$TS_LOCK_SEEN" = true ]; then
            [ "${TS_EVENT:-}" != sweep ] || TS_GONE=$((TS_GONE + 1))
            [ "$TS_GONE" -lt 2 ] || TS_WORKER_STATE=wrapped
        fi
    fi
    # A second worker on the key that still holds its lock keeps the ticket owned, so
    # one worker's wrap never demotes a ticket another worker is working.
    if [ "$TS_WORKER_STATE" = wrapped ]; then
        while IFS= read -r other; do
            [ -n "$other" ] && [ "$other" != "$doc" ] || continue
            _ts_worker_state "$other"
            [ "$TS_LOCK_HELD" != yes ] || { owner=$TS_WORKER_STATE; TS_OWNER_DOC=$other; break; }
        done <<<"$(jq -r '(.docs // [])[]' <<<"$TS_REC")"
        TS_WORKER_STATE=${owner:-wrapped}
    fi
    if [ -z "${TS_SNAPSHOT_DIR:-}" ] && ! ts_scan_gate ticket-status graphql core; then _ts_no_write miss "" gh; return 0; fi
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
    if [ -z "$doc" ]; then
        _ts_no_write skip D7
        return 0
    fi
    if [ "$TS_WORKER_STATE" != wrapped ]; then TS_DERIVED="In Progress"; TS_RULE=D5
    else
        rc=0; ts_partial_merge "$key" || rc=$?
        if [ "$rc" -eq 2 ]; then _ts_no_write miss "" log
        elif [ "$rc" -eq 0 ]; then
            if _ts_d5d "$key" "$TS_ML_PR" "$TS_ML_REPO"; then TS_DERIVED="To Do"; TS_RULE=D5d
            else TS_DERIVED="In Progress"; TS_RULE=D5c
            fi
        else
            # No partial row: a ticket with no merge row at all may still have shipped a PR merged
            # outside merge-on-green; that is a partial too.
            rc=0; ts_has_merge_row "$key" || rc=$?
            if [ "$rc" -eq 1 ]; then
                rc=0; ts_merged_no_row "$key" || rc=$?
                if [ "$rc" -eq 0 ]; then
                    if _ts_d5d "$key" "$TS_MERGED_PR"; then TS_DERIVED="To Do"; TS_RULE=D5d; TS_STAGE=merged-no-row
                    else TS_DERIVED="In Progress"; TS_RULE=D5c; TS_STAGE=merged-no-row
                    fi
                elif [ "$rc" -eq 2 ]; then _ts_no_write miss "" gh
                else _ts_derive_d6 "$doc"
                fi
            elif [ "$rc" -eq 2 ]; then _ts_no_write miss "" log
            else _ts_derive_d6 "$doc"
            fi
        fi
    fi
}

# ts_worker_comment <KEY> <status> <move> — the WORKER comment shows the owner,
# its state, the open PRs and the status. Reads TS_REC (the record) and the TS_
# outputs of the last derive; sets TS_CID and TS_CHASH. An unchanged class
# (owner, state, PR heads, status) writes nothing; a changed one edits the
# stored comment in place, and a 404 or a missing id posts one new comment.
# rc 1 = the Jira write failed (TS_CID, TS_CHASH unchanged, so the next event retries).
ts_worker_comment() {
    local key=$1 status=$2 move=$3 worker heads hash cid body out rc=1
    TS_CID=$(jq -r '.comment_id // ""' <<<"$TS_REC")
    TS_CHASH=$(jq -r '.comment_hash // ""' <<<"$TS_REC")
    worker=$(jq -r '.leg // ""' <<<"$TS_REC")
    [ -n "$worker$(jq -r '.doc // ""' <<<"$TS_REC")" ] || return 0
    heads=$(printf '%s' "$TS_PR_STATE" | awk -F'\t' 'NF { printf "%s#%s@%s", (n++ ? "," : ""), $1, substr($2, 1, 9) }')
    hash=$(printf '%s|%s|%s|%s%s' "$worker" "$TS_WORKER_STATE" "$heads" "$status" "${TS_D5D_OWNER:+|owner:$TS_D5D_OWNER}" | cksum | awk '{ print $1 }')
    [ "$hash" != "$TS_CHASH" ] || return 0
    body=$(mktemp "${TMPDIR:-/tmp}/ts-worker-comment.XXXXXX") || return 1
    printf 'WORKER %s (%s)\n\nPRs: %s\n\nJira status: %s\n\nlast move: %s\n' \
        "${worker:-?}" "$TS_WORKER_STATE" "${heads:-none}" "$status" "${move:-none}" > "$body"
    [ -z "${TS_D5D_OWNER:-}" ] || printf '\nRemainder owner: %s\n' "$TS_D5D_OWNER" >> "$body"
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
