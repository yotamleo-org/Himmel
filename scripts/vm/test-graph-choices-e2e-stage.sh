#!/usr/bin/env bash
# test-graph-choices-e2e-stage.sh -- hermetic coverage for the VM e2e graph-choices stage:
# scripts/vm/graph-choices-e2e.sh (the pure guest helpers, the guest-only guard, input
# refusal and the host driver: lock, restore, stage, the --guest call, screenshots, the
# --expect-red control). No real VM: the vmsdk and guest-exec seams are fakes that log
# their argv, so the suite passes with no VM, no network and no key.
#
# Usage: bash scripts/vm/test-graph-choices-e2e-stage.sh
# shellcheck disable=SC2016,SC2317,SC2329  # fake-tool bodies are single-quoted on purpose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/graph-choices-e2e.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-graph-choices-e2e-stage.XXXXXX")" || exit 1
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
expect_eq() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then pass "$1"; else fail_case "$1 (want '$2', got '$3')"; fi
}

[ -f "$SCRIPT" ] || { fail_case "graph-choices-e2e.sh exists: $SCRIPT"; echo "$FAILED FAILED"; exit 1; }

# --- guest helpers (sourced: a sourced script defines only its pure helpers) ------
# shellcheck source=graph-choices-e2e.sh
. "$SCRIPT"

# A pass log shaped as the real pass and the runner wrote it (graph-choices-pass.sh words).
cat > "$WORK/pass.log" <<'EOF'
[fired 2026-11-14 04:40:00]
graph-choices-pass: gce-repo no-route every account in the route is out of credit or room
graph-choices-pass: gce-repo ALERT no-route every account in the route is out of credit or room
graph-choices-pass: - something that is not a word line
graph-choices-pass: gce-repo extracted
[exit rc=0]
EOF
expect_eq "words lists the result words in order, never an ALERT or a dash line" "no-route extracted" "$(gce_words "$WORK/pass.log" gce-repo | paste -sd' ' -)"
if gce_word_before "$WORK/pass.log" gce-repo no-route extracted; then pass "no-route comes before extracted"; else fail_case "no-route comes before extracted"; fi
if gce_word_before "$WORK/pass.log" gce-repo extracted no-route; then fail_case "RED control: extracted before no-route is refused"; else pass "RED control: extracted before no-route is refused"; fi
if gce_word_before "$WORK/pass.log" gce-repo no-route key-rejected; then fail_case "a word that never appears is refused"; else pass "a word that never appears is refused"; fi
if gce_word_before "$WORK/pass.log" other no-route extracted; then fail_case "another corpus's words are not read"; else pass "another corpus's words are not read"; fi

printf 'CALL aaaa keyvars=none\nCALL bbbb keyvars=none\nnoise\n' > "$WORK/calls.log"
expect_eq "call count reads the CALL lines" 2 "$(gce_call_count "$WORK/calls.log")"
expect_eq "distinct prompt count: one call per chunk" 2 "$(gce_call_distinct "$WORK/calls.log")"
expect_eq "no call carried a key variable" 0 "$(gce_calls_with_key_var "$WORK/calls.log")"
printf 'CALL aaaa keyvars=none\nCALL aaaa keyvars=none\nCALL cccc keyvars=ANTHROPIC_API_KEY\n' > "$WORK/calls2.log"
expect_eq "RED control: a repeated prompt is counted once" 2 "$(gce_call_distinct "$WORK/calls2.log")"
expect_eq "RED control: a call with a key variable is counted" 1 "$(gce_calls_with_key_var "$WORK/calls2.log")"
expect_eq "no log reads as zero calls" 0 "$(gce_call_count "$WORK/none.log")"

printf '* * * * * /x/run.sh # HIMMEL-GraphChoices\n0 1 * * * /y # HIMMEL-GraphMap\n' > "$WORK/tab"
expect_eq "cron rows named HIMMEL-GraphChoices are counted" 1 "$(gce_cron_rows "$WORK/tab")"
printf '0 1 * * * /y # HIMMEL-GraphMap\n' > "$WORK/tab"
expect_eq "no GraphChoices row reads zero" 0 "$(gce_cron_rows "$WORK/tab")"

# --- guest guard: refuses to run the destructive steps anywhere but the VM --------
env -i PATH="$PATH" HOME="$WORK/home" bash "$SCRIPT" --guest "$WORK" >"$WORK/g.out" 2>&1; rc=$?
expect_rc "--guest refuses without the guest marker" 2 "$rc"
expect_has "...and says why" "HIMMEL_GCE_GUEST" "$(cat "$WORK/g.out")"
if [ ! -e "$WORK/home/.himmel" ]; then pass "...before anything is written"; else fail_case "...before anything is written"; fi

