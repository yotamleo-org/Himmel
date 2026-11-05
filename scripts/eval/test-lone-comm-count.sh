#!/usr/bin/env bash
# scripts/eval/test-lone-comm-count.sh - hermetic suite for lone-comm-count.py.
# Synthetic session JSONL under a temp dir; no real HOME, no model call. Session s1 holds, in one window:
#   a1 lone append-results bullet (LIVE)          -> batchable bullet (a repeat record of the same id counts once)
#   a2 bullet + Read in one turn (two records)    -> not lone
#   a3 lone SendMessage "READY ..."               -> batchable message
#   a4 lone SendMessage "GO <pr> <sha>"           -> safety (GO)
#   a5 lone SUCCESSION bullet                     -> safety (SUCCESSION)
#   a6 lone Bash ls                               -> not a comm tool
#   a7 lone himmel-bus send                       -> batchable bus
#   a8 lone SendMessage quoting a RETASK token    -> safety (token-quoting)
#   a9 a <synthetic> turn                         -> skipped
#   a10 bullet chained with && pytest             -> not lone;  a12 bullet chained with ;pytest (no spaces) -> not lone
#   a11 lone SendMessage "READY" quoting a token  -> safety (token-quoting)
#   a13 lone bullet whose unquoted text has a # that follows READY and precedes a token -> safety (token-quoting)
# 13 ids minus a9 = 12 turns: 3 batchable (1 bullet, 1 message, 1 bus), 5 safety. Session s2 (record 2020) is out of window.
#  1. per-session TSV row and TOTAL line carry the known counts;  2. class rows keep safety apart;
#  3. the time window and file arguments;  4. no input exits 2.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LC="$HERE/lone-comm-count.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lone-comm-count-test.XXXXXX")" || { echo "test-lone-comm-count: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

T="$(printf '\t')"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
# asst <id> <ts> <content-blocks>: one assistant record
asst() { printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"claude-sonnet-5-5","content":[%s]}}\n' "$2" "$1" "$3"; }
bash_tu() { printf '{"type":"tool_use","id":"tu-%s","name":"Bash","input":{"command":"%s"}}' "$1" "$2"; }
send_tu() { printf '{"type":"tool_use","id":"tu-%s","name":"SendMessage","input":{"to":"chief","message":"%s"}}' "$1" "$2"; }

mkdir "$TMP/win" "$TMP/empty" || exit 1
{
  asst a1 "$NOW" "$(bash_tu a1 'bash /r/append-results.sh /d.md \"LIVE — started\"')"
  asst a1 "$NOW" "$(bash_tu a1 'bash /r/append-results.sh /d.md \"LIVE — started\"')"
  asst a2 "$NOW" "$(bash_tu a2 'bash /r/append-results.sh /d.md \"FINDING — x\"')"
  asst a2 "$NOW" '{"type":"tool_use","id":"tu-a2r","name":"Read","input":{"file_path":"/f"}}'
  asst a3 "$NOW" "$(send_tu a3 'READY 4800 abc GREEN')"
  asst a4 "$NOW" "$(send_tu a4 'GO 4800 abcdef0')"
  asst a5 "$NOW" "$(bash_tu a5 'bash /r/append-results.sh /d.md \"SUCCESSION accepted: B replaces A\"')"
  asst a6 "$NOW" "$(bash_tu a6 'ls /x')"
  asst a7 "$NOW" '{"type":"tool_use","id":"tu-a7","name":"mcp__himmel-bus__send","input":{"to":"chief","b":"BLOCKED — need a ruling"}}'
  asst a8 "$NOW" "$(send_tu a8 'ruling for RE-N4754-60dbba5b: narrow the scope')"
  asst a10 "$NOW" "$(bash_tu a10 'bash /r/append-results.sh /d.md \"LIVE — x\" && pytest -q')"
  asst a12 "$NOW" "$(bash_tu a12 'bash /r/append-results.sh /d.md \"LIVE — y\";pytest -q')"
  asst a13 "$NOW" "$(bash_tu a13 'bash /r/append-results.sh /d.md READY#RE-N4754-60dbba5b')"
  asst a11 "$NOW" "$(send_tu a11 'READY ruling for RE-N4754-60dbba5b: ship it')"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"a9","model":"<synthetic>","content":[]}}\n' "$NOW"
  printf 'not json at all\n'
} >"$TMP/win/s1.jsonl"
asst b1 "2020-01-01T00:00:00.000Z" "$(bash_tu b1 'bash /r/append-results.sh /d.md \"LIVE — old\"')" >"$TMP/win/s2.jsonl"

echo "1. per-session row and total"
python3 "$LC" --dir "$TMP/win" --hours 24 >"$TMP/a.out" 2>"$TMP/a.err"; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "s1 row: 12 turns, 3 batchable (1 bullet, 1 message, 1 bus), 5 safety" 'grep -qxF "s1${T}12${T}3${T}1${T}1${T}1${T}5" "$TMP/a.out"'
check "the out-of-window session prints no row" '! grep -q "^s2" "$TMP/a.out"'
check "TOTAL line" 'grep -qx "TOTAL sessions=1 turns=12 lone_batchable=3 bullet=1 message=1 bus=1 lone_safety=5" "$TMP/a.out"'

echo "2. class rows"
check "GO is a safety class" 'grep -qxF "CLASS${T}GO${T}safety${T}1" "$TMP/a.out"'
check "SUCCESSION is a safety class" 'grep -qxF "CLASS${T}SUCCESSION${T}safety${T}1" "$TMP/a.out"'
check "token-quoting is a safety class" 'grep -qxF "CLASS${T}token-quoting${T}safety${T}3" "$TMP/a.out"'
check "LIVE bullet is batchable" 'grep -qxF "CLASS${T}LIVE${T}batchable${T}1" "$TMP/a.out"'
check "a READY that quotes a token is safety, so READY stays at the one plain message" 'grep -qxF "CLASS${T}READY${T}batchable${T}1" "$TMP/a.out"'
check "a bullet chained with another command is not lone (LIVE stays at the one plain bullet)" 'grep -qxF "CLASS${T}LIVE${T}batchable${T}1" "$TMP/a.out"'
check "a batched bullet (FINDING + Read) is not counted" '! grep -qF "CLASS${T}FINDING${T}" "$TMP/a.out"'
check "a safety row never shows as batchable" '! grep -qE "^CLASS${T}(GO|SUCCESSION|token-quoting)${T}batchable" "$TMP/a.out"'

echo "3. window and file arguments"
python3 "$LC" "$TMP/win/s2.jsonl" >"$TMP/b.out" 2>"$TMP/b.err"; rc=$?
check "a file argument counts every record, no window" '[ "$rc" = 0 ] && grep -qxF "s2${T}1${T}1${T}1${T}0${T}0${T}0" "$TMP/b.out"'
python3 "$LC" --dir "$TMP/win" --hours 400000 >"$TMP/c.out" 2>"$TMP/c.err"; rc=$?
check "a wide window pulls the 2020 session in" '[ "$rc" = 0 ] && grep -q "^s2" "$TMP/c.out" && grep -q "^TOTAL sessions=2 " "$TMP/c.out"'

echo "4. no input"
python3 "$LC" --dir "$TMP/empty" >"$TMP/d.out" 2>"$TMP/d.err"; rc=$?
check "an empty dir exits 2 with a message" '[ "$rc" = 2 ] && grep -q "no session files" "$TMP/d.err"'
python3 "$LC" >"$TMP/e.out" 2>"$TMP/e.err"; rc=$?
check "no argument exits 2" '[ "$rc" = 2 ]'

echo
echo "lone-comm-count: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
