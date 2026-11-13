#!/usr/bin/env bash
# A parked marker after WRAPPED must keep the worker parked, in either spelling.
# Platform guard: POSIX bash 3.2+.
# shellcheck disable=SC2034  # TS_OWNER_HELD is read by ts_owner in the sourced lib
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

# A wrapped owner with no PR and no merge row: an In Progress ticket stays In Progress (D6n) only when
# the brief says Completes ticket: no above ## Results; every other brief keeps D6 (To Do).
brief() { # <flag-line|-> - the owner doc: the Completes ticket line (when given) above ## Results
    { [ "$1" = - ] || printf '> **Completes ticket:** %s\n\n' "$1"
      printf '## Results (newest at the bottom)\n- 10:00 WRAPPED — ended\n'; } > "$tmp/owner.md"
    jq -nc --arg doc "$tmp/owner.md" '{doc:$doc,docs:[$doc],prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_derive HIMMEL-9001
}
brief no
check "completes no: an In Progress ticket stays In Progress" "$TS_RULE/$TS_DERIVED" 'D6n/In Progress'
brief yes
check "completes yes: To Do" "$TS_RULE/$TS_DERIVED" 'D6/To Do'
brief -
check "no flag line: To Do" "$TS_RULE/$TS_DERIVED" 'D6/To Do'
printf 'HIMMEL-9001\tTask\tIn Review\n' > "$TS_SNAPSHOT_DIR/jira.tsv"
brief no
check "completes no with Jira In Review: To Do" "$TS_RULE/$TS_DERIVED" 'D6/To Do'
printf 'HIMMEL-9001\tTask\tIn Progress\n' > "$TS_SNAPSHOT_DIR/jira.tsv"

for jstatus in "To Do" "In Progress"; do
    printf 'HIMMEL-9001\tTask\t%s\n' "$jstatus" > "$TS_SNAPSHOT_DIR/jira.tsv"
    jq -nc '{prs:{"7":{head:"abc",ci:"green",red_latch:false,open:false}}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_derive HIMMEL-9001
    check "never had a worker, closed PRs only, Jira $jstatus: D7 no-write, not D5" "$TS_RULE/$TS_DERIVED" 'D7/no-write'
done
printf 'HIMMEL-9001\tTask\tIn Progress\n' > "$TS_SNAPSHOT_DIR/jira.tsv"

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

# The merge rows are read once per pass, not once per key and question (31 s of a traced drift pass).
# A counting filter stands in for merge-rows-effective.py; the three questions about three keys share one read, and a
# log that grew since is read again.
mkdir -p "$tmp/countlib"
cat > "$tmp/countlib/merge-rows-effective.py" <<'EOF'
import os, runpy
with open(os.environ["MRC_LOG"], "a") as f:
    f.write("run\n")
runpy.run_path(os.environ["MRC_REAL"], run_name="__main__")
EOF
export MRC_LOG="$tmp/mrc.log" MRC_REAL="$_TS_LIB_DIR/merge-rows-effective.py"
: > "$MRC_LOG"
cl_all() { # <key>... - the three questions, answers as one string
    local k out=""
    for k in "$@"; do
        _TS_LIB_DIR="$tmp/countlib" ts_done_pending "$k"; out="$out$?"
        _TS_LIB_DIR="$tmp/countlib" ts_partial_merge "$k"; out="$out$?"
        _TS_LIB_DIR="$tmp/countlib" ts_has_merge_row "$k"; out="$out$?"
    done
    printf '%s' "$out"
}
ans=$(cl_all HIMMEL-9101 HIMMEL-9102 HIMMEL-9105)
check "9436: the answers over the counting filter are right: 9101 none, 9102 done-pending + a row, 9105 partial + a row" "$ans" "111010100"
check "9436: nine merge-row questions over one unchanged log run the filter once" "$(wc -l < "$MRC_LOG" | tr -d ' ')" 1
printf '{"ts":"t","event":"merge","key":"HIMMEL-9190","pr":"90","head":"h90","contract":"yes","result":"moved","stage":"x"}\n' >> "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
_TS_LIB_DIR="$tmp/countlib" ts_has_merge_row HIMMEL-9190; check "9436: a log that grew since the last read is read again and the new row seen" "$?:$(wc -l < "$MRC_LOG" | tr -d ' ')" "0:2"
sed 's/HIMMEL-9190/HIMMEL-9191/' "$TICKET_STATUS_STATE_DIR/status-events.jsonl" > "$TICKET_STATUS_STATE_DIR/status-events.new"
mv "$TICKET_STATUS_STATE_DIR/status-events.new" "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
_TS_LIB_DIR="$tmp/countlib" ts_has_merge_row HIMMEL-9190; a=$?
_TS_LIB_DIR="$tmp/countlib" ts_has_merge_row HIMMEL-9191; b=$?
check "9436: a log replaced by a file of the same size is read again, not served from the cache" "$a$b:$(wc -l < "$MRC_LOG" | tr -d ' ')" "10:3"

