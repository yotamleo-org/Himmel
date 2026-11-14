#!/usr/bin/env bash
# test-chief-wait-resume-stale.sh — an underfilled sample whose pool lists a RESUME row that has
# been parked past the resume wait wakes the chief once per window (WAKE resume-stale <KEYS>),
# and a sample whose park start cannot be read in full wakes nothing and leaves the marker alone.
# The park age reads ticket-status.sh (ts_now, ts_await_due, ts_park_since_rows), so the clock
# is TICKET_STATUS_NOW, never the wall clock. tick.sh's capacity field, the bank verdict, the
# dispatch command and the GitHub read are stubbed. bash 3.2-safe.
#
# CHIEF_WAIT overrides the script under test.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-resume-stale.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-resume-stale-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
echo x >> "$STUB/ticks"
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
echo PROCEED
EOF
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=1/1 capacity=UNDERFILLED:1 gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$STUB/tick.line"
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
export CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1 CHIEF_WAIT_PAUSED_REPROBE_SEC=0 CHIEF_WAIT_REPOOL_TIMEOUT=5
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/off.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh" CHIEF_WAIT_ORPHAN="$STUB/off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh"
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"
mkdir -p "$WORK/stub-jira"
cat > "$WORK/stub-jira/index.js" <<'STUBEOF'
const a = process.argv.slice(2);
if (a[0] === 'release' && a[1] === 'core-check') for (const k of a.slice(a.indexOf('--key') + 1)) console.log('NOT-CORE ' + k);
else { console.error('stub jira: unknown command ' + a.join(' ')); process.exit(2); }
STUBEOF
export NEXT_DISPATCH_JIRA_CLI="$WORK/stub-jira/index.js"

cat > "$STUB/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" --priority-pool-only "*)
        printf 'RESUME\tFIXT-7\tMedium\tv1\tparked\tfiles=z.sh\n# pool=1/7,LOW\n' ;;
esac
EOF
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
# shellcheck disable=SC2016  # $STUB expands in the stub, not here
printf '#!/usr/bin/env bash\necho x >> "$STUB/gh-calls"\nexec sleep 60\n' > "$STUB/gh-slow.sh"
chmod +x "$STUB/gh-slow.sh"
export MERGE_ROWS_GH="$STUB/gh-slow.sh"
unset MERGE_ROWS_BUDGET_SECS TICKET_STATUS_AWAIT_TTL_RESUME

NOW="$(date +%s)"
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }  # gnu-ok: Linux-only suite
H=3600

case_new() {
    CASE="$1"
    INBOX="$WORK/$CASE/consoles/c.md"
    mkdir -p "$WORK/$CASE/consoles" "$WORK/$CASE/state"
    : > "$INBOX"
    export TICKET_STATUS_STATE_DIR="$WORK/$CASE/state"
    export TICKET_STATUS_NOW="$NOW"
    LOG="$WORK/$CASE/state/status-events.jsonl"
    : > "$LOG"
    printf 'FIXT-7\n' > "$INBOX.wait.underfill"
    touch -d '2 hours ago' "$INBOX.wait.underfill"  # gnu-ok: Linux-only suite
    rm -f "$STUB/ticks" "$STUB/gh-calls"
}
row() {
    printf '{"ts":"%s","event":"%s","key":"FIXT-7","result":"%s","rule":"%s"%s}\n' "$(iso_at $((NOW - $1)))" "$2" "$3" "$4" "${5:+,$5}" >> "$LOG"
}
arm() { timeout "$2" bash "$WAIT" "$INBOX" --workers "N1.md" > "$1" 2> "$1.err"; rc=$?; }  # gnu-ok: Linux-only kit
stale_wakes() { grep -c '^WAKE resume-stale FIXT-7' "$1" 2>/dev/null; }
ticks() { if [ -f "$STUB/ticks" ]; then wc -l < "$STUB/ticks" | tr -d ' '; else echo 0; fi; }
ghcalls() { if [ -f "$STUB/gh-calls" ]; then wc -l < "$STUB/gh-calls" | tr -d ' '; else echo 0; fi; }

case_new r1
row $((7 * H)) sweep noop D5c
row 60 sweep noop D5c
arm "$WORK/r1.out" 12
check '1 a RESUME row parked 7 h wakes the chief naming the key (WAKE resume-stale FIXT-7)' '0:1' "$rc:$(stale_wakes "$WORK/r1.out")"

