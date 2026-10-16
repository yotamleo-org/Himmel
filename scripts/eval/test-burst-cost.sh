#!/usr/bin/env bash
# scripts/eval/test-burst-cost.sh - suite for scripts/eval/burst-cost.sh
# Deterministic rows run against a fake BURST_PROC_ROOT that the "command" advances;
# one live row checks the real /proc sees a 200-fork burst.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/burst-cost.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/burst-cost-test.XXXXXX")" || { echo "test-burst-cost: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

mkdir -p "$TMP/proc/pressure"
printf 'cpu  100 0 100 800 0 0 0 0 0 0\nctxt 1000\nprocesses 5000\n' > "$TMP/proc/stat"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1000000\n' > "$TMP/proc/pressure/cpu"
# The burst: 300 forks, 3000 context switches, 200 busy of 300 cpu ticks, 500 ms stall.
cat > "$TMP/burst.sh" <<EOS
printf 'cpu  200 0 200 900 0 0 0 0 0 0\nctxt 4000\nprocesses 5300\n' > "$TMP/proc/stat"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1500000\n' > "$TMP/proc/pressure/cpu"
EOS

OUT=$(BURST_PROC_ROOT="$TMP/proc" bash "$SCRIPT" --idle 0 -- bash "$TMP/burst.sh" 2>&1); RC=$?
eq "fake proc: exit code" "$RC" "0"
has "fake proc: idle window sees no forks" "$OUT" "| idle | "
IDLE_ROW=$(printf '%s\n' "$OUT" | grep '^| idle ')
BURST_ROW=$(printf '%s\n' "$OUT" | grep '^| burst ')
eq "fake proc: idle forks column" "$(printf '%s' "$IDLE_ROW" | awk -F'|' '{gsub(/ /, "", $4); print $4}')" "0"
eq "fake proc: burst forks column" "$(printf '%s' "$BURST_ROW" | awk -F'|' '{gsub(/ /, "", $4); print $4}')" "300"
eq "fake proc: burst cpu busy %" "$(printf '%s' "$BURST_ROW" | awk -F'|' '{gsub(/ /, "", $7); print $7}')" "66.7"
eq "fake proc: burst PSI stall ms" "$(printf '%s' "$BURST_ROW" | awk -F'|' '{gsub(/ /, "", $8); print $8}')" "500.0"

BURST_PROC_ROOT="$TMP/proc" bash "$SCRIPT" --idle 0 -- false >/dev/null 2>&1; RC=$?
eq "failing command: exit 4" "$RC" "4"

bash "$SCRIPT" >/dev/null 2>&1; RC=$?
eq "no command: usage exit 2" "$RC" "2"
bash "$SCRIPT" --idle abc -- true >/dev/null 2>&1; RC=$?
eq "bad --idle: usage exit 2" "$RC" "2"

# Live: 200 external /bin/true spawns must show at least 200 forks in the burst row.
OUT=$(bash "$SCRIPT" --idle 0 -- bash -c 'for i in $(seq 200); do /bin/true; done' 2>&1)
FORKS=$(printf '%s\n' "$OUT" | grep '^| burst ' | awk -F'|' '{gsub(/ /, "", $4); print $4}')
if [ "${FORKS:-0}" -ge 200 ]; then pass "live /proc: 200-spawn burst counted ($FORKS forks)"; else fail "live /proc: expected >=200 forks, got '$FORKS'"; fi

echo "burst-cost: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
