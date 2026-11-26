#!/usr/bin/env bash
# test-trust-slot-sample.sh - fixture suite for trust-slot-sample.sh (slice 2 of the 24-hour trust run, sampler 2).
# The first rows are the plan's control: two free slots, one listed ticket and no attempt row report that
# ticket unfilled (silent); with an attempt-started row it is reported started. Hermetic: the preflight and
# the dispatcher are stubs from fixtures/trust-slot/, the launch record is a fixture file.
#
# PLATFORM GUARD: the chief kit is Linux-only; this Bash 3.2 suite exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/trust-slot-sample.sh"
FIX="$HERE/fixtures/trust-slot"
fails=0
pass() { printf 'PASS - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

NOW=2026-11-26T01:00:00Z
SINCE=2026-11-26T00:45:00Z
run() {
    local refusals="$1"; shift
    PF_ERR="${PF_ERR-$FIX/preflight-ok.err}" PF_OUT="${PF_OUT-$FIX/preflight-ok.out}" DP_OUT="${DP_OUT-$FIX/dispatch-listed.txt}" \
        TRUST_SLOT_PREFLIGHT_CMD="$FIX/preflight-stub.sh" TRUST_SLOT_DISPATCH_CMD="$FIX/dispatch-stub.sh" \
        bash "$SUT" --launch-refusals "$refusals" --now "$NOW" --since "$SINCE" "$@" 2>/dev/null
}
jf() { printf '%s\n' "$1" | jq -c "$2" 2>/dev/null; }

before="$(cd "$FIX" && find . -type f -exec cksum {} + | sort | cksum)"

out="$(run "$FIX/refusals-nofill.jsonl")"; rc=$?
same 'control: two free slots, one listed ticket, no attempt row reports it unfilled' "$(jf "$out" '.silent')" '["FIX-100"]'
same 'control: and it is not reported started' "$(jf "$out" '.started')" '[]'
out2="$(run "$FIX/refusals-started.jsonl")"
same 'control: with an attempt-started row the same ticket is reported started' "$(jf "$out2" '.started')" '["FIX-100"]'
same 'control: and it is no longer unfilled' "$(jf "$out2" '.silent')" '[]'

same 'the run exits 0' "$rc" '0'
same 'one row per sample' "$(printf '%s\n' "$out" | grep -c '^{')" '1'
same 'the row carries cap, live and free as usage-preflight prints them' "$(jf "$out" '[.cap, .live, .free]')" '[50,48,2]'
same 'the row carries the sample time' "$(jf "$out" '.ts')" '"2026-11-26T01:00:00Z"'
same 'a PROCEED preflight is no fleet reason' "$(jf "$out" '.fleet_reason')" 'null'
same 'listed is every ticket the dispatcher lists (an owned ticket is not listed)' "$(jf "$out" '.listed')" '["FIX-100"]'
same 'an attempt-started row of another ticket does not fill the listed one' "$(jf "$out" '.started')" '[]'
same 'an attempt-started row before the window does not count' "$(jf "$out2" '.refused')" '[]'

out3="$(run "$FIX/refusals-refused.jsonl")"
same 'a launch refusal of the listed ticket names ticket and reason' "$(jf "$out3" '.refused')" '[{"key":"FIX-100","reason":"the brief has no Writes line"}]'
same 'a refused listed ticket is not unfilled' "$(jf "$out3" '.silent')" '[]'

out4="$(PF_OUT="$FIX/preflight-hold.out" run "$FIX/refusals-nofill.jsonl")"
same 'a preflight that does not print PROCEED is the fleet reason' "$(jf "$out4" '.fleet_reason')" '"HOLD fleet-paused: the chief paused dispatch"'
same 'a fleet reason is a stated reason for every listed ticket' "$(jf "$out4" '.silent')" '[]'
out5="$(PF_ERR="$FIX/preflight-full.err" run "$FIX/refusals-nofill.jsonl")"
same 'no free slot (50/50) leaves nothing unfilled' "$(jf "$out5" '[.free, .silent]')" '[0,[]]'

u="$(PF_ERR='' PF_OUT='' run "$FIX/refusals-nofill.jsonl")"; urc=$?
same 'a preflight with no FLEET line prints UNKNOWN fleet' "$u" 'UNKNOWN fleet'
same 'a preflight with no FLEET line exits 3' "$urc" '3'
u="$(DP_OUT="$FIX/dispatch-paused.txt" run "$FIX/refusals-nofill.jsonl")"; urc=$?
same 'a paused dispatcher (quota-pause, no rows) prints UNKNOWN dispatcher' "$u" 'UNKNOWN dispatcher'
same 'a paused dispatcher exits 3' "$urc" '3'
u="$(DP_OUT="$FIX/dispatch-unread.txt" run "$FIX/refusals-nofill.jsonl")"; urc=$?
same 'a listing with open PRs unknown prints UNKNOWN dispatcher' "$u" 'UNKNOWN dispatcher'
same 'a listing with open PRs unknown exits 3' "$urc" '3'
u="$(DP_RC=3 run "$FIX/refusals-nofill.jsonl")"; urc=$?
same 'a dispatcher that exits 3 prints UNKNOWN dispatcher' "$u" 'UNKNOWN dispatcher'
same 'a dispatcher that exits 3 exits 3' "$urc" '3'
u="$(run "$FIX/no-such-launch-refusals.jsonl")"; urc=$?
same 'a missing launch record prints UNKNOWN launch-refusals' "$u" 'UNKNOWN launch-refusals'
same 'a missing launch record exits 3' "$urc" '3'

after="$(cd "$FIX" && find . -type f -exec cksum {} + | sort | cksum)"
same 'the sampler writes nothing under its sources' "$after" "$before"

printf '%s\n' "$fails failing row(s)"
[ "$fails" -eq 0 ]
