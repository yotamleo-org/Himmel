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

printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/lock-free.sh"
chmod +x "$tmp/lock-free.sh"
rbrief() { # <flag-line> <resume_brief: path|-> - the brief file (flag line above ## Results), then the derive
    { printf '> **Completes ticket:** %s\n\n## Results (newest at the bottom)\n- 10:00 WRAPPED — ended\n' "$1"; } > "$tmp/rb.md"
    jq -nc --arg doc "$tmp/gone.md" --arg rb "$2" \
        '{doc:$doc,docs:[$doc],lock_seen:true,lock_gone_sweeps:1,prs:{}} | if $rb != "-" then .resume_brief = $rb else . end' \
        > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    TICKET_STATUS_QUEUE_LOCK="$tmp/lock-free.sh" ts_derive HIMMEL-9001
}
rbrief no "$tmp/rb.md"
check "9323 unreadable owner doc: the resume_brief says completes no, so D6n and In Progress" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6n/In Progress'
rbrief no -
check "9323 unreadable owner doc, no resume_brief: D6 (control)" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6/To Do'
rbrief yes "$tmp/rb.md"
check "9323 unreadable owner doc, the resume_brief says completes yes: D6 (control)" "$TS_RULE/$TS_DERIVED" 'D6/To Do'
rbrief no "$tmp/missing-brief.md"
check "9323 unreadable owner doc, the resume_brief names an unreadable file: D6 (control)" "$TS_RULE/$TS_DERIVED" 'D6/To Do'

mkdir -p "$tmp/sdbin"
cat > "$tmp/sdbin/python3" <<'EOF'
#!/usr/bin/env bash
# the disposition read of the doc in SD_DOC answers the JSON word in SD_WORD; every other call is the real python3
if [ -n "${SD_DOC:-}" ] && [ "${2##*/}" = fleet_runtime.py ] && [ "${3-}" = disposition ] && [ "${4-}" = "--doc=$SD_DOC" ]; then
    printf '%s\n' "$SD_WORD"
    exit 0
fi
exec "$SD_REAL_PYTHON" "$@"
EOF
chmod +x "$tmp/sdbin/python3"
SD_REAL_PYTHON=$(command -v python3)
export SD_REAL_PYTHON
printf '#!/usr/bin/env bash\nexit 3\n' > "$tmp/lock-err.sh"
chmod +x "$tmp/lock-err.sh"
sib() {
    local b="$tmp/sb.md"
    printf -- '- 10:00 WRAPPED — primary ended\n' > "$tmp/sa.md"
    printf -- '\n' > "$tmp/sc.md"
    if [ "${4:-}" = dir ]; then b="$tmp/sbdir.md"; mkdir -p "$b"; else printf -- '%s\n' "$2" > "$b"; fi
    [ "${4:-}" != unreadable ] || chmod 000 "$b"
    jq -nc --arg a "$tmp/sa.md" --arg b "$b" --arg c "${5:+$tmp/sc.md}" '{doc:$a,docs:([$a,$b] + (if $c == "" then [] else [$c] end)),prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    PATH="$tmp/sdbin:$PATH" SD_DOC="${1:+$b}" SD_WORD="$1" TICKET_STATUS_QUEUE_LOCK="${3:-$tmp/lock-free.sh}" ts_derive HIMMEL-9001
    [ "${4:-}" != unreadable ] || chmod 644 "$b"
}
for word in pending committed unknown; do
    sib "\"$word\"" ''
    check "X07-3 a sibling whose attempt is $word keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'unknown/D5/In Progress'
    check "X07-3 a sibling whose attempt is $word is the owner doc" "$TS_OWNER_DOC" "$tmp/sb.md"
done
sib '"pending"' '- 10:00 WRAPPED — sibling ended'
check "X07-3 a sibling with a pending attempt after its own wrap is not provably ended" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'unknown/D5/In Progress'
sib '' ''
check "X07-3 control: a sibling with no attempt, no marker and a free lock leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6/To Do'
check "X07-3 control: and names no owner doc" "$TS_OWNER_DOC" ''
for word in legacy refused complete; do
    sib "\"$word\"" ''
    check "X07-3 control: a sibling with a $word disposition, no marker and a free lock leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6/To Do'
done
sib '' '- 10:00 WRAPPED — sibling ended'
check "X07-3 control: a sibling that wrapped itself leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6/To Do'
check "X07-3 control: a sibling that wrapped itself is no owner doc" "$TS_OWNER_DOC" ''
sib '"launched"' ''
check "X07-3 a sibling whose attempt is launched, with no marker and a free lock, keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'unknown/D5/In Progress'
check "X07-3 a sibling whose attempt is launched, with no marker and a free lock, is the owner doc" "$TS_OWNER_DOC" "$tmp/sb.md"
sib '"launched"' '- 10:00 WRAPPED — sibling ended'
check "X07-3 control: a sibling whose attempt is launched and that wrapped itself leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6/To Do'
check "X07-3 control: a sibling whose attempt is launched and that wrapped itself is no owner doc" "$TS_OWNER_DOC" ''
sib '' '' "$tmp/lock-err.sh"
check "X07-3 a sibling whose lock read fails keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'unknown/D5/In Progress'
check "X07-3 a sibling whose lock read fails is the owner doc" "$TS_OWNER_DOC" "$tmp/sb.md"
sib '' '- 10:00 WRAPPED — sibling ended' "$tmp/lock-err.sh"
check "X07-3 control: a sibling that wrapped itself leaves the primary's wrap whatever its lock read says" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6/To Do'
check "X07-3 control: a sibling that wrapped itself is no owner doc whatever its lock read says" "$TS_OWNER_DOC" ''
printf x > "$tmp/probe-un.md"
chmod 000 "$tmp/probe-un.md"
if [ -r "$tmp/probe-un.md" ]; then un_ok=no; else un_ok=yes; fi
chmod 644 "$tmp/probe-un.md"
session_up() {
    WORKER_SESSION_DOC="$1" python3 -I -c 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); time.sleep(60)' &
    SESSION_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat "/proc/$SESSION_PID/comm" 2>/dev/null)" != claude ] || break; sleep 0.1; done
}
session_down() { kill "$SESSION_PID" 2>/dev/null; wait "$SESSION_PID" 2>/dev/null; SESSION_PID=""; }
if [ -d /proc/self ]; then proc_ok=yes; else proc_ok=no; fi
for word in legacy refused complete; do
    sib "\"$word\"" '- 10:00 PARKED-USAGE — sibling parked'
    check "X07-3 a sibling with a $word attempt, a free lock and a PARKED-USAGE marker keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'parked/D5/In Progress/sb.md'
    for marker in LIVE READY BLOCKED; do
        if [ "$proc_ok" = no ]; then
            echo "SKIP - 10682 a sibling with a $word attempt, a free lock, a $marker marker and no session: no /proc to scan"
            continue
        fi
        sib "\"$word\"" "- 10:00 $marker — sibling working"
        check "10682 a sibling with a $word attempt, a free lock, a $marker marker and no live session does not own the ticket" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'wrapped/D6/To Do/'
        session_up "$tmp/sb.md"
        sib "\"$word\"" "- 10:00 $marker — sibling working"
        session_down
        check "10682 control: a sibling with a $word attempt, a free lock, a $marker marker and a live session keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'unknown/D5/In Progress/sb.md'
    done
    sib "\"$word\"" '' '' dir
    check "X07-3 a sibling with a $word attempt, a free lock and a doc that is a directory keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'unknown/D5/In Progress/sbdir.md'
    if [ "$un_ok" = yes ]; then
        sib "\"$word\"" 'x' '' unreadable
        check "X07-3 a sibling with a $word attempt, a free lock and an unreadable doc keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'unknown/D5/In Progress/sb.md'
    else
        echo "SKIP - X07-3 a sibling with a $word attempt, a free lock and an unreadable doc keeps the ticket owned: this user reads a mode 000 file"
    fi
