#!/usr/bin/env bash
# scripts/handover/console-kit/status-sweep.sh - the drift net under the event
# funnel. An event moves a ticket's Jira status at once; this sweep catches what
# no event announced: a PR closed or reopened in the UI, a worker whose lock
# vanished. It never writes a status or the worker record itself.
#
# Usage: status-sweep.sh [--repo <owner/repo>]   (default this checkout's origin)
#
# A ticket whose recorded open PR is not in that repo (a fork PR) is left as it is,
# never moved back to In Progress or To Do.
#
# One batched snapshot per sweep (one `gh pr list` with the check rollup, one
# GraphQL read of the review threads and check apps, one JQL search); the
# per-key dry derive (scripts/lib/ticket-status.sh, TS_SNAPSHOT_DIR) then costs
# no further call. A key goes to the funnel (leg-jira-status.sh --event sweep)
# only when its dry derive differs from Jira, or its liveness class or lock
# counters changed. A failed, partial or saturated read makes the sweep
# `unknown`: nothing moves and one `sweep miss` row is logged.
#
# A sweep stops at TICKET_STATUS_SWEEP_BUDGET seconds (default 60) and saves the
# first unserved key in <state>/sweep/cursor; the next sweep resumes there, and a
# fully served sweep clears it. Output ends `wake=1` only when the set of
# (result, stage, class) failures is new since the last sweep, so a caller waking
# on it is not woken twice for one standing problem.
#
# Env: TICKET_STATUS_STATE_DIR, TICKET_STATUS_SWEEP_BUDGET, TICKET_STATUS_SWEEP_GRACE
# (hard cap = budget + grace, default 60), JIRA_PROJECT_KEY (default HIMMEL); the
# rest is read by the lib.
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
# shellcheck disable=SC2034  # TS_SNAPSHOT_DIR and TS_EVENT are read by the sourced lib
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
command -v jq >/dev/null 2>&1 || { echo "status-sweep: jq not found (continuing; nothing swept)" >&2; exit 0; }
# shellcheck source=../../lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/ticket-status.sh"
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"

export LC_ALL=C
# The sweep reads one repo: every gh call (this script's and the lib's) resolves
# it from GH_REPO, so a cwd that is a fork checkout cannot change what is swept.
REPO=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || { echo "status-sweep: --repo needs a value" >&2; exit 2; }; REPO="$2"; shift 2 ;;
        *) echo "usage: status-sweep.sh [--repo <owner/repo>]" >&2; exit 2 ;;
    esac
done
# shellcheck source=../../lib/env-value.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/env-value.sh"
# The default is this checkout's origin (not the cwd's), or the operator's config.
# shellcheck disable=SC2329  # called by name through env_value
origin_slug() { git -C "$HERE" remote get-url origin | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##'; }
[ -n "$REPO" ] || REPO=$(env_value HIMMEL_REPO origin_slug) || { echo "status-sweep: cannot resolve the himmel repo; pass --repo <owner/repo>" >&2; exit 2; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "status-sweep: '$REPO' is not an owner/repo" >&2; exit 2; }
export GH_REPO="$REPO"
BUDGET="${TICKET_STATUS_SWEEP_BUDGET:-60}"
case "$BUDGET" in ''|*[!0-9]*) BUDGET=60 ;; esac
STATE="$(ts_state_dir)"
SDIR="$STATE/sweep"
LOG="$STATE/status-events.jsonl"
mkdir -p "$SDIR" 2>/dev/null || { echo "status-sweep: cannot create $SDIR (continuing; nothing swept)" >&2; exit 0; }

# The whole sweep runs in a re-exec under a hard cap of the budget plus
# TICKET_STATUS_SWEEP_GRACE (default 60: one funnel run), so a hung Jira or gh
# call cannot hold the sweep lock; a cut-off sweep logs `sweep miss timeout` and
# wakes the caller once.
GRACE="${TICKET_STATUS_SWEEP_GRACE:-60}"
case "$GRACE" in ''|*[!0-9]*) GRACE=60 ;; esac
if [ -z "${TICKET_STATUS_SWEEP_IN_BUDGET:-}" ] && [ -n "$_TIMEOUT_BIN" ]; then
    rc=0
    TICKET_STATUS_SWEEP_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 $((BUDGET + GRACE)) bash "${BASH_SOURCE[0]}" --repo "$REPO" || rc=$?
    case "$rc" in
        124|137)
            status_event event=sweep key=- result=miss stage=timeout
            prev=$(cat "$SDIR/wake-sig" 2>/dev/null) # swallow-ok: no prior signature reads empty, so the first timeout wakes
            wake=0
            [ "$prev" = timeout ] || { printf 'timeout\n' > "$SDIR/wake-sig"; wake=1; }
            echo "status-sweep: unknown (timeout after $((BUDGET + GRACE))s) keys=0 sig=timeout wake=$wake" ;;
    esac
    exit 0
