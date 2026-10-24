#!/usr/bin/env bash
# scripts/handover/console-kit/status-drift.sh - the report-only drift check
# over the derive-and-set status funnel. It runs the derive dry for every active
# key and compares the result with Jira, which covers every forward and
# backward move, then checks worker records against locks, docs and the WORKER
# comment. It never writes Jira, a record or the outcome log; the sweep
# (status-sweep.sh) is the fixer.
#
# Usage: status-drift.sh [--repo <owner/repo>] [--docs-dir <dir>] [--snapshot <dir>]
#   --docs-dir is where leg docs are scanned for a second owner (default the
#   handover root).
#   --snapshot is a status-sweep.sh --snapshot-out dir: the derive takes the PRs,
#   their checks and threads from it instead of gh per key. A dir without prs.json
#   and threads.tsv is ignored (live reads). Jira is still read fresh.
#
# One row per finding, `CLASS KEY detail | writer=<script> | fix=<command>`:
#   DERIVE-MISMATCH   Jira differs from derive(now); names the D rule and direction
#   MERGE-MISMATCH    a contract-yes merge row, but the ticket is not Done
#   DONE-WITH-OPEN-PR Done, but a PR whose title's first [KEY] is the key is open
#   MISSED            a miss with no later moved or noop row for the same key and PR,
#                     unless a derive now settles the key (Done or off the ladder, or
#                     Jira already at the derived status)
#   WORKER-STALE      the record says live or idle, but the lock is released or the doc ended
#   WORKER-COMMENT    the WORKER comment hash differs from the one the record's class gives
#   TWO-OWNERS        two live docs claim one key
#   UNOWNED           started, no open PR, no live owner
#   HELD-IN-WORK      labelled held, with a live owner or an open PR
#   HEALTH            an input is unreadable or saturated, the log is unwritable
#                     or carries a disabled row, or a status is unknown
# The last line is `sdrift=<n>:<sig8>` (n rows, sig8 over the sorted rows), or
# `sdrift=unknown` when the open-PR list or the Jira search could not be read in
# full. Always exits 0 (2 on a usage error).
#
# The active keys are the open-PR keys, the keys of records that are not
# wrapped, and the keys the Jira search finds in a ladder status. Log-based
# classes look at the last 500 rows only. The whole pass is cut off at
# TICKET_STATUS_DRIFT_BUDGET seconds (default 90).
#
# ponytail: without --snapshot the derive reads gh live per key that has a ladder
# status (~4 s a key), upgrade path = always pass the sweep's snapshot.
#
# Env: TICKET_STATUS_STATE_DIR, JIRA_PROJECT_KEY (default HIMMEL); the rest is
# read by the lib.
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
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
# shellcheck source=../../lib/env-value.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/env-value.sh"
# shellcheck source=../../lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh"

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
            echo "HEALTH - drift: the pass was cut off after ${BUDGET}s | writer=- | fix=bash scripts/handover/console-kit/status-drift.sh"
            echo "sdrift=unknown" ;;
    esac
    exit 0
fi

STATE="$(ts_state_dir)"
LOG="$STATE/status-events.jsonl"
SWEEP_FIX="bash scripts/handover/console-kit/status-sweep.sh"
FUNNEL="leg-jira-status.sh"
rows=""
add() { # <class> <key> <detail> <writer> <fix>
    rows="$rows$1 $2 $3 | writer=$4 | fix=$5"$'\n'
}
finish() { # <unknown>
    local n sig
    rows=$(printf '%s' "$rows" | sed '/^$/d' | sort -u)
    [ -z "$rows" ] || printf '%s\n' "$rows"
    if [ "$1" = unknown ]; then echo "sdrift=unknown"; exit 0; fi
    n=$(printf '%s\n' "$rows" | grep -c .)
    sig=$(printf '%s' "$rows" | cksum | awk '{ printf "%08x", $1 }')
    echo "sdrift=$n:$sig"
    exit 0
}
bounded() {
    local s=$1
    shift
    if [ -n "$_TIMEOUT_BIN" ]; then "$_TIMEOUT_BIN" -k 2 "$s" "$@"; else "$@"; fi
}

# --- health of the log -------------------------------------------------------------
if [ -e "$LOG" ] && { [ ! -f "$LOG" ] || [ ! -w "$LOG" ]; }; then
    add HEALTH - "log: $LOG is unwritable" - "make the outcome log a writable file"
elif [ ! -e "$LOG" ] && [ -d "$STATE" ] && [ ! -w "$STATE" ]; then
    add HEALTH - "log: $STATE is unwritable" - "make the state dir writable"
fi
logtail=""
if [ -f "$LOG" ]; then
    logtail=$(tail -n 500 "$LOG" 2>/dev/null | jq -Rc 'fromjson? // empty' 2>/dev/null) # swallow-ok: an unreadable log leaves the log-based classes empty and the health row above stands
fi
if [ -n "$logtail" ] && [ -n "$(jq -r 'select(.result == "disabled") | 1' <<<"$logtail" | head -n 1)" ]; then
    add HEALTH - "log: a disabled row in the last 500 rows (the funnel was off, so this sample is not clean)" - "unset WORKER_SESSION_JIRA_STATUS and LEG_JIRA_STATUS (0 in either disables the funnel)"
fi

# --- the snapshot ------------------------------------------------------------------
# swallow-ok: an unreadable PR list becomes a HEALTH row below, never a plausible count
prs=$(bounded 30 gh pr list --state open --limit 300 --json number,title 2>/dev/null) || prs=""
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