done
sib '"refused"' '- 10:00 WRAPPED — sibling ended'
check "X07-3 control: a sibling with a refused attempt and a WRAPPED marker leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'wrapped/D6/To Do/'
sib '"complete"' '- 10:00 HALTED — out of budget'
check "X07-3 control: a sibling with a complete attempt and a HALTED marker leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'wrapped/D6/To Do/'
sib '"launched"' '- 10:00 WRAPPED — sibling ended' '' '' any
check "X07-3 control: a launched sibling that wrapped itself leaves no sign behind for the next sibling (none, no marker, free lock)" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'wrapped/D6/To Do/'
rt_sib() {
    local a="$tmp/rtb-$1/HIMMEL-9001-N1-a.md" b="$tmp/rtb-$1/HIMMEL-9001-N2-b.md" m="$tmp/rtb-$1/chief.fleet.json" fm="$HERE/../handover/chief-kit/fleet-manifest.sh"
    mkdir -p "$tmp/rtb-$1" "$tmp/rth-$1"
    printf -- '---\ndescription: a\n---\n> **Prior art:** none found (offline fixture)\n\n# a\n## Results\n- 10:00 WRAPPED — primary ended\n' > "$a"
    printf -- '---\ndescription: b\n---\n> **Prior art:** none found (offline fixture)\n\n# b\n## Results\n' > "$b"
    export HOME="$tmp/rth-$1" HIMMEL_FLEET_SLOTS="$tmp/rth-$1/slots" HIMMEL_POLICY_FOLLOWS_HOME=1
    bash "$fm" control init "$m" --target 2 >/dev/null 2>&1 || { printf 'fixture failed: control init'; return 0; }
    bash "$fm" add "$m" "$b" --lane native --pending >/dev/null 2>&1 || { printf 'fixture failed: add'; return 0; }
    bash "$fm" control set "$m" --mode active --expect-gen 1 >/dev/null 2>&1 || { printf 'fixture failed: control set'; return 0; }
    bash "$fm" runtime begin --doc "$b" --manifest "$m" --name b --attempt-id one --pid $$ >/dev/null 2>&1 || { printf 'fixture failed: begin'; return 0; }
    if [ "$1" = launched ]; then
        printf '#!/bin/bash\nexit 0\n' > "$tmp/rth-$1/ps"
        chmod +x "$tmp/rth-$1/ps"
        FLEET_LAUNCH_DOC="$b" FLEET_LAUNCH_MANIFEST="$m" FLEET_LAUNCH_ATTEMPT=one CADENCE_USAGE_LAUNCH=1 CADENCE_USAGE_WORKER=b \
            CADENCE_USAGE_CALLER_PID=$$ CADENCE_USAGE_LANE=native CADENCE_USAGE_SKIP_REFRESH=1 CADENCE_USAGE_CACHE="$tmp/rth-$1/missing-cache" \
            CADENCE_USAGE_LEDGER="$tmp/rth-$1/cadence.jsonl" FLEET_PS_CMD="$tmp/rth-$1/ps" FLEET_CAP_OK=1 HIMMEL_API_LANE=on \
            bash "$HERE/usage-preflight.sh" >/dev/null 2>&1 || { printf 'fixture failed: preflight'; return 0; }
        bash "$fm" runtime commit --doc "$b" --manifest "$m" --name b --attempt-id one --pid $$ >/dev/null 2>&1 || { printf 'fixture failed: commit'; return 0; }
        bash "$fm" runtime outcome --doc "$b" --manifest "$m" --name b --attempt-id one --pid $$ --phase launched >/dev/null 2>&1 || { printf 'fixture failed: outcome'; return 0; }
    fi
    [ "$(python3 -I "$HERE/fleet_runtime.py" disposition --doc="$b")" = "\"$1\"" ] || { printf 'fixture failed: phase'; return 0; }
    jq -nc --arg a "$a" --arg b "$b" '{doc:$a,docs:[$a,$b],prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    TICKET_STATUS_QUEUE_LOCK="$tmp/lock-free.sh" ts_derive HIMMEL-9001
    printf '%s/%s/%s' "$TS_WORKER_STATE" "$TS_RULE" "$TS_DERIVED"
}
check "X07-3 a sibling with a real pending managed attempt keeps the ticket owned" "$(rt_sib pending)" 'unknown/D5/In Progress'
check "X07-3 a sibling with a real launched managed attempt, a free lock and no marker keeps the ticket owned" "$(rt_sib launched)" 'unknown/D5/In Progress'

