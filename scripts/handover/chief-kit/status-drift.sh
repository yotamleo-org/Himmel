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
#                     `queue-lock.sh status` calls STALE-DEAD (the fix is the reap). A chief-owned
#                     park (rule D6n: the worker wrapped and its brief says Completes ticket: no)
#                     is UNOWNED once it is 24 h old, saying it is awaiting the chief and overdue
#   AWAITING          the same chief-owned park before its 24 h are up: a wait, not drift. Its row
#                     ends in ` | wait=chief`. So is a ticket-hold.sh hold (a result=moved hold row with a valid
#                     owner, while the ticket carries the `held` label) until its until date (end of that UTC day),
#                     else its owner's wait length; the row ends in ` | wait=<owner>`. A held ticket with no valid
#                     hold row says `held with no owner on record` on its UNOWNED row
#   HELD-IN-WORK      labelled held, with a live owner or an open PR
#   VERSION-DRIFT    Done or worked (In Progress / In Review / IN CI), held only in a later unreleased
#                     version than the current one; the fix is an INTAKE request to the current version.
#                     The release manager's rulings are read first: when the key's latest ruling refused
#                     its INTAKE and no merged PR naming it, status change or admissions-ledger row is
#                     newer, the row is AWAITING `<owner> since=<ts> ruling=<id>` ending in ` | wait=<owner>`
#                     (rm or operator) instead. An unreadable ruling store is a HEALTH row and sdrift=unknown
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
# ponytail: without --snapshot the derive reads gh live per key that has a ladder
# status (~4 s a key), upgrade path = always pass the sweep's snapshot.
#
# Env: TICKET_STATUS_STATE_DIR, JIRA_PROJECT_KEY (default HIMMEL); TICKET_STATUS_NOW (epoch, the clock),
# TICKET_STATUS_AWAIT_TTL_CHIEF (default 24h), TICKET_STATUS_AWAIT_TTL_OPERATOR and _OTHER (default 72h) and
# TICKET_STATUS_AWAIT_MAX (default 14d, at most 14d), each
# <n>h or <n>d, else the default and one HEALTH row; the rest is read by the lib.
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
load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../../.." 2>/dev/null)" HANDOVER_DIR 2>/dev/null || true # swallow-ok: an unreadable .env leaves the resolver's own fallback, as before

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
    n=$(printf '%s\n' "$rows" | grep -Ev '^AWAITING .* \| wait=(chief|operator|[a-z][a-z0-9-]{0,31})$' | grep -c .)
    sig=$(printf '%s' "$rows" | cksum | awk '{ printf "%08x", $1 }')
    echo "sdrift=$n:$sig"
    exit 0
}
bounded() {
    local s=$1
    shift
    if [ -n "$_TIMEOUT_BIN" ]; then "$_TIMEOUT_BIN" -k 2 "$s" "$@"; else "$@"; fi
}