NOW=1794139200
export TICKET_STATUS_NOW=$NOW
iso_at() {
    local e=$((NOW - $1))
    date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ
}
ODUE=$(date -u -d "@$((NOW + 86400))" +%Y-%m-%d 2>/dev/null || date -u -r "$((NOW + 86400))" +%Y-%m-%d)
OK=HIMMEL-9301
OD="$tmp/odocs"
export PLOCK_DIR="$tmp/plock"
export TICKET_STATUS_STATE_DIR="$tmp/ostate" TS_SNAPSHOT_DIR="$tmp/osnap" TS_EVENT=sweep
olog="$TICKET_STATUS_STATE_DIR/status-events.jsonl"
mkdir -p "$TS_SNAPSHOT_DIR"
printf '%s\tTask\tIn Progress\n' "$OK" > "$TS_SNAPSHOT_DIR/jira.tsv"
printf '[]\n' > "$TS_SNAPSHOT_DIR/prs.json"
cat > "$tmp/plock.sh" <<'EOF'
#!/usr/bin/env bash
f="$PLOCK_DIR/$(basename "$2")"
rc=11 st=FRESH
[ -r "$f" ] && read -r rc st < "$f"
[ "$rc" = 0 ] && { echo free; exit 0; }
printf '{\n  "heartbeat": "%s"\n}\nstatus: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$st"
exit "$rc"
EOF
chmod +x "$tmp/plock.sh"
export TICKET_STATUS_QUEUE_LOCK="$tmp/plock.sh"

OLEGACY="LEGACY-1 LEGACY-2 LEGACY-3 LEGACY-4 LEGACY-5"
OEXEMPT="UNSEEN HELD-STALE"
check "ts_owner: the LEGACY list names five shapes" "$(echo "$OLEGACY" | wc -w | tr -d ' ')" 5
check "ts_owner: the exemption list names the two" "$OEXEMPT" "UNSEEN HELD-STALE"

ocell() {
    rm -rf "$TICKET_STATUS_STATE_DIR" "$PLOCK_DIR" "$OD"
    mkdir -p "$TICKET_STATUS_STATE_DIR/workers" "$PLOCK_DIR" "$OD"
    _TS_MI_SIG=""
    unset TS_OWNER_HELD TS_OWNER_ROWS
}
odoc() {
    local f=$1 flag=$2 b
    shift 2
    {
        [ "$flag" = - ] || printf '> **Completes ticket:** %s\n\n' "$flag"
        printf '## Results (newest at the bottom)\n'
        for b in "$@"; do printf -- '%s\n' "$b"; done
    } > "$f"
}
orec() {
    local x=$1 dl
    shift
    dl=$(printf '%s\n' "$@" | jq -Rnc '[inputs]')
    jq -nc --argjson x "$x" --argjson dl "$dl" --arg d "$1" --arg t "$(iso_at 60)" \
        '{doc: $d, docs: $dl, prs: {}, last_event_ts: $t} + $x' > "$TICKET_STATUS_STATE_DIR/workers/$OK.json"
}
olock() { printf '%s %s\n' "$2" "$3" > "$PLOCK_DIR/$(basename "$1")"; }
orow() {
    jq -nc --arg ts "$(iso_at "$1")" --arg e "$2" --arg k "$OK" --arg r "$3" --arg rule "$4" --argjson x "${5:-{\}}" \
        '{ts: $ts, event: $e, key: $k, result: $r} + (if $rule == "-" then {} else {rule: $rule} end) + $x' >> "$olog"
}
omerge() {
    orow "$1" merge moved - "$(jq -nc --argjson x "${3:-{\}}" --arg c "$2" '{pr: "41", head: "h41", contract: $c, stage: "x"} + $x')"
}
olive() { odoc "$OD/p.md" - '- 10:00 LIVE — x'; orec '{"lock_seen":true}' "$OD/p.md"; }
oparked() { odoc "$OD/p.md" - '- 10:00 LIVE — x' '- 10:20 PARKED-USAGE — limit'; orec '{"lock_seen":true}' "$OD/p.md"; }
owrap() { odoc "$OD/p.md" "$1" '- 10:00 WRAPPED — x'; orec '{"lock_seen":true}' "$OD/p.md"; }
oans() {
    ts_owner "$OK" | awk -F'\t' '$1 == "worker" { print "worker:" $2; next } $1 == "awaiting" { print "awaiting:" $2 ":" $5 ":" $3; next } { print $1 }'
}
ochk() {
    local ans need="" ok=0
    ts_derive "$OK"
    ans=$(oans)
    case "$ans" in
        none) [ "$TS_DERIVED" != "In Progress" ] || need=legacy ;;
        worker:*)
            if [ "$TS_LOCK_DEAD" = no ] && { [ "$TS_WORKER_STATE" = IDLE-HELD ] || [ "$TS_WORKER_STATE" = parked ]; }; then need=HELD-STALE
            elif [ "$TS_LOCK_HELD" = no ] && [ "$TS_LOCK_SEEN" = false ] && [ "$TS_DERIVED" = "In Progress" ]; then need=UNSEEN
            fi ;;
    esac
    case "$need" in
        legacy) case " $OLEGACY " in *" ${3:-} "*) ok=1 ;; esac ;;
        '') [ -z "${3:-}" ] && ok=1 ;;
        *) if [ "${3:-}" = "$need" ]; then case " $OEXEMPT " in *" $need "*) ok=1 ;; esac; fi ;;
    esac
    check "ts_owner $1: answers" "$ans" "$2"
    check "ts_owner $1: and its none or exemption is listed (${need:-no})" "$ok" 1
}

