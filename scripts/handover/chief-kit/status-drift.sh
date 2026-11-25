#!/usr/bin/env bash
# scripts/handover/chief-kit/status-drift.sh - the report-only drift check
# over the derive-and-set status funnel. It runs the derive dry for every active
# key and compares the result with Jira, which covers every forward and
# backward move, then checks worker records against locks, docs and the WORKER
# comment. It never writes Jira, a record or the outcome log; the sweep
# (status-sweep.sh) is the fixer.
#
# Usage: status-drift.sh [--repo <owner/repo>] [--docs-dir <dir>] [--snapshot <dir>]
#   --docs-dir is where worker docs are scanned for a second owner (default the
#   handover root).
#   --snapshot is a status-sweep.sh --snapshot-out dir: the derive takes the PRs,
#   their checks and threads from it instead of gh per key. A dir without prs.json
#   and threads.tsv is ignored (live reads). Jira is still read fresh.
#
# One row per finding, `CLASS KEY detail | writer=<script> | fix=<command>`:
#   DERIVE-MISMATCH   Jira differs from derive(now); names the D rule and direction
#   MERGE-MISMATCH    a contract-yes merge row, but the ticket is not Done
#   DONE-WITH-OPEN-PR Done, but a PR whose title's first [KEY] is the key is open
#   MERGED-NO-ROW    a PR merged in the last 14 days with no merge row of its own (compared by PR number),
#                     its first [KEY] still open (not Done, not an Epic); the fix is to close the ticket
#                     or record the remainder
#   MISSED            a miss with no later moved or noop row for the same key and PR,
#                     unless a derive now settles the key (Done or off the ladder, or
#                     Jira already at the derived status)
#   WORKER-STALE      the record says live or idle, but the lock is released or the doc ended
#   WORKER-COMMENT    the WORKER comment hash differs from the one the record's class gives
#   TWO-OWNERS        two live docs claim one key
#   UNOWNED           started, no open PR, no live owner; not for a `standing`-labelled
#                     ticket, nor one whose comments cite an OPEN PR whose title names the
#                     ticket (any repo; that also skips DERIVE-MISMATCH and WORKER-COMMENT).
#                     The derive's worker state decides: a key whose lock stayed gone for two sweeps
#                     is no worker, and neither is a held or parked worker over a lock
#                     `queue-lock.sh status` calls STALE-DEAD (the fix is the reap). A due date never makes a
#                     started ticket wait: the chief-owned park (rule D6n: the worker wrapped and
#                     its brief says Completes ticket: no), a ticket-hold.sh hold, an owed step and the RESUME
#                     remainder are each UNOWNED from the first tick, the row naming who it awaits, since when and
#                     the date it carries. A started ticket still carrying the `held` label says it is held, still
#                     In Progress (ticket-hold.sh moves a held ticket to To Do); one with no valid hold row also
#                     says `held with no owner on record`. A hold that names a T3 thread (ticket-hold.sh --thread)
#                     is owned while that thread is in scripts/t3/thread-list.sh and not settled: no row. Once it
#                     settles, the list lacks it or the list cannot be read, the row stays and says which
#   CLOSE-OR-DISPATCH an In Progress ticket with no open PR, no live owner, no `standing` label and no hold, whose newest
#                     merge row, worker doc and Jira comment are all over COD_AGE_SECONDS (72 h) old (with no merge row,
#                     its worker docs and Jira comments alone), and that is either
#                     left by a partial merge or parked on a named wait (an owed step, the chief's D6n park or the
#                     RESUME remainder). It REPLACES the key's UNOWNED row,
#                     so sdrift counts the ticket once. The text names the last PR (or `no merged PR`) and the owed ask (the words after
#                     `Remaining:` in the newest ticket comment that has them): the operator close ask that
#                     drift-summary.mjs and tracker.py list as `close KEY or name a worker`
#   AWAITING          only a release-manager ruling wait (VERSION-DRIFT, below): a ticket held in a later version whose
#                     INTAKE was refused. Its row ends in ` | wait=<owner>`. No started ticket is AWAITING: a started
#                     ticket with no live owner is UNOWNED however far off its date is
#   HOLD-STALE        a ticket-hold.sh hold whose newest hold row names `on=<KEY>` and that ticket is Done in the
#                     local Jira mirror: the wait is over. It replaces the key's UNOWNED row, so
#                     sdrift counts it; the fix is the release command, never run here. A hold with no `on`, an `on`
#                     ticket still open, or one the mirror lacks or cannot read reads as before
#   HELD-STALE        a held or parked worker's lock is STALE and not proven dead: an owner, so not drift
#                     (no wait mark, but `sdrift` n and drift-summary.mjs skip it)
#   HELD-IN-WORK     labelled held, with a live owner or an open PR
#   VERSION-DRIFT    Done or worked (In Progress / In Review / IN CI), held only in a later unreleased
#                     version than the current one; the fix is an INTAKE request to the current version.
#                     The release manager's rulings are read first: when the key's latest ruling refused
#                     its INTAKE and no merged PR naming it, status change or admissions-ledger row is
#                     newer, the row is AWAITING `<owner> since=<ts> ruling=<id>` ending in ` | wait=<owner>`
#                     (rm or operator) instead. A ruling older than 14 days (the merged-PR list's window)
#                     re-files the INTAKE. An unreadable ruling store is a HEALTH row and sdrift=unknown
#   HEALTH            an input is unreadable or saturated, the log is unwritable
#                     or carries a disabled row, or a status is unknown
# The last line is `sdrift=<n>:<sig8>` (n rows that are not wait rows, sig8 over every sorted row), or
# `sdrift=unknown` when the open-PR list or the Jira search could not be read in
# full. A GitHub out (ts_scan_gate before the PR list) reads as that unreadable list, with
# its QUOTA-PAUSE or GH-STALL line on stderr. Always exits 0 (2 on a usage error).
#
# The active keys are the open-PR keys, the keys of records that are not
# wrapped, and the keys the Jira search finds in a ladder status. Log-based
# classes look at the last 500 rows only, except the partial PRs an UNOWNED row names: those come from
# the whole log, read once per pass. The whole pass is cut off at
# TICKET_STATUS_DRIFT_BUDGET seconds (default 90).
#
#
# Env: STATUS_DRIFT_T3_LIST (the thread list reader, default scripts/t3/thread-list.sh) and STATUS_DRIFT_T3_TIMEOUT
# (its deadline in seconds, default 20); both are test seams,
# TICKET_STATUS_STATE_DIR, JIRA_PROJECT_KEY (default HIMMEL); TICKET_STATUS_NOW (epoch, the clock),
# TICKET_STATUS_AWAIT_TTL_CHIEF (default 24h), TICKET_STATUS_AWAIT_TTL_OPERATOR and _OTHER (default 72h),
# TICKET_STATUS_AWAIT_TTL_RESUME (default 6h) and
# TICKET_STATUS_AWAIT_MAX (default 14d, at most 14d), each
# <n>h or <n>d, else the default and one HEALTH row; they only set the `due=` a stuck UNOWNED row
# prints (a due date never makes a started ticket wait); the rest is read by the lib.
#
# Platform guard: POSIX bash 3.2+ (shell-only harness).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
export LC_ALL=C
# shellcheck source=../../lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/ticket-status.sh"
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"
GH_READ_BIN="$HERE/../../lib/gh-read.sh"
[ -f "$GH_READ_BIN" ] || GH_READ_BIN=gh
if [ "$GH_READ_BIN" != gh ]; then
    # shellcheck source=../../lib/gh-read.sh
    # shellcheck disable=SC1091
    . "$GH_READ_BIN"
    GH_READ_QUIET=1 gh_read_init
