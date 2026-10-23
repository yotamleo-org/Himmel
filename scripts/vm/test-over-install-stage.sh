#!/usr/bin/env bash
# test-over-install-stage.sh -- hermetic coverage for the VM e2e over-install stage:
# scripts/vm/over-install-guest.sh (pure helpers, input refusal), scripts/vm/over-install-e2e.sh
# (host driver, --expect-red control) and the opt-in hook in scripts/test-install-symmetry-vm.sh.
# No real VM: ssh and git are fakes on PATH.
#
# The settings rows run over scripts/vm/fixtures/test-over-install-settings-real.json, the
# project .claude/settings.json a real v1.1.2 -> main over-install left on a himmel-ar
# clone (captured through the stage's own OVERINSTALL_DUMP_SETTINGS output, jq-formatted).
# The duplicated-hook variant is a mechanical jq transform of that capture, the same
# one the guest RED control applies, not hand-written JSON.
#
# Usage: bash scripts/vm/test-over-install-stage.sh
# shellcheck disable=SC2016,SC2317,SC2329  # fake-tool bodies are single-quoted on purpose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUEST="$REPO_ROOT/scripts/vm/over-install-guest.sh"
DRIVER="$REPO_ROOT/scripts/vm/over-install-e2e.sh"
SYMM="$REPO_ROOT/scripts/test-install-symmetry-vm.sh"
REAL="$REPO_ROOT/scripts/vm/fixtures/test-over-install-settings-real.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-over-install-stage.XXXXXX")" || exit 1
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

command -v jq >/dev/null 2>&1 || { echo "SKIP jq not installed"; exit 0; }

# --- settings hook helpers -----------------------------------------------------
# shellcheck source=over-install-guest.sh
. "$GUEST"

if jq -e '.hooks | length > 0' "$REAL" >/dev/null 2>&1; then pass "real settings fixture present"; else fail_case "real settings fixture present"; fi

N="$(settings_hook_commands "$REAL" | wc -l)"
if [ "$N" -ge 1 ]; then pass "hook commands are listed from the real capture ($N)"; else fail_case "hook commands are listed from the real capture ($N)"; fi

OUT="$(settings_dup_hooks "$REAL")"
if [ -z "$OUT" ]; then pass "real over-install settings hold every hook once"; else fail_case "real over-install settings hold every hook once ($OUT)"; fi

# RED control: duplicate the first hook entry of the first event, as the guest does.
jq '(.hooks | to_entries[0]) as $e | .hooks[$e.key] += [$e.value[0]]' "$REAL" > "$WORK/dup.json"
OUT="$(settings_dup_hooks "$WORK/dup.json")"
if [ -n "$OUT" ]; then pass "RED control: a duplicated hook entry is detected"; else fail_case "RED control: a duplicated hook entry is detected"; fi
expect_has "...with its count" "2 " "$OUT"

# A hook present on two events is two entries of one command: that is a duplicate too.
jq '.hooks.Extra = [.hooks[][0]]' "$REAL" > "$WORK/dup2.json"
OUT="$(settings_dup_hooks "$WORK/dup2.json")"
if [ -n "$OUT" ]; then pass "a command repeated across events is detected"; else fail_case "a command repeated across events is detected"; fi

# The over-install hook set must equal a fresh install's: a dropped or an extra hook shows up.
OUT="$(settings_hook_set_diff "$REAL" "$REAL")"
if [ -z "$OUT" ]; then pass "identical hook sets have no diff"; else fail_case "identical hook sets have no diff ($OUT)"; fi
if jq '.hooks[(.hooks | keys[0])] |= .[1:]' "$REAL" > "$WORK/drop.json" && [ -s "$WORK/drop.json" ]; then pass "drop fixture built"; else fail_case "drop fixture built"; fi
OUT="$(settings_hook_set_diff "$REAL" "$WORK/drop.json")"
if [ -n "$OUT" ]; then pass "RED control: a dropped hook entry is detected"; else fail_case "RED control: a dropped hook entry is detected"; fi
expect_has "...as an expected-only line" "< " "$OUT"
if jq '(.hooks | keys) as $k | .hooks[$k[1]] += .hooks[$k[0]] | .hooks[$k[0]] = []' "$REAL" > "$WORK/moved.json" && [ -s "$WORK/moved.json" ]; then pass "moved fixture built"; else fail_case "moved fixture built"; fi
OUT="$(settings_hook_set_diff "$REAL" "$WORK/moved.json")"
if [ -n "$OUT" ]; then pass "RED control: a hook moved to another event is detected"; else fail_case "RED control: a hook moved to another event is detected"; fi
expect_has "...with its old registration as an expected-only line" "< " "$OUT"
expect_has "...and its new registration as an actual-only line" "> " "$OUT"
OUT="$(settings_hook_set_diff "$REAL" "$WORK/dup.json")"
expect_has "a duplicated entry shows as an actual-only line" "> " "$OUT"

