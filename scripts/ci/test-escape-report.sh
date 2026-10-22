#!/usr/bin/env bash
# Test for scripts/ci/escape-report.sh.
# A fake gh and a fake jira CLI serve recorded output; the script's own jq/awk
# run for real. Fixtures under test-escape-report-fixtures/ are recorded copies of
# the real services (jira list --labels, gh run list / run view / pr list /
# issue list); the labelled-bug and catch-scenario files are written inline below
# because no real Bug carries a found-by label yet. No gh write verb is ever served.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/escape-report.sh"
REAL="$ROOT/scripts/ci/test-escape-report-fixtures"
TMP="$(mktemp -d "/tmp/himmel-test-escape-report.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
is()  { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want '$2' got '$3'"; fi; }
has() { if grep -qxF -- "$3" "$2"; then ok "$1"; else bad "$1: no line '$3'"; fi; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: read-only verbs only, served from $FX.
echo "$*" >> "$FX/calls"
case "$1 $2" in
  "run list")  cat "$FX/runs.json" ;;
  "run view")  cat "$FX/jobs-$3.json" 2>/dev/null || { echo "fake-gh: no jobs for run $3" >&2; exit 1; } ;;
  "pr list")
    key=""
    while [ $# -gt 0 ]; do [ "$1" = --search ] && { key="${2%% *}"; break; }; shift; done
    cat "$FX/pr-$key.json" 2>/dev/null || echo '[]' ;;
  "issue list") cat "$FX/issues-main-red.json" ;;
  *) echo "fake-gh: unsupported '$1 $2'" >&2; exit 1 ;;
esac
EOF
cat > "$TMP/bin/jira" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FX/jira-calls"
[ "$1" = list ] || { echo "fake-jira: unsupported '$1'" >&2; exit 1; }
cat "$FX/jira.tsv"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/jira"