fi
# shellcheck source=../../lib/env-value.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/env-value.sh"
# shellcheck source=../../lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh"
# shellcheck source=../../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/load-dotenv.sh"
# A shell without HANDOVER_DIR would scan the stub folder; read the configured root from the primary checkout's .env.
load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../.." 2>/dev/null)" HANDOVER_DIR USER_SLUG 2>/dev/null || true # swallow-ok: an unreadable .env leaves the resolver's own fallback, as before

usage() { echo "usage: status-drift.sh [--repo <owner/repo>] [--docs-dir <dir>] [--snapshot <dir>]" >&2; exit 2; }
REPO="" DOCS="" SNAP=""
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --repo) REPO="$2" ;;
        --docs-dir) DOCS="$2" ;;
        --snapshot) SNAP="$2" ;;
        *) usage ;;
    esac
    shift 2
done
command -v jq >/dev/null 2>&1 || { echo "status-drift: jq not found" >&2; echo "sdrift=unknown"; exit 0; }
# shellcheck disable=SC2329  # called by name through env_value
origin_slug() { git -C "$HERE" remote get-url origin | sed -E 's#^.*[:/]([^/:]+/[^/]+)$#\1#; s#\.git$##'; }
[ -n "$REPO" ] || REPO=$(env_value HIMMEL_REPO origin_slug) || { echo "status-drift: cannot resolve the himmel repo; pass --repo <owner/repo>" >&2; exit 2; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "status-drift: '$REPO' is not an owner/repo" >&2; exit 2; }
export GH_REPO="$REPO"

BUDGET="${TICKET_STATUS_DRIFT_BUDGET:-90}"
case "$BUDGET" in ''|*[!0-9]*) BUDGET=90 ;; esac
if [ -z "${TICKET_STATUS_DRIFT_IN_BUDGET:-}" ] && [ -n "$_TIMEOUT_BIN" ]; then
    rc=0
    TICKET_STATUS_DRIFT_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 "$BUDGET" bash "${BASH_SOURCE[0]}" --repo "$REPO" ${DOCS:+--docs-dir "$DOCS"} ${SNAP:+--snapshot "$SNAP"} || rc=$?
    case "$rc" in
        124|137)
            echo "HEALTH - drift: the pass was cut off after ${BUDGET}s | writer=- | fix=bash scripts/handover/chief-kit/status-drift.sh"
            echo "sdrift=unknown" ;;
    esac
    exit 0
fi

STATE="$(ts_state_dir)"
LOG="$STATE/status-events.jsonl"
SWEEP_FIX="bash scripts/handover/chief-kit/status-sweep.sh"
FUNNEL="worker-jira-status.sh"
rows=""
add() { # <class> <key> <detail> <writer> <fix> [<wait who>]
    rows="$rows$1 $2 $3 | writer=$4 | fix=$5${6:+ | wait=$6}"$'\n'
}
finish() { # <unknown>
    local n sig
    rows=$(printf '%s' "$rows" | sed '/^$/d' | sort -u)
    [ -z "$rows" ] || printf '%s\n' "$rows"
    if [ "$1" = unknown ]; then echo "sdrift=unknown"; exit 0; fi
    n=$(printf '%s\n' "$rows" | grep -Ev '^AWAITING .* \| wait=(chief|operator|[a-z][a-z0-9-]{0,31})$|^HELD-STALE [A-Z][A-Z0-9]*-[0-9]+ ' | grep -c .)
    sig=$(printf '%s' "$rows" | cksum | awk '{ printf "%08x", $1 }')
    echo "sdrift=$n:$sig"
    exit 0
}
bounded() {
    local s=$1
    shift
    if [ -n "$_TIMEOUT_BIN" ]; then "$_TIMEOUT_BIN" -k 2 "$s" "$@"; else "$@"; fi
}

NOW=$(ts_now)
while IFS= read -r envname; do
    [ -n "$envname" ] || continue
    add HEALTH - "env: $envname is not <n>h or <n>d (at most 14d for the cap); the default is used" - "set $envname to a value like 24h"
done <<<"$(ts_await_env_bad)"

# --- health of the log -------------------------------------------------------------
if [ -e "$LOG" ] && { [ ! -f "$LOG" ] || [ ! -w "$LOG" ]; }; then
    add HEALTH - "log: $LOG is unwritable" - "make the outcome log a writable file"
elif [ ! -e "$LOG" ] && [ -d "$STATE" ] && [ ! -w "$STATE" ]; then
    add HEALTH - "log: $STATE is unwritable" - "make the state dir writable"
fi
logtail=""
if [ -f "$LOG" ]; then
    logtail=$(tail -n 500 "$LOG" 2>/dev/null | ts_merge_rows 2>/dev/null | jq -Rc 'fromjson? // empty' 2>/dev/null) # swallow-ok: an unreadable log leaves the log-based classes empty and the health row above stands
