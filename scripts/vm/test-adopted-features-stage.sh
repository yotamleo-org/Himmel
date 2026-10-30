#!/usr/bin/env bash
# test-adopted-features-stage.sh -- hermetic coverage for the VM e2e adopted-features
# stage: scripts/vm/adopted-features-guest.sh (row reporting, guest-only guard, the
# ten row functions) and scripts/vm/adopted-features-e2e.sh (host driver: lock,
# restore, stage, run, restore-after, --expect-red control). No real VM: the vmsdk and
# guest-exec seams are fakes that log their argv.
#
# Usage: bash scripts/vm/test-adopted-features-stage.sh
# shellcheck disable=SC2016,SC2317,SC2329  # fake-tool bodies are single-quoted on purpose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUEST="$REPO_ROOT/scripts/vm/adopted-features-guest.sh"
DRIVER="$REPO_ROOT/scripts/vm/adopted-features-e2e.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-adopted-features-stage.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
expect_rc() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1 (rc=$3)"; else fail_case "$1 (want rc=$2, got rc=$3)"; fi
}
expect_has() { # <label> <needle> <haystack>
  if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail_case "$1 (missing: $2)"; fi
}
expect_lacks() { # <label> <needle> <haystack>
  if grep -qF -- "$2" <<<"$3"; then fail_case "$1 (unexpected: $2)"; else pass "$1"; fi
}

[ -f "$GUEST" ] || { fail_case "guest script exists: $GUEST"; echo "$FAILED FAILED"; exit 1; }
[ -f "$DRIVER" ] || { fail_case "driver exists: $DRIVER"; echo "$FAILED FAILED"; exit 1; }

# --- guest helpers (sourced) -----------------------------------------------------
# shellcheck source=adopted-features-guest.sh
. "$GUEST"

OUT="$(row_report 3 "no force push" PASS "gate refused the force push")"
expect_has "row_report prints ROW <n> <name> <status> <detail>" "ROW 3 PASS no force push: gate refused the force push" "$OUT"

for n in 1 2 3 4 5 6 7 8 9 10; do
  if declare -F "row_$n" >/dev/null; then pass "row_$n is defined"; else fail_case "row_$n is defined"; fi
done

printf 'ROW 1 PASS a: x\nROW 2 FINDING b: y\nROW 3 FAIL c: z\nROW 4 FINDING d: w\n' > "$WORK/rows.txt"
expect_has "tally counts failures and findings" "RESULT: 1 failure(s), 2 finding(s)" "$(rows_tally "$WORK/rows.txt")"
{ printf 'ROW 1 FINDING a: x\n'; for n in 2 3 4 5 6 7 8 9 10; do printf 'ROW %s PASS r: ok\n' "$n"; done; } > "$WORK/rows-ok.txt"
rows_tally "$WORK/rows-ok.txt" >/dev/null; expect_rc "findings alone do not fail the stage" 0 $?
rows_tally "$WORK/rows.txt" >/dev/null; expect_rc "a FAIL row fails the stage" 1 $?
: > "$WORK/rows-empty.txt"
rows_tally "$WORK/rows-empty.txt" >/dev/null; expect_rc "an empty row log fails the stage (no row ran)" 1 $?
printf 'ROW 1 PASS a: x\n' > "$WORK/rows-short.txt"
rows_tally "$WORK/rows-short.txt" >/dev/null; expect_rc "fewer than ten rows fails the stage" 1 $?
{ for n in 1 1 2 3 4 5 6 7 8 9; do printf 'ROW %s PASS r: ok\n' "$n"; done; } > "$WORK/rows-dup.txt"
rows_tally "$WORK/rows-dup.txt" >/dev/null; expect_rc "ten rows with a duplicate id and a missing id fails the stage" 1 $?

# --- guest guard: refuses to adopt anywhere but the VM ----------------------------
env -i PATH="$PATH" HOME="$WORK/home" bash "$GUEST" "$WORK" >"$WORK/g.out" 2>&1; rc=$?
expect_rc "guest refuses without the guest marker" 2 "$rc"
expect_has "...and says why" "HIMMEL_ADOPTED_E2E_GUEST" "$(cat "$WORK/g.out")"

