#!/usr/bin/env bash
# test-budget-nudge.sh — Exercises budget-nudge.sh: one token-free bus nudge to each live
# worker of a fleet manifest, none to a WRAPPED or lockless row, fail-soft per worker.
# The bus CLI and the process census are stubbed (BUDGET_NUDGE_BUS / BUDGET_NUDGE_CENSUS).
# bash 3.2-safe.
#
# BUDGET_NUDGE overrides the script under test (the RED control).
#
# Run: bash scripts/handover/chief-kit/test-budget-nudge.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BN="${BUDGET_NUDGE:-$HERE/budget-nudge.sh}"

fails=0
check() {
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/budget-nudge-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

L1="$WORK/DEMO-1-N1-alpha-2026-11-24.md"
L2="$WORK/DEMO-2-N2-beta-2026-11-24.md"
L3="$WORK/DEMO-3-N3-wrapped-2026-11-24.md"
L4="$WORK/DEMO-4-P01-watched-2026-11-24.md"
L5="$WORK/DEMO-5-N5-codex-2026-11-24.md"
L6="$WORK/DEMO-6-N6-gone-2026-11-24.md"
for f in "$L1" "$L2" "$L4" "$L5" "$L6"; do printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n' > "$f"; done
printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n- 10:30 WRAPPED - done\n' > "$L3"
MANIFEST="$WORK/DEMO-nextleg-2026-11-24A-chief.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1","lane":"native"},{"doc":"%s","label":"N2","lane":"native"},{"doc":"%s","label":"N3","lane":"native"},{"doc":"%s","label":"P01","lane":"native","lockless":true},{"doc":"%s","label":"N5","lane":"claudex"},{"doc":"%s","label":"N6","lane":"native"}]}\n' \
    "$L1" "$L2" "$L3" "$L4" "$L5" "$L6" > "$MANIFEST"

printf '#!/usr/bin/env bash\ncat "%s/census.txt"\n' "$WORK" > "$WORK/census.sh"
: > "$WORK/census.txt"
for n in DEMO-1-N1-alpha-2026-11-24 DEMO-2-N2-beta-2026-11-24 DEMO-3-N3-wrapped-2026-11-24 DEMO-4-P01-watched-2026-11-24; do
    printf '100\t%s\topus\t200000\n' "$n" >> "$WORK/census.txt"
done
export BUDGET_NUDGE_CENSUS="$WORK/census.sh"
# shellcheck disable=SC2016  # $1-$3 expand in the stub, not here; read-sink-ok: $3 is the body file budget-nudge.sh mktemps
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1 $2" >> "%s/bus.log"; cat "$3" >> "%s/bus.body"\ncase "$2" in *-N2-*) echo "store unreachable" >&2; exit 1 ;; esac\n' "$WORK" "$WORK" > "$WORK/bus.sh"
chmod +x "$WORK/bus.sh"
export BUDGET_NUDGE_BUS="$WORK/bus.sh"
export HIMMEL_BUS_NAME=DEMO-nextleg-2026-11-24A-chief

rc=0
out="$(bash "$BN" "$MANIFEST" 2>&1)" || rc=$?
check "the nudge exits 0 with a failed worker" "0" "$rc"
check "the live native worker gets one record" "1" "$(grep -cx 'send DEMO-1-N1-alpha-2026-11-24' "$WORK/bus.log" 2>/dev/null)"
check "the claudex worker gets one record under its doc stem" "1" "$(grep -cx 'send DEMO-5-N5-codex-2026-11-24' "$WORK/bus.log" 2>/dev/null)"
check "the failing worker is tried once" "1" "$(grep -cx 'send DEMO-2-N2-beta-2026-11-24' "$WORK/bus.log" 2>/dev/null)"
check "a WRAPPED worker gets no record" "0" "$(grep -c 'N3' "$WORK/bus.log" 2>/dev/null)"
check "a lockless row gets no record" "0" "$(grep -c 'P01' "$WORK/bus.log" 2>/dev/null)"
check "exactly three records are sent in all" "3" "$(grep -c . "$WORK/bus.log" 2>/dev/null)"
check "the delivered sends are reported" "BUS-NUDGE N1 ok|BUS-NUDGE N5 ok" "$(printf '%s\n' "$out" | grep -E '^BUS-NUDGE N[15] ok$' | paste -sd'|' -)"
check "the failed send is reported with its reason" "BUS-NUDGE-FAIL N2 (store unreachable)" "$(printf '%s\n' "$out" | grep '^BUS-NUDGE-FAIL N2')"
check "a worker with no live session is UNRESOLVED, nothing sent" "1" "$(printf '%s\n' "$out" | grep -c '^UNRESOLVED N6 ')"
check "the summary counts n delivered of m live" "NUDGED 2 of 4" "$(printf '%s\n' "$out" | tail -n 1)"
check "the record says the budget is back" "3" "$(grep -c 'weekly budget is back' "$WORK/bus.body")"
check "the record says scope, token and chief are unchanged" "3" "$(grep -c 'scope, token and chief are unchanged' "$WORK/bus.body")"
check "the record carries no backticked token" "0" "$(grep -c '`' "$WORK/bus.body")"

rm -f "$WORK/bus.log"
out2="$(HIMMEL_BUS_NAME='' bash "$BN" "$MANIFEST" 2>&1)"; rc2=$?
check "no bus identity still exits 0" "0" "$rc2"
check "no bus identity sends nothing" "absent" "$([ -e "$WORK/bus.log" ] && echo present || echo absent)"
check "no bus identity reports each resolved worker" "3" "$(printf '%s\n' "$out2" | grep -c '^BUS-NUDGE-FAIL N[125] (no bus identity)$')"

rc3=0; bash "$BN" "$WORK/none.fleet.json" >/dev/null 2>&1 || rc3=$?
check "a missing manifest exits 2" "2" "$rc3"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
