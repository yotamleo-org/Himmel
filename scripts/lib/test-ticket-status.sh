#!/usr/bin/env bash
# A parked marker after WRAPPED must keep the worker parked, in either spelling.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/ticket-status.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/ticket-status-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected [$3] got [$2]"
        fails=$((fails + 1))
    fi
}

# The lock is fresh; the fixture never touches the station's real queue locks.
printf '#!/usr/bin/env bash\nexit 11\n' > "$tmp/lock.sh"
chmod +x "$tmp/lock.sh"
export TICKET_STATUS_QUEUE_LOCK="$tmp/lock.sh"
export QUEUE_LOCK_IDLE_WARN_SECONDS=2700
for marker in PARKED-USAGE PARKED-BANK; do
    printf -- '- 10:00 LIVE — started\n- 10:10 WRAPPED — ended\n- 10:20 %s — usage limit\n' "$marker" > "$tmp/worker.md"
    check "$marker is the newest marker after WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE
    check "$marker reports a parked worker, not wrapped" "$(ts_worker_state "$tmp/worker.md")" parked
    _ts_worker_state "$tmp/worker.md"
    check "$marker still reads its held lock" "$TS_LOCK_HELD" yes
done

printf -- '- 10:30 SUCCESSION accepted: next-chief replaces prior-chief\n' >> "$tmp/worker.md"
check "SUCCESSION after parking remains the newest marker" "$(ts_marker_newest "$tmp/worker.md")" SUCCESSION
check "SUCCESSION after parking resumes a live worker" "$(ts_worker_state "$tmp/worker.md")" live

printf -- '- 10:00 WRAPPED\n- PARKED-USAGE — usage limit\n' > "$tmp/worker.md"
check "untimestamped parked bullet overrides WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE
printf -- '- 10:00 WRAPPED\n- 10:20 **PARKED-USAGE** — usage limit\n' > "$tmp/worker.md"
check "bold parked bullet overrides WRAPPED" "$(ts_marker_newest "$tmp/worker.md")" PARKED-USAGE

# A wrapped primary owner cannot end a ticket still held by a parked second doc.
export TICKET_STATUS_STATE_DIR="$tmp/state" TS_SNAPSHOT_DIR="$tmp/snap" TS_EVENT=sweep
mkdir -p "$TICKET_STATUS_STATE_DIR/workers" "$TS_SNAPSHOT_DIR"
printf 'HIMMEL-9001\tTask\tIn Progress\n' > "$TS_SNAPSHOT_DIR/jira.tsv"
printf '[]\n' > "$TS_SNAPSHOT_DIR/prs.json"
printf -- '- 10:00 WRAPPED — primary ended\n' > "$tmp/owner.md"
for marker in PARKED-USAGE PARKED-BANK; do
    printf -- '- 10:00 LIVE\n- 10:20 %s — usage limit\n' "$marker" > "$tmp/parked.md"
    jq -nc --arg doc "$tmp/owner.md" --arg other "$tmp/parked.md" \
        '{doc:$doc,docs:[$doc,$other],prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_derive HIMMEL-9001
    check "$marker second owner keeps the ticket In Progress" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'parked/D5/In Progress'
    check "$marker second owner is recorded as the lock holder" "$TS_OWNER_DOC" "$tmp/parked.md"
done

# ts_merge_rows drops a pre-merge row whose PR did not merge; ts_partial_merge and
# ts_done_pending read through it. The gh seam answers: PR 11 OPEN, PR 12 MERGED at h12, PR 13 never asked.
cat > "$tmp/mrgh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MRGH_LOG"
case "$3" in 11) echo "OPEN h11" ;; 12) echo "MERGED h12" ;; 13) echo "MERGED h13" ;; 14) echo "MERGED other" ;;
    16) case "$*" in *"--repo owner/r16"*) echo "MERGED h16" ;; *) echo "OPEN h16" ;; esac ;; *) exit 1 ;; esac
