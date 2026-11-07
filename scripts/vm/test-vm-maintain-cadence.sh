#!/usr/bin/env bash
# Platform guard (linux-only): the cadence drives the Linux station's VirtualBox flow and cron.
# shellcheck disable=SC2016  # the bash -c check bodies are single-quoted on purpose: they read their own $1..$3
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/vm-maintain-cadence.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-maintain-cadence.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/calls.log"

FAILED=0
CASES=0
check() { local label="$1"; shift; CASES=$((CASES + 1)); if "$@"; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED + 1)); fi; }
control() { local label="$1"; shift; CASES=$((CASES + 1)); if "$@"; then echo "FAIL $label (the check passed on a broken run)"; FAILED=$((FAILED + 1)); else echo "PASS $label"; fi; }

[ -f "$SCRIPT" ] || { echo "FAIL $SCRIPT not found"; echo "RESULT: 0 passed, 1 failed"; exit 1; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/vmm" <<'STUB'
#!/usr/bin/env bash
echo "vmm begin $*" >> "$LOG"
mode="$1"; vm="$2"
rc=0
if [ "$mode" = run ]; then
    if [ "${FAIL_RUN_VM:-}" = "$vm" ]; then echo "vm-maintain: FAILED apt-upgrade ($vm) - guest command rc=100: E: boom"; rc=1
    elif [ "${BUSY_VM:-}" = "$vm" ]; then echo "vm-maintain: FAILED lock ($vm) - the vm-lock was refused, see the line above"; rc=2
    else echo "vm-maintain: OK $vm updated (claude 1, cli-proxy 2) and snapshotted as maint-20261107-1432; newest good recorded"; fi
else
    if [ "${CRASH_PROBE_VM:-}" = "$vm" ]; then echo "bash: line 1: $0: No such file or directory"; echo "vmm end $*" >> "$LOG"; exit 127; fi
    if [ "${EXPIRED_VM:-}" = "$vm" ]; then
        echo "vm-maintain: $vm claude login EXPIRED (refresh token past its expiry) - operator: on $vm run: claude auth login  (then re-run vm-maintain.sh run $vm)"; rc=1
    fi
fi
echo "vmm end $*" >> "$LOG"
exit "$rc"
STUB
cat > "$WORK/bin/update" <<'STUB'
#!/usr/bin/env bash
echo "update $*" >> "$LOG"
[ -z "${FAIL_UPDATE:-}" ] || { echo "update: pull failed"; exit 1; }
exit 0
STUB
cat > "$WORK/bin/census" <<'STUB'
#!/usr/bin/env bash
[ -z "${CENSUS_FAIL:-}" ] || { echo "census broke" >&2; exit 2; }
[ -z "${STUB_LIVE:-}" ] || printf '%s\n' "$STUB_LIVE"
exit 0
STUB
cat > "$WORK/bin/sender" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$SENT"
exit 0
STUB
cat > "$WORK/bin/crontab" <<'STUB'
#!/usr/bin/env bash
f="$CRON_FILE"
case "${1:-}" in
    -l) [ -s "$f" ] || { echo "no crontab for test" >&2; exit 1; }; cat "$f" ;;
    -) cat > "$f" ;;
