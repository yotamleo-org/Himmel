#!/usr/bin/env bash
# test-ice-followups.sh — Hermetic tests for ice-followups.sh over a fixture Jira
# mirror (never the operator's own). Today is pinned with ICE_FOLLOWUPS_TODAY.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/ice-followups.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/ice-followups-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

M="$W/HIMMEL"
mkdir -p "$M"
# issue <key> <comments-body>: a mirror file shaped like the real writer's.
issue() {
    printf -- '---\nkey: "%s"\nstatus: "To Do"\n---\n\n# %s: t\n\n## Description\n\nbody HIMMEL-9999 follow-up deferred\n\n## Comments\n%s\n' "$1" "$1" "${2:-}" > "$M/$1.md"
}
cmt() { printf '\n### Op — %s\n\n%s\n' "$1" "$2"; }

issue HIMMEL-9001 "$(cmt 2026-10-10T01:00:00.000+0200 'Moved to ICE-336. Closing.')"
issue HIMMEL-9002 "$(cmt 2026-10-10T01:00:00.000+0200 'Moved to the ICE project (Himmel icebox): parked work. It returns when a version pulls it.')"
issue HIMMEL-9003 "$(cmt 2026-10-10T01:00:00.000+0200 'Moved to LUNA-12. Closing.')"
issue HIMMEL-9004 ""
issue HIMMEL-9005 "$(cmt 2026-09-01T01:00:00.000+0200 'Moved to ICE-400. Closing.')"
issue HIMMEL-9006 "$(cmt 2026-10-10T01:00:00.000+0200 'Moved to ICE-401. Closing.')
$(cmt 2026-10-12T01:00:00.000+0200 'Follow-up: HIMMEL-9006 is parked.')"
issue HIMMEL-9010 "$(cmt 2026-10-12T01:00:00.000+0200 'Follow-up: HIMMEL-9001 deferred.
Deferred: HIMMEL-9003 and HIMMEL-9004 stay open.
HIMMEL-9002 is merely mentioned here.')
$(cmt 2026-10-15T01:00:00.000+0200 'Residual HIMMEL-9002 filed; also follow-up HIMMEL-9001 again.')
$(cmt 2026-09-01T01:00:00.000+0200 'Follow-up HIMMEL-9005 was cited long ago.')"

export ICE_FOLLOWUPS_TODAY=2026-10-19
out="$(bash "$SUT" "$M" 2>&1)"; rc=$?
same 'rc 0 over a readable mirror' "$rc" "0"
same 'count and keys: ICE-moved keys cited as follow-ups in the last 14 days, deduped, sorted' "$out" "ice-followups=2
HIMMEL-9001
HIMMEL-9002"

out="$(bash "$SUT" "$M" --days 60 2>&1)"
same '--days widens the window to include the old citation' "$(printf '%s' "$out" | head -1)" "ice-followups=3"

out="$(bash "$SUT" "$W/no-mirror" 2>&1)"; rc=$?
same 'an unreadable mirror reads ? and still rc 0' "$out/$rc" "ice-followups=?/0"

rm -rf "$M"; mkdir -p "$M"; issue HIMMEL-9004 ""
same 'no ICE citations reads 0 with no keys' "$(bash "$SUT" "$M" 2>&1)" "ice-followups=0"

if [ "$fails" -eq 0 ]; then printf '%s\n' 'PASS - test-ice-followups.sh'; exit 0; fi
printf 'FAIL - test-ice-followups.sh (%s failure(s))\n' "$fails"
exit 1
