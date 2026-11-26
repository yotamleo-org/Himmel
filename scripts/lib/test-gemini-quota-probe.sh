#!/usr/bin/env bash
# test-gemini-quota-probe.sh — suite for scripts/lib/gemini-quota-probe.sh.
# Every row drives the probe against a fixture `agy` stub (GEMINI_QUOTA_AGY);
# no live call, no quota spent. SUT is a variable so the same suite runs
# against a missing/old script for RED evidence.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="${GEMINI_PROBE_SUT:-$REPO/scripts/lib/gemini-quota-probe.sh}"
PASS=0; FAIL=0
W="$(mktemp -d -t gemini-quota-probe.XXXXXX)" || { echo "FAIL - mktemp" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
# shellcheck source=scripts/lib/timeout-bin.sh
. "$REPO/scripts/lib/timeout-bin.sh" 2>/dev/null

NOW=1795000000
FUT="2026-11-30T20:10:26Z"; FUT2="2026-12-01T00:00:00Z"
PAST="2026-11-01T00:00:00Z"; EPOCH="1970-01-01T00:00:00Z"

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }
has() { case "$3" in *"$2"*) PASS=$((PASS+1)); echo "ok - $1";; *) FAIL=$((FAIL+1)); echo "FAIL - $1: '$3' lacks '$2'";; esac; }

payload() {
  cat <<EOF
{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"id":"gemini-weekly","window":"weekly","remaining_fraction":$1,"reset_time":"$2"},
  {"id":"gemini-5h","window":"5h","remaining_fraction":$3,"reset_time":"$4"}]},
 {"name":"Claude and GPT models","buckets":[
  {"id":"3p-weekly","window":"weekly","remaining_fraction":0,"reset_time":"$FUT"}]}]}}}
EOF
}
stub_json() { printf '#!/bin/sh\ncat "%s"\n' "$2" > "$W/$1"; chmod +x "$W/$1"; }

probe() {
  local agy="$1"; shift
  OUT="$(GEMINI_QUOTA_FLOOR=0.02 GEMINI_QUOTA_TIMEOUT=20 GEMINI_QUOTA_AGY="$agy" GEMINI_QUOTA_NOW="$NOW" GEMINI_QUOTA_STATE_FILE="$W/state" \
    ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 30} bash "$SUT" "$@" 2>/dev/null)"; RC=$?
}

echo "== 1. empty bucket refuses (RED on base: admitted) =="
payload 0.4 "$FUT" 0 "$FUT2" > "$W/empty5h.json"; stub_json agy-empty5h "$W/empty5h.json"
probe "$W/agy-empty5h"
check "empty 5h bucket, future reset → exit 1" 1 "$RC"
has "empty 5h bucket → GEMINI-EMPTY token" "GEMINI-EMPTY until=2026-12-01T00:00:00Z" "$OUT"
has "per-bucket state line printed" "gemini-5h" "$OUT"
payload 0 "$FUT" 1 "$FUT2" > "$W/emptywk.json"; stub_json agy-emptywk "$W/emptywk.json"
probe "$W/agy-emptywk"
check "empty weekly bucket alone → exit 1" 1 "$RC"
payload 0 "$FUT" 0 "$FUT2" > "$W/emptyboth.json"; stub_json agy-emptyboth "$W/emptyboth.json"
probe "$W/agy-emptyboth"
has "both empty → empty_until is the LATER reset" "until=2026-12-01T00:00:00Z" "$OUT"
payload 0.01 "$FUT" 1 "$FUT2" > "$W/floor.json"; stub_json agy-floor "$W/floor.json"
probe "$W/agy-floor"
check "0.01 is at or under the default 0.02 floor → exit 1" 1 "$RC"

echo "== 2. full bucket admits (control) =="
payload 0.5 "$FUT" 0.99 "$FUT2" > "$W/full.json"; stub_json agy-full "$W/full.json"
probe "$W/agy-full"
check "full buckets → exit 0" 0 "$RC"
has "full buckets → GEMINI-ADMIT" "GEMINI-ADMIT" "$OUT"
check "the Claude and GPT group is ignored when empty" 0 "$RC"

echo "== 3. a reset in the past, or no window running, admits =="
payload 0 "$PAST" 0 "$PAST" > "$W/past.json"; stub_json agy-past "$W/past.json"
probe "$W/agy-past"
check "empty fraction, reset already past → exit 0" 0 "$RC"
payload 0 "$EPOCH" 0 "$EPOCH" > "$W/epoch.json"; stub_json agy-epoch "$W/epoch.json"
probe "$W/agy-epoch"
check "epoch reset (no window running) → exit 0" 0 "$RC"