ocell; olive; ochk "W1 live" "worker:live"
ocell; olive; olock "$OD/p.md" 0 -; ochk "W2 lock gone once" "worker:unknown"
ocell; olive; orec '{"lock_seen":true,"lock_gone_sweeps":1}' "$OD/p.md"; olock "$OD/p.md" 0 -; ochk "W3 lock gone twice (wrapped, D6 To Do)" none
ocell; owrap -; ochk "W4 WRAPPED bullet (D6 To Do)" none
ocell; olive; orec '{"lock_seen":false}' "$OD/p.md"; olock "$OD/p.md" 0 -; ochk "W5 never-seen lock" "worker:unknown" UNSEEN
ocell; odoc "$OD/p.md" -; orec '{"lock_seen":true}' "$OD/p.md"; ochk "W6 held lock, doc with no bullet" "worker:unknown"
ocell; olive; olock "$OD/p.md" 12 STALE; ochk "W7 rc 12 STALE" "worker:IDLE-HELD" HELD-STALE
check "ts_owner W7: the lock is not proven dead" "$TS_LOCK_DEAD" no
ocell; olive; olock "$OD/p.md" 12 STALE-DEAD; ochk "W8 rc 12 STALE-DEAD" none LEGACY-5
check "ts_owner W8: the lock is proven dead" "$TS_LOCK_DEAD" yes
ocell; oparked; ochk "W9 parked, FRESH lock" "worker:parked"
check "ts_owner W9: no dead-lock reading" "$TS_LOCK_DEAD" ""
ocell; oparked; olock "$OD/p.md" 12 STALE; ochk "W10 parked, rc 12 STALE" "worker:parked" HELD-STALE
check "ts_owner W10: the lock is not proven dead" "$TS_LOCK_DEAD" no
ocell; oparked; olock "$OD/p.md" 12 STALE-DEAD; ochk "W11 parked, rc 12 STALE-DEAD" none LEGACY-5
check "ts_owner W11: the lock is proven dead" "$TS_LOCK_DEAD" yes
ocell; oparked; orec '{"lock_seen":false}' "$OD/p.md"; olock "$OD/p.md" 0 -; ochk "W16 parked over a free lock never seen held" "worker:parked" UNSEEN

HOLDROW='{"owner":"operator","reason":"r"}'
OWEDROW='{"remainder":"owed","owed":"operator","owed_due":"'$ODUE'"}'
for w in W8 W11; do
    ocell; if [ "$w" = W8 ]; then olive; else oparked; fi; olock "$OD/p.md" 12 STALE-DEAD
    orow 1800 hold moved - "$HOLDROW"; TS_OWNER_HELD=yes
    ochk "$w with a labelled hold" "awaiting:operator:hold:$(iso_at 1800)"
    check "ts_owner $w with a hold: the lock is proven dead" "$TS_LOCK_DEAD" yes
    ocell; if [ "$w" = W8 ]; then olive; else oparked; fi; olock "$OD/p.md" 12 STALE-DEAD
    omerge 1800 no "$OWEDROW"
    ochk "$w with an owed merge row" "awaiting:operator:owed:$(iso_at 1800)"
    check "ts_owner $w with an owed row: the lock is proven dead" "$TS_LOCK_DEAD" yes
done

ocell; odoc "$OD/p.md" - '- 10:00 WRAPPED — x'; odoc "$OD/a.md" - '- 10:00 LIVE — x'; odoc "$OD/b.md" - '- 10:00 LIVE — x'
orec '{"lock_seen":true}' "$OD/p.md" "$OD/a.md" "$OD/b.md"; olock "$OD/a.md" 12 STALE-DEAD
ochk "W14 .docs [A dead, B live]" none LEGACY-5
check "ts_owner W14: the owner doc is A" "$TS_OWNER_DOC" "$OD/a.md"
check "ts_owner W14: and its lock is proven dead" "$TS_LOCK_DEAD" yes
ocell; odoc "$OD/p.md" - '- 10:00 WRAPPED — x'; odoc "$OD/a.md" - '- 10:00 LIVE — x'; odoc "$OD/b.md" - '- 10:00 LIVE — x'
orec '{"lock_seen":true}' "$OD/p.md" "$OD/b.md" "$OD/a.md"; olock "$OD/a.md" 12 STALE-DEAD
ochk "W15 .docs [B live, A dead]" "worker:live"

