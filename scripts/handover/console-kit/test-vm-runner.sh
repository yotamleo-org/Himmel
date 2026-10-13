#!/usr/bin/env bash
# test-vm-runner.sh — hermetic suite for vm-runner.sh (HIMMEL-5037 phase 2b):
# on / off / status / the tick token / the doctor rows. gh, systemctl,
# journalctl, VBoxManage and the VM lib are stubs; nothing touches a real VM,
# unit or repo variable.
#
# Platform guard (linux-only): the script drives systemd --user and VirtualBox.
# shellcheck disable=SC2015  # `check && ok || bad` is the suite's assertion idiom
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUT="$REPO_ROOT/scripts/handover/console-kit/vm-runner.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-runner.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/gh.argv"
case "$*" in
    *fork-pr-contributor-approval*) echo "${GH_APPROVAL-all_external_contributors}"; [ -n "${GH_APPROVAL-x}" ] ;;
    "variable set"*) a="$*"; echo "${a##* }" > "$STUB/var" ;;
    *actions/variables/HIMMEL_VM_RUNNER*) [ -e "$STUB/var" ] && cat "$STUB/var" || exit 1 ;;
    *actions/runners*) echo "${GH_BUSY:-0}" ;;
esac
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/systemctl.argv"
case "$*" in
    *is-active*) a="$*"; n="${a##*@}"; n="${n%.service}"; [ -e "$STUB/active-$n" ]; exit ;;
    *"--user start"*) [ -z "${STUB_START_FAIL:-}" ] || exit 1; a="$*"; n="${a##*@}"; n="${n%.service}"; : > "$STUB/active-$n" ;;
    *"--user stop"*) a="$*"; n="${a##*@}"; n="${n%.service}"; rm -f "$STUB/active-$n" ;;
esac
exit 0
EOF
cat > "$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in himmel-ci-runner@*) n="${a##*@}"; n="${n%.service}" ;; esac; done
cat "$STUB/journal-$n" 2>/dev/null
exit 0
EOF
cat > "$TMP/bin/VBoxManage" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/vbox.argv"
case "$*" in
    "showvminfo himmel-ci-1 --machinereadable") echo 'VMState="poweroff"'; echo 'localhostReachable="0"' ;;
    "showvminfo himmel-ci-2 --machinereadable") echo 'VMState="running"'; echo "localhostReachable=\"${STUB_REACH:-0}\"" ;;
    "snapshot himmel-ci-1 list --machinereadable") [ -n "${STUB_NO_SNAP:-}" ] || echo 'SnapshotName="ci-runner-v1"' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/systemctl" "$TMP/bin/journalctl" "$TMP/bin/VBoxManage"
cat > "$TMP/vmlib.sh" <<'EOF'
vm_env_init() { :; }
vm_lock_acquire_waiting() { echo "lock $1" >> "$STUB/vm.calls"; }
vm_lock_release() { echo "release $1" >> "$STUB/vm.calls"; }
vm_clone_ensure() { echo "clone $CLONE_NAME from $SOURCE_VM@$1" >> "$STUB/vm.calls"; }
EOF

reset() {
    rm -rf "$TMP/stub" "$TMP/units" "$TMP/state" "$TMP/stop"
    mkdir -p "$TMP/stub" "$TMP/units" "$TMP/state"
}
run() {
    STUB="$TMP/stub" PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
        HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
        HIMMEL_VM_RUNNER_UNIT_DIR="$TMP/units" HIMMEL_VM_RUNNER_STATE_DIR="$TMP/state" \
        HIMMEL_VM_RUNNER_VM_LIB="$TMP/vmlib.sh" VBOXMANAGE_PATH="$TMP/bin/VBoxManage" \
        bash "$SUT" "$@"
}
journal() { # <n> <secs ago> <message>
    printf '%s.000000 host himmel-ci-runner@%s[1]: %s\n' "$(( $(date +%s) - $2 ))" "$1" "$3" >> "$TMP/stub/journal-$1"
}

echo "T1 on refuses a weaker fork-approval policy"
reset
GH_APPROVAL=first_time_contributors run on >"$TMP/out" 2>&1; rc=$?
if [ "$rc" -eq 3 ] && [ ! -e "$TMP/stub/var" ] && [ ! -s "$TMP/stub/systemctl.argv" ]; then
    ok "weaker policy: rc=3, no variable set, no unit started"
else bad "weaker policy: rc=$rc"; fi

echo "T2 on: clones, variable, stop file, two units"
reset
: > "$TMP/stop"
run on >"$TMP/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then ok "on exits 0"; else bad "on rc=$rc: $(cat "$TMP/out")"; fi
[ "$(cat "$TMP/stub/var" 2>/dev/null)" = on ] && ok "variable set on" || bad "variable not on"
[ ! -e "$TMP/stop" ] && ok "stop file removed" || bad "stop file still present"
if [ -e "$TMP/stub/active-1" ] && [ -e "$TMP/stub/active-2" ]; then ok "units 1 and 2 started"; else bad "units not both started"; fi
if grep -q "clone himmel-ci-2 from himmel-ci-1@ci-runner-v1" "$TMP/stub/vm.calls"; then ok "VM 2 cloned from himmel-ci-1@ci-runner-v1"; else bad "clone call: $(cat "$TMP/stub/vm.calls" 2>/dev/null)"; fi
if grep -q "ExecStart=/bin/bash $REPO_ROOT/scripts/vm/ci-runner.sh run" "$TMP/units/himmel-ci-runner@.service" 2>/dev/null; then ok "unit installed with the repo root filled in"; else bad "unit file missing or unsubstituted"; fi