# --- host driver ---------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/hhome" "$WORK/locks" "$WORK/stage"
LOG="$WORK/calls-host.log"
cat > "$BIN/vmsdk" <<'EOS'
#!/usr/bin/env bash
echo "vmsdk $*" >> "${FAKE_LOG:?}"
if [ "$2" = push ] && [ -n "${FAKE_PUSH_COPY:-}" ]; then cp "$3" "$FAKE_PUSH_COPY"; fi
exit "${FAKE_VMSDK_RC:-0}"
EOS
cat > "$BIN/guest-exec" <<'EOS'
#!/usr/bin/env bash
echo "gx $*" >> "${FAKE_LOG:?}"
case "$*" in
  *" --guest"*) printf '%s\n' "${FAKE_GUEST_OUT:-}"; exit "${FAKE_GUEST_RC:-0}" ;;
esac
exit 0
EOS
chmod +x "$BIN/vmsdk" "$BIN/guest-exec"
PNG_B64="$(printf 'not-really-a-png' | base64 | tr -d '\n')"
GOOD_OUT="$(printf 'PASS one\nSHOT settings-light.png %s\nSHOT settings-dark.png %s\nRESULT: 0 failure(s)' "$PNG_B64" "$PNG_B64")"

run_driver() { # <guest-rc> <guest-out> args...
  local grc="$1" gout="$2"; shift 2
  : > "$LOG"
  env -i PATH="$PATH" HOME="$WORK/hhome" FAKE_LOG="$LOG" FAKE_GUEST_RC="$grc" FAKE_GUEST_OUT="$gout" FAKE_PUSH_COPY="$WORK/pushed.tgz" \
    HIMMEL_GCE_VMSDK="$BIN/vmsdk" HIMMEL_GCE_GUEST_EXEC="$BIN/guest-exec" \
    HIMMEL_VM_LOCK_DIR="$WORK/locks" HIMMEL_GCE_STAGE_TMP="$WORK/stage" HIMMEL_GCE_SHOTS_DIR="$WORK/shots" \
    bash "$SCRIPT" "$@" >"$WORK/driver.out" 2>&1
  DRV_RC=$?
}

# usage and exit 2 on bad inputs, before any VM call
for bad in "" "ubuntu_new" "himmel-ar-1;id" "himmel-ar-x" "himmel-ar-1 extra"; do
  : > "$LOG"
  # shellcheck disable=SC2086  # the case with a space is two words on purpose
  env -i PATH="$PATH" HOME="$WORK/hhome" FAKE_LOG="$LOG" HIMMEL_GCE_VMSDK="$BIN/vmsdk" HIMMEL_GCE_GUEST_EXEC="$BIN/guest-exec" \
    bash "$SCRIPT" $bad >"$WORK/bad.out" 2>&1; rc=$?
  expect_rc "bad input '${bad:-<none>}' exits 2" 2 "$rc"
  expect_has "...and prints the usage" "usage: graph-choices-e2e.sh" "$(cat "$WORK/bad.out")"
  if [ ! -s "$LOG" ]; then pass "...before any VM call"; else fail_case "...before any VM call"; fi
done

run_driver 0 "$GOOD_OUT" himmel-ar-1
expect_rc "driver passes when the guest stage passes" 0 "$DRV_RC"
CALLS="$(cat "$LOG")"
expect_has "driver restores the clean snapshot first" "vmsdk himmel-ar-1 restore suite-ready-v4" "$CALLS"
expect_has "driver boots the VM" "vmsdk himmel-ar-1 up" "$CALLS"
expect_has "driver pushes the staged tree through vmsdk" "vmsdk himmel-ar-1 push" "$CALLS"
expect_has "driver runs the guest through guest-exec with the guest flag" "--guest" "$CALLS"
expect_has "driver names the guest marker" "HIMMEL_GCE_GUEST=1" "$CALLS"
expect_has "driver gives the guest a long timeout" "gx himmel-ar-1 --timeout 3000 --" "$CALLS"
expect_has "the staged tree carries the script" "scripts/vm/graph-choices-e2e.sh" "$(tar -tzf "$WORK/pushed.tgz" 2>&1)"
expect_has "the staged tree carries the pass" "scripts/graphify/graph-choices-pass.sh" "$(tar -tzf "$WORK/pushed.tgz" 2>&1)"
first_restore="$(grep -n 'restore suite-ready-v4' "$LOG" | head -1 | cut -d: -f1)"
last_restore="$(grep -n 'restore suite-ready-v4' "$LOG" | tail -1 | cut -d: -f1)"
run_line="$(grep -n -e '--guest' "$LOG" | head -1 | cut -d: -f1)"
if [ -n "$first_restore" ] && [ -n "$run_line" ] && [ "$first_restore" -lt "$run_line" ] && [ "$last_restore" -gt "$run_line" ]; then
  pass "restore happens before and after the guest run"