fi

# ponytail: no flock binary (stock macOS) runs unlocked, so two sweeps can
# overlap; upgrade path = a mkdir lock.
if command -v flock >/dev/null 2>&1; then
    exec 8>>"$SDIR/lock"
    flock -n 8 || { echo "status-sweep: busy (another sweep holds the lock) wake=0"; exit 0; } # prim-ok: a non-blocking single-instance guard, not a wait
fi

snap="$(tmpdir)" || { echo "status-sweep: mktemp failed (continuing; nothing swept)" >&2; exit 0; }
trap 'rm -rf "$snap"' EXIT
T0=$SECONDS

# bounded <seconds> <cmd...> - the command under the timeout binary when there is one.
bounded() {
    local s=$1
    shift
    if [ -n "$_TIMEOUT_BIN" ]; then "$_TIMEOUT_BIN" -k 2 "$s" "$@"; else "$@"; fi
}

# outside_repo <KEY> - rc 0 when a PR the record holds open is not provably this
# repo's: with no open PR in the snapshot, D5/D6 would read a fork PR as gone.
# A PR this repo shows with the key in its title is genuinely closed.
outside_repo() {
    local n t
    for n in $(jq -r '(.prs // {}) | to_entries[] | select(.value.open != false) | .key' <<<"$TS_REC"); do
        t=$(bounded 30 gh pr view "$n" --json title -q .title 2>/dev/null) || return 0 # swallow-ok: an unreadable PR is not proof it is this repo's, so the key is left unchanged
        [ "$(ticket_key_from_title "$t")" = "$1" ] || return 0
    done
    return 1
}

# done_record_stale <KEY> - rc 0 when a Done ticket's worker record reads live or idle
# while its doc/lock says the leg ended: the funnel skips a Done ticket's move but
# refreshes that record.
done_record_stale() {
    local doc rstate
    ts_record_read "$1" || return 1
    rstate=$(jq -r '.state // ""' <<<"$TS_REC")
    { [ "$rstate" = live ] || [ "$rstate" = idle ]; } || return 1
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    [ -n "$doc" ] || return 1
    case "$(ts_worker_state "$doc")" in wrapped|unknown) return 0 ;; esac
    return 1
}

fails="" # newline-separated "result:stage:class" triples
add_fail() { fails="$fails$1:$2:$3"$'\n'; }

finish() { # <summary text>
    local set sig prev wake=0
    set=$(printf '%s' "$fails" | sed '/^$/d' | sort -u)
    sig=$(printf '%s' "$set" | cksum | awk '{ print $1 }')
    prev=$(cat "$SDIR/wake-sig" 2>/dev/null) # swallow-ok: no prior signature reads empty, so the first sweep wakes
    if [ -z "$set" ]; then
        rm -f "$SDIR/wake-sig"
    elif [ "$sig" != "$prev" ]; then
        printf '%s\n' "$sig" > "$SDIR/wake-sig"
        wake=1
    fi
    echo "status-sweep: $1 sig=${set:+$sig} wake=$wake"
    exit 0
}

unknown() { # <stage>
    status_event event=sweep key=- result=miss stage="$1"
    add_fail miss "$1" -
    finish "unknown (snapshot $1) keys=0"
}

# --- the snapshot ---------------------------------------------------------------
bounded 30 gh pr list --state open --limit 300 \
    --json number,title,headRefOid,baseRefName,reviewDecision,statusCheckRollup > "$snap/prs.json" 2>/dev/null || unknown gh
n=$(jq 'length' "$snap/prs.json" 2>/dev/null) || unknown gh # swallow-ok: a failed count is the unknown branch on this line
case "$n" in ''|*[!0-9]*) unknown gh ;; esac
[ "$n" -lt 300 ] || unknown pr-limit