d6n() { owrap no; }
ocell; d6n; orow 7200 wrapped noop D6n; orow 60 sweep noop D6n
ochk "D10 no anchor row, D6n rows only" "awaiting:chief:d6n:$(iso_at 7200)"
ocell; d6n; orow 100000 live noop D5; orow 7200 wrapped noop D6n; orow 60 sweep noop D6n
ochk "D1 park present" "awaiting:chief:d6n:$(iso_at 7200)"
ocell; d6n; orow 3600 wrapped moved D6n
ochk "D2 the moved anchor carries the rule" "awaiting:chief:d6n:$(iso_at 3600)"
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 pr-open moved D5
ochk "D3 an anchor of another rule after the last D6n row" none LEGACY-4
ocell; d6n; orow 90000 wrapped noop D6n; orow 7200 live skip RM; orow 7200 live disabled -; orow 7200 sweep deferred - '{"stage":"lock"}'; orow 7200 sweep noop D5; orow 60 sweep noop D6n
ochk "D4 a run interrupted by rows that are no anchor" "awaiting:chief:d6n:$(iso_at 90000)"
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 hold moved - "$HOLDROW"; orow 60 sweep noop D6n; TS_OWNER_HELD=yes
ochk "D5 a labelled hold newer than the park" "awaiting:operator:hold:$(iso_at 3600)"
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 hold moved - "$HOLDROW"; orow 60 sweep noop D6n
ochk "D6 the same hold without the label" "awaiting:chief:d6n:$(iso_at 7200)"
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 hold miss - "$HOLDROW"; TS_OWNER_HELD=yes
ochk "D7 a hold that missed" "awaiting:chief:d6n:$(iso_at 7200)"
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 hold moved - "$HOLDROW"; orow 1800 hold-release moved -; TS_OWNER_HELD=yes
ochk "D8 a hold, then a release" "awaiting:chief:d6n:$(iso_at 7200)"
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 hold moved - '{"owner":"Bad Who","reason":"r"}'; TS_OWNER_HELD=yes
ochk "D9 a hold whose owner fails the pattern" "awaiting:chief:d6n:$(iso_at 7200)"

ocell; owrap yes; ochk "B1 brief yes (D6 To Do)" none
ocell; owrap -; ochk "B2 brief none (D6 To Do)" none
ocell; owrap -; omerge 7200 yes; ochk "Y1 contract yes, brief none (D6 To Do)" none
ocell; d6n; omerge 100000 yes; orow 7200 wrapped noop D6n; orow 60 sweep noop D6n
ochk "Y2 contract yes, brief no, a park after the merge row" "awaiting:chief:d6n:$(iso_at 7200)"

ocell; owrap -; omerge 7200 no "$OWEDROW"; orow 3600 hold moved - "$HOLDROW"; TS_OWNER_HELD=yes
ochk "R14 an owed row and a newer labelled hold" "awaiting:operator:hold:$(iso_at 3600)"
ocell; owrap -; orow 7200 hold moved - "$HOLDROW"; omerge 3600 no "$OWEDROW"; TS_OWNER_HELD=yes
ochk "R15 a labelled hold, then a newer owed row" "awaiting:operator:owed:$(iso_at 3600)"
ocell; owrap -; omerge 7200 no; ochk "R1 remainder field absent" none LEGACY-2
ocell; owrap -; omerge 7200 no '{"remainder":"none"}'; ochk "R2 remainder none" none LEGACY-3
ocell; owrap -; omerge 7200 no '{"remainder":"handed-off"}'; ochk "R3 remainder handed-off" none LEGACY-3
ocell; owrap -; omerge 7200 no "$OWEDROW"; ochk "R4 remainder owed" "awaiting:operator:owed:$(iso_at 7200)"
r5() { owrap -; omerge 100000 no '{"remainder":"remaining"}'; orow 7200 wrapped noop D5c; orow 60 sweep noop D5c; }
ocell; r5; ochk "R5 remaining, park present" "awaiting:chief:resume:$(iso_at 7200)"
ocell; owrap -; omerge 100000 no '{"remainder":"remaining"}'; orow 3600 wrapped moved D5c
ochk "R6 remaining, a moved D5c anchor with nothing after it" "awaiting:chief:resume:$(iso_at 3600)"
ocell; owrap -; orow 100000 wrapped noop D5c; omerge 7200 no '{"remainder":"remaining"}'; ochk "R7 remaining, no D5c row at or after the merge row" none LEGACY-4
ocell; owrap -; omerge 100000 no '{"remainder":"remaining"}'; orow 90000 wrapped noop D5c; orow 7200 live skip RM; orow 7200 live disabled -; orow 7200 sweep deferred - '{"stage":"lock"}'; orow 7200 sweep noop D5; orow 60 sweep noop D5c
ochk "R8 remaining, a run interrupted by rows that are no anchor" "awaiting:chief:resume:$(iso_at 90000)"
ocell; r5; orow 3600 hold moved - "$HOLDROW"; TS_OWNER_HELD=yes
ochk "R9 remaining, a labelled hold newer than the park" "awaiting:operator:hold:$(iso_at 3600)"
ocell; r5; orow 3600 hold moved - "$HOLDROW"
ochk "R10 the same hold without the label" "awaiting:chief:resume:$(iso_at 7200)"
ocell; r5; orow 3600 hold miss - "$HOLDROW"; TS_OWNER_HELD=yes
ochk "R11 a hold that missed" "awaiting:chief:resume:$(iso_at 7200)"
ocell; r5; orow 3600 hold moved - "$HOLDROW"; orow 1800 hold-release moved -; TS_OWNER_HELD=yes
ochk "R12 a hold, then a release" "awaiting:chief:resume:$(iso_at 7200)"
ocell; r5; orow 3600 hold moved - '{"owner":"Bad Who","reason":"r"}'; TS_OWNER_HELD=yes
ochk "R13 a hold whose owner fails the pattern" "awaiting:chief:resume:$(iso_at 7200)"