else
  fail_case "restore happens before and after the guest run (first=$first_restore run=$run_line last=$last_restore)"
fi
if [ "$(tail -1 "$LOG")" = "vmsdk himmel-ar-1 down" ]; then pass "the VM is powered off last"; else fail_case "the VM is powered off last ($(tail -1 "$LOG"))"; fi
if [ ! -e "$WORK/locks/himmel-vm-lock-himmel-ar-1" ]; then pass "the vm-lock is released"; else fail_case "the vm-lock is released"; fi
if [ "$(cat "$WORK/shots/settings-light.png" 2>/dev/null)" = "not-really-a-png" ] && [ "$(cat "$WORK/shots/settings-dark.png" 2>/dev/null)" = "not-really-a-png" ]; then
  pass "the light and dark screenshots are decoded to the shots dir"
else
  fail_case "the light and dark screenshots are decoded to the shots dir"
fi
expect_lacks "the screenshot bytes are not echoed to the console" "$PNG_B64" "$(cat "$WORK/driver.out")"

# a FAIL line gives exit 1
run_driver 1 'FAIL the sentence is printed
RESULT: 1 failure(s)' himmel-ar-1
expect_rc "driver fails when the guest stage fails" 1 "$DRV_RC"
expect_has "...and shows the FAIL line" "FAIL the sentence is printed" "$(cat "$WORK/driver.out")"
if [ "$(tail -1 "$LOG")" = "vmsdk himmel-ar-1 down" ]; then pass "a failed run still powers the VM off"; else fail_case "a failed run still powers the VM off"; fi
# a guest that exits 0 but printed a FAIL line is still a failure
run_driver 0 'FAIL a row failed quietly
RESULT: 1 failure(s)' himmel-ar-1
expect_rc "a FAIL line fails the run even when the guest exits 0" 1 "$DRV_RC"
# a guest that printed no RESULT line proved nothing
run_driver 0 'PASS only a start' himmel-ar-1
expect_rc "a run with no RESULT line fails" 1 "$DRV_RC"
# a lifecycle failure is exit 3
: > "$LOG"
env -i PATH="$PATH" HOME="$WORK/hhome" FAKE_LOG="$LOG" FAKE_VMSDK_RC=1 HIMMEL_GCE_VMSDK="$BIN/vmsdk" HIMMEL_GCE_GUEST_EXEC="$BIN/guest-exec" \
  HIMMEL_VM_LOCK_DIR="$WORK/locks" HIMMEL_GCE_STAGE_TMP="$WORK/stage" bash "$SCRIPT" himmel-ar-1 >"$WORK/driver.out" 2>&1; rc=$?
expect_rc "a VM that will not restore exits 3" 3 "$rc"
if ! grep -qe '--guest' "$LOG"; then pass "...and the guest never ran"; else fail_case "...and the guest never ran"; fi

# RED control: --expect-red stages a tree with no S4 pass; the first guest assertion must fail on it
run_driver 1 'FAIL graph-choices-pass.sh is in the tree (S4 present)
RESULT: 1 failure(s)' --expect-red himmel-ar-1
expect_rc "--expect-red passes when the stage fails on its first assertion" 0 "$DRV_RC"
expect_lacks "--expect-red stages a tree without the pass" "scripts/graphify/graph-choices-pass.sh" "$(tar -tzf "$WORK/pushed.tgz" 2>&1)"
expect_has "--expect-red tells the guest" "HIMMEL_GCE_RED=1" "$(cat "$LOG")"
run_driver 0 'RESULT: 0 failure(s)' --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when the stage passes without the pass" 1 "$DRV_RC"
run_driver 1 'PASS graph-choices-pass.sh is in the tree (S4 present)
FAIL the sentence is printed
RESULT: 1 failure(s)' --expect-red himmel-ar-1
expect_rc "--expect-red FAILS when the first assertion passed and a later one failed" 1 "$DRV_RC"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILED FAILED"; fi
[ "$FAILED" -eq 0 ]
