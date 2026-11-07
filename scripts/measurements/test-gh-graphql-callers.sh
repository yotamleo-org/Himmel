#!/usr/bin/env bash
# Tests for scripts/measurements/gh-graphql-callers.sh.
# Hermetic: `gh` is a PATH stub; never talks to GitHub.
#
#   1. report: a fixture log attributes points per caller, sorted, points/hour
#   2. RED control: a log with one caller line dropped does NOT match the
#      expected table (the row fails if a caller line is not counted)
#   3. report --top N prints N rows; the log is not modified (read-only)
#   4. run: the shim attributes GraphQL calls to the calling script, skips REST
#   5. run: remaining under the floor refuses (rc 2) and runs nothing
#   6. watch: a live gh process is charged once to its calling script
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/measurements/gh-graphql-callers.sh"
passes=0
fails=0
ok() { echo "ok - $1"; passes=$((passes + 1)); }
bad() { echo "FAIL - $1" >&2; [ $# -lt 2 ] || printf '    %s\n' "$2" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gqlc-test.XXXXXX")" || { echo "FAIL - mktemp -d failed" >&2; exit 1; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then echo "FAIL - no temp dir" >&2; exit 1; fi
trap 'rm -rf "$TMP"' EXIT

# --- fixture log: epoch<TAB>caller<TAB>points<TAB>args ---------------------
LOG="$TMP/calls.log"
{
  printf '1000\ttick.sh\t1\tpr list\n'
  printf '1001\ttick.sh\t1\tpr list\n'
  printf '1002\ttick.sh\t1\tpr view 7\n'
  printf '1003\tnext-dispatchable.sh\t1\tpr view 1\n'
  printf '1004\tnext-dispatchable.sh\t1\tpr view 2\n'
  printf '1005\tcheck-ci.sh\t1\tpr checks 9\n'
  printf '1006\tstatus-drift.sh\t1\tpr list\n'
  printf '1007\tcr-first-release.sh\t1\tpr view 3\n'
  printf '1008\tcr-first-release.sh\t1\tpr view 4\n'
  printf '1009\tcr-first-release.sh\t1\tpr view 5\n'
  printf '1010\tcr-first-release.sh\t1\tpr view 6\n'
  printf '1011\torphan-branches.sh\t1\tpr checks 2\n'
} >"$LOG"

# 2 hours observed: tick 3 pts = 1.5/h ... printed with one decimal
EXPECT=$(printf '%s\n' \
  "rank	caller	calls	points	points/hour" \
  "1	cr-first-release.sh	4	4	2.0" \
  "2	tick.sh	3	3	1.5" \
  "3	next-dispatchable.sh	2	2	1.0" \
  "4	check-ci.sh	1	1	0.5" \
  "5	orphan-branches.sh	1	1	0.5")

out=$(bash "$SCRIPT" report --log "$LOG" --hours 2 --top 5 2>&1)
if [ "$out" = "$EXPECT" ]; then ok "report prints the top five callers by points per hour"
else bad "report table differs" "got: $out"; fi

# RED control: drop one caller line, the table must no longer match.
LOG_DROP="$TMP/dropped.log"
sed '3d' "$LOG" >"$LOG_DROP"
out_drop=$(bash "$SCRIPT" report --log "$LOG_DROP" --hours 2 --top 5 2>&1)
if [ "$out_drop" != "$EXPECT" ]; then ok "control: an uncounted caller line fails the table match"
else bad "control: table matched although a caller line was dropped"; fi

before=$(cksum <"$LOG")
out3=$(bash "$SCRIPT" report --log "$LOG" --hours 2 --top 3 2>&1)
rows=$(printf '%s\n' "$out3" | grep -c -E '^[0-9]+	')
after=$(cksum <"$LOG")
if [ "$rows" = 3 ] && [ "$before" = "$after" ]; then ok "report --top 3 prints 3 rows and leaves the log untouched"
else bad "top/read-only" "rows=$rows before=$before after=$after"; fi

# --- run: shim attribution --------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat >"$BIN/gh" <<'STUB'
#!/bin/bash
[ -z "${FAKE_SLEEP:-}" ] || sleep "$FAKE_SLEEP"
case "$*" in
  "api -i graphql"*) printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: 4102444800\r\n\r\n{}\n' "${FAKE_REMAINING:-4000}" ;;
  *) echo '{}' ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"