ocell; d6n; orow 90000 wrapped noop D6n
orow 7200 merge pending - '{"pr":"11","head":"h11","contract":"no","stage":"pre-merge"}'; orow 60 sweep noop D6n
ochk "X1 a pre-merge row whose PR is open is no anchor" "awaiting:chief:d6n:$(iso_at 90000)"
ocell; owrap -; orow 3600 sweep miss - '{"stage":"merged-no-row","merged_pr":"5"}'
ochk "X2 no merge row, a merged PR (D5c merged-no-row)" none LEGACY-1
check "ts_owner X2: the derive says merged-no-row" "$TS_STAGE/$TS_RULE" "merged-no-row/D5c"

ts_oans_rows() {
    if [ "$1" = - ]; then unset TS_OWNER_ROWS; else export TS_OWNER_ROWS=$1; fi
    ts_owner "$OK"
    unset TS_OWNER_ROWS
}
ocell; d6n; orow 7200 wrapped noop D6n; orow 3600 hold moved - "$HOLDROW"; TS_OWNER_HELD=yes; ts_derive "$OK"
ts_merge_rows "$olog" | ts_owner_rows > "$tmp/orows"
check "ts_owner rows file, hold cell: the same answer as the log" "$(ts_oans_rows "$tmp/orows")" "$(ts_oans_rows -)"
ocell; owrap -; omerge 7200 no "$OWEDROW"; ts_derive "$OK"
ts_merge_rows "$olog" | ts_owner_rows > "$tmp/orows"
check "ts_owner rows file, owed cell: the same answer as the log" "$(ts_oans_rows "$tmp/orows")" "$(ts_oans_rows -)"
ocell; r5; ts_derive "$OK"
ts_merge_rows "$olog" | ts_owner_rows > "$tmp/orows"
check "ts_owner rows file, park cell: the same answer as the log" "$(ts_oans_rows "$tmp/orows")" "$(ts_oans_rows -)"
check "ts_owner rows file, park cell: and it is the park's answer" "$(ts_oans_rows "$tmp/orows" | cut -f1,2,5)" "$(printf 'awaiting\tchief\tresume')"

ocell; owrap -; omerge 100000 no '{"remainder":"remaining"}'; orow 25200 wrapped noop D5c; orow 60 sweep noop D5c
ts_derive "$OK"
check "ts_owner resume: since is the first D5c row, due 6 h later, already past" "$(ts_owner "$OK" | cut -f3,4)" "$(printf '%s\t%s' "$(iso_at 25200)" "$(iso_at 3600)")"