# scenario <name>: a fixture dir seeded from the recorded copies
scenario() {
  FX="$TMP/$1"; mkdir -p "$FX"
  cp "$REAL"/* "$FX"/
  : > "$FX/calls"; : > "$FX/jira-calls"
}
# run the script in an empty cwd; stdout/stderr to $TMP, rc in $rc
report() {
  mkdir -p "$TMP/cwd"; ( cd "$TMP/cwd" && FX="$FX" PATH="$TMP/bin:$PATH" ESCAPE_JIRA_CMD="$TMP/bin/jira" \
    ESCAPE_REPORT_DATE=2026-10-22 bash "$SCRIPT" "$@" ) > "$TMP/out" 2> "$TMP/err"
  rc=$?
}

# --- usage -----------------------------------------------------------------
scenario s0
report
is "no --since exits 2" 2 "$rc"
report --since not-a-date --out "$TMP/r.md"
is "bad date exits 2" 2 "$rc"

# --- UNLABELLED: recorded real bugs carry no found-by label -----------------
scenario s1
cp "$REAL/jira-bugs.tsv" "$FX/jira.tsv"
report --since 2026-10-15 --out "$TMP/r1.md"
is "report run exits 0" 0 "$rc"
has "all 12 recorded bugs are UNLABELLED" "$TMP/r1.md" "UNLABELLED (12):"
has "recorded bug listed with what it misses" "$TMP/r1.md" "- HIMMEL-7042 (missing: found-by, escape) main red: test-build-tarball.sh hangs to the 600 s runner cap on every CI run, blocking all merges"
if grep -q 'created >= "2026-10-15"' "$FX/jira-calls"; then ok "jira asked for Bugs since the date"; else bad "jira JQL lacks the window"; fi
if grep -q 'issuetype = Bug' "$FX/jira-calls"; then ok "jira JQL filters Bugs"; else bad "jira JQL lacks issuetype = Bug"; fi

# --- grouping by found-by and class -----------------------------------------
scenario s2
printf 'HIMMEL-9001\tBug\tDone\tguard let a thing through\tfound-by:leg,escape:guard,standalone\nHIMMEL-9002\tBug\tTo Do\tflaky thing\tfound-by:ci-main,escape:flake\nHIMMEL-9003\tBug\tTo Do\thalf labelled\tfound-by:operator\n' > "$FX/jira.tsv"
echo '[{"number":9100,"title":"fix(x): [HIMMEL-9001] guard","body":"just prose","mergedAt":"2026-10-20T00:00:00Z","files":[{"path":"docs/x.md"},{"path":"scripts/hooks/guard-x.sh"}]}]' > "$FX/pr-HIMMEL-9001.json"
report --since 2026-10-15 --out "$TMP/r2.md"
has "found-by:leg counted" "$TMP/r2.md" "- found-by:leg: 1"
has "found-by:ci-main counted" "$TMP/r2.md" "- found-by:ci-main: 1"
has "escape:guard counted" "$TMP/r2.md" "- escape:guard: 1"
has "half-labelled bug is UNLABELLED" "$TMP/r2.md" "UNLABELLED (1):"
has "half-labelled bug names the missing label" "$TMP/r2.md" "- HIMMEL-9003 (missing: escape) half labelled"
has "Done escape with no test in the fix is a gap" "$TMP/r2.md" "- HIMMEL-9001: PR #9100, test in fix: no, RED recorded: no, GAP: no test in fix"
has "uncovered class becomes a ticket draft" "$TMP/r2.md" "1. escape:guard (1 escape without a test in the fix: HIMMEL-9001): draft: test(guard): cover escape:guard escapes with a test in the fix"

# --- would CI have caught it: recorded fix PR with a test and a RED line -----
scenario s3
printf 'HIMMEL-6957\tBug\tDone\tfix(hooks): guard-agent-model pins console-judge-ro to opus like console-judge\tstandalone\n' > "$FX/jira.tsv"
report --since 2026-10-01 --out "$TMP/r3.md"
has "recorded fix PR: test changed and RED recorded" "$TMP/r3.md" "- HIMMEL-6957: PR #3472, test in fix: yes, RED recorded: yes"

# --- CI cost from recorded runs ---------------------------------------------
scenario s4
cp "$REAL/jira-bugs.tsv" "$FX/jira.tsv"
report --since 2026-10-15 --out "$TMP/r4.md"
# expected cancelled minutes: independent of the script (jq -> tsv -> awk)
want="$(
  for id in $(jq -r '.[]|select(.conclusion=="cancelled")|.databaseId' "$REAL/runs.json"); do
    jq -r '.jobs[]|select(.conclusion!="skipped" and .startedAt!=null and .completedAt!=null)|[.startedAt,.completedAt]|@tsv' "$REAL/jobs-$id.json"
  done | while IFS=$'\t' read -r a b; do echo "$(date -u -d "$a" +%s) $(date -u -d "$b" +%s)"; done \
    | awk '{ if ($2 > $1) s += $2 - $1 } END { printf "%.1f", s / 60 }'
)"
if [ "$want" != "0.0" ]; then ok "recorded cancelled runs hold real runner time ($want min)"; else bad "fixture has no cancelled runner time"; fi
has "cancelled-run minutes sum" "$TMP/r4.md" "Cancelled-run minutes: $want"
if grep -q '^Runs sampled: 5$' "$TMP/r4.md"; then ok "five recorded runs sampled"; else bad "runs sampled line"; fi
if grep -q '^Queue wait p50 min: ' "$TMP/r4.md"; then ok "queue wait line present"; else bad "queue wait line missing"; fi
if grep -q '^PR wall p50/p90 min: ' "$TMP/r4.md"; then ok "PR wall line present"; else bad "PR wall line missing"; fi
if grep -q 'schedule failure' "$TMP/r4.md"; then ok "scheduled sweep listed with its conclusion"; else bad "scheduled sweep row missing"; fi

# --- CI catches: S2 rule on a synthetic failed-then-fixed branch -------------
scenario s5
printf 'HIMMEL-9001\tBug\tTo Do\tx\tfound-by:leg,escape:guard\n' > "$FX/jira.tsv"
cat > "$FX/runs.json" <<'EOF'
[
 {"databaseId":9001,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T10:00:00Z","startedAt":"2026-10-20T10:00:05Z","updatedAt":"2026-10-20T10:20:00Z","headBranch":"feat/a","headSha":"aaa"},
 {"databaseId":9002,"event":"pull_request","status":"completed","conclusion":"success","createdAt":"2026-10-20T11:00:00Z","startedAt":"2026-10-20T11:00:05Z","updatedAt":"2026-10-20T11:15:00Z","headBranch":"feat/a","headSha":"bbb"},
 {"databaseId":9003,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T12:00:00Z","startedAt":"2026-10-20T12:00:05Z","updatedAt":"2026-10-20T12:10:00Z","headBranch":"feat/b","headSha":"ccc"}
]
EOF
echo '{"jobs":[{"name":"shell-unit-shard (linux, 3)","status":"completed","conclusion":"failure","startedAt":"2026-10-20T10:00:30Z","completedAt":"2026-10-20T10:10:30Z"},{"name":"lint","status":"completed","conclusion":"success","startedAt":"2026-10-20T10:00:30Z","completedAt":"2026-10-20T10:01:30Z"}]}' > "$FX/jobs-9001.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"success","startedAt":"2026-10-20T11:00:30Z","completedAt":"2026-10-20T11:02:30Z"},{"name":"shell-unit-shard (linux, 3)","status":"completed","conclusion":"success","startedAt":"2026-10-20T11:00:30Z","completedAt":"2026-10-20T11:00:30Z"}]}' > "$FX/jobs-9002.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"failure","startedAt":"2026-10-20T12:00:30Z","completedAt":"2026-10-20T12:01:30Z"}]}' > "$FX/jobs-9003.json"
report --since 2026-10-15 --out "$TMP/r5.md"
has "catch counted once for the fixed-by-next-push failure" "$TMP/r5.md" "Catches: 1 (of 2 failed PR runs)"
has "catch grouped by job family" "$TMP/r5.md" "- shell-unit-shard: 1"
has "a failure with no later push is not a catch" "$TMP/r5.md" "Failed without a fixing next push: 1"
# runner-min total: 10 + 1 + 2 + 1 = 14.0 -> catches per 1000 runner-min = 71.4
has "catches per 1000 runner-min" "$TMP/r5.md" "Catches per 1000 runner-min: 71.4"

# --- the script writes only the report file, and only reads from gh/jira ------
scenario s6
cp "$REAL/jira-bugs.tsv" "$FX/jira.tsv"
rm -rf "$TMP/cwd"; mkdir -p "$TMP/cwd" "$TMP/hand"
( cd "$TMP/cwd" && FX="$FX" PATH="$TMP/bin:$PATH" ESCAPE_JIRA_CMD="$TMP/bin/jira" HANDOVER_DIR="$TMP/hand" \
  ESCAPE_REPORT_DATE=2026-10-22 bash "$SCRIPT" --since 2026-10-15 ) > "$TMP/out" 2> "$TMP/err"
is "default --out run exits 0" 0 "$?"
if [ -f "$TMP/hand/reports/ci-escape-weekly-2026-10-22.md" ]; then ok "default report lands in the state reports dir"; else bad "default report path"; fi
is "cwd stays empty" 0 "$(find "$TMP/cwd" -mindepth 1 | wc -l | tr -d ' ')"
is "no stray files beside the report" 1 "$(find "$TMP/hand" -type f | wc -l | tr -d ' ')"
bad_verbs="$(grep -vcE '^(run list|run view|pr list|issue list) ' "$FX/calls" || true)"
is "gh only ever read" 0 "$bad_verbs"

# --- a failing source degrades its section and fails the run ------------------
scenario s7
cp "$REAL/jira-bugs.tsv" "$FX/jira.tsv"
rm "$FX/runs.json"
report --since 2026-10-15 --out "$TMP/r7.md"
is "unreadable gh data exits 3" 3 "$rc"
if grep -q '^UNAVAILABLE: ' "$TMP/r7.md"; then ok "report names the unavailable section"; else bad "no UNAVAILABLE line"; fi

# --- a later push that fails the same job family is not a catch ---------------
scenario s8
printf 'HIMMEL-9001\tBug\tTo Do\tx\tfound-by:leg,escape:guard\n' > "$FX/jira.tsv"
cat > "$FX/runs.json" <<'EOF'
[
 {"databaseId":9101,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T10:00:00Z","startedAt":"2026-10-20T10:00:05Z","updatedAt":"2026-10-20T10:20:00Z","headBranch":"feat/c","headSha":"ccc"},
 {"databaseId":9102,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T11:00:00Z","startedAt":"2026-10-20T11:00:05Z","updatedAt":"2026-10-20T11:15:00Z","headBranch":"feat/c","headSha":"ddd"},
 {"databaseId":9103,"event":"pull_request","status":"completed","conclusion":"success","createdAt":"2026-10-20T12:00:00Z","startedAt":"2026-10-20T12:00:05Z","updatedAt":"2026-10-20T12:10:00Z","headBranch":"feat/c","headSha":"eee"},
 {"databaseId":9104,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T13:00:00Z","startedAt":"2026-10-20T13:00:05Z","updatedAt":"2026-10-20T13:10:00Z","headBranch":"feat/d","headSha":"fff"},
 {"databaseId":9105,"event":"pull_request","status":"in_progress","conclusion":null,"createdAt":"2026-10-20T14:00:00Z","startedAt":"2026-10-20T14:00:05Z","updatedAt":"2026-10-20T14:05:00Z","headBranch":"feat/d","headSha":"ggg"},
 {"databaseId":9106,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T15:00:00Z","startedAt":"2026-10-20T15:00:05Z","updatedAt":"2026-10-20T15:10:00Z","headBranch":"feat/f","headSha":"jjj"},
 {"databaseId":9107,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T16:00:00Z","startedAt":"2026-10-20T16:00:05Z","updatedAt":"2026-10-20T16:10:00Z","headBranch":"feat/f","headSha":"kkk"}
]
EOF
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"failure","startedAt":"2026-10-20T10:00:30Z","completedAt":"2026-10-20T10:01:30Z"}]}' > "$FX/jobs-9101.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"failure","startedAt":"2026-10-20T11:00:30Z","completedAt":"2026-10-20T11:01:30Z"}]}' > "$FX/jobs-9102.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"success","startedAt":"2026-10-20T12:00:30Z","completedAt":"2026-10-20T12:01:30Z"}]}' > "$FX/jobs-9103.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"failure","startedAt":"2026-10-20T13:00:30Z","completedAt":"2026-10-20T13:01:30Z"}]}' > "$FX/jobs-9104.json"
echo '{"jobs":[]}' > "$FX/jobs-9105.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"failure","startedAt":"2026-10-20T15:00:30Z","completedAt":"2026-10-20T15:01:30Z"}]}' > "$FX/jobs-9106.json"
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"skipped","startedAt":"2026-10-20T16:00:30Z","completedAt":"2026-10-20T16:00:30Z"},{"name":"docs","status":"completed","conclusion":"failure","startedAt":"2026-10-20T16:00:30Z","completedAt":"2026-10-20T16:01:30Z"}]}' > "$FX/jobs-9107.json"
report --since 2026-10-15 --out "$TMP/r8.md"
# 9101 is followed by a same-family failure, 9102 by a success, 9104 by a run still going,
# 9106 by a push whose lint job was skipped behind another failure
has "only the push that fixes the failure is credited" "$TMP/r8.md" "Catches: 1 (of 5 failed PR runs)"
has "a run still going or a skipped job is no evidence of a fix" "$TMP/r8.md" "Failed without a fixing next push: 4"

# --- a Jira result at its row cap is flagged, not presented as complete -------
scenario s10
awk 'BEGIN { for (i = 1; i <= 200; i++) printf "HIMMEL-%d\tBug\tTo Do\tbug %d\tfound-by:leg,escape:guard\n", 8000 + i, i }' > "$FX/jira.tsv"
report --since 2026-10-15 --out "$TMP/r10.md"
is "a capped Jira list exits 3" 3 "$rc"
if grep -q '^UNAVAILABLE: the full Bug list' "$TMP/r10.md"; then ok "capped Jira list is flagged as a sample"; else bad "no cap warning"; fi

# --- unreadable job times degrade the cost section and fail the run -----------
scenario s9
printf 'HIMMEL-9001\tBug\tTo Do\tx\tfound-by:leg,escape:guard\n' > "$FX/jira.tsv"
cat > "$FX/runs.json" <<'EOF'
[
 {"databaseId":9201,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-10-20T10:00:00Z","startedAt":"2026-10-20T10:00:05Z","updatedAt":"2026-10-20T10:20:00Z","headBranch":"feat/e","headSha":"hhh"},
 {"databaseId":9202,"event":"pull_request","status":"completed","conclusion":"success","createdAt":"2026-10-20T11:00:00Z","startedAt":"2026-10-20T11:00:05Z","updatedAt":"2026-10-20T11:15:00Z","headBranch":"feat/e","headSha":"iii"}
]
EOF
echo '{"jobs":[{"name":"lint","status":"completed","conclusion":"success","startedAt":"2026-10-20T11:00:30Z","completedAt":"2026-10-20T11:01:30Z"}]}' > "$FX/jobs-9202.json"
report --since 2026-10-15 --out "$TMP/r9.md"
is "unreadable job times exit 3" 3 "$rc"
if grep -q '^UNAVAILABLE: runner time of 1 run' "$TMP/r9.md"; then ok "cost section names the unreadable runs"; else bad "no UNAVAILABLE runner time line"; fi
has "catch rate is n/a with partial runner time" "$TMP/r9.md" "Catches per 1000 runner-min: n/a"

[ "$fails" -eq 0 ] && { echo "all rows passed"; exit 0; }
echo "$fails row(s) failed" >&2
exit 1
