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
bash "$SCRIPT" --idle . -- true >/dev/null 2>&1; RC=$?
eq "--idle '.': usage exit 2" "$RC" "2"
bash "$SCRIPT" --idle 1.2.3 -- true >/dev/null 2>&1; RC=$?
eq "--idle 1.2.3: usage exit 2" "$RC" "2"

# An unreadable /proc/stat stops before the command runs.
BURST_PROC_ROOT="$TMP/nope" bash "$SCRIPT" --idle 0 -- touch "$TMP/ran" >/dev/null 2>&1; RC=$?
eq "missing proc/stat: exit 3" "$RC" "3"
eq "missing proc/stat: command not run" "$([ -e "$TMP/ran" ] && echo ran || echo clean)" "clean"

# guest/guest_nice (fields 10-11) are inside user/nice and must not enter the total:
# 100 user + 100 idle of 200 total = 50 % busy; counting guest 100 would give 33.3.
mkdir -p "$TMP/g/pressure"
printf 'cpu  100 0 0 100 0 0 0 0 100 0\nctxt 1\nprocesses 1\n' > "$TMP/g/stat"
printf 'cpu  200 0 0 200 0 0 0 0 200 0\nctxt 2\nprocesses 2\n' > "$TMP/g.next"
OUT=$(BURST_PROC_ROOT="$TMP/g" bash "$SCRIPT" --idle 0 -- cp "$TMP/g.next" "$TMP/g/stat" 2>&1)
eq "guest cpu not double-counted" "$(printf '%s\n' "$OUT" | grep '^| burst ' | awk -F'|' '{gsub(/ /, "", $7); print $7}')" "50.0"

# Live: 200 external /bin/true spawns must show at least 200 forks in the burst row.
OUT=$(bash "$SCRIPT" --idle 0 -- bash -c 'for i in $(seq 200); do /bin/true; done' 2>&1)
FORKS=$(printf '%s\n' "$OUT" | grep '^| burst ' | awk -F'|' '{gsub(/ /, "", $4); print $4}')
if [ "${FORKS:-0}" -ge 200 ]; then pass "live /proc: 200-spawn burst counted ($FORKS forks)"; else fail "live /proc: expected >=200 forks, got '$FORKS'"; fi

echo "burst-cost: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