# --- host driver ------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
LOG="$WORK/calls.log"
# vmsdk fake: logs "<vm> <verb> ...", succeeds.
cat > "$BIN/vmsdk" <<'EOS'
#!/usr/bin/env bash
echo "vmsdk $*" >> "${FAKE_LOG:?}"
if [ -n "${FAKE_FAIL_POST_RUN:-}" ] && grep -q 'adopted-features-guest.sh' "$FAKE_LOG"; then exit 1; fi
exit "${FAKE_VMSDK_RC:-0}"
EOS
# guest-exec fake: logs the command; the guest-script call prints FAKE_GUEST_OUT and
# exits FAKE_GUEST_RC; every other call (extract, scan, cleanup) succeeds empty.
cat > "$BIN/guest-exec" <<'EOS'
#!/usr/bin/env bash
echo "gx $*" >> "${FAKE_LOG:?}"
case "$*" in
  *adopted-features-guest.sh*) printf '%s\n' "${FAKE_GUEST_OUT:-}"; exit "${FAKE_GUEST_RC:-0}" ;;
esac
exit 0
EOS
chmod +x "$BIN/vmsdk" "$BIN/guest-exec"
GOOD_OUT="$(printf 'ROW 1 PASS a: x\nROW 2 FINDING b: y\nRESULT: 0 failure(s), 1 finding(s)')"

run_driver() { # <guest-rc> <guest-out> args...
  local grc="$1" gout="$2"; shift 2
  : > "$LOG"
  env -i PATH="$PATH" HOME="$WORK/hhome" FAKE_LOG="$LOG" FAKE_GUEST_RC="$grc" FAKE_GUEST_OUT="$gout" FAKE_FAIL_POST_RUN="${FAKE_FAIL_POST_RUN:-}" \
    HIMMEL_ADOPTED_VMSDK="$BIN/vmsdk" HIMMEL_ADOPTED_GUEST_EXEC="$BIN/guest-exec" \
    HIMMEL_VM_LOCK_DIR="$WORK/locks" HIMMEL_ADOPTED_STAGE_TMP="$WORK/stage" \
    bash "$DRIVER" "$@" >"$WORK/driver.out" 2>&1
  DRV_RC=$?
}
mkdir -p "$WORK/hhome" "$WORK/locks" "$WORK/stage"

run_driver 0 "$GOOD_OUT" himmel-ar-1
expect_rc "driver passes when the guest stage passes (findings are not failures)" 0 "$DRV_RC"
CALLS="$(cat "$LOG")"
expect_has "driver restores the clean snapshot first" "vmsdk himmel-ar-1 restore suite-ready-v4" "$CALLS"
expect_has "driver boots the VM" "vmsdk himmel-ar-1 up" "$CALLS"
expect_has "driver pushes the staged tree through vmsdk" "vmsdk himmel-ar-1 push" "$CALLS"
expect_has "driver runs the guest script through guest-exec" "gx himmel-ar-1" "$CALLS"
expect_has "driver marks the guest as the VM" "HIMMEL_ADOPTED_E2E_GUEST=1" "$CALLS"
expect_has "driver reports the findings" "FINDING" "$(cat "$WORK/driver.out")"
first_restore="$(grep -n 'restore suite-ready-v4' "$LOG" | head -1 | cut -d: -f1)"
last_restore="$(grep -n 'restore suite-ready-v4' "$LOG" | tail -1 | cut -d: -f1)"
run_line="$(grep -n 'adopted-features-guest.sh' "$LOG" | head -1 | cut -d: -f1)"
if [ -n "$first_restore" ] && [ -n "$run_line" ] && [ "$first_restore" -lt "$run_line" ] && [ "$last_restore" -gt "$run_line" ]; then
  pass "restore happens before and after the guest run"
else
  fail_case "restore happens before and after the guest run (first=$first_restore run=$run_line last=$last_restore)"
fi
if [ "$(tail -1 "$LOG")" = "vmsdk himmel-ar-1 down" ]; then pass "the VM is powered off last"; else fail_case "the VM is powered off last ($(tail -1 "$LOG"))"; fi
if [ ! -e "$WORK/locks/himmel-vm-lock-himmel-ar-1" ]; then pass "the vm-lock is released"; else fail_case "the vm-lock is released"; fi