tm() { printf -- '%s\n' "$@" > "$tmp/tm.md"; ts_marker_newest "$tmp/tm.md"; }
check "9323 a clean WRAPPED line is WRAPPED (control)" "$(tm '- 10:00 LIVE — x' '- 10:10 WRAPPED')" WRAPPED
check "9323 WRAPPED with trailing text is WRAPPED" "$(tm '- 10:00 LIVE — x' '- 10:10 WRAPPED all done, PR 12 merged')" WRAPPED
check "9323 HALTED with trailing text is HALTED" "$(tm '- 10:00 LIVE — x' '- 10:10 HALTED: out of budget')" HALTED
check "9323 a bold marker with trailing text is read" "$(tm '- 10:00 LIVE — x' '- 10:10 **HALTED** — out of budget')" HALTED
check "9323 a marker word glued to more letters is no marker" "$(tm '- 10:00 LIVE — x' '- 10:10 WRAPPEDX done')" LIVE
check "9323 a marker word later in the line is no marker" "$(tm '- 10:00 LIVE — x' '- 10:10 note: WRAPPED')" LIVE
printf -- '- 10:00 LIVE — x\n- 10:10 HALTED: out of budget\n' > "$tmp/tm.md"
check "9323 HALTED with trailing text reads as a wrapped owner (lock held)" "$(ts_worker_state "$tmp/tm.md")" wrapped

check "10673 a SUCCESSION after WRAPPED leaves WRAPPED the newest marker" "$(tm '- 10:00 LIVE — x' '- 22:30 WRAPPED — merged' '- 09:00 SUCCESSION accepted: AQ replaces AP')" WRAPPED
check "10673 a bus-adopt and a SUCCESSION after WRAPPED leave WRAPPED the newest marker" \
    "$(tm '- 10:00 LIVE — x' '- 22:30 WRAPPED — merged' '- 09:00 bus-adopt: adopted: d console AP → AQ [via anchor]' '- 09:00 SUCCESSION accepted: AQ replaces AP')" WRAPPED
check "10673 a SUCCESSION after HALTED leaves HALTED the newest marker" "$(tm '- 10:00 LIVE — x' '- 22:30 HALTED — out of budget' '- 09:00 SUCCESSION accepted: AQ replaces AP')" HALTED
check "10673 control: a SUCCESSION after LIVE is the newest marker" "$(tm '- 10:00 LIVE — x' '- 09:00 SUCCESSION accepted: AQ replaces AP')" SUCCESSION
check "10673 control: a LIVE after a SUCCESSION after WRAPPED is the newest marker" "$(tm '- 22:30 WRAPPED — merged' '- 09:00 SUCCESSION accepted: AQ replaces AP' '- 09:10 LIVE — resumed')" LIVE
printf -- '- 10:00 LIVE — x\n- 22:30 WRAPPED — merged\n- 09:00 bus-adopt: adopted: d console AP → AQ [via anchor]\n- 09:00 SUCCESSION accepted: AQ replaces AP\n' > "$tmp/tm.md"
check "10673 a WRAPPED doc with a later SUCCESSION and a free lock reads wrapped" "$(TICKET_STATUS_QUEUE_LOCK="$tmp/lock-free.sh" ts_worker_state "$tmp/tm.md")" wrapped
sib '' "$(printf -- '- 10:00 LIVE — x\n- 22:30 WRAPPED — merged\n- 09:00 SUCCESSION accepted: AQ replaces AP')"
check "10673 a sibling that wrapped before a SUCCESSION leaves the primary's wrap" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'wrapped/D6/To Do/'

n5870="$(printf -- '# HIMMEL-9001 — abandoned worker\n\n## Results (newest at the bottom)\n- 09:10 LIVE — started\n- 11:40 FINDING — a question\n- 11:55 RESOLVED — ruling received\n- 12:30 LIVE — still working')"
if [ "$proc_ok" = yes ]; then
    sib '' "$n5870"
    check "10682 an abandoned sibling (newest LIVE, never wrapped, free lock, no session) does not own the ticket" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'wrapped/D6/To Do/'
    printf 'HIMMEL-9001\tTask\tIn Progress\n' > "$TS_SNAPSHOT_DIR/jira.tsv"
    printf '> **Completes ticket:** no\n\n## Results (newest at the bottom)\n- 10:00 WRAPPED — primary ended\n' > "$tmp/sa-no.md"
    printf -- '%s\n' "$n5870" > "$tmp/sb.md"
    jq -nc --arg a "$tmp/sa-no.md" --arg b "$tmp/sb.md" '{doc:$a,docs:[$a,$b],prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    TICKET_STATUS_QUEUE_LOCK="$tmp/lock-free.sh" ts_derive HIMMEL-9001
    check "10682 an abandoned sibling beside a completes-no primary keeps D6n, not D5" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED" 'wrapped/D6n/In Progress'
    session_up "$tmp/sb.md"
    sib '' "$n5870"
    session_down
    check "10682 control: the same sibling with a live session keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'unknown/D5/In Progress/sb.md'
else
    echo "SKIP - 10682 an abandoned sibling does not own the ticket: no /proc to scan"
fi
sib '' "$n5870" "$tmp/lock.sh"
check "10682 control: the same sibling with its lock held keeps the ticket owned" "$TS_WORKER_STATE/$TS_RULE/$TS_DERIVED/${TS_OWNER_DOC##*/}" 'live/D5/In Progress/sb.md'

hd="$tmp/hard"
mkdir -p "$hd/-state/workers"
for f in -f -- plain; do
    printf '> **Completes ticket:** no\n\n## Results (newest at the bottom)\n- 10:10 WRAPPED — ended\n' > "$hd/$f"
done
rk=HIMMEL-9001
printf '{"doc":"in-the-record"}\n' > "$hd/-state/workers/$rk.json"
check "9323 a plain relative doc path is read (control)" "$(cd "$hd" && ts_marker_newest plain </dev/null)" WRAPPED
check "9323 a doc path -f is read as a file" "$(cd "$hd" && ts_marker_newest -f </dev/null)" WRAPPED
check "9323 a doc path -- is read as a file" "$(cd "$hd" && ts_marker_newest -- </dev/null)" WRAPPED
check "9323 a plain relative brief is read (control)" "$(cd "$hd" && _ts_brief_completes_no plain </dev/null; echo $?)" 0
check "9323 a brief path -f is read as a file" "$(cd "$hd" && _ts_brief_completes_no -f </dev/null; echo $?)" 0
check "9323 a brief path -- is read as a file" "$(cd "$hd" && _ts_brief_completes_no -- </dev/null; echo $?)" 0
check "9323 a record under a state dir named -state is read" \
    "$(cd "$hd" && TICKET_STATUS_STATE_DIR=-state ts_record_read "$rk" </dev/null && jq -r '.doc' <<<"$TS_REC")" in-the-record

