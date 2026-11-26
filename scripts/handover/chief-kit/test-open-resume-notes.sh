#!/usr/bin/env bash
# scripts/handover/chief-kit/test-open-resume-notes.sh - suite: open-resume-notes.sh, the one owner of
# "which resume notes still owe a relaunch".
#
# Every case runs against a fresh fixture under one mktemp -d: a bucket (<root>/yotamleo/himmel), a Jira
# mirror with a .cursor.json, an events file, and a seam for the lock sweep and the merge filter. The seams
# act only under HIMMEL_TEST_FIXTURE=1. A real sweep and the real merge filter run in one row each.
#
# Platform guard: Linux bash 3.2+ (GNU touch -d / date -d), as the owner itself.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/open-resume-notes.sh"
QL="$HERE/../queue-lock.sh"
VECTORS="$HERE/fixtures/open-notes-trailers.tsv"
TAB=$'\t'

W="$(mktemp -d "${TMPDIR:-/tmp}/open-notes-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
unset GIT_DIR GIT_WORK_TREE
export HOME="$W/home"; mkdir -p "$HOME"
unset HANDOVER_DIR TICKET_STATUS_STATE_DIR HIMMEL_JIRA_MIRROR

pass=0; fails=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; [ $# -lt 2 ] || printf '    %s\n' "$2"; fails=$((fails+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "[$2] != [$3]"; fi; }
has()   { if grep -qF -e "$2" <<<"$OUT"; then ok "$1"; else bad "$1" "output does not contain [$2]: $OUT"; fi; }
lacks() { if grep -qF -e "$2" <<<"$OUT"; then bad "$1" "output contains [$2]: $OUT"; else ok "$1"; fi; }
count_notes() { grep -c "^NOTE$TAB" <<<"$OUT" || true; }

NOW_ISO="2026-11-26T12:00:00Z"
NOW="$(date -u -d "$NOW_ISO" +%s)"
CUR_ISO="2026-11-26T11:00:00Z"

cat > "$W/sweep" <<'EOF'
#!/usr/bin/env bash
cat "$SWEEP_DIR/sweep.out"
exit "$(cat "$SWEEP_DIR/sweep.rc")"
EOF
cat > "$W/sweep-slow" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo "sweep: no held locks"
EOF
cat > "$W/sweep-term" <<'EOF'
#!/usr/bin/env bash
sleep 60 &
echo $! > "$CHILD_PID_FILE"
wait
EOF
printf '#!/usr/bin/env bash\nexit 2\n' > "$W/merge-fail"
printf '#!/usr/bin/env bash\necho "OPEN abc"\n' > "$W/gh-open"
chmod +x "$W/sweep" "$W/sweep-slow" "$W/sweep-term" "$W/merge-fail" "$W/gh-open"

CN=0
newcase() {
    CN=$((CN + 1))
    C="$W/c$CN"; B="$C/yotamleo/himmel"; M="$C/mirror"; E="$C/events.jsonl"
    mkdir -p "$B" "$M"; : > "$E"
    : > "$M/.cursor.json"; touch -d "$CUR_ISO" "$M/.cursor.json"
    echo "sweep: no held locks" > "$C/sweep.out"; echo 0 > "$C/sweep.rc"
    SWEEP_CMD="$W/sweep"; MERGE_CMD="cat"
    BUCKET_ARG="$B"; MIRROR_ARG="$M"; EVENTS_ARG="$E"
}
mknote() {
    printf '%s\n' '# resume note' > "$B/$1"; touch -d "$2" "$B/$1"
}
mkmirror() {
    printf '%s\n' '---' "key: \"$1\"" "status: \"$2\"" "statusCategory: \"$3\"" '---' '' "# $1: a ticket" > "$M/$1.md"
}
sweep_says() { printf '%s\n' "$1" > "$C/sweep.out"; echo "$2" > "$C/sweep.rc"; }

TRAILER_RE='^# open-notes: (complete|incomplete [^ ]+) n=[0-9]+ unverified=[0-9]+ merge_hidden=[0-9]+ mirror_cursor_age_min=([0-9]+|-)$'
run_owner() {
    local label="$1" last nt nn nu tn tu verdict=ok
    shift
    local -a e=(HIMMEL_TEST_FIXTURE=1 "OPEN_NOTES_NOW=$NOW" "SWEEP_DIR=$C")
    [ -z "$SWEEP_CMD" ] || e+=("OPEN_NOTES_SWEEP_CMD=$SWEEP_CMD")
    [ -z "$MERGE_CMD" ] || e+=("OPEN_NOTES_MERGE_ROWS_CMD=$MERGE_CMD")
    [ $# -eq 0 ] || e+=("$@")
    OUT="$(env "${e[@]}" bash "$SUT" --bucket "$BUCKET_ARG" --mirror "$MIRROR_ARG" --events "$EVENTS_ARG" --root "$C" 2>"$C/err")"; RC=$?
    last="$(tail -n 1 <<<"$OUT")"
    nt="$(grep -c '^# open-notes:' <<<"$OUT" || true)"
    nn="$(count_notes)"; nu="$(grep -c "^UNVERIFIED$TAB" <<<"$OUT" || true)"
    tn="$(sed -n 's/^# open-notes: .* n=\([0-9][0-9]*\) unverified=.*/\1/p' <<<"$last")"
    tu="$(sed -n 's/^# open-notes: .* unverified=\([0-9][0-9]*\) merge_hidden=.*/\1/p' <<<"$last")"
    [ "$nt" = 1 ] || verdict="trailer lines: $nt"
    grep -Eq "$TRAILER_RE" <<<"$last" || verdict="last line is not a trailer: [$last]"
    [ "$nn:$nu" = "$tn:$tu" ] || verdict="counts rows $nn:$nu, trailer $tn:$tu"
    check "$label: one trailer, last, counts match" "$verdict" ok
}

if [ ! -f "$SUT" ]; then bad "open-resume-notes.sh exists" "$SUT is missing"; fi

[ -f "$VECTORS" ] || bad "the shared trailer vectors exist" "$VECTORS is missing"

plant_set() {
    mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
    mknote DEMO-2-N2-b-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-2 Done Done
    mknote DEMO-3-N3-c-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-3 "In Progress" "In Progress"
    echo '{"ts":"2026-11-21T10:00:00Z","event":"merge","key":"DEMO-3","pr":"7001","contract":"no","result":"noop"}' > "$E"
}

echo "row 1/2: the planted set of three lists one note; a Done ticket is not listed"
newcase; plant_set
run_owner "row1"
check "row 1: exactly one NOTE row" "$(count_notes)" "1"
has "row 1: DEMO-1 is the note" "NOTE${TAB}DEMO-1${TAB}"
has "row 1: the merge hid one note" "merge_hidden=1"
lacks "row 2: a Done ticket is not listed" "${TAB}DEMO-2${TAB}"
lacks "row 1: a note older than a contract=no merge is hidden" "${TAB}DEMO-3${TAB}"
check "row 1: exit 0" "$RC" "0"

echo "row 3: contract=yes hides, a contract-less derive row hides nothing"
newcase
mknote DEMO-17-N17-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-17 "In Progress" "In Progress"
mknote DEMO-18-N18-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-18 "In Progress" "In Progress"
printf '%s\n' '{"ts":"2026-11-21T10:00:00Z","event":"merge","key":"DEMO-17","pr":"7","contract":"yes","result":"ok"}' \
    '{"ts":"2026-11-21T10:00:00Z","event":"merge","key":"DEMO-18","pr":"8","result":"derive"}' > "$E"
run_owner "row3"
lacks "row 3: a contract=yes merge newer than the note hides it" "${TAB}DEMO-17${TAB}"
has "row 3: a contract-less derive row hides nothing" "NOTE${TAB}DEMO-18${TAB}"

echo "row 4: the newer note is listed, date-after shape included"
newcase
mknote DEMO-4-N4-d-2026-11-19-RESUME.md 2026-11-19T08:00:00Z
mknote DEMO-4-N4b-d-RESUME-2026-11-21.md 2026-11-21T08:00:00Z; mkmirror DEMO-4 "In Progress" "In Progress"
run_owner "row4"
has "row 4: the date-after note is the listed one" "$B/DEMO-4-N4b-d-RESUME-2026-11-21.md"
lacks "row 4: the older note is not listed" "DEMO-4-N4-d-2026-11-19-RESUME.md"

echo "row 5: RESUME2 beats a same-time plain note"
newcase
mknote DEMO-5-N5-e-RESUME.md 2026-11-22T08:00:00Z
mknote DEMO-5-N5-e-RESUME2.md 2026-11-22T08:00:00Z; mkmirror DEMO-5 "In Progress" "In Progress"
run_owner "row5"
has "row 5: RESUME2 is listed" "$B/DEMO-5-N5-e-RESUME2.md"
lacks "row 5: the plain note is not" "$B/DEMO-5-N5-e-RESUME.md${TAB}"

echo "row 6: hybrids and one-offs are never candidates"
newcase; plant_set
mknote DEMO-1-x-RESUME2-2026-11-21.md 2026-11-21T09:00:00Z
mknote DEMO-1-RESUME-NOTE-2026-11-21.md 2026-11-21T09:00:00Z
mknote DEMO-1-x-RESUME.worker-contract.md 2026-11-21T09:00:00Z
run_owner "row6"
has "row 6: row 1's path is unchanged" "$B/DEMO-1-N1-a-2026-11-20-RESUME.md${TAB}"
lacks "row 6: the hybrid is not a candidate" "RESUME2-2026-11-21"
lacks "row 6: the one-off is not a candidate" "RESUME-NOTE"
lacks "row 6: a helper file is not a candidate" "worker-contract"

echo "row 7: a To Do ticket's note is listed"
newcase
mknote DEMO-6-N6-f-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-6 "To Do" "To Do"
run_owner "row7"
has "row 7: DEMO-6 (To Do) is listed" "NOTE${TAB}DEMO-6${TAB}"
has "row 7: its status is printed" "status=To Do"

echo "row 8: locks"
SLUG="yotamleo__himmel__DEMO-6-N6x-other-2026-11-26"
lock_case() {
    newcase
    mknote DEMO-6-N6-f-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-6 "To Do" "To Do"
    mknote DEMO-60-N60-f-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-60 "To Do" "To Do"
    sweep_says "$2" "$3"
    run_owner "$1"
    check "$1: DEMO-6 listed" "$(grep -c "^NOTE${TAB}DEMO-6${TAB}" <<<"$OUT")" "$([ "$4" = yes ] && echo 1 || echo 0)"
    check "$1: DEMO-60 is never hidden by a lock on DEMO-6-" "$(grep -c "^NOTE${TAB}DEMO-60${TAB}" <<<"$OUT")" "1"
}
lock_case "row8 OK" "slug=$SLUG session=s host=h age=1s status=OK" 0 no
lock_case "row8 STALE-DEAD" "slug=$SLUG session=s host=h age=99999s status=STALE-DEAD" 20 yes
has "row 8: STALE-DEAD is still a complete read" "# open-notes: complete "
lock_case "row8 CORRUPT" "slug=$SLUG status=CORRUPT reason=owner.json-missing" 20 no
lock_case "row8 UNKNOWN" "slug=$SLUG session=s host=h age=unknown status=UNKNOWN" 20 no
lock_case "row8 INDETERMINATE" "slug=$SLUG status=INDETERMINATE reason=owner.json-missing-recent age=1s" 0 no
lock_case "row8 IDLE-HELD?" "slug=$SLUG session=s host=h age=9999s status=IDLE-HELD?" 20 no
lock_case "row8 no held locks" "sweep: no held locks" 0 yes

echo "row 9: the wrap sequence keeps the note open"
newcase
mknote DEMO-8-N8-g-RESUME-2026-11-20.md 2026-11-20T10:00:00Z; mkmirror DEMO-8 "In Progress" "In Progress"
printf '%s\n' '# worker' '## Results' '- 10:03 WRAPPED — resume brief DEMO-8-N8-g-RESUME-2026-11-20.md' > "$B/DEMO-8-N8-g-2026-11-20.md"
touch -d 2026-11-20T10:00:11Z "$B/DEMO-8-N8-g-2026-11-20.md"
mknote DEMO-9-N9-h-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-9 "In Progress" "In Progress"
printf '%s\n' '# worker' '## Results' '- 10:03 WRAPPED — resume brief DEMO-9-N9-h-RESUME.md' > "$B/DEMO-9-N9-h.md"
touch -d 2026-11-20T10:00:11Z "$B/DEMO-9-N9-h.md"
run_owner "row9"
has "row 9: the date-after note is listed with its dated original" "orig=$B/DEMO-8-N8-g-2026-11-20.md"
has "row 9: a <stem>.md original is named" "orig=$B/DEMO-9-N9-h.md"
check "row 9: both notes stay open" "$(count_notes)" "2"

echo "row 10: the real lock sweep, no seam"
newcase
printf '%s\n' '# worker' > "$B/DEMO-16-N16-x.md"
mknote DEMO-16-N16-x-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-16 "In Progress" "In Progress"
ACQ="$(HANDOVER_DIR="$C" bash "$QL" acquire "$B/DEMO-16-N16-x.md" 2>/dev/null)"
# shellcheck disable=SC2016  # the backticks are literal characters of the release-token line
TOK="$(sed -n 's/^release-token: `\(.*\)`$/\1/p' <<<"$ACQ")"
SWEEP_CMD=""
run_owner "row10 held"
lacks "row 10: a note whose ticket holds a real lock is hidden" "${TAB}DEMO-16${TAB}"
HANDOVER_DIR="$C" bash "$QL" release "$B/DEMO-16-N16-x.md" "$TOK" >/dev/null 2>&1
run_owner "row10 released"
has "row 10: after release the note is listed" "NOTE${TAB}DEMO-16${TAB}"

echo "row 11: an unparseable ts hides nothing"
newcase
mknote DEMO-11-N11-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-11 "In Progress" "In Progress"
echo '{"ts":"t","event":"merge","key":"DEMO-11","pr":"7","contract":"no","result":"noop"}' > "$E"
run_owner "row11"
has "row 11: DEMO-11 is listed" "NOTE${TAB}DEMO-11${TAB}"

echo "row 12: the merge compare is to the second"
newcase
mknote DEMO-12-N12-j-2026-11-20-RESUME.md 2026-11-21T06:00:00Z; mkmirror DEMO-12 "In Progress" "In Progress"
echo '{"ts":"2026-11-20T23:59:58Z","event":"merge","key":"DEMO-12","pr":"7","contract":"no","result":"noop"}' > "$E"
run_owner "row12 before"
has "row 12: note_at is the end of the name day" "${TAB}2026-11-20T23:59:59Z${TAB}"
has "row 12: a merge one second before leaves the note listed" "NOTE${TAB}DEMO-12${TAB}"
echo '{"ts":"2026-11-21T00:00:00Z","event":"merge","key":"DEMO-12","pr":"7","contract":"no","result":"noop"}' > "$E"
run_owner "row12 after"
lacks "row 12: a merge one second after hides it" "NOTE${TAB}DEMO-12${TAB}"
has "row 12: and counts it" "merge_hidden=1"

echo "row 13: an invalid name date falls back to the mtime"
newcase
mknote DEMO-13-N13-h-2026-13-45-RESUME.md 2026-11-25T08:00:00Z; mkmirror DEMO-13 "In Progress" "In Progress"
run_owner "row13"
has "row 13: note_at is the mtime" "2026-11-25T08:00:00Z"

echo "row 14: a moved key is UNVERIFIED with a complete trailer"
newcase
mknote DEMO-14-N14-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z
mknote DEMO-21-N21-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z
printf '%s\n' '---' 'key: "DEMO-21"' 'status: "To Do"' '---' > "$M/DEMO-21.md"
run_owner "row14"
has "row 14: no mirror file" "UNVERIFIED${TAB}DEMO-14${TAB}$B/DEMO-14-N14-a-2026-11-20-RESUME.md${TAB}2026-11-20T10:00:00Z${TAB}reason=no-mirror-file"
has "row 14: no statusCategory" "reason=no-status"
has "row 14: the read is complete, two unverified" "# open-notes: complete n=0 unverified=2 "
lacks "row 14: DEMO-14 is not a NOTE" "NOTE${TAB}DEMO-14${TAB}"

echo "row 15: mirror freshness"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
touch -d 2026-11-25T11:00:00Z "$M/.cursor.json"
run_owner "row15 stale"
has "row 15: a 1500 min old cursor is mirror-stale" "# open-notes: incomplete mirror-stale"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
rm -f "$M/.cursor.json"
run_owner "row15 no cursor"
has "row 15: no .cursor.json is mirror-unreadable" "# open-notes: incomplete mirror-unreadable"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z
MIRROR_ARG="$C/no-such-mirror"
run_owner "row15 no dir"
has "row 15: a missing mirror dir is mirror-unreadable" "# open-notes: incomplete mirror-unreadable"

echo "row 16: a failing or slow sweep gives locks-unknown"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
sweep_says "" 3
run_owner "row16 exit 3"
has "row 16: a seam that exits 3" "incomplete locks-unknown"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
SWEEP_CMD="$W/sweep-slow"
t0="$(date +%s)"
run_owner "row16 slow" OPEN_NOTES_SWEEP_SECS=1
t1="$(date +%s)"
has "row 16: a sweep that sleeps past its timeout" "incomplete locks-unknown"
check "row 16: wall time is at most 1 + 3 s" "$([ $((t1 - t0)) -le 4 ] && echo ok || echo "$((t1 - t0)) s")" ok

echo "row 17: merge failures give events-unreadable"
newcase
mknote DEMO-19-N19-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-19 "In Progress" "In Progress"
mkdir -p "$C/eventsdir"; EVENTS_ARG="$C/eventsdir"
run_owner "row17 events dir"
has "row 17: --events as a directory" "incomplete events-unreadable"
newcase
mknote DEMO-19-N19-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-19 "In Progress" "In Progress"
MERGE_CMD="$W/merge-fail"
run_owner "row17 merge fails"
has "row 17: a merge seam that exits 2" "incomplete events-unreadable"
newcase
mknote DEMO-19-N19-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-19 "In Progress" "In Progress"
echo '{"ts":"2026-11-21T10:00:00Z","event":"merge","stage":"pre-merge","result":"pending","key":"DEMO-19","pr":"900","head":"abc","contract":"no"}' > "$E"
MERGE_CMD=""
run_owner "row17 real filter, PR open" "MERGE_ROWS_GH=$W/gh-open"
has "row 17: a PR that never merged hides nothing (real filter)" "NOTE${TAB}DEMO-19${TAB}"
has "row 17: and the read is complete" "# open-notes: complete "
run_owner "row17 real filter, no budget" "MERGE_ROWS_GH=$W/gh-open" MERGE_ROWS_BUDGET_SECS=0
has "row 17: a merge filter that warns gives merges-partial" "incomplete merges-partial"

echo "row 18: a stat failure gives stat-failed, no older note is promoted"
newcase
mknote DEMO-15-N15-i-2026-11-19-RESUME.md 2026-11-19T10:00:00Z; mkmirror DEMO-15 "In Progress" "In Progress"
ln -s "$C/nonexistent" "$B/DEMO-15-N15-i-2026-11-20-RESUME.md"
run_owner "row18"
has "row 18: the key is UNVERIFIED, path and note_at are -" "UNVERIFIED${TAB}DEMO-15${TAB}-${TAB}-${TAB}reason=stat-failed"
has "row 18: the read names the key" "incomplete stat-failed:DEMO-15"
lacks "row 18: no NOTE row for it" "NOTE${TAB}DEMO-15${TAB}"

echo "row 19: an unreadable bucket"
newcase
BUCKET_ARG="$C/no-such-bucket"
run_owner "row19"
has "row 19: bucket-unreadable" "incomplete bucket-unreadable"

echo "row 20: the deadline"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
SWEEP_CMD="$W/sweep-slow"
t0="$(date +%s)"
run_owner "row20" OPEN_NOTES_BUDGET_SECS=2
t1="$(date +%s)"
has "row 20: incomplete deadline" "incomplete deadline"
check "row 20: wall time is at most 2 + 3 s" "$([ $((t1 - t0)) -le 5 ] && echo ok || echo "$((t1 - t0)) s")" ok

echo "row 21: SIGTERM kills the child group and still prints a trailer"
newcase
mknote DEMO-1-N1-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-1 "In Progress" "In Progress"
PIDF="$C/child.pid"
( exec env HIMMEL_TEST_FIXTURE=1 "OPEN_NOTES_NOW=$NOW" "OPEN_NOTES_SWEEP_CMD=$W/sweep-term" OPEN_NOTES_MERGE_ROWS_CMD=cat "CHILD_PID_FILE=$PIDF" \
    bash "$SUT" --bucket "$B" --mirror "$M" --events "$E" --root "$C" >"$C/out21" 2>"$C/err21" ) &
OPID=$!
i=0; while [ ! -s "$PIDF" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
sleep 1
kill -TERM "$OPID" 2>/dev/null
wait "$OPID" 2>/dev/null
CPID="$(cat "$PIDF" 2>/dev/null)"
i=0; while [ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
check "row 21: the sweep seam's child is gone" "$([ -n "$CPID" ] && ! kill -0 "$CPID" 2>/dev/null && echo gone || echo "pid=[$CPID] alive or unwritten")" gone
OUT="$(cat "$C/out21")"
check "row 21: the output still ends in an incomplete trailer" "$(tail -n 1 <<<"$OUT" | grep -Ec '^# open-notes: incomplete ')" "1"
check "row 21: exactly one trailer" "$(grep -c '^# open-notes:' <<<"$OUT")" "1"

echo "row 23: newest first"
newcase
mknote DEMO-31-N31-a-RESUME.md 2026-11-22T08:00:00Z; mkmirror DEMO-31 "In Progress" "In Progress"
mknote DEMO-30-N30-a-RESUME.md 2026-11-24T08:00:00Z; mkmirror DEMO-30 "In Progress" "In Progress"
mknote DEMO-32-N32-a-RESUME.md 2026-11-18T08:00:00Z; mkmirror DEMO-32 "In Progress" "In Progress"
run_owner "row23"
check "row 23: NOTE rows are in descending note_at" "$(grep "^NOTE$TAB" <<<"$OUT" | cut -f2 | tr '\n' ,)" "DEMO-30,DEMO-31,DEMO-32,"

echo "row 24: an unreadable mirror file is UNVERIFIED"
if [ "$(id -u)" = 0 ]; then
    ok "row 24: skipped as root (chmod 000 does not stop root; CI runs non-root)"
else
    newcase
    mknote DEMO-20-N20-a-2026-11-20-RESUME.md 2026-11-20T10:00:00Z; mkmirror DEMO-20 "In Progress" "In Progress"
    chmod 000 "$M/DEMO-20.md"
    run_owner "row24"
    has "row 24: mirror-unreadable" "UNVERIFIED${TAB}DEMO-20${TAB}$B/DEMO-20-N20-a-2026-11-20-RESUME.md${TAB}2026-11-20T10:00:00Z${TAB}reason=mirror-unreadable"
    chmod 644 "$M/DEMO-20.md"
fi

echo "row 25: the shared vectors decode"
nv=0
while IFS="$TAB" read -r vname vexp vout; do
    [ -n "$vname" ] || continue
    nv=$((nv + 1))
    dec="${vout//\\n/$'\n'}"
    want="${vname##*-}"; want="${want%l}"
    check "row 25: vector $vname decodes to $want line(s)" "$(printf '%s\n' "$dec" | wc -l | tr -d ' ')" "$want"
    case "$vexp" in complete|incomplete:*) ok "row 25: vector $vname names a result" ;; *) bad "row 25: vector $vname names a result" "[$vexp]" ;; esac
done < "$VECTORS"
check "row 25: the file holds eight vectors" "$nv" "8"

echo "test-open-resume-notes: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
