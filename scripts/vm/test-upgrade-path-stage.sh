#!/usr/bin/env bash
# test-upgrade-path-stage.sh -- hermetic coverage for the VM e2e upgrade-path stage
# scripts/vm/upgrade-path-guest.sh (doctor comparison, input refusal),
# scripts/vm/upgrade-path-e2e.sh (host driver, --expect-red control) and the opt-in
# hook in scripts/test-install-symmetry-vm.sh. No real VM: ssh/rsync are fakes on PATH.
#
# The doctor rows run over scripts/vm/fixtures/test-himmel-doctor-real.txt, a real
# `himmel-doctor.sh --no-color` capture (HOME paths scrubbed, lines cut at 150 cols);
# the "after" variants are mechanical sed transforms of that capture, not hand-written
# output, so a change in doctor's row format breaks this suite loudly.
#
# Usage: bash scripts/vm/test-upgrade-path-stage.sh
# shellcheck disable=SC2016,SC2317,SC2329  # fake-tool bodies are single-quoted on purpose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUEST="$REPO_ROOT/scripts/vm/upgrade-path-guest.sh"
DRIVER="$REPO_ROOT/scripts/vm/upgrade-path-e2e.sh"
SYMM="$REPO_ROOT/scripts/test-install-symmetry-vm.sh"
REAL="$REPO_ROOT/scripts/vm/fixtures/test-himmel-doctor-real.txt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-upgrade-path-stage.XXXXXX")" || exit 1
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

# --- doctor comparison -----------------------------------------------------
# shellcheck source=upgrade-path-guest.sh
. "$GUEST"

if [ -s "$REAL" ] && grep -q '^Summary:' "$REAL"; then pass "real doctor fixture present"; else fail_case "real doctor fixture present"; fi

ALLOW="$DOCTOR_ARTEFACT_ALLOW"
# shellcheck disable=SC2086
doctor_regressions "$REAL" "$REAL" $ALLOW >/dev/null; expect_rc "identical real before/after is clean" 0 $?

# The POC's two harness artefacts: C32 OK -> WARN (the guest tree became a git repo),
# C42 INFO -> WARN (no gh). Derived from the real capture.
sed 's/^OK   C32-main-ref-guard/WARN C32-main-ref-guard/' "$REAL" > "$WORK/after-c32.txt"
sed 's/^WARN C42-sweep-health/INFO C42-sweep-health/' "$REAL" > "$WORK/before-c42.txt"
# shellcheck disable=SC2086
doctor_regressions "$REAL" "$WORK/after-c32.txt" $ALLOW >/dev/null; expect_rc "C32 OK->WARN is allowlisted by name" 0 $?
# shellcheck disable=SC2086
doctor_regressions "$WORK/before-c42.txt" "$REAL" $ALLOW >/dev/null; expect_rc "C42 INFO->WARN is allowlisted by name" 0 $?
OUT="$(doctor_regressions "$REAL" "$WORK/after-c32.txt")"; rc=$?
expect_rc "RED control: C32 OK->WARN with no allowlist regresses" 1 "$rc"
expect_has "regression names the check" "WORSE C32-main-ref-guard OK WARN" "$OUT"

# By NAME, not by count: a different check going worse is a regression even though
# the number of worsened checks equals the allowlisted artefact count.
sed 's/^OK   C20-node/WARN C20-node/' "$REAL" > "$WORK/after-c20.txt"
# shellcheck disable=SC2086
OUT="$(doctor_regressions "$REAL" "$WORK/after-c20.txt" $ALLOW)"; rc=$?
expect_rc "a non-allowlisted check going worse fails" 1 "$rc"
expect_has "...and is named" "WORSE C20-node OK WARN" "$OUT"

# A new FAIL is never allowlisted, even for an allowlisted name.
sed 's/^OK   C32-main-ref-guard/FAIL C32-main-ref-guard/' "$REAL" > "$WORK/after-fail.txt"
# shellcheck disable=SC2086
OUT="$(doctor_regressions "$REAL" "$WORK/after-fail.txt" $ALLOW)"; rc=$?
expect_rc "a new FAIL fails even for an allowlisted name" 1 "$rc"
expect_has "...as NEW-FAIL" "NEW-FAIL C32-main-ref-guard" "$OUT"

# A FAIL present before and after is not a NEW FAIL.
# shellcheck disable=SC2086
doctor_regressions "$WORK/after-fail.txt" "$WORK/after-fail.txt" $ALLOW >/dev/null; expect_rc "a FAIL already present before is not new" 0 $?