echo "== 4. probe failure → unknown, non-zero (the caller default refuses) =="
probe "$W/no-such-agy"
check "agy missing → exit 2" 2 "$RC"
has "agy missing → GEMINI-UNKNOWN" "GEMINI-UNKNOWN" "$OUT"
printf 'not json at all' > "$W/garbage.json"; stub_json agy-garbage "$W/garbage.json"
probe "$W/agy-garbage"
check "unreadable JSON → exit 2" 2 "$RC"
printf '{"status":"SUCCESS","command":{"data":{"groups":[]}}}' > "$W/nogroup.json"; stub_json agy-nogroup "$W/nogroup.json"
probe "$W/agy-nogroup"
check "no Gemini group in the payload → exit 2" 2 "$RC"
printf '{"status":"ERROR","command":{"data":{"groups":[]}}}' > "$W/err.json"; stub_json agy-err "$W/err.json"
probe "$W/agy-err"
check "status not SUCCESS → exit 2" 2 "$RC"
printf '{"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"x","remaining_fraction":"high","reset_time":"%s"}]}]}}}' "$FUT" > "$W/badfrac.json"
stub_json agy-badfrac "$W/badfrac.json"
probe "$W/agy-badfrac"
check "non-numeric remaining_fraction → exit 2" 2 "$RC"
printf '#!/bin/sh\necho oops >&2\nexit 2\n' > "$W/agy-rc2"; chmod +x "$W/agy-rc2"
probe "$W/agy-rc2"
check "agy exits non-zero → exit 2" 2 "$RC"
if [ -n "$_TIMEOUT_BIN" ]; then
  printf '#!/bin/sh\nsleep 30\n' > "$W/agy-hang"; chmod +x "$W/agy-hang"
  T0="$(date +%s)"
  OUT="$(GEMINI_QUOTA_TIMEOUT=1 GEMINI_QUOTA_AGY="$W/agy-hang" GEMINI_QUOTA_NOW="$NOW" GEMINI_QUOTA_STATE_FILE="$W/state" \
    "$_TIMEOUT_BIN" 20 bash "$SUT" 2>/dev/null)"; RC=$?
  check "a hung agy is cut off → exit 2" 2 "$RC"
  check "the hang is bounded under 10s" 1 "$([ $(( $(date +%s) - T0 )) -lt 10 ] && echo 1 || echo 0)"
else
  echo "skip - no timeout binary: the bounded-hang rows"
fi

echo "== 5. the output-line backstop =="
rm -f "$W/state"
LINE='⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 3h26m16s.'
probe "$W/agy-full" --record "$LINE"
check "--record of the quota line → exit 0" 0 "$RC"
check "state file holds now + 3h26m16s" "$((NOW + 3*3600 + 26*60 + 16))" "$(cat "$W/state" 2>/dev/null)"
probe "$W/agy-full"
check "a recorded cap marks the group empty although /usage reads full → exit 1" 1 "$RC"
has "backstop empty carries its until" "GEMINI-EMPTY until=" "$OUT"
printf '%s\n' "$((NOW - 5))" > "$W/state"
probe "$W/agy-full"
check "an expired backstop admits again" 0 "$RC"
for case_ in "Resets in 59m51s.|3591" "Resets in 26m47s|1607" "Resets in 1d2h.|93600" "Resets in 45s|45"; do
  want="${case_##*|}"; txt="${case_%|*}"
  rm -f "$W/state"
  probe "$W/agy-full" --record "Individual quota reached. ... $txt"
  check "parse '$txt'" "$((NOW + want))" "$(cat "$W/state" 2>/dev/null)"
done
rm -f "$W/state"
probe "$W/agy-full" --record "all good, nothing to see"
check "a line that is not the quota line → exit 2" 2 "$RC"
check "…and writes no state" "no" "$([ -e "$W/state" ] && echo yes || echo no)"
probe "$W/agy-full" --record "Individual quota reached. Resets in soon"
check "the quota line without a duration → exit 2" 2 "$RC"
printf 'garbage' > "$W/state"
probe "$W/agy-full"
check "a garbled state file is ignored, /usage decides" 0 "$RC"

rm -f "$W/state"
probe "$W/agy-full" --record "Individual quota reached. Resets in 40h"
probe "$W/agy-full" --record "Individual quota reached. Resets in 5m"
check "a shorter later cap does not erase a longer one" "$((NOW + 40*3600))" "$(cat "$W/state" 2>/dev/null)"
rm -f "$W/state"
PIDS=""
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  GEMINI_QUOTA_FLOOR=0.02 GEMINI_QUOTA_AGY="$W/agy-full" GEMINI_QUOTA_NOW="$NOW" GEMINI_QUOTA_STATE_FILE="$W/state" \
    bash "$SUT" --record "Individual quota reached. Resets in ${n}h" >/dev/null 2>&1 &
  PIDS="$PIDS $!"
done
BAD=0
for p in $PIDS; do wait "$p" || BAD=$((BAD + 1)); done
check "every concurrent record exits 0" 0 "$BAD"
check "twelve concurrent records keep the longest deadline" "$((NOW + 12*3600))" "$(cat "$W/state" 2>/dev/null)"
rm -f "$W/state"

echo "== 6. an unreadable reset_time =="
payload 0 "not-a-date" 1 "$FUT2" > "$W/badreset.json"; stub_json agy-badreset "$W/badreset.json"
probe "$W/agy-badreset"
check "empty bucket with an unreadable reset_time → exit 2, not admitted" 2 "$RC"
payload 0.9 "not-a-date" 1 "$FUT2" > "$W/badresetfull.json"; stub_json agy-badresetfull "$W/badresetfull.json"
probe "$W/agy-badresetfull"
check "a full bucket with an unreadable reset_time still admits" 0 "$RC"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