is_owner_state() { case "$1" in live|idle|IDLE-HELD) return 0 ;; *) return 1 ;; esac; }

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

# --- per key -----------------------------------------------------------------------
while IFS= read -r key; do
    [ -n "$key" ] || continue
    unset TS_EVENT
    # shellcheck disable=SC2034  # read by ticket-status.sh
    if [ -n "$SNAP" ]; then TS_SNAPSHOT_DIR="$SNAP"; else unset TS_SNAPSHOT_DIR; fi
    ts_derive "$key"
    jstatus="$TS_J_STATUS" derived="$TS_DERIVED" rule="$TS_RULE" result="$TS_RESULT" stage="$TS_STAGE"
    wstate_derive="$TS_WORKER_STATE" pr_state="$TS_PR_STATE"
    open_prs=$(printf '%s' "$pr_keys" | awk -F'\t' -v k="$key" '$1 == k { printf "%s#%s", (n++ ? "," : ""), $2 }')

    if [ "$derived" = no-write ]; then
        [ "$result" != miss ] || add HEALTH "$key" "status unknown (stage=${stage:-?}${rule:+ rule=$rule})" "$FUNNEL" "$SWEEP_FIX"
    elif [ "$derived" != "$jstatus" ]; then
        if [ "$(ts_rank "$derived")" -gt "$(ts_rank "$jstatus")" ]; then dir=forward; else dir=backward; fi
        add DERIVE-MISMATCH "$key" "jira=$jstatus derived=$derived rule=$rule dir=$dir" "$FUNNEL --event sweep" "$SWEEP_FIX"
    fi
    if [ "$jstatus" = Done ] && [ -n "$open_prs" ]; then
        add DONE-WITH-OPEN-PR "$key" "Done with open PR $open_prs" jira "close or retitle the PR, or reopen the ticket by hand"
    fi

    ts_record_read "$key" || continue
    leg=$(jq -r '.leg // ""' <<<"$TS_REC")
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    rstate=$(jq -r '.state // ""' <<<"$TS_REC")
    wstate=none
    [ -z "$doc" ] || wstate=$(ts_worker_state "$doc")

    if { [ "$rstate" = live ] || [ "$rstate" = idle ]; } && { [ "$wstate" = wrapped ] || [ "$wstate" = unknown ]; }; then
        add WORKER-STALE "$key" "record=$rstate but the doc/lock says $wstate" "$FUNNEL --event sweep" "$SWEEP_FIX"
    fi

    if [ "$derived" != no-write ] && [ -n "$leg$doc" ]; then
        heads=$(printf '%s' "$pr_state" | awk -F'\t' 'NF { printf "%s#%s@%s", (n++ ? "," : ""), $1, substr($2, 1, 9) }')
        want=$(printf '%s|%s|%s|%s' "$leg" "$wstate_derive" "$heads" "$derived" | cksum | awk '{ print $1 }')
        have=$(jq -r '.comment_hash // ""' <<<"$TS_REC")
        if [ "$want" != "$have" ]; then
            add WORKER-COMMENT "$key" "record hash ${have:-none} vs class hash $want" "$FUNNEL" "bash scripts/handover/console-kit/leg-jira-status.sh $key --event sweep"
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
    [ "$nown" -lt 2 ] || add TWO-OWNERS "$key" "$nown live docs claim it" - "wrap or halt all but one leg doc"

    if [ "$(ts_rank "$jstatus")" -ge 1 ] && [ -z "$open_prs" ]; then
        case "$wstate" in none|wrapped) add UNOWNED "$key" "$jstatus with no open PR and no live owner" "$FUNNEL" "dispatch a RESUME leg, or $SWEEP_FIX" ;; esac
    fi

    if [ "$jstatus" != Done ] && { [ -n "$open_prs" ] || is_owner_state "$wstate"; }; then
        # swallow-ok: an unreadable ticket raises no HELD-IN-WORK row; the derive miss already raised a HEALTH row
        if jq -e '(.fields.labels // []) | index("held")' >/dev/null 2>&1 <<<"$(ts_jira get "$key" --json 2>/dev/null)"; then
            add HELD-IN-WORK "$key" "held while ${open_prs:+PR $open_prs open}${open_prs:+${wstate:+ and }}owner $wstate" "ticket-hold.sh" "bash scripts/handover/console-kit/ticket-hold.sh $key --release"
        fi
    fi
done <<<"$keys"

# --- from the outcome log ----------------------------------------------------------
if [ -n "$logtail" ]; then
    mkeys_all=$(jq -rs '[.[] | select(.event == "merge" and .key != null)] | group_by(.key) | map(last | select(.contract == "yes") | .key) | .[]' <<<"$logtail" 2>/dev/null) # swallow-ok: an unparsable window leaves MERGE-MISMATCH empty
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
        add MISSED "$k" "${p:+pr=$p }event=$ev${st:+ stage=$st} has no later moved or noop row" "$FUNNEL" "bash scripts/handover/console-kit/leg-jira-status.sh $k --event sweep"
    done < <(jq -rs '[.[] | select(.key != null and .key != "-")] | group_by([.key, (.pr // "")])[]
        | . as $g | ([range(0; length)] | map(select($g[.].result == "miss")) | last) as $m
        | select($m != null)
        | select([$g[($m + 1):][] | select(.result == "moved" or .result == "noop")] | length == 0)
        | [$g[$m].key, ($g[$m].pr // ""), ($g[$m].event // ""), ($g[$m].stage // "")] | @tsv' <<<"$logtail" 2>/dev/null) # swallow-ok: an unparsable window leaves MISSED empty
fi

finish known