# shellcheck disable=SC2016  # $owner/$name are GraphQL variables
bounded 30 gh api graphql -F owner='{owner}' -F name='{repo}' -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(states:OPEN,first:100){pageInfo{hasNextPage} nodes{number reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved}} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{__typename ... on CheckRun{databaseId name checkSuite{app{databaseId}} status conclusion startedAt}}}}}}}}}}}' \
    > "$snap/graphql.json" 2>/dev/null || unknown gh
# Any further page anywhere makes the count or the check list partial.
jq -r '.data.repository.pullRequests as $p
    | if ($p.pageInfo.hasNextPage != false) or ($p.nodes | any(
        .reviewThreads.pageInfo.hasNextPage != false
        or ((.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage // false) != false)))
      then error("more pages")
      else $p.nodes[] | [.number, ([.reviewThreads.nodes[] | select(.isResolved | not)] | length)] | @tsv end' \
    "$snap/graphql.json" > "$snap/threads.tsv" 2>/dev/null || unknown gh

# Per-PR check rows (gh pr checks buckets) from the rollup, and the producer rows
# (state, name, app id, started, id) from the GraphQL check runs.
for num in $(jq -r '.[].number' "$snap/prs.json"); do : > "$snap/rows-$num.tsv"; : > "$snap/prows-$num.tsv"; done
jq -r '.[] | .number as $n | (.statusCheckRollup // [])[]
    | [$n,
       (if .__typename == "StatusContext"
        then ({SUCCESS: "pass", PENDING: "pending", EXPECTED: "pending"}[.state] // "fail")
        elif .status != "COMPLETED" then "pending"
        elif (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL") then "pass"
        elif .conclusion == "SKIPPED" then "skipping"
        elif .conclusion == "CANCELLED" then "cancel"
        else "fail" end),
       (.name // .context)] | @tsv' "$snap/prs.json" 2>/dev/null \
    | awk -F'\t' -v d="$snap" '{ f = d "/rows-" $1 ".tsv"; sub(/^[^\t]*\t/, ""); print >> f; close(f) }'
[ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ] || unknown gh
jq -r '.data.repository.pullRequests.nodes[] | .number as $n
    | (.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[] | select(.__typename == "CheckRun" and .databaseId != null)
    | [$n,
       (if .status != "COMPLETED" then "pending"
        elif (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED") then "pass"
        elif .conclusion == "CANCELLED" then "cancel" else "fail" end),
       .name, (.checkSuite.app.databaseId // ""), (.startedAt // ""), .databaseId] | @tsv' "$snap/graphql.json" 2>/dev/null \
    | awk -F'\t' -v d="$snap" '{ f = d "/prows-" $1 ".tsv"; sub(/^[^\t]*\t/, ""); print >> f; close(f) }'
[ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ] || unknown gh

# --- the key set ------------------------------------------------------------------
KEY_RE='^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
pr_keys=$(jq -r '.[].title' "$snap/prs.json" 2>/dev/null | while IFS= read -r title; do ticket_key_from_title "$title"; done | sort -u) # swallow-ok: prs.json parsed above; a title without a key adds no key
shopt -s nullglob
recfiles=("$STATE"/workers/*.json)
shopt -u nullglob
rec_all="" rec_live=""
if [ "${#recfiles[@]}" -gt 0 ]; then
    rec_tsv=$(jq -r '[(.key // ""), (.state // "")] | @tsv' "${recfiles[@]}" 2>/dev/null) # swallow-ok: an unreadable record leaves its key out of the set; its PR or Jira status still adds it
    rec_all=$(printf '%s\n' "$rec_tsv" | awk -F'\t' '$1 != "" { print $1 }' | sort -u)
    rec_live=$(printf '%s\n' "$rec_tsv" | awk -F'\t' '$1 != "" && $2 != "wrapped" { print $1 }' | sort -u)
fi
logged=""
[ ! -r "$LOG" ] || logged=$(jq -Rr 'fromjson? | .key // empty' "$LOG" 2>/dev/null | sort -u) # swallow-ok: an unreadable log only narrows the ladder-status keys that have a log row

seed=$(printf '%s\n%s\n' "$pr_keys" "$rec_live" | grep -E "$KEY_RE" | sort -u)
jql="project = ${JIRA_PROJECT_KEY:-HIMMEL} AND status in (\"In Progress\",\"In Review\",\"IN CI\")"
[ -z "$seed" ] || jql="key in ($(printf '%s' "$seed" | tr '\n' ',' | sed 's/,$//')) OR ($jql)"
ts_jira list --jql "$jql" --limit 300 2>/dev/null | awk -F'\t' '$1 ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }' > "$snap/jira.tsv"
[ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ] || unknown jira
[ "$(wc -l < "$snap/jira.tsv")" -lt 300 ] || unknown jira-limit

ladder=$(awk -F'\t' '$3 == "In Progress" || $3 == "In Review" || $3 == "IN CI" { print $1 }' "$snap/jira.tsv" | sort -u)
owned_ladder=$(printf '%s\n%s\n' "$rec_all" "$logged" | grep -E "$KEY_RE" | sort -u | comm -12 - <(printf '%s\n' "$ladder"))
keys=$(printf '%s\n%s\n' "$seed" "$owned_ladder" | grep -E "$KEY_RE" | sort -u)

cursor=$(cat "$SDIR/cursor" 2>/dev/null) # swallow-ok: no cursor file means start from the first key
[ -z "$cursor" ] || keys=$(printf '%s\n' "$keys" | awk -v c="$cursor" '$0 >= c')

# --- the sweep --------------------------------------------------------------------
total=0 served=0 moved=0 miss=0 funnel=0 next=""
while IFS= read -r key; do
    [ -n "$key" ] || continue
    if [ "$served" -gt 0 ] && [ $((SECONDS - T0)) -ge "$BUDGET" ]; then next=$key; break; fi
    served=$((served + 1))
    TS_SNAPSHOT_DIR="$snap" TS_EVENT=sweep
    ts_derive "$key"
    if [ "$TS_DERIVED" = no-write ]; then
        if [ "$TS_RESULT" = miss ]; then
            miss=$((miss + 1))
            add_fail miss "${TS_STAGE:-}" "$TS_WORKER_STATE"
        elif [ "$TS_RULE" = D0 ] && [ "$TS_J_STATUS" = Done ] && done_record_stale "$key"; then
            TS_SNAPSHOT_DIR="" TS_EVENT=""
            funnel=$((funnel + 1))
            bash "$HERE/leg-jira-status.sh" "$key" --event sweep --repo "$REPO" >/dev/null 2>&1
            continue
        fi
        TS_SNAPSHOT_DIR="" TS_EVENT=""
        continue
    fi
    rec_view=$(jq -r '[(.state // ""), (.lock_seen // false), (.lock_gone_sweeps // 0)] | @tsv' <<<"$TS_REC")
    state_now="$TS_WORKER_STATE" class_now="$TS_WORKER_STATE" derived="$TS_DERIVED" jstatus="$TS_J_STATUS"
    want="$state_now"$'\t'"$TS_LOCK_SEEN"$'\t'"$TS_GONE"
    TS_SNAPSHOT_DIR="" TS_EVENT=""
    if [ "$derived" = "$jstatus" ] && [ "$rec_view" = "$want" ]; then continue; fi
    if { [ "$TS_RULE" = D5 ] || [ "$TS_RULE" = D6 ]; } && outside_repo "$key"; then continue; fi
    funnel=$((funnel + 1))
    before=0
    [ ! -e "$LOG" ] || before=$(wc -l < "$LOG")
    bash "$HERE/leg-jira-status.sh" "$key" --event sweep --repo "$REPO" >/dev/null 2>&1
    outcome=""
    [ ! -e "$LOG" ] || outcome=$(tail -n "+$((before + 1))" "$LOG" | jq -rs --arg k "$key" \
        '[.[] | select(.key == $k)] | ((map(select(.result == "miss" or .result == "deferred")) | first) // last) | select(. != null) | [.result, (.stage // "")] | @tsv' 2>/dev/null)
    case "${outcome%%$'\t'*}" in
        moved) moved=$((moved + 1)) ;;
        miss|deferred)
            miss=$((miss + 1))
            add_fail "${outcome%%$'\t'*}" "${outcome#*$'\t'}" "$class_now" ;;
    esac
done <<<"$keys"
total=$(printf '%s\n' "$keys" | grep -c .)

if [ -n "$next" ]; then printf '%s\n' "$next" > "$SDIR/cursor"; else rm -f "$SDIR/cursor"; fi
finish "keys=$total served=$served moved=$moved miss=$miss funnel=$funnel${next:+ cursor=$next}"