fi
partials=""
lastmerge=""
OWN_ROWS=$(mktemp "${TMPDIR:-/tmp}/status-drift-owner.XXXXXX" 2>/dev/null) || OWN_ROWS="" # swallow-ok: no temp file means ts_owner reads the log per key
[ -z "$OWN_ROWS" ] || trap 'rm -f "$OWN_ROWS"' EXIT
if [ -f "$LOG" ]; then
    mergeout=$(ts_merge_rows "$LOG" 2>/dev/null) # swallow-ok: an unreadable log names no partial PR and no wait, and the generic fix stands
    partials=$(jq -Rrs '[split("\n")[] | fromjson? | select(type == "object" and .event == "merge" and .key != null and has("contract") and .contract != "")]
        | group_by(.key)[] | select(last.contract == "no")
        | [.[0].key, ("#" + ([.[] | select(.contract == "no") | .pr // empty | tostring] | reduce .[] as $p ([]; if index([$p]) then . else . + [$p] end) | join(", #")))] | @tsv' <<<"$mergeout" 2>/dev/null) # swallow-ok: as above
    lastmerge=$(jq -Rrs '[split("\n")[] | fromjson? | select(type == "object" and .event == "merge" and .key != null and has("contract") and .contract != "")]
        | group_by(.key)[] | last | select((.ts | type) == "string" and .ts != "" and .pr != null and (.pr | tostring) != "")
        | [.key, .ts, (.pr | tostring)] | @tsv' <<<"$mergeout" 2>/dev/null) # swallow-ok: an unreadable log leaves no merge row, so no key reaches CLOSE-OR-DISPATCH
    if [ -n "$OWN_ROWS" ]; then
        ts_owner_rows <<<"$mergeout" > "$OWN_ROWS"
        export TS_OWNER_ROWS="$OWN_ROWS"
    fi
fi
if [ -n "$logtail" ] && [ -n "$(jq -r 'select(.result == "disabled") | 1' <<<"$logtail" | head -n 1)" ]; then
    add HEALTH - "log: a disabled row in the last 500 rows (the funnel was off, so this sample is not clean)" - "unset WORKER_SESSION_JIRA_STATUS (0 disables the funnel)"
fi

# --- the snapshot ------------------------------------------------------------------
prs=""
if ts_scan_gate status-drift graphql core; then
    # swallow-ok: an unreadable PR list becomes a HEALTH row below, never a plausible count
    prs=$(GH_READ_NO_MAIN_FALLBACK=1 bounded 30 "$GH_READ_BIN" pr list --state open --limit 300 --json number,title 2>/dev/null) || prs=""
fi
# swallow-ok: a non-numeric count is the unreadable case the next line turns into a HEALTH row
npr=$(jq 'length' <<<"$prs" 2>/dev/null)
case "$npr" in ''|*[!0-9]*)
    add HEALTH - "gh: the open-PR list is unreadable" gh "gh auth status; then rerun this check"
    finish unknown ;;
esac
if [ "$npr" -ge 300 ]; then
    add HEALTH - "gh: the open-PR list hit its limit (300)" gh "raise the limit in status-drift.sh"
    finish unknown
fi
pr_keys="" # "<KEY>\t<pr>" per open PR, by the first [KEY] of its title only
while IFS=$'\t' read -r n title; do
    [ -n "$n" ] || continue
    k=$(ticket_key_from_title "$title") || continue
    pr_keys="$pr_keys$k"$'\t'"$n"$'\n'
done < <(jq -r '.[] | [.number, .title] | @tsv' <<<"$prs")

KEY_RE='^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
jql="project = ${JIRA_PROJECT_KEY:-HIMMEL} AND status in (\"In Progress\",\"In Review\",\"IN CI\")"
# swallow-ok: a failed ladder search becomes a HEALTH row and sdrift=unknown
if ! jtsv=$(ts_jira list --jql "$jql" --limit 300 2>/dev/null); then
    add HEALTH - "jira: the ladder search is unreadable" jira "jira list --jql '$jql'"
    finish unknown
fi
jtsv=$(printf '%s\n' "$jtsv" | awk -F'\t' '$1 ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }')
if [ "$(printf '%s\n' "$jtsv" | grep -c .)" -ge 300 ]; then
    add HEALTH - "jira: the ladder search hit its limit (300)" jira "narrow the search in status-drift.sh"
    finish unknown
fi
ladder=$(printf '%s\n' "$jtsv" | awk -F'\t' '$3 == "In Progress" || $3 == "In Review" || $3 == "IN CI" { print $1 }')

rec_live=""
for f in "$STATE"/workers/*.json; do
    [ -e "$f" ] || continue
    rec_live="$rec_live$(jq -r 'select(.state != "wrapped") | .key // empty' "$f" 2>/dev/null)"$'\n' # swallow-ok: an unreadable record is reported by the key's own derive when Jira or a PR names it
done
keys=$(printf '%s\n%s\n%s\n' "$(printf '%s' "$pr_keys" | cut -f1)" "$rec_live" "$ladder" | grep -E "$KEY_RE" | sort -u)

docs_all=""
if [ -z "$DOCS" ]; then DOCS=$(handover_root 2>/dev/null) || DOCS=""; fi # swallow-ok: no handover root means no second-owner scan
[ -z "$DOCS" ] || [ ! -d "$DOCS" ] || docs_all=$(find "$DOCS" -maxdepth 4 -type f -name '*-N*.md' 2>/dev/null) # swallow-ok: an unreadable tree narrows the TWO-OWNERS scan only

is_owner_state() { case "$1" in live|idle|IDLE-HELD|parked) return 0 ;; *) return 1 ;; esac; }
read_doc_state_after_early_derive() { if [ "$TS_WORKER_STATE" = none ] && [ -n "$doc" ]; then _ts_worker_state "$doc"; fi; }

# 0 when a comment on the ticket names a PR that gh reports OPEN and whose title's first [KEY]
# is this ticket. The pr list above only sees this repo, so a ticket whose PR lives elsewhere
# looks ownerless without this. The title binds the PR to the ticket: a PR a comment merely
# cites (another ticket's, an upstream one) exempts nothing. A closed or merged PR, a PR
# titled for another ticket or none, or a failed gh read is not a yes: the ticket's rows stay.
MIRROR_DIR="${TICK_TRACKER_MIRROR_DIR:-$HOME/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}}"
# A ticket's labels and comments come from its file in the local Jira mirror, as its status and type do for the
# merged-no-row class below: one live `jira get` or `jira comments` per ticket cost 37 s of a traced pass.
# A key the mirror lacks, a file with no `labels:` line (labels) or no `## Comments` heading (comments) is read live.
# has_label <KEY> <label>: rc 0 labelled, 1 not
has_label() {
    local line f=$MIRROR_DIR/$1.md
    if [ -r "$f" ]; then
        # swallow-ok: an unreadable or label-less file leaves the line empty and the ticket is read live below
        line=$(awk '/^---$/ { if (++n == 2) exit; next } n == 1 && /^labels: / { print; exit }' "$f" 2>/dev/null)
        if [ -n "$line" ]; then
            case "$line" in *'"'"$2"'"'*) return 0 ;; *) return 1 ;; esac
        fi
    fi
    # swallow-ok: an unreadable ticket is not labelled, so its rows stay
    jq -e --arg l "$2" '(.fields.labels // []) | index($l)' >/dev/null 2>&1 <<<"$(ts_jira get "$1" --json 2>/dev/null)"
}
hold_on() {
    # swallow-ok: unreadable rows name no on ticket, so the hold reads as before
    jq -Rrs --arg k "$1" '[split("\n")[] | fromjson? | select(type == "object" and .key == $k and (.event == "hold" or .event == "hold-release") and .result == "moved")]
        | last // empty | select(.event == "hold") | (.on // "") | select(type == "string" and test("^[A-Z][A-Z0-9]*-[0-9]+$"))' <<<"${mergeout:-}" 2>/dev/null
}
hold_thread() {
    # swallow-ok: unreadable rows name no thread, so the hold reads as before
    jq -Rrs --arg k "$1" '[split("\n")[] | fromjson? | select(type == "object" and .key == $k and (.event == "hold" or .event == "hold-release") and .result == "moved")]
        | last // empty | select(.event == "hold") | (.thread // "") | select(type == "string" and test("^[A-Za-z0-9][A-Za-z0-9:_.-]{0,95}$"))' <<<"${mergeout:-}" 2>/dev/null
}
T3_LOADED=0 T3_LIST=""
t3_load() {
    [ "$T3_LOADED" = 0 ] || return 0
    T3_LOADED=1
    local out
    # swallow-ok: an unreadable list leaves T3_LIST empty, so no thread is proven live and the ticket stays stuck
    out=$(bounded "${STATUS_DRIFT_T3_TIMEOUT:-20}" bash "${STATUS_DRIFT_T3_LIST:-$HERE/../../t3/thread-list.sh}" 2>/dev/null) || return 0
    jq -e '.threads | type == "array"' >/dev/null 2>&1 <<<"$out" && T3_LIST=$out
    return 0
}
thread_state() {
    [ -n "$T3_LIST" ] || { echo unreadable; return 0; }
    jq -r --arg t "$1" '[.threads[] | select(.threadId == $t)] | first | if . == null then "missing" elif .state == "settled" then "settled" else "live" end' <<<"$T3_LIST" 2>/dev/null || echo unreadable # swallow-ok: an unreadable list proves no thread live
}
mirror_done() {
    local st
    [ -r "$MIRROR_DIR/$1.md" ] || return 1
    # swallow-ok: an unreadable file is not Done, so the hold reads as before
    st=$(awk -F'"' '/^---$/ { if (++n == 2) exit; next } n == 1 && /^status: "/ { print $2; exit }' "$MIRROR_DIR/$1.md" 2>/dev/null)
    [ "$st" = Done ]
}
# ticket_comments <KEY>: the comment text, from the mirror when its file has a Comments section
ticket_comments() {
    local f=$MIRROR_DIR/$1.md
    if [ -r "$f" ] && grep -q '^## Comments' "$f" 2>/dev/null; then # swallow-ok: an unreadable file is read live below
        sed -n '/^## Comments/,$p' "$f"
        return 0
    fi
    ts_jira comments "$1" 2>/dev/null # swallow-ok: an unreadable comment list means no cross-repo PR is known, so the rows stay
}
xrepo_open() { # <KEY>
    local urls u row tkey
    urls=$(ticket_comments "$1" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | sort -u)
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        # swallow-ok: a failed gh read is not proof the PR is open, so the rows stay
        row=$(GH_READ_NO_MAIN_FALLBACK=1 bounded 20 "$GH_READ_BIN" pr view "$u" --json state,title --jq '.state + "\t" + .title' 2>/dev/null) || continue
        [ "${row%%$'\t'*}" = OPEN ] || continue
        tkey=$(ticket_key_from_title "${row#*$'\t'}") || continue
        [ "$tkey" = "$1" ] && return 0
    done <<<"$urls"
    return 1
}

# The status and type of every active key in a few JQL searches, not one `jira get`
# per key. A key the batch lacks (or a failed chunk) is still read by its own get.
jbatch=""
while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    # swallow-ok: a failed chunk leaves its keys to the per-key get
    jrows=$(ts_jira list --jql "key in ($chunk)" --limit 300 2>/dev/null) || continue
    jbatch="$jbatch$jrows"$'\n'
done <<<"$(printf '%s\n' "$keys" | awk 'NF { printf "%s%s", (n++ % 100 ? "," : (n > 1 ? "\n" : "")), $0 } END { print "" }')"
jbatch=$(printf '%s\n' "$jbatch" | awk -F'\t' '$1 ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }')
eval "$(declare -f ts_read_jira | sed '1s/^ts_read_jira/_ts_read_jira_get/')"
ts_read_jira() { # <KEY> - the batch row, else the lib's own get
    local row
    row=$(printf '%s\n' "$jbatch" | awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3; exit }')
    if [ -n "$row" ]; then
        TS_J_TYPE=${row%%$'\t'*}
        TS_J_STATUS=${row#*$'\t'}
        [ -n "$TS_J_STATUS" ] && [ -n "$TS_J_TYPE" ]
        return
    fi
    TS_SNAPSHOT_DIR='' _ts_read_jira_get "$1"
}
{ [ -f "$SNAP/prs.json" ] && [ -f "$SNAP/threads.tsv" ]; } 2>/dev/null || SNAP=""

VD_EP='def ep: [sub("\\.[0-9]+"; "") | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")]
    | if length == 1 then .[0] else error("not a time") end | (.d + "Z" | fromdateiso8601) - (if .z == "Z" then 0 else ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) * (if .z[0:1] == "+" then 1 else -1 end) end);'

COD_AGE_SECONDS=$((72 * 3600))
cod_comment_epoch() {
    ticket_comments "$1" | awk -F'\t' -v re='^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+(Z|[+-][0-9][0-9]:?[0-9][0-9])$' '
        /^### / { n = split($0, a, " — "); if (n > 1 && a[n] ~ re) print a[n]; next }
        NF >= 2 && $2 ~ re { print $2 }' | jq -Rr "$VD_EP"'try ep catch empty' 2>/dev/null | sort -n | tail -n 1 # swallow-ok: an unreadable comment time is no event, and the merge row and the worker docs still decide
}
cod_related_epoch() {
    local card=$MIRROR_DIR/$1.md rel r ts e best=0
    rel=$({
        [ ! -r "$card" ] || awk '/^---$/ { if (++n == 2) exit; next } n == 1 && /^links:/ { on = 1; next } n == 1 && /^[^ ]/ { on = 0 } n == 1 && on' "$card" | grep -oE '[A-Za-z][A-Za-z0-9]*-[0-9]+' | while IFS= read -r r; do
            grep -qE '^labels: .*"(residual|follow-up)"' "$MIRROR_DIR/$r.md" 2>/dev/null && printf '%s\n' "$r"
        done
        grep -rlxF --include='*.md' "parent: \"$1\"" "$MIRROR_DIR" 2>/dev/null | sed 's#.*/##; s#\.md$##'
    } | grep -vxF "$1" | sort -u)
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        ts=$(awk -F'\t' -v k="$r" '$1 == k { print $2; exit }' <<<"$lastmerge")
        [ -n "$ts" ] || continue
        e=$(_ts_epoch_of_iso "$ts") || continue
        [ "$e" -le "$best" ] || best=$e
    done <<<"$rel"
    printf '%s\n' "$best"
}
cod_ask() {
    local t
    t=$(ticket_comments "$1" | grep 'Remaining:' | tail -n 1 | sed 's/^.*Remaining:[[:space:]]*//' | tr -d '|\r' | tr '\t' ' ' | jq -Rr '.[0:120]' 2>/dev/null) # swallow-ok: an unreadable comment leaves the fallback ask
    printf '%s\n' "${t:-$2}"
}
cod_raise() {
    local key=$1 st=$2 lm mts pr="" newest=0 e d ce ask when age last
    [ "$st" = "In Progress" ] || return 1
    lm=$(awk -F'\t' -v k="$key" '$1 == k { print; exit }' <<<"$lastmerge")
    if [ -n "$lm" ]; then
        IFS=$'\t' read -r _ mts pr <<<"$lm"
        newest=$(_ts_epoch_of_iso "$mts") || return 1
    fi
    while IFS= read -r d; do
        [ -n "$d" ] && [ -f "$d" ] || continue
        e=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null) || continue # swallow-ok: a doc with no readable time is no event
        case "$e" in ''|*[!0-9]*) continue ;; esac
        [ "$e" -le "$newest" ] || newest=$e
    done <<<"$owners"
    [ "$newest" -eq 0 ] || [ $((10#$NOW - newest)) -gt "$COD_AGE_SECONDS" ] || return 1
    ce=$(cod_comment_epoch "$key")
    case "$ce" in ''|*[!0-9]*) ;; *) [ "$ce" -le "$newest" ] || newest=$ce ;; esac
    ce=$(cod_related_epoch "$key")
    case "$ce" in ''|*[!0-9]*) ;; *) [ "$ce" -le "$newest" ] || newest=$ce ;; esac
    [ "$newest" -gt 0 ] || return 1
    [ $((10#$NOW - newest)) -gt "$COD_AGE_SECONDS" ] || return 1
    ask=$(cod_ask "$key" "$3")
    when=$(date -u -d "@$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$newest" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1 # swallow-ok: the BSD form follows
    age=$(((10#$NOW - newest) / 3600))
    last="no merged PR"
    [ -z "$pr" ] || last="last PR #$pr"
    add CLOSE-OR-DISPATCH "$key" "$st with no open PR, no live owner and no event since $when ($age h); $last, owed: $ask" jira "the operator closes $key (jira transition $key Done) when nothing remains, or names a worker: dispatch a RESUME worker, or hold it: bash scripts/handover/chief-kit/ticket-hold.sh $key --owner <who> --until <date> --reason <why>"
}

# --- per key -----------------------------------------------------------------------
while IFS= read -r key; do
    [ -n "$key" ] || continue
    unset TS_EVENT
    # shellcheck disable=SC2034  # read by ticket-status.sh
    if [ -n "$SNAP" ]; then TS_SNAPSHOT_DIR="$SNAP"; else unset TS_SNAPSHOT_DIR; fi
    ts_derive "$key"
    jstatus="$TS_J_STATUS" derived="$TS_DERIVED" rule="$TS_RULE" result="$TS_RESULT" stage="$TS_STAGE"
    wstate_derive="$TS_WORKER_STATE" pr_state="$TS_PR_STATE" owner_doc="$TS_OWNER_DOC"
    open_prs=$(printf '%s' "$pr_keys" | awk -F'\t' -v k="$key" '$1 == k { printf "%s#%s", (n++ ? "," : ""), $2 }')

    # A started ticket with no PR here is not drift when it is `standing` (started on purpose,
    # no single PR) or when its PR is open in another repo (that PR is its owner).
    standing=0 xrepo=0
    if [ -z "$open_prs" ] && [ "$(ts_rank "$jstatus")" -ge 1 ]; then
        if has_label "$key" standing; then standing=1; fi
        if xrepo_open "$key"; then xrepo=1; fi
    fi

    if [ "$derived" = no-write ]; then
        [ "$result" != miss ] || add HEALTH "$key" "status unknown (stage=${stage:-?}${rule:+ rule=$rule})" "$FUNNEL" "$SWEEP_FIX"
    elif [ "$derived" != "$jstatus" ] && [ "$xrepo" = 0 ]; then
        if [ "$(ts_rank "$derived")" -gt "$(ts_rank "$jstatus")" ]; then dir=forward; else dir=backward; fi
        add DERIVE-MISMATCH "$key" "jira=$jstatus derived=$derived rule=$rule dir=$dir" "$FUNNEL --event sweep" "$SWEEP_FIX"
    fi
    if [ "$jstatus" = Done ] && [ -n "$open_prs" ]; then
        add DONE-WITH-OPEN-PR "$key" "Done with open PR $open_prs" jira "close or retitle the PR, or reopen the ticket by hand"
    fi

    ts_record_read "$key" || continue
    worker=$(jq -r '.leg // ""' <<<"$TS_REC")
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    rstate=$(jq -r '.state // ""' <<<"$TS_REC")
    wstate=none
    [ -z "$doc" ] || wstate=$(ts_worker_state "$doc")

    if { [ "$rstate" = live ] || [ "$rstate" = idle ] || [ "$rstate" = parked ]; } && { [ "$wstate" = wrapped ] || [ "$wstate" = unknown ]; }; then
        add WORKER-STALE "$key" "record=$rstate but the doc/lock says $wstate" "$FUNNEL --event sweep" "$SWEEP_FIX"
    fi

    if [ "$derived" != no-write ] && [ "$xrepo" = 0 ] && [ -n "$worker$doc" ]; then
        heads=$(printf '%s' "$pr_state" | awk -F'\t' 'NF { printf "%s#%s@%s", (n++ ? "," : ""), $1, substr($2, 1, 9) }')
        want=$(printf '%s|%s|%s|%s' "$worker" "$wstate_derive" "$heads" "$derived" | cksum | awk '{ print $1 }')
        have=$(jq -r '.comment_hash // ""' <<<"$TS_REC")
        if [ "$want" != "$have" ]; then
            add WORKER-COMMENT "$key" "record hash ${have:-none} vs class hash $want" "$FUNNEL" "bash scripts/handover/chief-kit/worker-jira-status.sh $key --event sweep"
        fi
    fi

    owners=""
    [ -z "$doc" ] || owners="$doc"$'\n'
    owners="$owners$(printf '%s\n' "$docs_all" | awk -v p="$key-N" '{ n = split($0, a, "/"); if (index(a[n], p) == 1) print }')"
    nown=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if is_owner_state "$(ts_worker_state "$d")"; then nown=$((nown + 1)); fi
    done <<<"$(printf '%s\n' "$owners" | sort -u)"
    [ "$nown" -lt 2 ] || add TWO-OWNERS "$key" "$nown live docs claim it" - "wrap or halt all but one worker doc"

    if [ "$(ts_rank "$jstatus")" -ge 1 ] && [ -z "$open_prs" ] && [ "$standing" = 0 ] && [ "$xrepo" = 0 ]; then
        read_doc_state_after_early_derive
        export TS_OWNER_HELD=no
        ts_owner "$key" >/dev/null
        held=0
        if [ "${TS_OWNER_ANS%%$'\t'*}" != worker ] && has_label "$key" held; then
            held=1
            export TS_OWNER_HELD=yes
            ts_owner "$key" >/dev/null
        fi
        IFS=$'\t' read -r okind owho osince odue osrc owhat <<<"$TS_OWNER_ANS"
        hhint=""
        if [ "$held" = 1 ]; then hhint="; held, still $jstatus: a held ticket belongs in To Do (jira transition $key \"To Do\") or released (ticket-hold.sh $key --release)"; fi
        if [ "$held" = 1 ] && [ "$TS_OWNER_HOLD_VALID" != yes ]; then hhint="$hhint; held with no owner on record: re-run ticket-hold.sh $key --owner <who> --until <date> --reason <why>"; fi
        case "$okind" in
            worker)
                if [ "$TS_LOCK_DEAD" = no ] && { [ "$TS_WORKER_STATE" = IDLE-HELD ] || [ "$TS_WORKER_STATE" = parked ]; }; then
                    add HELD-STALE "$key" "$jstatus with no open PR; its worker's lock (${owner_doc:-$doc}) is STALE and not proven dead" queue-lock.sh "check the leg on its host, or reap it once it is gone (an age cap is a follow-up)"
                fi ;;
            awaiting)
                chieffix="the chief closes $key by hand when nothing remains, or dispatches a RESUME worker for the rest"
                case "$osrc" in
                    hold) wwriter=ticket-hold.sh wfix="$owho acts on $key, or re-hold it: bash scripts/handover/chief-kit/ticket-hold.sh $key --owner <who> --until <date> --reason <why>" wwho=$owho ;;
                    owed) wwriter=merge-on-green.sh wfix="$owho acts on $key, or hold it: bash scripts/handover/chief-kit/ticket-hold.sh $key --owner <who> --until <date> --reason <why>" wwho=$owho ;;
                    *) wwriter=$FUNNEL wfix=$chieffix wwho="the chief" ;;
                esac
                hstale="" tid="" tstate=""
                if [ "$osrc" = hold ]; then
                    hstale=$(hold_on "$key")
                    [ -z "$hstale" ] || mirror_done "$hstale" || hstale=""
                    tid=$(hold_thread "$key")
                    if [ -n "$tid" ]; then
                        t3_load
                        tstate=$(thread_state "$tid")
                        case "$tstate" in
                            settled) hhint="$hhint; thread $tid is settled" ;;
                            missing) hhint="$hhint; thread $tid does not exist" ;;
                            *) hhint="$hhint; thread $tid is not proven live: the thread list unreadable" ;;
                        esac
                    fi
                fi
                if [ "$tstate" = live ]; then
                    :
                elif [ -n "$hstale" ]; then
                    add HOLD-STALE "$key" "on $hstale (Done)" ticket-hold.sh "bash scripts/handover/chief-kit/ticket-hold.sh $key --release"
                else
                    case "$osrc" in
                        owed) cfb="a step owed by $owho" ;;
                        d6n) cfb="the chief's decision on the remainder" ;;
                        *) cfb="a RESUME worker for the remainder" ;;
                    esac
                    { [ "$held" = 0 ] && [ "$osrc" != hold ] && cod_raise "$key" "$jstatus" "$cfb"; } \
                        || add UNOWNED "$key" "$jstatus with no open PR and no live owner; a date never makes it wait: awaiting $wwho since=$osince due=$odue what=$owhat source=$osrc$hhint" "$wwriter" "$wfix"
                fi ;;
            *)
                ppr=$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' <<<"$partials")
                if [ "$TS_LOCK_DEAD" = yes ]; then
                    add UNOWNED "$key" "$jstatus with no open PR and its worker's lock is STALE-DEAD$hhint" "$FUNNEL" "bash scripts/handover/queue-lock.sh status --sweep --reap-dead (the reap appends a HALTED bullet, so the next derive reads $key wrapped, after two gone sweeps if that append failed; it releases every STALE-DEAD lock under the root, each re-proved under its claim and CAS)"
                elif [ -n "$ppr" ]; then
                    { [ "$held" = 0 ] && cod_raise "$key" "$jstatus" "the remainder of partial merge PR $ppr"; } \
                        || add UNOWNED "$key" "$jstatus with no open PR and no live owner, left by partial merge PR $ppr$hhint" "$FUNNEL" "bash scripts/handover/chief-kit/next-dispatchable.sh lists $key: dispatch the RESUME worker it names; or hold it: bash scripts/handover/chief-kit/ticket-hold.sh $key --owner <who> --until <date> --reason <why>; or close $key by hand when nothing remains"
                else
                    add UNOWNED "$key" "$jstatus with no open PR and no live owner$hhint" "$FUNNEL" "dispatch a RESUME worker, or $SWEEP_FIX"
                fi ;;
        esac
    fi

    if [ "$jstatus" != Done ] && { [ -n "$open_prs" ] || is_owner_state "$wstate"; }; then
        # an unreadable ticket raises no HELD-IN-WORK row; the derive miss already raised a HEALTH row
        if has_label "$key" held; then
            add HELD-IN-WORK "$key" "held while ${open_prs:+PR $open_prs open}${open_prs:+${wstate:+ and }}owner $wstate" "ticket-hold.sh" "bash scripts/handover/chief-kit/ticket-hold.sh $key --release"
        fi
    fi