# Duplicate rows for one check id (C7-shipped prints several): the worst wins.
printf 'OK   C7-shipped: a\nWARN C7-shipped: b\nINFO C7-shipped: c\n' > "$WORK/dup.txt"
expect_has "worst severity wins across a check's rows" "C7-shipped WARN" "$(doctor_worst "$WORK/dup.txt")"

# A check that printed before and vanishes after is a regression, not a pass.
sed '/^OK   C20-node/d' "$REAL" > "$WORK/after-missing.txt"
# shellcheck disable=SC2086
OUT="$(doctor_regressions "$REAL" "$WORK/after-missing.txt" $ALLOW)"; rc=$?
expect_rc "a check that disappears fails" 1 "$rc"
expect_has "...as MISSING" "MISSING C20-node" "$OUT"

# A capture that is empty or truncated must not read as "no regression".
doctor_valid "$REAL"; expect_rc "real doctor capture is valid" 0 $?
: > "$WORK/empty.txt"
doctor_valid "$WORK/empty.txt"; expect_rc "empty doctor capture is invalid" 1 $?
printf 'bash: scripts/himmel-doctor.sh: No such file or directory\n' > "$WORK/junk.txt"
doctor_valid "$WORK/junk.txt"; expect_rc "non-doctor output is invalid" 1 $?
grep -v '^Summary:' "$REAL" > "$WORK/nosummary.txt"
doctor_valid "$WORK/nosummary.txt"; expect_rc "capture without a Summary line is invalid" 1 $?

# Exact version compare: 0.9.8 is not 0.9.85, and "command not found" is no version.
SV="$(first_semver "graphify 0.9.85")"
if [ "$SV" = "0.9.85" ]; then rc=0; else rc=1; fi; expect_rc "first_semver reads x.y.z" 0 "$rc"
if [ "$SV" = "0.9.8" ]; then rc=0; else rc=1; fi; expect_rc "0.9.85 does not equal 0.9.8" 1 "$rc"
SV="$(first_semver "graphify: command not found")"
if [ -z "$SV" ]; then rc=0; else rc=1; fi; expect_rc "no version in an error line" 0 "$rc"

# A step is green only when the updater command AND its follow-up check both succeeded
# a failed qmd baseline updater or graphify update must not ride on a leftover binary
# or a stale graph.json.
both_ok 0 0; expect_rc "updater rc=0 and check ok passes" 0 $?
both_ok 1 0; expect_rc "RED control: updater rc!=0 with the check ok still fails" 1 $?
both_ok 0 1; expect_rc "updater rc=0 with the check failing fails" 1 $?
both_ok 3 1; expect_rc "updater and check both failing fails" 1 $?

# --- guest input refusal (exit 2 before anything is installed) -----------------
GOOD_SHA="744000a1a4f9ce19f5964774f853d029797b87ef53796d054389258c66cb1224"
run_guest() { # env assignments as args
  env -i PATH="$PATH" HOME="$WORK/home" "$@" bash "$GUEST" "$WORK" >"$WORK/g.out" 2>&1
}
mkdir -p "$WORK/home"
run_guest UPGRADE_GRAPHIFY_VERSION=0.9.85 UPGRADE_CLIPROXY_VERSION=8.0.23 UPGRADE_CLIPROXY_SHA256="$GOOD_SHA"
expect_rc "missing ast-grep target refuses" 2 $?
run_guest UPGRADE_AST_GREP_VERSION=0.50.0 UPGRADE_GRAPHIFY_VERSION=latest UPGRADE_CLIPROXY_VERSION=8.0.23 UPGRADE_CLIPROXY_SHA256="$GOOD_SHA"
expect_rc "non-x.y.z graphify target refuses" 2 $?
run_guest UPGRADE_AST_GREP_VERSION=0.50.0 UPGRADE_GRAPHIFY_VERSION=0.9.85 UPGRADE_CLIPROXY_VERSION=8.0.23 UPGRADE_CLIPROXY_SHA256=abc
expect_rc "malformed cli-proxy sha refuses" 2 $?
# A valid first line must not carry a second one: the value reaches a remote shell.
run_guest UPGRADE_AST_GREP_VERSION=0.50.0 UPGRADE_GRAPHIFY_VERSION=$'0.9.85\n;touch /tmp/x' UPGRADE_CLIPROXY_VERSION=8.0.23 UPGRADE_CLIPROXY_SHA256="$GOOD_SHA"
expect_rc "multiline graphify target refuses" 2 $?