for jstatus in "To Do" "In Progress"; do
    printf 'HIMMEL-9001\tTask\t%s\n' "$jstatus" > "$TS_SNAPSHOT_DIR/jira.tsv"
    jq -nc '{prs:{"7":{head:"abc",ci:"green",red_latch:false,open:false}}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_derive HIMMEL-9001
    check "never had a worker, closed PRs only, Jira $jstatus: D7 no-write, not D5" "$TS_RULE/$TS_DERIVED" 'D7/no-write'
done

nodoc() {
    printf 'HIMMEL-9001\tTask\t%s\n' "$1" > "$TS_SNAPSHOT_DIR/jira.tsv"
    printf '%s' "$2" > "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
    jq -nc '{prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_derive HIMMEL-9001
}
nd_partial='{"ts":"2026-11-19T21:18:00Z","event":"merge","key":"HIMMEL-9001","pr":"21","repo":"octo/repo","contract":"no","result":"noop"}'
nodoc "IN CI" "$nd_partial"$'\n'
check "10538 no worker doc, a contract=no merge row, Jira IN CI: D5c In Progress, not D7" "$TS_RULE/$TS_DERIVED" 'D5c/In Progress'
nodoc "IN CI" '{"ts":"2026-11-19T21:18:00Z","event":"merge","key":"HIMMEL-9001","pr":"21","repo":"octo/repo","contract":"no","result":"noop","remainder":"owed","owed":"chief","owed_due":"2026-11-22"}'$'\n'
check "10538 no worker doc, a contract=no merge row whose remainder names its owner, Jira IN CI: D5d To Do" "$TS_RULE/$TS_DERIVED/$TS_D5D_OWNER" 'D5d/To Do/chief by 2026-11-22'
for jstatus in "To Do" "In Progress" "In Review"; do
    nodoc "$jstatus" "$nd_partial"$'\n'
    check "10538 no worker doc, a contract=no merge row, Jira $jstatus: skip D7, a hand-set status is never moved" "$TS_RESULT/$TS_RULE/$TS_DERIVED" 'skip/D7/no-write'
done
nodoc "In Progress" '{"ts":"2026-11-19T21:18:00Z","event":"merge","key":"HIMMEL-9001","pr":"21","repo":"octo/repo","contract":"no","result":"noop","remainder":"owed","owed":"chief","owed_due":"2026-11-22"}'$'\n'
check "10538 no worker doc, a contract=no merge row whose remainder names its owner, Jira In Progress: skip D7, not D5d To Do" "$TS_RESULT/$TS_RULE/$TS_DERIVED" 'skip/D7/no-write'
nodoc "IN CI" '{"ts":"t","event":"sweep","key":"HIMMEL-9001","result":"moved","rule":"D5c","stage":"merged-no-row","merged_pr":"31"}'$'\n'
check "10538 no worker doc, no merge row, a logged merged-no-row PR, Jira IN CI: D5c with stage merged-no-row" "$TS_RULE/$TS_DERIVED/$TS_STAGE/$TS_MERGED_PR" 'D5c/In Progress/merged-no-row/31'
nodoc "IN CI" '{"ts":"t","event":"sweep","key":"HIMMEL-9001","result":"moved","rule":"D5d","stage":"merged-no-row","merged_pr":"31","owner":"HIMMEL-9002"}'$'\n'
check "10538 no worker doc, no merge row, a logged merged-no-row PR whose owner is logged, Jira IN CI: D5d with stage merged-no-row" "$TS_RULE/$TS_DERIVED/$TS_STAGE/$TS_D5D_OWNER" 'D5d/To Do/merged-no-row/HIMMEL-9002'
for jstatus in "To Do" "In Progress" "IN CI"; do
    nodoc "$jstatus" ''
    check "10538 control: no PR, no worker doc, no merge row, Jira $jstatus: skip D7" "$TS_RESULT/$TS_RULE/$TS_DERIVED" 'skip/D7/no-write'
done
# shellcheck disable=SC2329  # the stubs below stand in for the lib's readers that ts_derive calls
live_nodoc() { (
    unset TS_SNAPSHOT_DIR
    : > "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
    jq -nc '{prs:{}}' > "$TICKET_STATUS_STATE_DIR/workers/HIMMEL-9001.json"
    ts_read_jira() { TS_J_STATUS="IN CI"; TS_J_TYPE=Task; }
    ts_scan_gate() { return 0; }
    ts_read_prs() { TS_PRS=""; }
    _ts_gh() { [ "$1 $2" = "pr list" ] && [ -n "${LIVE_GH+x}" ] || return 1; printf '%s\n' "$LIVE_GH"; }
    ts_derive HIMMEL-9001
    printf '%s/%s/%s/%s/%s' "$TS_RESULT" "$TS_RULE" "$TS_DERIVED" "$TS_STAGE" "$TS_MERGED_PR"
) }
check "10538 no worker doc, no merge row, a merged PR found by the title search, Jira IN CI: D5c with stage merged-no-row" \
    "$(LIVE_GH='[{"number":31,"title":"fix(x): [HIMMEL-9001] y"}]' live_nodoc)" '/D5c/In Progress/merged-no-row/31'
check "10538 no worker doc, the merged-PR list unreadable: a miss, not D7" "$(live_nodoc)" 'miss//no-write/gh/'
check "10538 control: no worker doc, no merged PR in the title search: skip D7" "$(LIVE_GH='[]' live_nodoc)" 'skip/D7/no-write//'
check "10538 control: no worker doc, a merged PR whose first key is another ticket: skip D7" \
    "$(LIVE_GH='[{"number":32,"title":"fix(x): [HIMMEL-9002] [HIMMEL-9001] y"}]' live_nodoc)" 'skip/D7/no-write//'
rm -f "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
printf 'HIMMEL-9001\tTask\tIn Progress\n' > "$TS_SNAPSHOT_DIR/jira.tsv"