arm "$WORK/r2.out" 6
check '2 (control) a second sample inside the re-wake window prints no WAKE' '124:0' "$rc:$(grep -c '^WAKE ' "$WORK/r2.out")"

case_new r3a
row $((5 * H)) sweep noop D5c
arm "$WORK/r3a.out" 6
check '3 (control) a 5 h park prints no WAKE resume-stale' '124:0' "$rc:$(stale_wakes "$WORK/r3a.out")"
case_new r3b
row $((7 * H)) sweep noop D5c
TICKET_STATUS_AWAIT_TTL_RESUME=10h arm "$WORK/r3b.out" 6
check '3 (control) TICKET_STATUS_AWAIT_TTL_RESUME=10h silences the 7 h row' '124:0' "$rc:$(stale_wakes "$WORK/r3b.out")"

case_new r4
row $((7 * H)) wrapped moved D5c
arm "$WORK/r4.out" 12
check '4 a key whose only D5c row is its newest anchor (event=wrapped result=moved) wakes' '0:1' "$rc:$(stale_wakes "$WORK/r4.out")"

case_new r5
row $((7 * H)) sweep noop D5c
row 60 sweep noop D5c
TICKET_STATUS_NOW=$((NOW - 6 * H)) arm "$WORK/r5.out" 6
check '5 (control, clock) the read uses TICKET_STATUS_NOW, not the wall clock: no wake' '124:0' "$rc:$(stale_wakes "$WORK/r5.out")"

three_prs() {
    row $((7 * H)) sweep noop D5c
    row $((6 * H)) merge pending - '"pr":"11","head":"h11","contract":"no","stage":"pre-merge"'
    row $((5 * H)) merge pending - '"pr":"12","head":"h12","contract":"no","stage":"pre-merge"'
    row $((4 * H)) merge pending - '"pr":"13","head":"h13","contract":"no","stage":"pre-merge"'
}
case_new r6a
three_prs
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=3600 arm "$WORK/r6a.out" 20
ticks6a="$(ticks)"
check '6a (default budget) the sample returns inside 20 s after one slow GitHub read and prints no WAKE resume-stale' '124:0:yes:1' "$rc:$(stale_wakes "$WORK/r6a.out"):$([ "$ticks6a" -ge 5 ] && echo yes || echo "ticks=$ticks6a"):$(ghcalls)"

case_new r6b
three_prs
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=3600 MERGE_ROWS_BUDGET_SECS=120 arm "$WORK/r6b.out" 40
ticks6b="$(ticks)"
check '6b (timeout) the sample returns inside 40 s after slow GitHub reads and prints no WAKE resume-stale' '124:0:yes:yes' "$rc:$(stale_wakes "$WORK/r6b.out"):$([ "$ticks6b" -ge 3 ] && echo yes || echo "ticks=$ticks6b"):$([ "$(ghcalls)" -ge 1 ] && echo yes || echo none)"

mkdir -p "$STUB/bin"
JQ_REAL="$(command -v jq)"
export JQ_REAL
# shellcheck disable=SC2016  # $JQ_REAL expands in the stub, not here
printf '#!/usr/bin/env bash\n[ "${1:-}" != -Rrs ] || exit 1\nexec "$JQ_REAL" "$@"\n' > "$STUB/bin/jq"
chmod +x "$STUB/bin/jq"
case_new r7
row $((5 * H)) sweep noop D5c
printf 'FIXT-7\n' > "$INBOX.wait.resume-stale"
touch -d '5 hours ago' "$INBOX.wait.resume-stale"  # gnu-ok: Linux-only suite
PATH="$STUB/bin:$PATH" arm "$WORK/r7.out" 6
check '7 a failed park read wakes nothing and leaves the resume-stale marker as it was' '124:0:FIXT-7' "$rc:$(stale_wakes "$WORK/r7.out"):$(cat "$INBOX.wait.resume-stale" 2>/dev/null)"

case_new r8
row $((5 * H)) sweep noop D5c
printf 'FIXT-7\n' > "$INBOX.wait.resume-stale"
touch -d '5 hours ago' "$INBOX.wait.resume-stale"  # gnu-ok: Linux-only suite
chmod 000 "$LOG"
arm "$WORK/r8.out" 6
check '8 an unreadable status log wakes nothing and leaves the resume-stale marker as it was' '124:0:FIXT-7' "$rc:$(stale_wakes "$WORK/r8.out"):$(cat "$INBOX.wait.resume-stale" 2>/dev/null)"

printf '\n%s failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