done <<<"$keys"

# --- merged PRs with no merge row ------------------------------------
# A PR merged by hand, or by any route that writes no merge row, leaves its ticket reading
# unfinished with no word of the merge. The PRs merged in the last 14 days are read in two 7-day
# slices (a GitHub list returns at most MNR_LIMIT PRs, and one 14-day read filled it) and compared by
# PR number with the merge rows of the log, which are read once; a row that carries no PR number
# covers every PR of its key. A slice that reaches MNR_LIMIT is one HEALTH row: its older merges are
# not checked. One row per open ticket (not Done, not an Epic), naming its newest PR with no merge row.
# Cost per run: two gh lists (about 5 s per 700 PRs), one pass over the log, and for each distinct key
# with an unrecorded PR its status and type from the local Jira mirror (a file read, outside the budget).
# A measured station run spent the whole 40 s budget on 108 live `jira get` reads at 0.34 s
# each (node start), leaving 85 PRs unread however often it ran. Only a key the mirror lacks is read live,
# newest first, until the read budget is spent: MNR_BUDGET seconds (default 40) or the time left in the
# pass less 25 s for the classes after this one, whichever is less. A Done ticket costs a live read, so
# once the budget is spent open tickets may be among the PRs left unread; they are one HEALTH row naming
# the first keys. A cut-off pass loses every row.
MNR_LIMIT="${TICKET_STATUS_DRIFT_MNR_LIMIT:-1000}"
case "$MNR_LIMIT" in ''|*[!0-9]*) MNR_LIMIT=1000 ;; esac
mday() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d 2>/dev/null; } # swallow-ok: no date is the unreadable case the merged list check turns into a HEALTH row
mlist() { GH_READ_NO_MAIN_FALLBACK=1 bounded 20 "$GH_READ_BIN" pr list --state merged --search "$1" --limit "$MNR_LIMIT" --json number,title,mergedAt 2>/dev/null; }
md14=$(mday 14) md8=$(mday 8) md7=$(mday 7) # swallow-ok: an empty date is an unreadable list below
mprs=""
if [ -n "$md14" ] && [ -n "$md8" ] && [ -n "$md7" ] && m1=$(mlist "merged:$md14..$md8") && m2=$(mlist "merged:>=$md7"); then
    n1=$(jq 'length' <<<"$m1" 2>/dev/null) n2=$(jq 'length' <<<"$m2" 2>/dev/null) # swallow-ok: a non-numeric count is the unreadable case below
    mprs=$(jq -s 'add | sort_by(.number) | reverse' <<<"$m1"$'\n'"$m2" 2>/dev/null) # swallow-ok: an unparsable list is the unreadable case below
    case "$n1$n2" in *[!0-9]*) mprs="" ;; esac
    if [ -n "$mprs" ] && { [ "$n1" -ge "$MNR_LIMIT" ] || [ "$n2" -ge "$MNR_LIMIT" ]; }; then
        add HEALTH - "merged-no-row: a 7-day merged-PR slice reached the $MNR_LIMIT-PR limit, so its older merges are not checked" gh "narrow the slice or raise TICKET_STATUS_DRIFT_MNR_LIMIT"
    fi