# --- host driver ---------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/hhome"
# ssh fake: records argv; the guest script call prints FAKE_GUEST_OUT and exits
# FAKE_GUEST_RC; every other call (connect probe, rsync probe, scan) succeeds empty.
cat > "$BIN/ssh" <<'EOS'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo ----; } >> "${FAKE_NET_LOG:?}"
[ -t 0 ] || cat >/dev/null
case "$*" in
  *"command -v rsync"*) exit 1 ;;
  *upgrade-path-guest.sh*) printf '%s\n' "${FAKE_GUEST_OUT:-RESULT: 0 failure(s)}"; exit "${FAKE_GUEST_RC:-0}" ;;
esac
exit 0
EOS
chmod +x "$BIN/ssh"
TGT=(UPGRADE_AST_GREP_VERSION=0.50.0 UPGRADE_GRAPHIFY_VERSION=0.9.85 UPGRADE_CLIPROXY_VERSION=8.0.23 "UPGRADE_CLIPROXY_SHA256=$GOOD_SHA")
run_driver() { # <fake-rc> <fake-out> args...
  local frc="$1" fout="$2"; shift 2
  : > "$WORK/net.log"
  env -i PATH="$BIN:$PATH" HOME="$WORK/hhome" FAKE_NET_LOG="$WORK/net.log" FAKE_GUEST_RC="$frc" FAKE_GUEST_OUT="$fout" \
    "${TGT[@]}" bash "$DRIVER" "$@" >"$WORK/driver.out" 2>&1
  DRV_RC=$?
}

run_driver 0 'RESULT: 0 failure(s)' user@localhost 2299 "$WORK/key"
expect_rc "driver passes when the guest stage passes" 0 "$DRV_RC"
expect_has "driver hands the targets to the guest" "UPGRADE_CLIPROXY_VERSION='8.0.23'" "$(cat "$WORK/net.log")"
expect_has "driver hands the real sha to the guest" "UPGRADE_CLIPROXY_SHA256='$GOOD_SHA'" "$(cat "$WORK/net.log")"

run_driver 1 'RESULT: 1 failure(s)' user@localhost 2299 "$WORK/key"
expect_rc "driver fails when the guest stage fails" 1 "$DRV_RC"

# RED control: --expect-red swaps in a bad sha; the stage must fail on a checksum.
run_driver 1 'FAIL  cli-proxy-api is none: checksum mismatch' --expect-red user@localhost 2299 "$WORK/key"
expect_rc "--expect-red passes when the stage fails on the bad pin" 0 "$DRV_RC"
expect_has "--expect-red sends a bad sha, not the real one" "UPGRADE_CLIPROXY_SHA256='0000000000000000000000000000000000000000000000000000000000000000'" "$(cat "$WORK/net.log")"
run_driver 0 'RESULT: 0 failure(s)' --expect-red user@localhost 2299 "$WORK/key"
expect_rc "--expect-red FAILS when a bad pin does not fail the stage" 1 "$DRV_RC"
run_driver 1 'FAIL  something unrelated' --expect-red user@localhost 2299 "$WORK/key"
expect_rc "--expect-red FAILS when the stage failed for another reason" 1 "$DRV_RC"

# Inputs are required and shape-checked before any ssh.
: > "$WORK/net.log"
env -i PATH="$BIN:$PATH" HOME="$WORK/hhome" FAKE_NET_LOG="$WORK/net.log" bash "$DRIVER" user@localhost 2299 "$WORK/key" >/dev/null 2>&1; rc=$?
expect_rc "driver refuses without targets" 2 "$rc"
if [ ! -s "$WORK/net.log" ]; then pass "...before any ssh"; else fail_case "...before any ssh"; fi

# --- opt-in wiring in the symmetry entry point -----------------------------------
if grep -q 'HIMMEL_VM_E2E_UPGRADE' "$SYMM" && grep -q 'upgrade-path-e2e.sh' "$SYMM"; then
  pass "symmetry entry point runs the stage behind HIMMEL_VM_E2E_UPGRADE"
else
  fail_case "symmetry entry point runs the stage behind HIMMEL_VM_E2E_UPGRADE"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILED FAILED"; fi
[ "$FAILED" -eq 0 ]