owed_merge() {
    printf '{"ts":"2026-11-15T10:00:00Z","event":"merge","key":"HIMMEL-9001","pr":"21","repo":"octo/repo","contract":"no","result":"noop","remainder":"owed","owed":"%s","owed_due":"%s"}\n' "$1" "$2" \
        > "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
    brief no
}
owed_merge chief 2026-11-22
check "10194 an owed-to-chief partial leaves In Progress: D5d To Do" "$TS_RULE/$TS_DERIVED" 'D5d/To Do'
check "10194 the owner names who and the due date" "$TS_D5D_OWNER" 'chief by 2026-11-22'
owed_merge operator 2026-11-29
check "10194 an owed-to-operator partial: D5d with the operator named" "$TS_RULE/$TS_D5D_OWNER" 'D5d/operator by 2026-11-29'
owed_merge proof 2026-11-29
check "10220 an executable proof partial is To Do with the actual proof owner" "$TS_RULE/$TS_DERIVED/$TS_D5D_OWNER" 'D5d/To Do/proof by 2026-11-29'
owed_merge chief not-a-date
check "10194 an owed row with no valid due date stays D5c" "$TS_RULE/$TS_DERIVED" 'D5c/In Progress'
owed_merge 'chief;x' 2026-11-22
check "10194 an owed row whose owner is not chief or operator stays D5c" "$TS_RULE/$TS_DERIVED" 'D5c/In Progress'
rm -f "$TICKET_STATUS_STATE_DIR/status-events.jsonl"
opaths() { printf '## Ticket coverage\n- a: done\n- %s: owed → %s by 2026-11-22\n' "$1" "${2:-chief}" | ts_owed_chief_paths "$HERE/pr_remainder.py" K-1 | cut -f1; }
check "10194 a bare file name is a repo path" "$(opaths 'the INTAKE age (tick.sh, held)')" 'tick.sh'
check "10194 a dot-relative file is a repo path" "$(opaths 'run ./tick.sh and ../lib/x.py')" '../lib/x.py, ./tick.sh'
check "10194 a relative directory is a repo path" "$(opaths 'part B under scripts/handover/chief-kit/')" 'scripts/handover/chief-kit/'
check "10194 absolute and home paths are not" "$(opaths 'set /etc/himmel/x.json and ~/.codex/config.toml')" ''
check "10194 versions, dates and and/or are not" "$(opaths 'v1.1.3 tag and node 26.13.1, and/or w/ the fix')" ''
check "10194 an operator line is not checked" "$(opaths 'run scripts/lib/x.sh' operator)" ''
check "10194 an owed line under a ### heading is not an owed line" \
    "$(printf '## Ticket coverage\n- a: done\n### More\n- tick.sh: owed → chief by 2026-11-22\n' | ts_owed_chief_paths "$HERE/pr_remainder.py" K-1 | cut -f1)" ''
printf '## Ticket coverage\n- tick.sh: owed → chief by 2026-11-22\n' | ts_owed_chief_paths "$tmp/no-reader.py" K-1 >/dev/null
check "10194 a missing reader is rc 3, never read as no path" "$?" 3

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
check "merge-rows: the read names the row's repo, so a same-numbered PR elsewhere is not credited" "$(ts_merge_rows "$tmp/repo.jsonl" | grep -cE '"key":"[A-Z]+-910(6|7)"')" 1
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
export TICKET_STATUS_STATE_DIR="$tmp/ostate" TS_SNAPSHOT_DIR="$tmp/osnap" TS_EVENT=sweep
olog="$TICKET_STATUS_STATE_DIR/status-events.jsonl"
mkdir -p "$TS_SNAPSHOT_DIR"
printf '%s\tTask\tIn Progress\n' "$OK" > "$TS_SNAPSHOT_DIR/jira.tsv"
printf '[]\n' > "$TS_SNAPSHOT_DIR/prs.json"
cat > "$tmp/plock.sh" <<'EOF'
#!/usr/bin/env bash
case "$(basename "$2")" in p.md) v=${LK_P:-} ;; a.md) v=${LK_A:-} ;; b.md) v=${LK_B:-} ;; *) v= ;; esac
rc=11 st=FRESH
[ -z "$v" ] || read -r rc st <<<"$v"
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
    rm -rf "$TICKET_STATUS_STATE_DIR" "$OD"
    mkdir -p "$TICKET_STATUS_STATE_DIR/workers" "$OD"
    unset LK_P LK_A LK_B
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
olock() { case "$(basename "$1")" in p.md) export LK_P="$2 $3" ;; a.md) export LK_A="$2 $3" ;; b.md) export LK_B="$2 $3" ;; esac; }
empty='{}'
orow() {
    jq -nc --arg ts "$(iso_at "$1")" --arg e "$2" --arg k "$OK" --arg r "$3" --arg rule "$4" --argjson x "${5:-$empty}" \
        '{ts: $ts, event: $e, key: $k, result: $r} + (if $rule == "-" then {} else {rule: $rule} end) + $x' >> "$olog" || { echo "FAIL - fixture: orow jq failed ($*)"; exit 1; }
}
omerge() {
    local m
    m="$(jq -nc --argjson x "${3:-$empty}" --arg c "$2" '{pr: "41", head: "h41", contract: $c, stage: "x"} + $x')" || { echo "FAIL - fixture: omerge jq failed ($*)"; exit 1; }
    orow "$1" merge moved - "$m"
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
    jq -nc --arg ts "$(iso_at "$2")" --arg k "$1" --arg e "$3" --arg r "$4" --arg rule "$5" --argjson x "${6:-$empty}" \
        '{ts: $ts, event: $e, key: $k, result: $r} + (if $rule == "-" then {} else {rule: $rule} end) + $x' >> "$plog" || { echo "FAIL - fixture: pk jq failed ($*)"; exit 1; }
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
mkdir -p "$TICKET_STATUS_STATE_DIR/workers" "$tmp/qbin" "$tmp/qroot" "$tmp/qnoroot"
printf 'himmel_github_token_vm2=ghp_TSREAD0123456789\n' > "$tmp/qroot/.env"
: > "$tmp/qnoroot/.env"
cat > "$tmp/qjira" <<'EOF'
#!/usr/bin/env bash
printf '{"fields":{"status":{"name":"In Progress"},"issuetype":{"name":"Task"}}}\n'
EOF
cat > "$tmp/qbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QGH_LOG"
printf '%s %s %s\n' "${GH_TOKEN:-main}" "$1" "$2" >> "$QGH_LOG.tok"
if [ -n "${GH_TOKEN:-}" ] && [ -n "${QGH_READ_RL:-}" ]; then echo 'GraphQL: API rate limit already exceeded for user ID 2.' >&2; exit 1; fi
if [ -n "${QGH_ONE_PR:-}" ] && [ "$1 $2" = "pr list" ]; then
    case "$*" in *"--state open"*) echo '[{"number":7,"title":"fix: [HIMMEL-9201] x","headRefOid":"h7","baseRefName":"main","reviewDecision":""}]'; exit 0 ;; esac