fi
nmp=$(jq 'length' <<<"$mprs" 2>/dev/null) # swallow-ok: a non-numeric count is the unreadable case the next line turns into a HEALTH row
mrows=""
mlog=ok
if [ -e "$LOG" ] && [ ! -r "$LOG" ]; then
    mlog=unreadable
elif [ -r "$LOG" ]; then
    # swallow-ok: an unreadable log becomes a HEALTH row below, never a row for every merged PR
    mr=$(ts_merge_rows "$LOG" 2>/dev/null) && mrows=$(jq -R -r 'fromjson? | select(.event == "merge" and has("contract")) | "\(.key)\t\(.pr // "")"' <<<"$mr" 2>/dev/null) || mlog=unreadable
fi
MNR_BUDGET="${TICKET_STATUS_DRIFT_MNR_BUDGET:-40}"
case "$MNR_BUDGET" in ''|*[!0-9]*) MNR_BUDGET=40 ;; esac
# mirror_read <KEY> - TS_J_STATUS and TS_J_TYPE from the key's file in the local Jira mirror (the frontmatter only);
# rc 1 = no file, or either field missing, so the caller reads the ticket live.
mirror_read() {
    local row
    TS_J_STATUS="" TS_J_TYPE=""
    [ -r "$MIRROR_DIR/$1.md" ] || return 1
    # swallow-ok: an unreadable or unparsable file is rc 1 below and the caller reads the ticket live
    row=$(awk -F'"' '/^---$/ { if (++n == 2) exit; next } n == 1 && /^type: "/ { t = $2 } n == 1 && /^status: "/ { s = $2 } END { if (s != "" && t != "") print t "\t" s }' "$MIRROR_DIR/$1.md" 2>/dev/null)
    [ -n "$row" ] || return 1
    TS_J_TYPE=${row%%$'\t'*}
    TS_J_STATUS=${row#*$'\t'}
}
case "$nmp" in
    ''|*[!0-9]*) add HEALTH - "gh: the merged-PR list is unreadable" gh "gh auth status; then rerun this check" ;;
    *)
        if [ "$mlog" != ok ]; then
            add HEALTH - "log: the merge rows are unreadable" - "check $LOG"
            nmp=0
        fi
        mseen=""
        mstart=$SECONDS
        mlimit=$MNR_BUDGET
        mrest=$((BUDGET - SECONDS - 25))
        [ "$mrest" -ge "$mlimit" ] || mlimit=$mrest
        mskipped=0
        mskeys=""
        mnskeys=0
        while IFS=$'\t' read -r n title; do
            [ -n "$n" ] || continue
            k=$(ticket_key_from_title "$title") || continue
            case " $mseen " in *" $k "*) continue ;; esac
            case $'\n'"$mrows"$'\n' in *$'\n'"$k"$'\t'"$n"$'\n'*|*$'\n'"$k"$'\t\n'*) continue ;; esac
            mfile=0
            mirror_read "$k" && mfile=1
            if [ "$mfile" = 0 ] && [ $((SECONDS - mstart)) -ge "$mlimit" ]; then
                mskipped=$((mskipped + 1))
                case " $mskeys " in *" $k "*) ;; *) if [ "$mnskeys" -lt 10 ]; then mskeys="$mskeys $k"; mnskeys=$((mnskeys + 1)); fi ;; esac
                continue
            fi
            mseen="$mseen $k"
            if [ "$mfile" = 1 ] || ts_read_jira "$k"; then
                [ "$TS_J_TYPE" != Epic ] && [ "$(ts_rank "$TS_J_STATUS")" -ge 0 ] || continue
                add MERGED-NO-ROW "$k" "PR #$n merged with no merge row and the ticket is $TS_J_STATUS: close the ticket or record the remainder" "merge-on-green.sh" "jira transition $k Done (work finished), or record the remainder as a partial"
            else
                add HEALTH "$k" "status unknown (stage=get)" jira "$SWEEP_FIX"
            fi
        done <<<"$([ "$nmp" -gt 0 ] && jq -r '.[] | [.number, .title] | @tsv' <<<"$mprs")"
        [ "$mskipped" -eq 0 ] || add HEALTH - "merged-no-row: $mskipped merged PRs not checked, the ${mlimit}s read budget was spent; open tickets may be among them, first keys:$mskeys" - "check the listed tickets with jira get; the newest unrecorded PRs are read first"
        ;;