EOF
export MRGH_LOG="$tmp/mrgh.log"
chmod +x "$tmp/mrgh"
export MERGE_ROWS_GH="$tmp/mrgh"
log="$tmp/mr.jsonl"
mrow() { # <key> <pr> <head> <contract> <result> <stage> - one merge row
    printf '{"ts":"t","event":"merge","key":"%s","pr":"%s","head":"%s","contract":"%s","result":"%s","stage":"%s"}\n' "$@" >> "$log"
}
: > "$log"
mrow HIMMEL-9101 11 h11 yes pending pre-merge
mrow HIMMEL-9102 12 h12 yes pending pre-merge
mrow HIMMEL-9103 13 h13 yes pending pre-merge
printf '{"ts":"t","event":"merge","key":"HIMMEL-9103","pr":"13","head":"h13","result":"not-merged","stage":"merge-failed"}\n' >> "$log"
mrow HIMMEL-9104 14 h14 yes pending pre-merge
mrow HIMMEL-9105 15 h15 no pending pre-merge
mrow HIMMEL-9105 15 h15 no noop ""
mrow HIMMEL-9108 17 h17 yes pending pre-merge
printf '{"ts":"t","event":"merge","key":"HIMMEL-9108","pr":"17","head":"h17","result":"moved"}\n' >> "$log"
printf 'not json\n' >> "$log"
check "merge-rows: a pre-merge row whose PR is open is dropped" "$(ts_merge_rows "$log" | grep -c '"pr":"11"')" 0
check "merge-rows: one whose PR GitHub reports MERGED at its head is kept" "$(ts_merge_rows "$log" | grep -c '"pr":"12"')" 1
check "merge-rows: one followed by a not-merged row is dropped (GitHub would say MERGED), leaving only the not-merged row" "$(ts_merge_rows "$log" | grep -c '"pr":"13"')" 1
check "merge-rows: and GitHub was not asked about it" "$(grep -c 'pr view 13 ' "$MRGH_LOG")" 0
check "merge-rows: one merged at another head than the row's is dropped" "$(ts_merge_rows "$log" | grep -c '"pr":"14"')" 0
check "merge-rows: one a later merge row of the same PR and head follows is kept with that row" "$(ts_merge_rows "$log" | grep -c '"pr":"15"')" 2
check "merge-rows: a later contract-less merge row (an older funnel's derive row) does not confirm the pre-merge row" "$(ts_merge_rows "$log" | grep -c '"pr":"17".*"stage":"pre-merge"')" 0
check "merge-rows: an unparseable line passes through" "$(ts_merge_rows "$log" | grep -c 'not json')" 1
export TICKET_STATUS_STATE_DIR="$tmp/mrstate"
mkdir -p "$TICKET_STATUS_STATE_DIR"
cp "$log" "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
ts_done_pending HIMMEL-9101; check "merge-rows: ts_done_pending ignores an open PR's pre-merge row" "$?" 1
ts_done_pending HIMMEL-9102; check "merge-rows: ts_done_pending counts a pre-merge row of a merged PR" "$?" 0
ts_done_pending HIMMEL-9103; check "merge-rows: ts_done_pending ignores a not-merged PR" "$?" 1
ts_partial_merge HIMMEL-9105; check "merge-rows: ts_partial_merge reads the row that followed the pre-merge row" "$?" 0
printf '{"ts":"t","event":"merge","key":"HIMMEL-9106","pr":"16","head":"h16","repo":"owner/r16","contract":"yes","result":"pending","stage":"pre-merge"}\n' > "$tmp/repo.jsonl"
printf '{"ts":"t","event":"merge","key":"HIMMEL-9107","pr":"16","head":"h16","repo":"owner/other","contract":"yes","result":"pending","stage":"pre-merge"}\n' >> "$tmp/repo.jsonl"
check "merge-rows: the read names the row's repo, so a same-numbered PR elsewhere is not credited" "$(ts_merge_rows "$tmp/repo.jsonl" | grep -c '"key":"HIMMEL-9106"\|"key":"HIMMEL-9107"')" 1
check "merge-rows: and only the row of the repo that merged is kept" "$(ts_merge_rows "$tmp/repo.jsonl" | grep -c 'owner/r16')" 1
: > "$MRGH_LOG"
check "merge-rows: a spent read budget asks GitHub nothing and counts no unproven row" "$(MERGE_ROWS_BUDGET_SECS=0 ts_merge_rows "$tmp/repo.jsonl" 2>/dev/null | wc -l | tr -d ' ')" 0
check "merge-rows: and the budget run made no GitHub call" "$(wc -l < "$MRGH_LOG" | tr -d ' ')" 0
_TS_LIB_DIR="$tmp/nolib" ts_partial_merge HIMMEL-9105; check "merge-rows: ts_partial_merge reports rc 2, not no-partial, when the filter cannot run" "$?" 2
_TS_LIB_DIR="$tmp/nolib" ts_done_pending HIMMEL-9102; check "merge-rows: ts_done_pending reports an unreadable state (rc 2) when the filter cannot run" "$?" 2

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-ticket-status.sh"
else
    echo "FAIL - test-ticket-status.sh: $fails failure(s)"
    exit 1
fi