fi
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
    : > "$tmp/qgh.log"; : > "$tmp/qgh.log.tok"
    [ "$1" = - ] || q=("HIMMEL_QUOTA_DIR=$1")
    env -u HIMMEL_QUOTA_DIR -u himmel_github_token_vm2 ${q[@]+"${q[@]}"} GH_READ_ENV_ROOT="${QROOT:-$tmp/qnoroot}" \
        PATH="$tmp/qbin:$PATH" QGH_LOG="$tmp/qgh.log" WORKER_SESSION_JIRA_CLI="$tmp/qjira" \
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

qplant_read() {
    qplant "$1" 4000 ok
    local now; now=$(date +%s)
    printf 'read\tgraphql\t%s\t5000\t%s\t%s\t%s\nread\tcore\t4000\t5000\t%s\t%s\tok\n' "$2" "$((now + 1800))" "$now" "$3" "$((now + 1800))" "$now" >> "$1/quota.tsv"
}
qplant_read "$tmp/q-rok" 4000 ok
check "9479 T11: a healthy derive with a read token derives" "$(QROOT="$tmp/qroot" qderive "$tmp/q-rok")" "In Progress///D5"
check "9479 T11: its PR list goes out on the read token" "$(grep -c '^ghp_TSREAD0123456789 pr list$' "$tmp/qgh.log.tok")" 1
check "9479 T11: and no read rides main" "$(grep -c '^main ' "$tmp/qgh.log.tok")" 0
check "9479 T11: a read token rate-limited after an ok probe leaves the derive unread (a scan)" "$(QGH_READ_RL=1 QROOT="$tmp/qroot" qderive "$tmp/q-rok")" "no-write/miss/gh/"
check "9479 T11: and the refused read is not retried on main" "$(grep -c '^main ' "$tmp/qgh.log.tok")" 0
mkdir -p "$tmp/q-rcore"
qnow=$(date +%s)
printf 'main\tgraphql\t4000\t5000\t%s\t%s\tok\nmain\tcore\t100\t5000\t%s\t%s\tok\nread\tgraphql\t4000\t5000\t%s\t%s\tok\nread\tcore\t4000\t5000\t%s\t%s\tok\n' \
    "$((qnow + 1800))" "$qnow" "$((qnow + 1800))" "$qnow" "$((qnow + 1800))" "$qnow" "$((qnow + 1800))" "$qnow" > "$tmp/q-rcore/quota.tsv"
check "9479 T11: an open PR's classic protection read (main's) pauses on main core under the floor" "$(QGH_ONE_PR=1 QROOT="$tmp/qroot" qderive "$tmp/q-rcore" | cut -d/ -f1-2)" "no-write/miss"
check "9479 T11: that pause line names main core" "$(grep -c '^QUOTA-PAUSE github core token=main remaining=100 .* caller=ticket-status nothing-was-judged$' "$tmp/qerr")" 1
check "9479 T11: and no read spends main" "$(grep -c '^main ' "$tmp/qgh.log.tok")" 0
qplant_read "$tmp/q-rout" 0 refused
check "9479 T11: the scan gate pauses on the read token's row" "$(QROOT="$tmp/qroot" qderive "$tmp/q-rout")" "no-write/miss/gh/"
check "9479 T11: the pause line names the read token" "$(grep -c '^QUOTA-PAUSE github graphql token=read remaining=0 .* caller=ticket-status nothing-was-judged$' "$tmp/qerr")" 1
check "9479 T11: a paused derive makes no gh call" "$(wc -l < "$tmp/qgh.log" | tr -d ' ')" 0
qplant "$tmp/q-r401" 0 refused
printf 'read\tgraphql\t-\t-\t-\t%s\tunreadable\nread\tcore\t-\t-\t-\t%s\tunreadable\n' "$(date +%s)" "$(date +%s)" >> "$tmp/q-r401/quota.tsv"
check "9479 T11: a read token that probes unreadable (a 401) gates on main's row, and main at 0 pauses the derive" "$(QROOT="$tmp/qroot" qderive "$tmp/q-r401")" "no-write/miss/gh/"
check "9479 T11: that pause line names main" "$(grep -c '^QUOTA-PAUSE github graphql token=main remaining=0 .* caller=ticket-status nothing-was-judged$' "$tmp/qerr")" 1
check "9479 T11: and no read went out" "$(wc -l < "$tmp/qgh.log" | tr -d ' ')" 0
check "9479 T11 RED control: with no read token configured the derive reads on main, as today" "$(qderive "$tmp/q-rok")" "In Progress///D5"
check "9479 T11 RED control: the PR list goes out on main" "$(grep -c '^main pr list$' "$tmp/qgh.log.tok")" 1

mkdir -p "$tmp/mrbin"
cat > "$tmp/mrbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s %s\n' "${GH_TOKEN:-main}" "$1" "$2" "$3" >> "$MR_TOK_LOG"
[ -z "${MR_HANG:-}" ] || exec -a "mr-sleep-$MR_HANG" sleep 30
if [ -n "${GH_TOKEN:-}" ] && [ -n "${MR_READ_RL:-}" ]; then echo 'GraphQL: API rate limit already exceeded for user ID 2.' >&2; exit 1; fi
[ "$1 $2" != "pr view" ] || echo "MERGED h12"
EOF
chmod +x "$tmp/mrbin/gh"
mr_t11() {
    local root="$1"
    shift
    : > "$tmp/mrtok.log"
    env -u MERGE_ROWS_GH -u himmel_github_token_vm2 PATH="$tmp/mrbin:$PATH" GH_READ_ENV_ROOT="$root" MR_TOK_LOG="$tmp/mrtok.log" "$@" \
        python3 -I "$HERE/merge-rows-effective.py" "$tmp/mr12.jsonl" 2>/dev/null | grep -c '"pr":"12"'
}
printf '{"ts":"t","event":"merge","key":"HIMMEL-9102","pr":"12","head":"h12","contract":"yes","result":"pending","stage":"pre-merge"}\n' > "$tmp/mr12.jsonl"
check "9479 T11: merge-rows keeps a merged PR's pre-merge row read through the router" "$(mr_t11 "$tmp/qroot")" 1
check "9479 T11: merge-rows' PR read goes out on the read token" "$(grep -c '^ghp_TSREAD0123456789 pr view 12$' "$tmp/mrtok.log")" 1
check "9479 T11 RED control: with no read token configured merge-rows reads on main" "$(mr_t11 "$tmp/qnoroot")" 1
check "9479 T11 RED control: its PR read goes out on main, as today" "$(grep -c '^main pr view 12$' "$tmp/mrtok.log")" 1
mrtag="mrhang$$"
check "9479 T11: a hung read under a 3 s budget is not counted" "$(mr_t11 "$tmp/qroot" MR_HANG="$mrtag" MERGE_ROWS_BUDGET_SECS=3)" 0
sleep 1
check "9479 T11: and the router's own bound left no gh behind" "$(pgrep -f "mr-sleep-$mrtag" | grep -c .)" 0
pkill -f "mr-sleep-$mrtag" 2>/dev/null
check "9479 T11: under 2 s of budget no read starts (the router's bound could not end first)" "$(mr_t11 "$tmp/qroot" MERGE_ROWS_BUDGET_SECS=1.5)" 0
check "9479 T11: and nothing went out" "$(grep -c . "$tmp/mrtok.log")" 0
printf '. %q\n' "$HERE/ticket-status.sh" > "$tmp/mrts.sh"
cat >> "$tmp/mrts.sh" <<'EOF'
ts_merge_rows "$1"
EOF
: > "$tmp/mrtok.log"
check "9479 T11: ticket-status's merge-rows read, rate-limited on the read token, counts no row (a scan)" \
    "$(env -u MERGE_ROWS_GH -u himmel_github_token_vm2 PATH="$tmp/mrbin:$PATH" GH_READ_ENV_ROOT="$tmp/qroot" MR_TOK_LOG="$tmp/mrtok.log" MR_READ_RL=1 \
        bash "$tmp/mrts.sh" "$tmp/mr12.jsonl" 2>/dev/null | grep -c '"pr":"12"')" 0