echo "T3 --vms bounds"
reset
run on --vms 3 >"$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$TMP/stub/var" ] && ok "--vms 3 refused (rc=2)" || bad "--vms 3: rc=$rc"
run on --vms 1 >"$TMP/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -e "$TMP/stub/active-1" ] && [ ! -e "$TMP/stub/active-2" ]; then ok "--vms 1 starts one unit"; else bad "--vms 1: rc=$rc"; fi

echo "T4 a unit that will not start switches the runner off again"
reset
STUB_START_FAIL=1 run on >"$TMP/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$TMP/stub/var")" = off ] && [ -e "$TMP/stop" ]; then ok "failed start: variable off, stop file written"; else bad "failed start: rc=$rc var=$(cat "$TMP/stub/var" 2>/dev/null)"; fi

echo "T5 off"
reset
run on >/dev/null 2>&1
run off >"$TMP/out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$TMP/stub/var")" = off ] && [ -e "$TMP/stop" ] && [ ! -e "$TMP/stub/active-1" ] && [ ! -e "$TMP/stub/active-2" ]; then
    ok "off: variable off, stop file written, both units stopped"
else bad "off: rc=$rc"; fi

echo "T6 the tick token"
reset
[ "$(run status --tick)" = off ] && ok "off with no unit installed (no gh call)" || bad "no unit -> $(run status --tick)"
: > "$TMP/units/himmel-ci-runner@.service"
[ "$(run status --tick)" = off ] && ok "off when the variable is off or unset" || bad "unset -> $(run status --tick)"
echo on > "$TMP/stub/var"
[ "$(run status --tick)" = DEAD ] && ok "DEAD: variable on, no unit up" || bad "dead -> $(run status --tick)"
: > "$TMP/stub/active-1"; printf '2\n' > "$TMP/state/vm-runner.vms"
[ "$(run status --tick)" = "ok:1/2,busy=0" ] && ok "ok:1/2,busy=0 with one unit up" || bad "one up -> $(run status --tick)"
rm -f "$TMP/state/tick-vmrun-cache"
GH_BUSY=1 run status --tick | grep -qx 'ok:1/2,busy=1' && ok "busy count from GitHub" || bad "busy -> $(GH_BUSY=1 run status --tick)"
journal 1 7000 "ci-runner: runner 4242 registered on yotamleo/Himmel (himmel-vm); waiting for one job (max 4500s)"
[ "$(run status --tick)" = STUCK ] && ok "STUCK: a job past JOB_MAX+600 with no done line" || bad "stuck -> $(run status --tick)"
journal 1 100 "ci-runner: runner 4242 done (rc=0)"
rm -f "$TMP/state/tick-vmrun-cache"
case "$(run status --tick)" in ok:*) ok "a done line clears STUCK" ;; *) bad "done -> $(run status --tick)" ;; esac

echo "T7 status prints the units and the last error"
reset
: > "$TMP/units/himmel-ci-runner@.service"
echo on > "$TMP/stub/var"; : > "$TMP/stub/active-1"
journal 2 50 "ci-runner: could not mint a JIT runner config for yotamleo/Himmel"
run status >"$TMP/out" 2>&1
if grep -q '^himmel-ci-1: up idle' "$TMP/out" && grep -q '^himmel-ci-2: down last-error: ci-runner: could not mint' "$TMP/out"; then ok "status: per-VM state and last error"; else bad "status: $(cat "$TMP/out")"; fi

echo "T8 doctor rows"
reset
run doctor >"$TMP/out" 2>&1
if ! grep -q '^FAIL' "$TMP/out" && grep -q 'ci-runner-v1 present' "$TMP/out" && grep -q 'all_external_contributors' "$TMP/out"; then ok "healthy: snapshot present, policy ok, no FAIL"; else bad "healthy: $(cat "$TMP/out")"; fi
STUB_NO_SNAP=1 run doctor 2>&1 | grep -q '^FAIL.*no ci-runner-v1 snapshot' && ok "missing snapshot FAILs" || bad "missing snapshot not flagged"
GH_APPROVAL=first_time_contributors run doctor 2>&1 | grep -q '^FAIL.*first_time_contributors' && ok "weaker policy FAILs" || bad "weaker policy not flagged"
STUB_REACH=1 run doctor 2>&1 | grep -q '^FAIL.*loopback reachable' && ok "running VM that reaches the loopback FAILs" || bad "NAT assert not flagged"
echo on > "$TMP/stub/var"; : > "$TMP/units/himmel-ci-runner@.service"
run doctor 2>&1 | grep -q '^FAIL.*runner DEAD' && ok "variable on with no unit FAILs (DEAD)" || bad "DEAD not flagged"

echo "T9 usage"
run bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "unknown subcommand: rc=2" || bad "usage rc=$rc"

echo
echo "vm-runner: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