# --- status summary line -----------------------------------------------------------
if [ "$(status_red_count $'7 green\n0 red, 1 degraded, 7 green, 40 n/a')" = 0 ]; then rc=0; else rc=1; fi
expect_rc "status red count reads 0" 0 "$rc"
if [ "$(status_red_count $'3 red, 1 degraded, 7 green, 40 n/a')" = 3 ]; then rc=0; else rc=1; fi
expect_rc "status red count reads 3" 0 "$rc"
if [ -z "$(status_red_count 'himmelctl: crashed')" ]; then rc=0; else rc=1; fi
expect_rc "a capture with no summary line yields no count (never 'no errors')" 0 "$rc"

# --- guest input refusal (exit 2 before anything is installed) ---------------------
mkdir -p "$WORK/home"
run_guest() { env -i PATH="$PATH" HOME="$WORK/home" "$@" bash "$GUEST" "$WORK/gw" >"$WORK/g.out" 2>&1; }
run_guest OVERINSTALL_CAND_TGZ="$WORK/none.tgz"
expect_rc "missing tarballs refuse" 2 $?
printf x > "$WORK/t.tgz"
run_guest OVERINSTALL_BASE_TGZ="$WORK/t.tgz" OVERINSTALL_CAND_TGZ="$WORK/t.tgz" OVERINSTALL_RED=bogus
expect_rc "an unknown RED control refuses" 2 $?
if [ ! -e "$WORK/gw" ]; then pass "...before anything is written"; else fail_case "...before anything is written"; fi

# --- host driver ---------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/hhome"
# ssh fake: records argv; the guest script call prints FAKE_GUEST_OUT and exits
# FAKE_GUEST_RC; every other call (connect probe, tree staging) succeeds empty.
cat > "$BIN/ssh" <<'EOS'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo ----; } >> "${FAKE_NET_LOG:?}"
[ -t 0 ] || cat >/dev/null
case "$*" in
  *over-install-guest.sh\ *|*"bash /tmp/himmel-over-install-vm/over-install-guest.sh"*) printf '%s\n' "${FAKE_GUEST_OUT:-RESULT: 0 failure(s)}"; exit "${FAKE_GUEST_RC:-0}" ;;
esac
exit 0
EOS
# git fake: a ref resolves unless it is `nope`; `archive` prints a few bytes, not the repo.
cat > "$BIN/git" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse"*nope*) exit 1 ;;
  *"rev-parse"*) exit 0 ;;
  *archive*) printf 'tree-bytes'; exit 0 ;;
esac
exit 0
EOS
chmod +x "$BIN/ssh" "$BIN/git"
run_driver() { # <fake-rc> <fake-out> args...
  local frc="$1" fout="$2"; shift 2
  : > "$WORK/net.log"
  env -i PATH="$BIN:$PATH" HOME="$WORK/hhome" FAKE_NET_LOG="$WORK/net.log" FAKE_GUEST_RC="$frc" FAKE_GUEST_OUT="$fout" \
    bash "$DRIVER" "$@" >"$WORK/driver.out" 2>&1
  DRV_RC=$?
}

run_driver 0 'RESULT: 0 failure(s)' user@localhost 2299 "$WORK/key"
expect_rc "driver passes when the guest stage passes" 0 "$DRV_RC"
expect_has "driver runs the plain stage (no RED control)" "OVERINSTALL_RED=''" "$(cat "$WORK/net.log")"
for up in base.tgz cand.tgz over-install-guest.sh; do
  expect_has "driver uploads $up" "cat > /tmp/himmel-over-install-vm/$up" "$(cat "$WORK/net.log")"
done