check "9479 T11: and is not retried on main" "$(grep -c '^main ' "$tmp/mrtok.log")" 0

# A caller that already holds the disposition (the dispatcher's one batch read) passes it as the second argument and the
# one-doc python read is skipped; only a recognised word is taken, and the one-argument call is what it always was.
u8lib="$tmp/u8lib"; mkdir -p "$u8lib"
printf 'import sys\nsys.exit(1)\n' > "$u8lib/fleet_runtime.py"  # a disposition read that always faults: the one-argument call reads unknown from it
printf -- '- 10:00 WRAPPED — ended\n' > "$tmp/u8-wrapped.md"
printf -- '- 10:00 LIVE — working\n' > "$tmp/u8-working.md"
: > "$tmp/u8-empty.md"
ucall() { _TS_LIB_DIR="$u8lib" TICKET_STATUS_QUEUE_LOCK="${U8_LOCK:-$tmp/lock-free.sh}" ts_worker_state "$@"; }
check "U8: with no second argument the disposition is read the one-doc way (here a fault, so unknown)" "$(ucall "$tmp/u8-wrapped.md")" unknown
check "U8: a supplied legacy disposition replaces that read, and the newest marker decides" "$(ucall "$tmp/u8-wrapped.md" '"legacy"')" wrapped
check "U8: a supplied legacy disposition, no marker and a free lock is unknown, not free" "$(ucall "$tmp/u8-empty.md" '"legacy"')" unknown
for word in pending committed unknown; do
    check "U8: a supplied $word disposition reads unknown over an end marker" "$(ucall "$tmp/u8-wrapped.md" "\"$word\"")" unknown
done
check "U8: a supplied launched disposition leaves the markers and the lock to decide" "$(ucall "$tmp/u8-wrapped.md" '"launched"')" wrapped
check "U8: a supplied refused disposition, no marker and a free lock reads wrapped" "$(ucall "$tmp/u8-empty.md" '"refused"')" wrapped
check "U8: a supplied complete disposition, no marker and a free lock reads wrapped" "$(ucall "$tmp/u8-empty.md" '"complete"')" wrapped
check "U8: a supplied refused disposition does not hide a held lock" "$(U8_LOCK="$tmp/lock.sh" ucall "$tmp/u8-working.md" '"refused"')" live
check "U8: a supplied refused disposition does not hide a live-class marker over a free lock" "$(ucall "$tmp/u8-working.md" '"refused"')" unknown
for junk in '"bogus"' 'legacy' '' '"legacy" '; do
    check "U8: a second argument that is not a recognised word ($junk) is not used" "$(ucall "$tmp/u8-wrapped.md" "$junk")" unknown
done

printf -- '- 10:00 LIVE — working\n' > "$tmp/u8-unread.md"
for word in refused complete; do
    check "X07-6 control: a readable doc with a LIVE marker, a $word receipt and a free lock reads unknown" "$(ucall "$tmp/u8-unread.md" "\"$word\"")" unknown
done
chmod 000 "$tmp/u8-unread.md"
if [ -r "$tmp/u8-unread.md" ]; then
    echo "SKIP - X07-6 an unreadable doc with a refused receipt and a free lock reads unknown, not wrapped: this user reads a mode 000 file"
else
    for word in refused complete; do
        check "X07-6 an unreadable doc with a $word receipt and a free lock reads unknown, not wrapped" "$(ucall "$tmp/u8-unread.md" "\"$word\"")" unknown
    done
fi
chmod 644 "$tmp/u8-unread.md"
for word in refused complete; do
    check "X07-6 a missing doc with a $word receipt and a free lock reads wrapped" "$(ucall "$tmp/u8-missing.md" "\"$word\"")" wrapped
