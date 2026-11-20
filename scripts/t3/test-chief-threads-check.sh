#!/usr/bin/env bash
# scripts/t3/test-chief-threads-check.sh - fixture suite for chief-threads-check.sh.
set -u
unset HIMMEL_T3_CHIEF_TITLES T3_CHIEF_CHECK_WINDOW_HOURS
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CHK="$HERE/chief-threads-check.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/t3chk-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_rc() { local n="$1" want="$2" rc; shift 2; "$@" >"$T/out" 2>"$T/err"; rc=$?; if [ "$rc" = "$want" ]; then ok "$n"; else bad "$n (rc=$rc)"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2)"; fi; }
expect_in() { if grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
expect_out() { if ! grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (found: $2)"; fi; }

cat > "$T/t3" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "thread list") cat "$STUB_LIST" ;;
  "thread send") echo "$*" >> "$STUB_LOG"; cat >> "$STUB_STDIN" ;;
esac
STUB
chmod +x "$T/t3"

# Timestamps relative to now, in the millisecond form T3 prints (GNU or BSD date).
ago() { date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -v-"$1"H +%Y-%m-%dT%H:%M:%S.123Z; }
H1="$(ago 1)"; H2="$(ago 2)"; H3="$(ago 3)"; H4="$(ago 4)"; H5="$(ago 5)"; H30="$(ago 30)"

cat > "$T/none.json" <<JSON
[{"threadId":"t1","title":"Foo-Chief","status":"idle","settled":false},
 {"threadId":"t2","title":"worker","status":"idle","settled":true,"settledAt":"$H1"},
 {"threadId":"t3x","title":"Manage T3 Code Sync","status":"idle","settled":false}]
JSON
cat > "$T/some.json" <<JSON
[{"threadId":"t1","title":"Foo-Chief","status":"idle","settled":true,"settledAt":"$H1"},
 {"threadId":"t2","title":"worker","status":"idle","settled":true,"settledAt":"$H2"},
 {"threadId":"t3x","title":"Manage T3 Code Sync","status":"idle","settled":true,"settledAt":"$H3"},
 {"threadId":"t4","title":"bar-console","status":"idle","settled":true,"settledAt":"$H4"},
 {"threadId":"t5","title":"chiefly","status":"idle","settled":true,"settledAt":"$H5"},
 {"threadId":"import:claudeAgent:x","title":"old-roadmap-chief","status":"idle","settled":true,"settledAt":"$H1"},
 {"threadId":"t6","title":"stale-chief","status":"idle","settled":true,"settledAt":"$H30"}]
JSON
export T3_SEND_BIN="$T/t3" T3_SEND_PROJECT="$T" STUB_LOG="$T/log" STUB_STDIN="$T/stdin"
export STUB_LIST="$T/none.json"

expect_rc "none settled exits 0" 0 bash "$CHK"
expect_eq "none settled prints nothing" "$(cat "$T/out")" ""

export STUB_LIST="$T/some.json"
expect_rc "settled chief-role exits 1" 1 bash "$CHK"
expect_in "-chief title reported case-insensitively" "^SETTLED t1 Foo-Chief $H1 (report only: not in HIMMEL_T3_CHIEF_TITLES)$" "$T/out"
expect_in "-console title reported" "^SETTLED t4 bar-console " "$T/out"
expect_in "listed title reported without the report-only note" "^SETTLED t3x Manage T3 Code Sync $H3$" "$T/out"
expect_out "plain worker not reported" "SETTLED t2 " "$T/out"
expect_out "suffix-lookalike not reported" "SETTLED t5 " "$T/out"
expect_out "import: id skipped" "SETTLED import:" "$T/out"
expect_out "thread settled outside the window skipped" "SETTLED t6 " "$T/out"
expect_eq "no --wake sends nothing" "$(cat "$T/log" 2>/dev/null)" ""

T3_CHIEF_CHECK_WINDOW_HOURS=48 bash "$CHK" >"$T/out" 2>&1
expect_in "a wider window brings the older thread back" "^SETTLED t6 stale-chief " "$T/out"
T3_CHIEF_CHECK_WINDOW_HOURS=0 bash "$CHK" >"$T/out" 2>&1; rc=$?
expect_eq "a zero window reports nothing (rc 0)" "$rc" 0

HIMMEL_T3_CHIEF_TITLES="worker" bash "$CHK" >"$T/out" 2>&1
expect_in "custom title list replaces the default" "^SETTLED t2 worker $H2$" "$T/out"
expect_out "default title dropped when list is replaced" "SETTLED t3x " "$T/out"

expect_rc "--wake exits 1" 1 bash "$CHK" --wake
expect_in "--wake reports send rc for a listed title" "wake-send rc=0" "$T/out"
expect_in "--wake sent to the listed title" "^thread send t3x -$" "$T/log"
expect_eq "--wake sent to nothing else" "$(grep -c . "$T/log")" 1
expect_in "--wake message body sent" "A chief-role thread was settled" "$T/stdin"
expect_in "suffix-only match still reported under --wake" "^SETTLED t4 bar-console .*report only" "$T/out"

expect_rc "bad flag exits 2" 2 bash "$CHK" --bogus
expect_rc "non-numeric window exits 2" 2 env T3_CHIEF_CHECK_WINDOW_HOURS=x bash "$CHK"

cat > "$T/badts.json" <<JSON
[{"threadId":"t7","title":"bad-chief","status":"idle","settled":true,"settledAt":"not-a-date"}]
JSON
expect_rc "unparseable settledAt exits 2" 2 env STUB_LIST="$T/badts.json" bash "$CHK"

cat > "$T/pr.json" <<JSON
[{"threadId":"p1","title":"Manage T3 Code Sync","settled":false,"pullRequestCount":1,"openPullRequestCount":1},
 {"threadId":"p2","title":"Zero-chief","settled":false,"pullRequestCount":1,"openPullRequestCount":0},
 {"threadId":"p3","title":"worker","settled":false,"pullRequestCount":1,"openPullRequestCount":2},
 {"threadId":"p4","title":"Done-chief","settled":true,"settledAt":"$H1","pullRequestCount":1,"openPullRequestCount":1}]
JSON
export STUB_LIST="$T/pr.json"; : > "$T/log"
expect_rc "open linked PR on an unsettled chief exits 1" 1 bash "$CHK"
expect_in "unsettled listed title with an open PR reported" "^LINKED-PR p1 Manage T3 Code Sync open=1$" "$T/out"
expect_out "zero open PRs gives no line" "p2 " "$T/out"
expect_out "non-chief thread with an open PR gives no line" "p3 " "$T/out"
expect_in "settled chief with an open PR is reported as SETTLED" "^SETTLED p4 Done-chief " "$T/out"
expect_out "settled chief with an open PR is not reported twice" "LINKED-PR p4 " "$T/out"
cat > "$T/pronly.json" <<JSON
[{"threadId":"q1","title":"Manage T3 Code Sync","settled":false,"openPullRequestCount":1}]
JSON
STUB_LIST="$T/pronly.json" bash "$CHK" >"$T/out" 2>&1
expect_out "LINKED-PR-only output has no SETTLED line" "^SETTLED" "$T/out"
expect_rc "--wake with a LINKED-PR case exits 1" 1 bash "$CHK" --wake
expect_eq "--wake sends nothing for LINKED-PR" "$(grep -c 'thread send p1' "$T/log")" 0

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