# An identity path with a space reaches ssh as one argument.
mkdir -p "$WORK/key dir"
run_driver 0 'RESULT: 0 failure(s)' user@localhost 2299 "$WORK/key dir/id"
expect_rc "driver passes with a space in the identity path" 0 "$DRV_RC"
if grep -qxF "$WORK/key dir/id" "$WORK/net.log"; then pass "...the identity path stays one ssh argument"; else fail_case "...the identity path stays one ssh argument"; fi

run_driver 1 'RESULT: 1 failure(s)' user@localhost 2299 "$WORK/key"
expect_rc "driver fails when the guest stage fails" 1 "$DRV_RC"

# RED control: --expect-red asks the guest to duplicate a hook; the stage must fail on it.
run_driver 1 'FAIL settings hooks appear once each (5 hook commands; duplicated: 2 x)' --expect-red user@localhost 2299 "$WORK/key"
expect_rc "--expect-red passes when the stage fails on the duplicated hook" 0 "$DRV_RC"
expect_has "--expect-red asks the guest for the dup-hook control" "OVERINSTALL_RED='dup-hook'" "$(cat "$WORK/net.log")"
run_driver 0 'RESULT: 0 failure(s)' --expect-red user@localhost 2299 "$WORK/key"
expect_rc "--expect-red FAILS when the duplicate does not fail the stage" 1 "$DRV_RC"
run_driver 1 'FAIL second install is a no-op' --expect-red user@localhost 2299 "$WORK/key"
expect_rc "--expect-red FAILS when the stage failed for another reason" 1 "$DRV_RC"

# Refs are checked before any ssh.
: > "$WORK/net.log"
env -i PATH="$BIN:$PATH" HOME="$WORK/hhome" FAKE_NET_LOG="$WORK/net.log" OVERINSTALL_BASE_REF=nope \
  bash "$DRIVER" user@localhost 2299 "$WORK/key" >/dev/null 2>&1; rc=$?
expect_rc "driver refuses an unresolvable base ref" 2 "$rc"
if [ ! -s "$WORK/net.log" ]; then pass "...before any ssh"; else fail_case "...before any ssh"; fi

# --- opt-in wiring in the symmetry entry point -----------------------------------
# Run the gate block itself against a stub driver: the stage must run only when the symmetry
# pass was green AND the opt-in is set, and its exit status must become the script's.
sed -n '/^if \[ "\$rc" -eq 0 \] && \[ "\${HIMMEL_VM_E2E_OVERINSTALL/,/^fi$/p' "$SYMM" > "$WORK/gate.sh"
mkdir -p "$WORK/fakerepo/scripts/vm"
printf '%s\n' '#!/usr/bin/env bash' 'echo ran >> "$STUB_LOG"' 'exit "${STUB_RC:-0}"' > "$WORK/fakerepo/scripts/vm/over-install-e2e.sh"
run_gate() { # <label> <incoming rc> <opt-in value or -> <stub rc> <want stage ran: 0|1> <want rc>
  : > "$WORK/stub.log"
  local optin=() got_ran got_rc
  [ "$3" = - ] || optin=(HIMMEL_VM_E2E_OVERINSTALL="$3")
  got_rc="$(env -i PATH="$PATH" REPO="$WORK/fakerepo" HOSTSPEC=h PORT=1 IDENT=k STUB_LOG="$WORK/stub.log" STUB_RC="$4" ${optin[@]+"${optin[@]}"} \
    RC0="$2" bash -c 'rc=$RC0; . "$1"; echo "$rc"' _ "$WORK/gate.sh" 2>/dev/null | tail -1)" # read-sink-ok: gate.sh is the file this suite just wrote under its own $WORK
  got_ran="$(wc -l < "$WORK/stub.log" | tr -d ' ')"
  if [ "$got_ran" = "$5" ] && [ "$got_rc" = "$6" ]; then pass "opt-in gate: $1"; else fail_case "opt-in gate: $1 (stage ran $got_ran, want $5; rc $got_rc, want $6)"; fi
}
run_gate "off by default, the stage does not run" 0 - 0 0 0
run_gate "opt-in set but the symmetry pass failed: the stage does not run" 1 1 0 0 1
run_gate "opt-in set after a green pass: the stage runs" 0 1 0 1 0
run_gate "the stage's failure becomes the exit status" 0 1 7 1 7

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILED FAILED"; fi
[ "$FAILED" -eq 0 ]