NOW="${TICKET_STATUS_NOW:-}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac
await_secs() {
    local v n
    AWAIT_SECS=$2
    v="${!1:-}"
    [ -n "$v" ] || return 0
    if [[ "$v" =~ ^[1-9][0-9]{0,3}[hd]$ ]]; then
        n=${v%[hd]}
        case "$v" in *h) n=$((n * 3600)) ;; *) n=$((n * 86400)) ;; esac
        if [ "$n" -le "$3" ]; then AWAIT_SECS=$n; return 0; fi
    fi
    add HEALTH - "env: $1 is not <n>h or <n>d (at most 14d for the cap); the default is used" - "set $1 to a value like 24h"
}
await_secs TICKET_STATUS_AWAIT_MAX 1209600 1209600
AWAIT_MAX_S=$AWAIT_SECS
await_secs TICKET_STATUS_AWAIT_TTL_CHIEF 86400 1000000000
AWAIT_TTL_CHIEF_S=$AWAIT_SECS
await_secs TICKET_STATUS_AWAIT_TTL_OPERATOR 259200 1000000000
AWAIT_TTL_OPERATOR_S=$AWAIT_SECS
await_secs TICKET_STATUS_AWAIT_TTL_OTHER 259200 1000000000
AWAIT_TTL_OTHER_S=$AWAIT_SECS
iso_of() { TZ=UTC date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; } # swallow-ok: the BSD form follows

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
partials="" parkrows="" holdrows=""
if [ -f "$LOG" ]; then
    # Every key whose latest merge row carrying a contract is partial (contract=no), with its partial PRs, read once from the
    # WHOLE log: the last 500 rows hold about five hours, so a ticket a partial merge left days ago would name no PR there.
    mergeout=$(ts_merge_rows "$LOG" 2>/dev/null) # swallow-ok: an unreadable log names no partial PR and no park start, and the generic fix stands
    partials=$(jq -Rrs '[split("\n")[] | fromjson? | select(type == "object" and .event == "merge" and .key != null and has("contract") and .contract != "")]
        | group_by(.key)[] | select(last.contract == "no")
        | [.[0].key, ("#" + ([.[] | select(.contract == "no") | .pr // empty | tostring] | reduce .[] as $p ([]; if index([$p]) then . else . + [$p] end) | join(", #")))] | @tsv' <<<"$mergeout" 2>/dev/null) # swallow-ok: as above
    parkrows=$(jq -Rrs '[split("\n")[] | fromjson? | select(type == "object" and .key != null and (.ts | type) == "string")]
        | group_by(.key)[] | . as $g
        | ([range(0; length) | select($g[.] | (.event == "merge" and has("contract") and .contract != "") or (.result == "moved" and .event != "hold" and .event != "hold-release") or (.event == "live" and .result != "skip" and .result != "disabled"))] | last // 0) as $a
        | ("D6n", "D5c") as $r
        | ([$g[$a:][] | select(.rule == $r)] | first) as $f
        | select($f != null)
        | [$g[0].key, $r, $f.ts] | @tsv' <<<"$mergeout" 2>/dev/null) # swallow-ok: as above
    holdrows=$(jq -Rr 'fromjson? | select(type == "object" and (.event == "hold" or .event == "hold-release") and .result == "moved" and (.key | type) == "string")
        | def ok($re): if type == "string" and test($re) then . else "" end;
        [.key, .event, (.ts | ok("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z")),
            (.owner | ok("\\A(chief|operator|[a-z][a-z0-9-]{0,31})\\z")), (.until | ok("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z")),
            ((.reason // "") | if type == "string" then gsub("[|\t\r\n\u001f]"; "") else "" end)] | join("\u001f")' <<<"$mergeout" 2>/dev/null) # swallow-ok: as above
fi
date_ok() {
    local e
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    e=$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$1" +%s 2>/dev/null) || return 1 # swallow-ok: the BSD form follows
    [ "$(date -u -d "@$e" +%Y-%m-%d 2>/dev/null || date -u -r "$e" +%Y-%m-%d 2>/dev/null)" = "$1" ] # swallow-ok: the BSD form follows
}
hold_of() {
    local line ev
    H_SINCE="" H_OWNER="" H_UNTIL="" H_REASON=""
    line=$(awk -F'\037' -v k="$1" '$1 == k { l = $0 } END { if (l != "") print l }' <<<"$holdrows")
    [ -n "$line" ] || return 1
    IFS=$'\037' read -r _ ev H_SINCE H_OWNER H_UNTIL H_REASON <<<"$line"
    [ "$ev" = hold ] && [ -n "$H_OWNER" ] && [ -n "$H_SINCE" ] && _ts_epoch_of_iso "$H_SINCE" >/dev/null || return 1
    date_ok "$H_UNTIL" || H_UNTIL=""
}
park_since() { # <KEY> <rule> - the ISO ts of the key's park start; empty when there is none or it does not parse
    local t
    t=$(awk -F'\t' -v k="$1" -v r="$2" '$1 == k && $2 == r { print $3; exit }' <<<"$parkrows")
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && _ts_epoch_of_iso "$t" >/dev/null && printf '%s' "$t"
}
if [ -n "$logtail" ] && [ -n "$(jq -r 'select(.result == "disabled") | 1' <<<"$logtail" | head -n 1)" ]; then
    add HEALTH - "log: a disabled row in the last 500 rows (the funnel was off, so this sample is not clean)" - "unset WORKER_SESSION_JIRA_STATUS (0 disables the funnel)"
fi

# --- the snapshot ------------------------------------------------------------------
prs=""
if ts_scan_gate status-drift graphql core; then
    # swallow-ok: an unreadable PR list becomes a HEALTH row below, never a plausible count
    prs=$(bounded 30 gh pr list --state open --limit 300 --json number,title 2>/dev/null) || prs=""
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

# 0 when a comment on the ticket names a PR that gh reports OPEN and whose title's first [KEY]
# is this ticket. The pr list above only sees this repo, so a ticket whose PR lives elsewhere
# looks ownerless without this. The title binds the PR to the ticket: a PR a comment merely
# cites (another ticket's, an upstream one) exempts nothing. A closed or merged PR, a PR
# titled for another ticket or none, or a failed gh read is not a yes: the ticket's rows stay.
MIRROR_DIR="${TICK_TRACKER_MIRROR_DIR:-$HOME/.himmel/state/jira-mirror/${JIRA_PROJECT_KEY:-HIMMEL}}"
# A ticket's labels and comments come from its file in the local Jira mirror, as its status and type do for the
# merged-no-row class below: one live `jira get` or `jira comments` per ticket cost 37 s of a traced pass.
# A key the mirror lacks, a file with no `labels:` line (labels) or no `## Comments` heading (comments) is read live.
# ponytail: the mirror is as fresh as the last focus refresh, which mirrors just before this pass; upgrade path =
# compare the file's updated field with the ticket's before trusting a label.
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
        row=$(bounded 20 gh pr view "$u" --json state,title --jq '.state + "\t" + .title' 2>/dev/null) || continue
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

# --- per key -----------------------------------------------------------------------
while IFS= read -r key; do
    [ -n "$key" ] || continue
    unset TS_EVENT
    deadlock=0
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
        ws=$wstate_derive
        [ "$ws" != none ] || ws=$wstate
        case "$ws" in IDLE-HELD|parked)
            ldoc=${owner_doc:-$doc}
            if [ -n "${TICKET_STATUS_QUEUE_LOCK:-}" ]; then
                lout=$("$TICKET_STATUS_QUEUE_LOCK" status "$ldoc" 2>/dev/null); lrc=$? # swallow-ok: an unreadable lock status leaves the owner standing
            else
                lout=$(bash "$HERE/../queue-lock.sh" status "$ldoc" 2>/dev/null); lrc=$? # swallow-ok: as above
            fi
            if [ "$lrc" = 12 ] && grep -q '^status: STALE-DEAD' <<<"$lout"; then deadlock=1; fi ;;
        esac
        noworker=$deadlock
        case "$ws" in none|wrapped) noworker=1 ;; esac
        if [ "$noworker" = 1 ]; then
            # rule D5c leaves a partly merged ticket here: name the partial PRs the ticket's merge rows record
            ppr=$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' <<<"$partials")
            psince=""
            [ "$rule" != D6n ] || psince=$(park_since "$key" D6n)
            held=0 hvalid=0 usehold=0 hhint=""
            if has_label "$key" held; then
                held=1
                if hold_of "$key"; then
                    hvalid=1
                    if [ -z "$psince" ] || [ "$(_ts_epoch_of_iso "$H_SINCE")" -ge "$(_ts_epoch_of_iso "$psince")" ]; then usehold=1; fi
                fi
            fi
            if [ "$held" = 1 ] && [ "$hvalid" = 0 ]; then hhint="; held with no owner on record: re-run ticket-hold.sh $key --owner <who> --until <date> --reason <why>"; fi
            if [ "$usehold" = 1 ]; then
                hsec=$(_ts_epoch_of_iso "$H_SINCE")
                if [ -n "$H_UNTIL" ]; then
                    due=$(_ts_epoch_of_iso "${H_UNTIL}T23:59:59Z")
                else
                    case "$H_OWNER" in chief) ttl=$AWAIT_TTL_CHIEF_S ;; operator) ttl=$AWAIT_TTL_OPERATOR_S ;; *) ttl=$AWAIT_TTL_OTHER_S ;; esac
                    due=$((hsec + ttl))
                fi
                [ "$due" -le $((hsec + AWAIT_MAX_S)) ] || due=$((hsec + AWAIT_MAX_S))
                holdfix="$H_OWNER acts on $key, or re-hold it: bash scripts/handover/chief-kit/ticket-hold.sh $key --owner <who> --until <date> --reason <why>"
                if [ "$NOW" -lt "$due" ]; then
                    add AWAITING "$key" "$H_OWNER since=$H_SINCE due=$(iso_of "$due") what=$H_REASON source=hold" ticket-hold.sh "$holdfix" "$H_OWNER"
                else
                    add UNOWNED "$key" "$jstatus with no open PR and no live owner, awaiting $H_OWNER since $H_SINCE and overdue (due $(iso_of "$due"))" ticket-hold.sh "$holdfix"
                fi
            elif [ "$deadlock" = 1 ]; then
                add UNOWNED "$key" "$jstatus with no open PR and its worker's lock is STALE-DEAD$hhint" "$FUNNEL" "bash scripts/handover/queue-lock.sh status --sweep --reap-dead (the reap appends a HALTED bullet, so the next derive reads $key wrapped, after two gone sweeps if that append failed; it releases every STALE-DEAD lock under the root, each re-proved under its claim and CAS)"
            elif [ -n "$psince" ]; then
                ttl=$AWAIT_TTL_CHIEF_S
                [ "$ttl" -le "$AWAIT_MAX_S" ] || ttl=$AWAIT_MAX_S
                due=$(($(_ts_epoch_of_iso "$psince") + ttl))
                chieffix="the chief closes $key by hand when nothing remains, or dispatches a RESUME worker for the rest"
                if [ "$NOW" -lt "$due" ]; then
                    what=$(printf '%s' "the worker wrapped and the brief says Completes ticket: no, so the chief decides the remainder" | tr -d '|\t\r\n')
                    add AWAITING "$key" "chief since=$psince due=$(iso_of "$due") what=$what source=d6n" "$FUNNEL" "$chieffix" chief
                else
                    add UNOWNED "$key" "$jstatus with no open PR and no live owner, awaiting the chief since $psince and overdue (due $(iso_of "$due"))$hhint" "$FUNNEL" "$chieffix"
                fi
            elif [ -n "$ppr" ]; then
                add UNOWNED "$key" "$jstatus with no open PR and no live owner, left by partial merge PR $ppr$hhint" "$FUNNEL" "bash scripts/handover/chief-kit/next-dispatchable.sh lists $key: dispatch the RESUME worker it names; close $key by hand when it says HANDED-OFF (the remainder is on other tickets); or, when it says NEEDS-CHIEF-NOTE, add the remainder to the partial PR's body or close $key by hand if nothing remains"
            else
                add UNOWNED "$key" "$jstatus with no open PR and no live owner$hhint" "$FUNNEL" "dispatch a RESUME worker, or $SWEEP_FIX"
            fi
        fi
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
# ponytail: the mirror is as fresh as the last focus refresh, which mirrors just before this pass; upgrade
# path = compare the file's updated field with the PR's merge time before trusting a Done or open status.
MNR_LIMIT="${TICKET_STATUS_DRIFT_MNR_LIMIT:-1000}"
case "$MNR_LIMIT" in ''|*[!0-9]*) MNR_LIMIT=1000 ;; esac
mday() { date -u -d "$1 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"$1"d +%Y-%m-%d 2>/dev/null; } # swallow-ok: no date is the unreadable case the merged list check turns into a HEALTH row
mlist() { bounded 20 gh pr list --state merged --search "$1" --limit "$MNR_LIMIT" --json number,title,mergedAt 2>/dev/null; }
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
# ponytail: the release is named after the version, upgrade path = a release lookup in the CLI once a
# release declares several versions.
proj="${JIRA_PROJECT_KEY:-HIMMEL}"
VD_EP='def ep: [sub("\\.[0-9]+"; "") | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")]
    | if length == 1 then .[0] else error("not a time") end | (.d + "Z" | fromdateiso8601) - (if .z == "Z" then 0 else ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) * (if .z[0:1] == "+" then 1 else -1 end) end);'
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
