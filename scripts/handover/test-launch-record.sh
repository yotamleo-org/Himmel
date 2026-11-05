#!/usr/bin/env bash
# test-launch-record.sh - launch-record.sh writes the line worker_ledger.py reads back.
# Every cache dir and HOME is a temp dir; the real launch-logs is never touched.
# shellcheck disable=SC2016,SC2034  # check takes its condition as a single-quoted string it evals; rc and out are read there
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LR="${LAUNCH_RECORD:-$HERE/launch-record.sh}"
WL="$HERE/../eval/worker-digest"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/launch-record.XXXXXX")" || exit 1; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "  ok   $1"; pass=$((pass+1)); }
no() { echo "  FAIL $1"; fail=$((fail+1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

SID=9163c0de-0000-4000-8000-000000000001
SID2=9163c0de-0000-4000-8000-000000000002
C="$TMP/cache"; mkdir -p "$TMP/home"
# the reader's view of a session: (profile, lane) from the launch record under cache $1 for who $2 (json)
reader() { HIMMELCTL_CACHE_DIR="$1" python3 -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import worker_ledger as w; who = json.loads(sys.argv[2]); print(w.launch_profile(who), w.record_lane(who))' "$WL" "$2" 2>&1; }

echo "1. a headless run: found by its session id"
HOME="$TMP/home" HIMMELCTL_CACHE_DIR="$C" bash "$LR" rm-judge-9163c0de bare native release-manager "$SID" opus; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "the line is the headed-arm-worker format with profile lane model role session session_id launched" 'grep -Eq "^headed-arm-worker: profile=bare lane=native model=opus role=release-manager session=rm-judge-9163c0de session_id=$SID launched=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\$" "$C/launch-logs/rm-judge-9163c0de.log"'
check "the digest reader gets the profile and the lane back by the session id" '[ "$(reader "$C" "{\"session\": \"$SID\"}")" = "bare native" ]'

echo "2. a named run with no session id: found by launch name"
HIMMELCTL_CACHE_DIR="$C" bash "$LR" tg-named telegram native telegram
check "the line carries no session_id" '! grep -q session_id= "$C/launch-logs/tg-named.log"'
check "the reader gets the profile and the lane back by the launch name" '[ "$(reader "$C" "{\"launch_name\": \"tg-named\"}")" = "telegram native" ]'

echo "3. refusals write nothing"
for args in "bad/name bare native x" "ok-name bare api x" "ok-name Bad native x" "ok-name bare native X" "ok-name bare native x not-a-uuid" "ok-name bare native"; do
    # shellcheck disable=SC2086
    HIMMELCTL_CACHE_DIR="$C" bash "$LR" $args >/dev/null 2>&1; rc=$?
    check "refused (rc 2): $args" '[ "$rc" = 2 ]'
done
check "no log was made for a refused call" '[ ! -e "$C/launch-logs/ok-name.log" ] && [ ! -e "$C/launch-logs/bad" ]'

echo "4. best-effort: an unwritable cache warns and exits 0"
touch "$TMP/file-not-dir"
out="$(HIMMELCTL_CACHE_DIR="$TMP/file-not-dir" bash "$LR" w-name bare native x "$SID2" 2>&1)"; rc=$?
check "exit 0" '[ "$rc" = 0 ]'
check "the warning names the lost record" 'printf "%s" "$out" | grep -q "launch record for w-name NOT written"'

echo "5. no HIMMELCTL_CACHE_DIR: the record goes under HOME"
env -u HIMMELCTL_CACHE_DIR HOME="$TMP/home" bash "$LR" home-name bare native x
check "written under HOME/.claude/himmel/launch-logs" '[ -s "$TMP/home/.claude/himmel/launch-logs/home-name.log" ]'

echo "test-launch-record: $pass passed, $fail failed"
[ "$fail" = 0 ]