esac
STUB
chmod +x "$WORK"/bin/*

fresh() {
    rm -rf "${WORK:?}/state" "${WORK:?}/alerts" "${WORK:?}/runner" "${WORK:?}/home"; mkdir -p "$WORK/state" "$WORK/alerts" "$WORK/runner" "$WORK/home/.himmel/state"
    : > "$LOG"; : > "$WORK/sent"; : > "$WORK/cron"
}
cadence() {
    local envs=()
    while [ $# -gt 0 ]; do case "$1" in *=*) envs+=("$1"); shift ;; *) break ;; esac; done
    env LOG="$LOG" SENT="$WORK/sent" CRON_FILE="$WORK/cron" HOME="$WORK/home" HIMMEL_CRONTAB_LOCK="$WORK/crontab.lock" \
        VMCAD_VM_MAINTAIN="$WORK/bin/vmm" VMCAD_UPDATE_CMD="$WORK/bin/update" VMCAD_LIVE_WORKERS_CMD="$WORK/bin/census" \
        VMCAD_STATE_DIR="$WORK/state" VMCAD_CRONTAB="$WORK/bin/crontab" VMCAD_RUNNER_DIR="$WORK/runner" \
        CADENCE_ALERT_FILE="$WORK/alerts/log" CADENCE_ALERT_DEDUPE_DIR="$WORK/alerts/sent" \
        CADENCE_ALERT_SEND_CMD="$WORK/bin/sender" CADENCE_ALERT_SEND_FAILED_MARK="$WORK/alerts/mark" \
        "${envs[@]}" bash "$SCRIPT" "$@"
}

line_of() { grep -n -m1 -F -e "$1" "$LOG" | cut -d: -f1; }
in_order() { local prev=0 n f; for f in "$@"; do n=$(line_of "$f"); [ -n "$n" ] && [ "$n" -gt "$prev" ] || { echo "  order: '$f' (line ${n:-none}) not after line $prev" >&2; return 1; }; prev=$n; done; }
logged() { grep -qF -e "$1" "$LOG"; }
not_logged() { ! grep -qF -e "$1" "$LOG"; }
out_has() { grep -qF -e "$1" <<<"$out"; }
out_lacks() { ! grep -qF -e "$1" <<<"$out"; }
sent_count() { [ "$(wc -l < "$WORK/sent" | tr -d ' ')" -eq "$1" ]; }
count_in_out() { [ "$(grep -cF -e "$1" <<<"$out")" -eq "$2" ]; }

echo "== pass =="
pass_ok_check() {
    [ "$rc" -eq 0 ] \
      && in_order "vmm begin run vmA" "vmm end run vmA" "vmm begin probe vmA" "vmm end probe vmA" "vmm begin run vmB" "vmm end run vmB" "vmm begin probe vmB" "vmm end probe vmB" "update" \
      && not_logged "--no-secret-scan" && out_has "snapshotted as maint-20261107-1432"
}
fresh; out=$(cadence run --vms vmA,vmB 2>&1); rc=$?
check "C1 one pass runs vm-maintain then the probe on each VM in turn, then updates the station, never with --no-secret-scan" pass_ok_check
check "C1b a clean pass pages nobody" sent_count 0
fresh; out=$(cadence FAIL_RUN_VM=vmA run --vms vmA,vmB 2>&1); rc=$?
control "C1-RED the pass check fails when a VM run fails" pass_ok_check

echo "== named failure =="
stopped_check() {
    [ "$rc" -eq 1 ] && out_has "CADENCE FAILED vm-maintain vmA" && out_has "apt-upgrade" \
      && not_logged "vmm begin run vmB" && not_logged "update" && sent_count 1
}
fresh; out=$(cadence FAIL_RUN_VM=vmA run --vms vmA,vmB 2>&1); rc=$?
check "C2 a failed VM update stops the pass with CADENCE FAILED vm-maintain <vm> <step>, no later VM, no station update, one page" stopped_check
fresh; out=$(cadence run --vms vmA,vmB 2>&1); rc=$?
control "C2-RED the stopped check fails on a clean pass" stopped_check
fresh; out=$(cadence FAIL_RUN_VM=vmA run --vms vmA 2>&1); out=$(cadence FAIL_RUN_VM=vmA run --vms vmA 2>&1); rc=$?
check "C2b the same failure on the next pass does not page again" sent_count 1
fresh; out=$(cadence FAIL_RUN_VM=vmA run --vms vmA 2>&1); out=$(cadence run --vms vmA 2>&1); rc=$?
out=$(cadence FAIL_RUN_VM=vmA run --vms vmA 2>&1); rc=$?
check "C2c a pass that completes re-arms the page, so a later failure pages again" sent_count 2
fresh; out=$(cadence FAIL_UPDATE=1 run --vms vmA 2>&1); rc=$?
check "C3 a failed station update is CADENCE FAILED station-update, rc 1, one page" bash -c '[ "$1" -eq 1 ] && grep -qF "CADENCE FAILED station-update" <<<"$2" && [ "$(wc -l < "$3" | tr -d " ")" -eq 1 ]' _ "$rc" "$out" "$WORK/sent"
fresh; out=$(cadence BUSY_VM=vmA run --vms vmA,vmB 2>&1); rc=$?
check "C4 a VM another leg holds is skipped with a line, not failed: the next VM and the station update still run" bash -c '[ "$1" -eq 0 ] && grep -qF "SKIPPED vmA" <<<"$2"' _ "$rc" "$out"
check "C4b the skipped VM is not probed, the next VM is run" bash -c 'grep -qF "vmm begin run vmB" "$1" && ! grep -qF "vmm begin probe vmA" "$1"' _ "$LOG"

echo "== login report =="
fresh; out=$(cadence EXPIRED_VM=vmA run --vms vmA 2>&1); rc=$?
check "L1 an expired login is reported once with its exact command" count_in_out "claude auth login" 1
check "L1b an expired login does not fail the pass or stop the station update" bash -c '[ "$1" -eq 0 ] && grep -qF update "$2"' _ "$rc" "$LOG"
fresh; out=$(cadence run --vms vmA 2>&1); rc=$?
check "L2 live logins are silent: no EXPIRED line" out_lacks "EXPIRED"
fresh; out=$(cadence CRASH_PROBE_VM=vmA run --vms vmA 2>&1); rc=$?
check "L3 a probe that crashes (rc 127, no FAILED line) is a named failure, never read as an expired login" bash -c '[ "$1" -eq 1 ] && grep -qF "CADENCE FAILED vm-maintain vmA" <<<"$2" && ! grep -qF update "$3"' _ "$rc" "$out" "$LOG"

echo "== live workers =="
fresh; out=$(cadence STUB_LIVE="slug=x__himmel__HIMMEL-1-N1-foo session=s host=h age=10s status=OK" run --vms vmA 2>&1); rc=$?
defer_check() { [ "$rc" -eq 0 ] && not_logged "update" && out_has "DEFERRED station-update" && logged "vmm begin run vmA"; }
check "W1 a live worker defers the station update with a logged line, the VM run still happens, rc 0" defer_check
fresh; out=$(cadence run --vms vmA 2>&1); rc=$?
control "W1-RED the defer check fails when no worker is live" defer_check
fresh; out=$(cadence STUB_LIVE="slug=x__himmel__HIMMEL-nextleg-1UP-roadmap-chief session=s host=h age=10s status=OK" run --vms vmA 2>&1); rc=$?
check "W2 a held chief lock is not a worker: the update runs" logged "update"
fresh; out=$(cadence STUB_LIVE="slug=x__himmel__HIMMEL-2-N2-old session=s host=h age=99999s status=STALE-DEAD" run --vms vmA 2>&1); rc=$?
check "W3 a dead lock is not a live worker: the update runs" logged "update"
fresh; out=$(cadence CENSUS_FAIL=1 run --vms vmA 2>&1); rc=$?
check "W4 a census that fails defers the update (fail closed)" defer_check

echo "== arm =="
fresh; printf '0 5 * * * /usr/bin/other-job\n' > "$WORK/cron"
out=$(cadence VM_MAINTAIN_VMS=vmA,vmB arm --day 2 --time 04:15 2>&1); rc=$?
check "A1 arm installs one entry on the chosen day and time and keeps the other job" bash -c '[ "$1" -eq 0 ] && grep -q "^15 04 \* \* 2 .*# HIMMEL-VmMaintain" "$2" && grep -q other-job "$2" && [ -x "$3/vm-maintain-cadence.sh" ]' _ "$rc" "$WORK/cron" "$WORK/runner"
check "A1b the runner calls run and never the scan flag" bash -c 'grep -q "vm-maintain-cadence.sh.* run" "$1/vm-maintain-cadence.sh" && ! grep -q -e "--no-secret-scan" "$1/vm-maintain-cadence.sh"' _ "$WORK/runner"
check "A1c the runner keeps a VM list configured in the arming shell" bash -c 'grep -qF "VM_MAINTAIN_VMS" "$1/vm-maintain-cadence.sh" && grep -qE "vmA[\\]?,vmB" "$1/vm-maintain-cadence.sh"' _ "$WORK/runner"
out=$(cadence arm 2>&1); rc=$?
check "A2 a second arm without --force is refused with rc 3" test "$rc" -eq 3
out=$(cadence status 2>&1)
check "A3 status says ARMED" out_has "ARMED"
out=$(cadence disarm 2>&1); rc=$?
check "A4 disarm removes only this entry" bash -c '[ "$1" -eq 0 ] && ! grep -q HIMMEL-VmMaintain "$2" && grep -q other-job "$2"' _ "$rc" "$WORK/cron"
out=$(cadence arm --day 9 2>&1); rc=$?
check "A5 a bad --day is refused" test "$rc" -eq 1

echo "== usage =="
out=$(cadence 2>&1); rc=$?
check "U1 no verb exits 64 with the usage line" bash -c '[ "$1" -eq 64 ] && grep -q "Usage: vm-maintain-cadence.sh" <<<"$2"' _ "$rc" "$out"
out=$(cadence run --vms 'bad;vm' 2>&1); rc=$?
check "U2 a VM name with shell metacharacters exits 64 before any call" bash -c '[ "$1" -eq 64 ] && [ ! -s "$2" ]' _ "$rc" "$LOG"

echo "RESULT: $((CASES - FAILED)) passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