done
ts_marker_newest "$tmp/u8-empty.md" >/dev/null; check "X07-6 ts_marker_newest control: a readable doc with no marker is rc 0" "$?" 0
mkdir -p "$tmp/gbin" "$tmp/u8-dir.md"
ts_marker_newest "$tmp/u8-dir.md" >/dev/null; check "X07-6 ts_marker_newest: a doc it cannot read is rc 1" "$?" 1
ts_marker_newest "$tmp/u8-missing.md" >/dev/null; check "X07-6 ts_marker_newest: a missing doc is rc 2" "$?" 2
(cd "$tmp" && ts_marker_newest u8-no-such-here.md >/dev/null); check "X07-6 ts_marker_newest: a missing doc named without a slash is rc 2" "$?" 2
cat > "$tmp/gbin/grep" <<'EOF'
#!/bin/sh
[ "${GREP_STANDIN_RC:-1}" -ne 2 ] || echo "grep: (standard input): Input/output error" >&2
exit "${GREP_STANDIN_RC:-1}"
EOF
chmod +x "$tmp/gbin/grep"
check "X07-6 a doc that is a directory, with a refused receipt and a free lock, reads unknown, not wrapped" "$(ucall "$tmp/u8-dir.md" '"refused"')" unknown
check "X07-6 a directory that grep reads as empty, with a refused receipt and a free lock, reads unknown, not wrapped" "$(PATH="$tmp/gbin:$PATH" GREP_STANDIN_RC=1 ucall "$tmp/u8-dir.md" '"refused"')" unknown
check "X07-6 a doc that opens but fails when read, with a refused receipt and a free lock, reads unknown, not wrapped" "$(PATH="$tmp/gbin:$PATH" GREP_STANDIN_RC=2 ucall "$tmp/u8-empty.md" '"refused"')" unknown
check "X07-6 control: a readable doc that grep finds no marker in (exit 1), with a refused receipt and a free lock, reads wrapped" "$(PATH="$tmp/gbin:$PATH" GREP_STANDIN_RC=1 ucall "$tmp/u8-empty.md" '"refused"')" wrapped
mkfifo "$tmp/u8-fifo.md"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$tmp/u8-sock.md"
printf -- '- 10:00 LIVE — working\n\000\n' > "$tmp/u8-nul-live.md"
printf -- '- a note\n\000\n' > "$tmp/u8-nul-plain.md"
printf -- '- 10:00 LIVE — work\377ing\n' > "$tmp/u8-badutf.md"
ln -s "$tmp/u8-wrapped.md" "$tmp/u8-link.md"
fifo_state() {
    local fid pid i=0 hung=""
    ( while :; do : > "$tmp/u8-fifo.md"; done ) &
    fid=$!
    ( ucall "$tmp/u8-fifo.md" '"refused"' > "$tmp/fifo.out" 2>/dev/null ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        [ "$i" -lt 30 ] || { hung=yes; break; }
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    kill "$fid" 2>/dev/null
    wait "$fid" 2>/dev/null
    [ -z "$hung" ] || kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if [ -n "$hung" ]; then echo HUNG; else cat "$tmp/fifo.out"; fi
}
check "X07-6 a doc with a NUL byte and a LIVE marker, with a refused receipt and a free lock, reads unknown, not wrapped" "$(ucall "$tmp/u8-nul-live.md" '"refused"')" unknown
check "X07-6 a doc with a NUL byte and no marker, with a refused receipt and a free lock, reads unknown, not wrapped" "$(ucall "$tmp/u8-nul-plain.md" '"refused"')" unknown
check "X07-6 a doc with a byte that is not valid UTF-8 and a LIVE marker is read as text and reads unknown, not wrapped" "$(LC_ALL=C.UTF-8 ucall "$tmp/u8-badutf.md" '"refused"')" unknown
check "X07-6 a UNIX socket as the doc, with a refused receipt and a free lock, reads unknown, not wrapped" "$(ucall "$tmp/u8-sock.md" '"refused"')" unknown
check "X07-6 a FIFO as the doc, with a refused receipt and a free lock, returns and reads unknown, not wrapped" "$(fifo_state)" unknown
check "X07-6 control: a symlink to a readable doc with an end marker is read as that doc" "$(ucall "$tmp/u8-link.md" '"refused"')" wrapped
ln -s "$tmp/u8-no-target.md" "$tmp/u8-dangling.md"
for word in refused complete; do
    check "X07-6 a dangling symlink as the doc, with a $word receipt and a free lock, reads unknown, not wrapped" "$(ucall "$tmp/u8-dangling.md" "\"$word\"")" unknown
done
mkdir -p "$tmp/u8-locked"
chmod 000 "$tmp/u8-locked"
if [ -x "$tmp/u8-locked" ]; then
    echo "SKIP - X07-6 a missing doc inside a directory that cannot be searched reads unknown, not wrapped: this user searches a mode 000 directory"
else
    for word in refused complete; do
        check "X07-6 a missing doc inside a directory that cannot be searched, with a $word receipt and a free lock, reads unknown, not wrapped" "$(ucall "$tmp/u8-locked/gone.md" "\"$word\"")" unknown
    done
    ts_marker_newest "$tmp/u8-locked/gone.md" >/dev/null; check "X07-6 ts_marker_newest: a doc whose directory cannot be searched is rc 1" "$?" 1
fi
chmod 755 "$tmp/u8-locked"

reqcount() { grep -c . "$tmp/req-calls" 2>/dev/null || echo 0; }
ts_required_set() { echo "$1" >> "$tmp/req-calls"; [ -z "${REQ_FAIL:-}" ] || return 1; printf '%s\t\n' "${REQ_SET:-ci-quick}"; }
export TICKET_STATUS_STATE_DIR="$tmp/state-req"
export GH_REPO=own/alpha
fresh_snapshot() { rm -rf "$tmp/snap-req"; mkdir -p "$tmp/snap-req"; TS_SNAPSHOT_DIR="$tmp/snap-req"; }
: > "$tmp/req-calls"
fresh_snapshot; TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main >/dev/null
fresh_snapshot; out=$(TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main)
check "required set: a second snapshot inside the TTL reads the kept answer, not GitHub" "$(reqcount)" 1
check "required set: the kept answer is the one returned" "$out" "$(printf 'ci-quick\t')"
fresh_snapshot; TICKET_STATUS_REQSET_TTL=0 _ts_snap_required_set main >/dev/null
check "required set: TTL 0 reads GitHub again" "$(reqcount)" 2
: > "$tmp/req-calls"; rm -rf "$tmp/state-req"
fresh_snapshot; REQ_FAIL=1 TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main >/dev/null
fresh_snapshot; TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main >/dev/null
check "required set: an unreadable answer is never kept" "$(reqcount)" 2
printf '1\nstale\n' > "$tmp/state-req/required-set/own@alpha@main"
fresh_snapshot; out=$(TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main)
check "required set: an entry older than the TTL is read again" "$out" "$(printf 'ci-quick\t')"
rm -rf "$tmp/state-req"
fresh_snapshot; GH_REPO=own/alpha REQ_SET=alpha-check TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main >/dev/null
fresh_snapshot; out=$(GH_REPO=own/beta REQ_SET=beta-check TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main)
check "required set: a second repository with the same base inside the TTL reads its own set" "$out" "$(printf 'beta-check\t')"
fresh_snapshot; out=$(GH_REPO=own/alpha REQ_SET=other TICKET_STATUS_REQSET_TTL=300 _ts_snap_required_set main)
check "required set: the first repository still reads its own kept set" "$out" "$(printf 'alpha-check\t')"

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-ticket-status.sh"
else
    echo "FAIL - test-ticket-status.sh: $fails failure(s)"
    exit 1
fi