plog="$tmp/park.jsonl"
: > "$plog"
pk() {
    jq -nc --arg ts "$(iso_at "$2")" --arg k "$1" --arg e "$3" --arg r "$4" --arg rule "$5" --argjson x "${6:-{\}}" \
        '{ts: $ts, event: $e, key: $k, result: $r} + (if $rule == "-" then {} else {rule: $rule} end) + $x' >> "$plog"
}
pk HIMMEL-9401 90000 wrapped noop D6n; pk HIMMEL-9401 7200 live skip RM; pk HIMMEL-9401 7200 live disabled -; pk HIMMEL-9401 7200 sweep deferred - '{"stage":"lock"}'; pk HIMMEL-9401 7200 sweep noop D5; pk HIMMEL-9401 60 sweep noop D6n
pk HIMMEL-9402 108000 wrapped noop D6n; pk HIMMEL-9402 7200 live noop D5; pk HIMMEL-9402 3600 wrapped noop D6n; pk HIMMEL-9402 60 sweep noop D6n
pk HIMMEL-9403 7200 wrapped noop D6n; pk HIMMEL-9403 3600 live deferred D5; pk HIMMEL-9403 60 sweep noop D6n
pk HIMMEL-9404 7200 wrapped noop D6n; pk HIMMEL-9404 3600 pr-open moved D5
pk HIMMEL-9405 90000 wrapped noop D6n; pk HIMMEL-9405 7200 hold moved D6n; pk HIMMEL-9405 60 sweep noop D6n
pk HIMMEL-9406 3600 wrapped moved D6n
pk HIMMEL-9407 90000 wrapped noop D6n; pk HIMMEL-9407 7200 merge pending - '{"pr":"11","head":"h11","contract":"no","stage":"pre-merge"}'; pk HIMMEL-9407 60 sweep noop D6n
pk HIMMEL-9408 7200 wrapped noop D6n; pk HIMMEL-9408 60 sweep noop D6n
pk HIMMEL-9409 7200 wrapped noop D6n; pk HIMMEL-9409 3600 wrapped noop D5c
parks=$(ts_park_since_rows "$plog")
prow() { printf '%s' "$parks" | awk -F'\t' -v k="HIMMEL-$1" '$1 == k { printf "%s%s=%s", (n++ ? "," : ""), $2, $3 }'; }
check "park rows: rows that are no anchor inside the run do not restart it" "$(prow 9401)" "D6n=$(iso_at 90000)"
check "park rows: an event=live row is an anchor" "$(prow 9402)" "D6n=$(iso_at 3600)"
check "park rows: an event=live result=deferred row is one too" "$(prow 9403)" "D6n=$(iso_at 60)"
check "park rows: a moved row of another rule after the last rule row leaves no start" "$(prow 9404)" ""
check "park rows: a hold row inside the run starts nothing" "$(prow 9405)" "D6n=$(iso_at 90000)"
check "park rows: a moved anchor that carries the rule is the start" "$(prow 9406)" "D6n=$(iso_at 3600)"
check "park rows: a dropped pre-merge row is no anchor" "$(prow 9407)" "D6n=$(iso_at 90000)"
check "park rows: no anchor at all, the first rule row is the start" "$(prow 9408)" "D6n=$(iso_at 7200)"
check "park rows: one row per rule of a key" "$(prow 9409)" "D6n=$(iso_at 7200),D5c=$(iso_at 3600)"

check "ts_now: prints TICKET_STATUS_NOW when it is digits" "$(ts_now)" "$NOW"
tnow=$(TICKET_STATUS_NOW=abc ts_now); tdiff=$((tnow - $(date -u +%s))); check "ts_now: abc reads the wall clock (within 5 s)" "$([ "${tdiff#-}" -le 5 ] && echo ok)" ok
tnow=$(unset TICKET_STATUS_NOW; ts_now); tdiff=$((tnow - $(date -u +%s))); check "ts_now: unset reads the wall clock (within 5 s)" "$([ "${tdiff#-}" -le 5 ] && echo ok)" ok

bsdpath=$PATH
if date -u -d 2026-01-01 +%s >/dev/null 2>&1; then # gnu-ok: the probe itself, the shim below needs a GNU date
    mkdir -p "$tmp/bsd"
    cat >"$tmp/bsd/date" <<'EOS'
#!/usr/bin/env bash
real=$BSD_SHIM_REAL_DATE
orig=("$@")
j=0 r="" v="" out="" fmt="" str=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) echo "date: illegal option -- d" >&2; exit 1 ;;
        -j) j=1; shift ;;
        -f) fmt=${2:-}; str=${3:-}; shift 3 ;;
        -r) r=${2:-}; shift 2 ;;
        -v*) v=${1#-v-}; v=${v%d}; shift ;;
        +*) out=$1; shift ;;
        *) shift ;;
    esac