cat >"$TMP/fakecaller.sh" <<'CALLER'
#!/usr/bin/env bash
gh pr view 1 --json state
gh pr list
gh api repos/o/r/pulls
gh api graphql -f query='{viewer{login}}'
gh run list
CALLER
RLOG="$TMP/run.log"
FAKE_REMAINING=4000 PATH="$BIN:$PATH" bash "$SCRIPT" run --log "$RLOG" -- bash "$TMP/fakecaller.sh" >"$TMP/run.out" 2>&1
rc=$?
n=$(grep -c $'\tfakecaller.sh\t1\t' "$RLOG" 2>/dev/null)
total=$(wc -l <"$RLOG" 2>/dev/null | tr -d ' ')
if [ "$rc" = 0 ] && [ "$n" = 3 ] && [ "$total" = 3 ]; then ok "run attributes 3 GraphQL calls to fakecaller.sh, skips REST"
else bad "run attribution" "rc=$rc fakecaller=$n lines=$total out=$(cat "$TMP/run.out")"; fi

# --- run: floor guard -------------------------------------------------------
RLOG2="$TMP/run2.log"
FAKE_REMAINING=1000 PATH="$BIN:$PATH" bash "$SCRIPT" run --log "$RLOG2" -- bash "$TMP/fakecaller.sh" >"$TMP/run2.out" 2>&1
rc2=$?
if [ "$rc2" = 2 ] && [ ! -s "$RLOG2" ]; then ok "run refuses under the floor and runs nothing"
else bad "floor guard" "rc=$rc2 out=$(cat "$TMP/run2.out")"; fi

# --- argument and setup edges -----------------------------------------------
timeout 5 bash "$SCRIPT" report --log >/dev/null 2>&1
rc_missing=$?
if [ "$rc_missing" = 64 ]; then ok "an option with no value is a usage error, not a hang"
else bad "missing option value" "rc=$rc_missing (124 = hang)"; fi

bash "$SCRIPT" report --log "$LOG" --hours 0 >/dev/null 2>&1
rc_h0=$?
if [ "$rc_h0" = 64 ]; then ok "report rejects --hours 0"
else bad "hours 0" "rc=$rc_h0"; fi

cat >"$TMP/cdcaller.sh" <<'CALLER'
#!/usr/bin/env bash
cd /
gh pr view 1
CALLER
mkdir -p "$TMP/rel"
(cd "$TMP/rel" && FAKE_REMAINING=4000 PATH="$BIN:$PATH" bash "$SCRIPT" run --log relative.log -- bash "$TMP/cdcaller.sh" >/dev/null 2>&1)
if [ "$(grep -c $'\tcdcaller.sh\t1\t' "$TMP/rel/relative.log" 2>/dev/null)" = 1 ]; then ok "run logs a relative --log even when the child changes directory"
else bad "relative log" "$(cat "$TMP/rel/relative.log" 2>&1)"; fi

FAKE_REMAINING=4000 PATH="$BIN:$PATH" bash "$SCRIPT" run --log /proc/nope/x.log -- bash "$TMP/fakecaller.sh" >/dev/null 2>&1
rc_nolog=$?
if [ "$rc_nolog" = 2 ]; then ok "run refuses to start when the log cannot be written"
else bad "unwritable log" "rc=$rc_nolog"; fi

# --- watch: charges a live fleet gh process without a wrapper ---------------
cat >"$TMP/slowcaller.sh" <<'CALLER'
#!/usr/bin/env bash
FAKE_SLEEP=1 gh pr view 5
CALLER
WLOG="$TMP/watch.log"
FAKE_REMAINING=4000 PATH="$BIN:$PATH" bash "$SCRIPT" watch --log "$WLOG" --seconds 4 --interval 0.1 >"$TMP/watch.out" 2>&1 &
wpid=$!
sleep 1
PATH="$BIN:$PATH" bash "$TMP/slowcaller.sh"
wait "$wpid"
nw=$(grep -c $'\tslowcaller.sh\t1\t' "$WLOG" 2>/dev/null)
if [ "$nw" = 1 ]; then ok "watch charges one live gh call to slowcaller.sh"
else bad "watch attribution" "count=$nw log=$(cat "$WLOG" 2>/dev/null) out=$(cat "$TMP/watch.out")"; fi

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ]