run_driver 1 'ROW 3 FAIL no force push: gate did not refuse' himmel-ar-1
expect_rc "driver fails when the guest stage fails" 1 "$DRV_RC"
expect_has "...and still restores after the failed run" "vmsdk himmel-ar-1 down" "$(cat "$LOG")"
if [ ! -e "$WORK/locks/himmel-vm-lock-himmel-ar-1" ]; then pass "...and still releases the vm-lock"; else fail_case "...and still releases the vm-lock"; fi

run_driver 0 "$GOOD_OUT" 'bad name'
expect_rc "driver refuses an invalid vm name" 2 "$DRV_RC"
if [ ! -s "$LOG" ]; then pass "...before any vmsdk call"; else fail_case "...before any vmsdk call"; fi

run_driver 0 "$GOOD_OUT"
expect_rc "driver refuses a missing vm name" 2 "$DRV_RC"
run_driver 0 "$GOOD_OUT" ubuntu_new
expect_rc "driver refuses the golden image name" 2 "$DRV_RC"
run_driver 0 "$GOOD_OUT" himmel-ar-1x
expect_rc "driver refuses a name that only starts like a clone" 2 "$DRV_RC"
if [ ! -s "$LOG" ]; then pass "...before any vmsdk call"; else fail_case "...before any vmsdk call (golden/lookalike)"; fi

FAKE_FAIL_POST_RUN=1 run_driver 0 "$GOOD_OUT" himmel-ar-1
expect_rc "driver exits 3 when the post-run restore or power-off fails" 3 "$DRV_RC"
if [ ! -e "$WORK/locks/himmel-vm-lock-himmel-ar-1" ]; then pass "...and still releases the vm-lock"; else fail_case "...and still releases the vm-lock (lifecycle failure)"; fi

# A held lock refuses the run and touches no VM.
env -i PATH="$PATH" HOME="$WORK/hhome" HIMMEL_VM_LOCK_DIR="$WORK/locks" \
  bash -c '. "$1/scripts/vm/vm-lock.sh" && vm_lock_acquire_waiting himmel-ar-1 && sleep 60' _ "$REPO_ROOT" >/dev/null 2>&1 &
HOLDER=$!
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -d "$WORK/locks/himmel-vm-lock-himmel-ar-1" ] && break; sleep 0.5; done
run_driver 0 "$GOOD_OUT" himmel-ar-1
expect_rc "driver refuses while the vm-lock is held by another run" 3 "$DRV_RC"
expect_has "...and names the held lock" "is held; refusing" "$(cat "$WORK/driver.out")"
expect_lacks "...and issues no restore" "restore" "$(cat "$LOG")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -rf "$WORK/locks/himmel-vm-lock-himmel-ar-1"

# RED control: --expect-red passes only when the guest FAILS on row 3.
red_out() { # <failing-row>... -- ten rows, the listed ones FAIL, then the RESULT line
  local n k=0 f
  for n in 1 2 3 4 5 6 7 8 9 10; do
    f=PASS; for _r in "$@"; do [ "$_r" = "$n" ] && f=FAIL && k=$((k+1)); done
    if [ "$n" = 3 ] && [ "$f" = FAIL ]; then printf 'ROW 3 FAIL r3: %s\n' "${RED3_MSG:-check-no-force-push.sh was not copied into the project}"
    else printf 'ROW %s %s r%s: x\n' "$n" "$f" "$n"; fi
  done
  printf 'RESULT: %s failure(s), 0 finding(s)\n' "$#"
}
run_driver 1 "$(red_out 3)" --expect-red himmel-ar-1
expect_rc "--expect-red passes when row 3 alone fails and all ten rows ran" 0 "$DRV_RC"
expect_has "--expect-red tells the guest to sabotage row 3" "ADOPTED_E2E_RED=1" "$(cat "$LOG")"
run_driver 0 "$GOOD_OUT" --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when the sabotage did not fail the stage" 1 "$DRV_RC"
run_driver 1 "$(RED3_MSG='the gate was missing before the RED removal' red_out 3)" --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when row 3 failed for a reason other than the gate removal" 1 "$DRV_RC"
run_driver 1 "$(red_out 7)" --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when another row failed instead of row 3" 1 "$DRV_RC"
run_driver 1 "$(red_out 3 7)" --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when another row failed besides row 3" 1 "$DRV_RC"
run_driver 1 'ROW 3 FAIL no force push: the gate did not refuse' --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when the guest died right after row 3 (no ten-row result)" 1 "$DRV_RC"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILED FAILED"; fi
[ "$FAILED" -eq 0 ]