done
if [ "$j" = 1 ]; then
    case "$fmt" in
        %Y-%m-%d)
            base=$("$real" -u -d "${str:0:7}-01" +%s) || exit 1
            e=$((base + (10#${str:8:2} - 1) * 86400)) ;;
        %Y-%m-%dT%H:%M:%SZ)
            base=$("$real" -u -d "${str:0:7}-01" +%s) || exit 1
            e=$((base + (10#${str:8:2} - 1) * 86400 + 10#${str:11:2} * 3600 + 10#${str:14:2} * 60 + 10#${str:17:2})) ;;
        *) e=$("$real" -u -d "$str" +%s) || exit 1 ;;
    esac
    exec "$real" -u -d "@$e" "$out"
fi
[ -z "$r" ] || exec "$real" -u -d "@$r" "$out"
[ -z "$v" ] || exec "$real" -u -d "$v days ago" "$out"
exec "$real" "${orig[@]}"
EOS
    chmod +x "$tmp/bsd/date"
    BSD_SHIM_REAL_DATE=$(command -v date)
    export BSD_SHIM_REAL_DATE
    bsdpath="$tmp/bsd:$PATH"
fi
S0=2026-11-01T00:00:00Z
check "ts_await_due: chief 24 h" "$(ts_await_due $S0 chief)" 2026-11-02T00:00:00Z
check "ts_await_due: operator 72 h" "$(ts_await_due $S0 operator)" 2026-11-04T00:00:00Z
check "ts_await_due: any other owner 72 h" "$(ts_await_due $S0 legal)" 2026-11-04T00:00:00Z
check "ts_await_due: resume 6 h" "$(ts_await_due $S0 resume)" 2026-11-01T06:00:00Z
check "ts_await_due: a by date wins as 23:59:59Z" "$(ts_await_due $S0 chief 2026-11-05)" 2026-11-05T23:59:59Z
check "ts_await_due: a date 30 days out is clamped to 14 d" "$(ts_await_due $S0 chief 2026-12-01)" 2026-11-15T00:00:00Z
check "ts_await_due: TTL_CHIEF overrides its row" "$(TICKET_STATUS_AWAIT_TTL_CHIEF=2h ts_await_due $S0 chief)" 2026-11-01T02:00:00Z
check "ts_await_due: TTL_OPERATOR overrides its row" "$(TICKET_STATUS_AWAIT_TTL_OPERATOR=5d ts_await_due $S0 operator)" 2026-11-06T00:00:00Z
check "ts_await_due: TTL_OTHER overrides its row" "$(TICKET_STATUS_AWAIT_TTL_OTHER=1h ts_await_due $S0 legal)" 2026-11-01T01:00:00Z
check "ts_await_due: TTL_RESUME overrides its row" "$(TICKET_STATUS_AWAIT_TTL_RESUME=10h ts_await_due $S0 resume)" 2026-11-01T10:00:00Z
check "ts_await_due: MAX caps a TTL" "$(TICKET_STATUS_AWAIT_MAX=1d ts_await_due $S0 operator)" 2026-11-02T00:00:00Z
for bad in abc 0h 5m; do
    check "ts_await_due: TTL_CHIEF=$bad reads as the default" "$(TICKET_STATUS_AWAIT_TTL_CHIEF=$bad ts_await_due $S0 chief)" 2026-11-02T00:00:00Z
    check "ts_await_env_bad: names TTL_CHIEF=$bad" "$(TICKET_STATUS_AWAIT_TTL_CHIEF=$bad ts_await_env_bad)" TICKET_STATUS_AWAIT_TTL_CHIEF
done
check "ts_await_due: MAX=30d reads as the 14 d default" "$(TICKET_STATUS_AWAIT_MAX=30d ts_await_due $S0 chief 2026-12-01)" 2026-11-15T00:00:00Z
check "ts_await_env_bad: names MAX=30d" "$(TICKET_STATUS_AWAIT_MAX=30d ts_await_env_bad)" TICKET_STATUS_AWAIT_MAX
check "ts_await_env_bad: names each bad variable, TTL_RESUME included, and no value" "$(TICKET_STATUS_AWAIT_TTL_OPERATOR=x TICKET_STATUS_AWAIT_TTL_OTHER=y TICKET_STATUS_AWAIT_TTL_RESUME=z ts_await_env_bad | sort | paste -sd, -)" "TICKET_STATUS_AWAIT_TTL_OPERATOR,TICKET_STATUS_AWAIT_TTL_OTHER,TICKET_STATUS_AWAIT_TTL_RESUME"
check "ts_await_env_bad: a clean env names nothing" "$(ts_await_env_bad)" ""
check "ts_await_due: TZ=Asia/Tokyo in the caller's env gives the same answer" "$(TZ=Asia/Tokyo ts_await_due $S0 chief 2026-11-05)" 2026-11-05T23:59:59Z
check "ts_await_due: and the same for a TTL" "$(TZ=Asia/Tokyo ts_await_due $S0 chief)" 2026-11-02T00:00:00Z
check "ts_await_due: 2026-02-30 is refused, no due" "$(ts_await_due $S0 chief 2026-02-30)" ""
ts_await_due $S0 chief 2026-02-30 >/dev/null; check "ts_await_due: 2026-02-30 is refused with rc 1" "$?" 1
check "ts_await_due under the BSD date: the chief row is as with the system date (control)" "$(PATH="$bsdpath" ts_await_due $S0 chief)" 2026-11-02T00:00:00Z
check "ts_await_due under the BSD date: the by row is as with the system date (control)" "$(PATH="$bsdpath" ts_await_due $S0 chief 2026-11-05)" 2026-11-05T23:59:59Z
check "ts_await_due under the BSD date: 2026-02-30 is refused, not rolled to 2026-03-02" "$(PATH="$bsdpath" ts_await_due $S0 chief 2026-02-30)" ""
PATH="$bsdpath" ts_await_due $S0 chief 2026-02-30 >/dev/null; check "ts_await_due under the BSD date: 2026-02-30 is refused with rc 1" "$?" 1
_ts_date_ok 2026-11-05; check "_ts_date_ok: a real date passes" "$?" 0
_ts_date_ok 2026-02-30; check "_ts_date_ok: a day that does not exist fails" "$?" 1
_ts_date_ok tomorrow; check "_ts_date_ok: a word fails" "$?" 1
PATH="$bsdpath" _ts_date_ok 2026-02-30; check "_ts_date_ok under the BSD date: 2026-02-30 fails" "$?" 1
PATH="$bsdpath" _ts_date_ok 2026-11-05; check "_ts_date_ok under the BSD date: a real date passes (control)" "$?" 0

unset TICKET_STATUS_NOW
export TICKET_STATUS_QUEUE_LOCK="$tmp/lock.sh"
unset TS_SNAPSHOT_DIR TS_EVENT TS_OWNER_HELD TS_OWNER_ROWS
export TICKET_STATUS_STATE_DIR="$tmp/qstate"
mkdir -p "$TICKET_STATUS_STATE_DIR/workers" "$tmp/qbin"
cat > "$tmp/qjira" <<'EOF'
#!/usr/bin/env bash
printf '{"fields":{"status":{"name":"In Progress"},"issuetype":{"name":"Task"}}}\n'
EOF
cat > "$tmp/qbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QGH_LOG"
[ "$1 $2" != "pr list" ] || echo '[]'
EOF
chmod +x "$tmp/qjira" "$tmp/qbin/gh"
printf -- '- 10:00 LIVE — started\n' > "$tmp/qowner.md"
jq -nc --arg doc "$tmp/qowner.md" '{doc:$doc,docs:[$doc],prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9201.json"
qplant() {
    local now; now=$(date +%s)
    mkdir -p "$1"
    printf 'main\tgraphql\t%s\t5000\t%s\t%s\t%s\nmain\tcore\t4000\t5000\t%s\t%s\tok\n' "$2" "$((now + 1800))" "$now" "$3" "$((now + 1800))" "$now" > "$1/quota.tsv"
}
printf '. %q\n' "$HERE/ticket-status.sh" > "$tmp/qderive.sh"
cat >> "$tmp/qderive.sh" <<'EOF'
ts_derive HIMMEL-9201
printf '%s/%s/%s/%s' "$TS_DERIVED" "$TS_RESULT" "$TS_STAGE" "$TS_RULE"
EOF
qderive() {
    local q=()
    : > "$tmp/qgh.log"
    [ "$1" = - ] || q=("HIMMEL_QUOTA_DIR=$1")
    env -u HIMMEL_QUOTA_DIR ${q[@]+"${q[@]}"} PATH="$tmp/qbin:$PATH" QGH_LOG="$tmp/qgh.log" WORKER_SESSION_JIRA_CLI="$tmp/qjira" \
        bash "$tmp/qderive.sh" 2> "$tmp/qerr"
}
qplant "$tmp/q-out" 0 refused
check "9479 T8: a paused live derive is no-write + miss stage=gh" "$(qderive "$tmp/q-out")" "no-write/miss/gh/"
check "9479 T8: the pause line is on stderr" "$(grep -c '^QUOTA-PAUSE github graphql token=main remaining=0 .* caller=ticket-status nothing-was-judged$' "$tmp/qerr")" 1
check "9479 T8: a paused live derive makes no gh call" "$(wc -l < "$tmp/qgh.log" | tr -d ' ')" 0
qplant "$TICKET_STATUS_STATE_DIR/quota" 0 refused
check "9479 T8: with no HIMMEL_QUOTA_DIR the readings are the state dir's" "$(qderive -)" "no-write/miss/gh/"
check "9479 T8: and still no gh call" "$(wc -l < "$tmp/qgh.log" | tr -d ' ')" 0
qplant "$tmp/q-ok" 4000 ok
check "9479 T8 RED control: a healthy budget derives" "$(qderive "$tmp/q-ok")" "In Progress///D5"
check "9479 T8 RED control: no pause line" "$(grep -c 'QUOTA-PAUSE\|GH-STALL' "$tmp/qerr")" 0
check "9479 T8 RED control: the healthy derive reads the PR list" "$(grep -c '^pr list' "$tmp/qgh.log")" 1
qplant "$tmp/q-hung" 4000 timed-out
check "9479 T8: a timed-out probe is a pause too" "$(qderive "$tmp/q-hung")" "no-write/miss/gh/"
check "9479 T8: named GH-STALL on stderr" "$(grep -c '^GH-STALL github read timed out' "$tmp/qerr")" 1

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-ticket-status.sh"
else
    echo "FAIL - test-ticket-status.sh: $fails failure(s)"
    exit 1
fi