esac

# --- version drift -----------------------------------------------------------------
# A Done or worked ticket held only in a later unreleased version than the current one (the earliest
# unreleased, unarchived by date) is drift: the release manager's INTAKE request folds it in. One search
# per later version; a ticket that also carries the current version is left out by the JQL itself.
proj="${JIRA_PROJECT_KEY:-HIMMEL}"
vd_rulings() { # <keys> - VRUL = "key\tid\tts\tepoch\towner" per key whose latest ruling refused its INTAKE; rc 1 = unreadable
    local root hr common rf
    VRUL=""
    if [ -n "${HIMMEL_RELEASE_STATE_DIR:-}" ]; then
        root=$HIMMEL_RELEASE_STATE_DIR
    else
        [ -n "${USER_SLUG:-}" ] || return 1
        hr=$(handover_root 2>/dev/null) && [ -n "$hr" ] || return 1 # swallow-ok: no handover root is the unreadable store
        common=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1 # swallow-ok: no repo name is the unreadable store
        root="$hr/$USER_SLUG/$(basename "$(dirname "$common")")/release"
    fi
    rf="$root/$cur/rulings.jsonl"
    [ -e "$rf" ] || return 0
    # swallow-ok: an unreadable or unparsable ledger is rc 1, the caller's HEALTH row and sdrift=unknown
    VRUL=$(jq -nr --arg keys " $1 " "$VD_EP"'reduce (inputs | select(type == "object" and (.key | type) == "string")) as $r ({};
            if ($keys | index(" " + $r.key + " ")) then .[$r.key] = $r else . end)
        | .[] | select(.verb == "INTAKE" and .op.kind == "none" and .outcome == "BACKLOG"
            and ((.authority.kind // "") | test("^[a-z][a-z0-9-]{0,31}$")))
        | [.key, .id, .ts, (.ts | ep), .authority.kind] | @tsv' "$rf" 2>/dev/null)
}
vd_newer() { # <key> <ruling epoch> - rc 0 when evidence newer than the ruling exists or cannot be ruled out
    local r h hr ledger
    [ "$2" -ge $((10#$NOW - 14 * 86400)) ] || return 0
    case "$nmp" in ''|*[!0-9]*) return 0 ;; esac
    # swallow-ok: an unparsable merged list or timestamp prints no false, so the INTAKE fix stays
    r=$(jq -r --arg k "$1" --argjson t "$2" "$VD_EP"'any(.[]; (.title | test("(^|[^A-Za-z0-9-])" + $k + "([^0-9]|$)"))
        and (.mergedAt == null or (.mergedAt | ep) > $t))' <<<"$mprs" 2>/dev/null)
    [ "$r" = false ] || return 0
    h=$(ts_jira history "$1" --field status 2>/dev/null) || return 0 # swallow-ok: an unreadable history keeps the INTAKE fix
    h=$(printf '%s\n' "$h" | awk 'NF { l = $1 } END { print l }')
    if [ -n "$h" ]; then
        r=$(jq -nr --arg s "$h" --argjson t "$2" "$VD_EP"'$s | ep > $t' 2>/dev/null) # swallow-ok: an unparsable time prints no false
        [ "$r" = false ] || return 0
    fi
    ledger="${HIMMEL_ADMISSIONS_LEDGER:-}"
    if [ -z "$ledger" ]; then hr=$(handover_root 2>/dev/null) || return 0; ledger="$hr/admissions-ledger.jsonl"; fi # swallow-ok: no handover root keeps the INTAKE fix
    [ -e "$ledger" ] || return 1
    # swallow-ok: an unreadable ledger, a line that is not an object or a row of the key with a bad time keeps the INTAKE fix
    r=$(jq -Rr --arg k "$1" --argjson t "$2" "$VD_EP"'select(test("\\S")) | (fromjson? // null)
        | if type != "object" then true elif .key != $k then empty else (.ts | ep) > $t end' "$ledger" 2>/dev/null) || return 0
    case "$r" in *true*) return 0 ;; esac
    return 1
}
# swallow-ok: a failed version read becomes a HEALTH row and sdrift=unknown
if ! vers=$(ts_jira versions --project "$proj" 2>/dev/null); then
    add HEALTH - "jira: the version list is unreadable" jira "jira versions --project $proj"
    finish unknown
fi
cur=$(printf '%s\n' "$vers" | awk -F'\t' '$2 == "false" && $4 != "true" { printf "%s\t%06d\t%s\n", ($3 == "" ? "9999-99-99" : $3), NR, $1 }' | sort | head -n 1 | cut -f3)
if [ -n "$cur" ]; then
    vseen="" vfound=""
    while IFS= read -r later; do
        [ -n "$later" ] && [ "$later" != "$cur" ] || continue
        jlater=$(printf '%s' "$later" | sed 's/[\\"]/\\&/g') jcur=$(printf '%s' "$cur" | sed 's/[\\"]/\\&/g')
        vjql="project = $proj AND status in (\"In Progress\",\"In Review\",\"IN CI\",\"Done\") AND fixVersion = \"$jlater\" AND fixVersion != \"$jcur\""
        # swallow-ok: a failed search becomes a HEALTH row and sdrift=unknown
        if ! vrows=$(ts_jira list --jql "$vjql" --limit 300 2>/dev/null); then
            add HEALTH - "jira: the later-version search is unreadable" jira "jira list --jql '$vjql'"
            finish unknown
        fi
        vrows=$(printf '%s\n' "$vrows" | awk -F'\t' '$1 ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/ && NF >= 3 { print $1 "\t" $3 }')
        if [ "$(printf '%s\n' "$vrows" | grep -c .)" -ge 300 ]; then
            add HEALTH - "jira: the later-version search hit its limit (300)" jira "narrow the search in status-drift.sh"
            finish unknown
        fi
        while IFS=$'\t' read -r vk vst; do
            [ -n "$vk" ] || continue
            case " $vseen " in *" $vk "*) continue ;; esac
            vseen="$vseen $vk"
            vfound="$vfound$vk"$'\t'"$vst"$'\t'"$later"$'\n'
        done <<<"$vrows"
    done <<<"$(printf '%s\n' "$vers" | awk -F'\t' '$2 == "false" && $4 != "true" { print $1 }')"
    vstore=ok
    if [ -n "$vfound" ] && ! vd_rulings "$vseen"; then vstore=unreadable VRUL=""; fi
    qcur=$(printf '%q' "$cur")
    while IFS=$'\t' read -r vk vst later; do
        [ -n "$vk" ] || continue
        rrow=$(printf '%s\n' "${VRUL:-}" | awk -F'\t' -v k="$vk" '$1 == k { print; exit }')
        if [ -n "$rrow" ]; then
            IFS=$'\t' read -r _ rid rts rep rown <<<"$rrow"
            if ! vd_newer "$vk" "$rep"; then
                add AWAITING "$vk" "$rown since=$rts ruling=$rid what=the INTAKE to $cur was refused, status=$vst in=$later source=ruling" release-manager "none while $rid stands: a newer merged PR, status change or admission re-raises the INTAKE" "$rown"
                continue
            fi
        fi
        qlater=$(printf '%q' "$later")
        add VERSION-DRIFT "$vk" "status=$vst in=$later current=$cur" release-manager "jira release request $qcur --verb INTAKE --key $vk --from $qlater --to $qcur --why \"worked ticket held in a later version\""
    done <<<"$vfound"
    if [ "$vstore" != ok ]; then
        add HEALTH - "release: the rulings of $cur are unreadable" release-manager "jira release state $qcur"
        finish unknown
    fi
fi

# --- from the outcome log ----------------------------------------------------------
if [ -n "$logtail" ]; then
    mkeys_all=$(jq -rs '[.[] | select(.event == "merge" and .key != null and has("contract"))] | group_by(.key) | map(last | select(.contract == "yes") | .key) | .[]' <<<"$logtail" 2>/dev/null) # swallow-ok: an unparsable window leaves MERGE-MISMATCH empty
    mkeys=$(printf '%s\n' "$mkeys_all" | head -n 20)
    nmk=$(printf '%s\n' "$mkeys_all" | grep -c .) || nmk=0
    if [ "$nmk" -gt 20 ]; then
        add HEALTH - "MERGE-MISMATCH checked 20 of $nmk merge rows (coverage incomplete)" "$LOG" "rerun after the oldest merge rows age out of the window"
    fi
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        if ts_read_jira "$k"; then
            [ "$TS_J_STATUS" = Done ] || add MERGE-MISMATCH "$k" "merge row has contract=yes but the ticket is $TS_J_STATUS" merge-on-green.sh "jira transition $k Done"
        else
            add HEALTH "$k" "status unknown (stage=get)" jira "$SWEEP_FIX"
        fi
    done <<<"$mkeys"
    while IFS=$'\t' read -r k p ev st; do
        [ -n "$k" ] || continue
        ts_derive "$k"
        [ "$TS_RULE" != D0 ] || continue
        [ "$TS_DERIVED" = no-write ] || [ "$TS_DERIVED" != "$TS_J_STATUS" ] || continue
        add MISSED "$k" "${p:+pr=$p }event=$ev${st:+ stage=$st} has no later moved or noop row" "$FUNNEL" "bash scripts/handover/chief-kit/worker-jira-status.sh $k --event sweep"
    done < <(jq -rs '[.[] | select(.key != null and .key != "-")] | group_by([.key, (.pr // "")])[]
        | . as $g | ([range(0; length)] | map(select($g[.].result == "miss")) | last) as $m
        | select($m != null)
        | select([$g[($m + 1):][] | select(.result == "moved" or .result == "noop")] | length == 0)
        | [$g[$m].key, ($g[$m].pr // ""), ($g[$m].event // ""), ($g[$m].stage // "")] | @tsv' <<<"$logtail" 2>/dev/null) # swallow-ok: an unparsable window leaves MISSED empty
fi

finish known
