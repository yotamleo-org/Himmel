#!/usr/bin/env bash
# test-ci-runner.sh — hermetic suite for the self-hosted runner
# tooling: the guest job-started fork guard, the host loop's preflight, kill
# switch and JIT-config handling, and the guest provisioner's bare-metal
# refusal. No VirtualBox, no network: gh, ssh and the VM lib are stubs.
#
# Platform guard (linux-only): the runner tooling it tests drives VirtualBox
# on the Linux station and provisions an Ubuntu guest.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/vm/ci-runner/job-started-hook.sh"
LOOP="$REPO_ROOT/scripts/vm/ci-runner.sh"
PROVISION="$REPO_ROOT/scripts/vm/ci-runner/guest-provision.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-ci-runner.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

# --- the job-started fork guard -------------------------------------------
# hook_case <label> <want-rc> <event-name> <ref> <event-json>
hook_case() {
    local label="$1" want="$2" ev="$3" ref="$4" json="$5" rc
    printf '%s' "$json" > "$TMP/event.json"
    GITHUB_EVENT_NAME="$ev" GITHUB_REF="$ref" GITHUB_REPOSITORY="yotamleo/Himmel" \
        GITHUB_ACTOR="${HOOK_ACTOR-yotamleo}" GITHUB_TRIGGERING_ACTOR="${HOOK_TRIG-yotamleo}" \
        GITHUB_EVENT_PATH="$TMP/event.json" HIMMEL_CI_RUNNER_REPO="yotamleo/Himmel" \
        bash "$HOOK" >"$TMP/hook.out" 2>&1
    rc=$?
    if [ "$rc" = "$want" ]; then
        ok "hook: $label (rc=$rc)"
    else
        bad "hook: $label (want $want, got rc=$rc): $(cat "$TMP/hook.out")"
    fi
}

echo "T1 job-started fork guard"
same='{"pull_request":{"user":{"login":"yotamleo"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"yotamleo"}}'
fork='{"pull_request":{"head":{"repo":{"full_name":"mallory/Himmel"}}}}'
hook_case "same-repo PR runs"            0 pull_request refs/pull/1/merge "$same"
hook_case "fork PR refused"              1 pull_request refs/pull/1/merge "$fork"
# 5070(a): the PR author and the event sender must be operator accounts too.
dep='{"pull_request":{"user":{"login":"dependabot[bot]"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"yotamleo"}}'
own='{"pull_request":{"user":{"login":"yotamleo"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"yotamleo"}}'
hook_case "owner re-run of a third-party PR refused" 1 pull_request refs/pull/1/merge "$dep"
hook_case "owner PR with owner sender runs"          0 pull_request refs/pull/1/merge "$own"
hook_case "PR with a non-owner sender refused"       1 pull_request refs/pull/1/merge '{"pull_request":{"user":{"login":"yotamleo"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"mallory"}}'
hook_case "PR with no head repo refused" 1 pull_request refs/pull/1/merge '{"pull_request":{}}'
hook_case "push to main runs"            0 push refs/heads/main '{}'
hook_case "push to a branch refused"     1 push refs/heads/feat/x '{}'
hook_case "pull_request_target refused"  1 pull_request_target refs/heads/main "$same"
hook_case "workflow_dispatch runs"       0 workflow_dispatch refs/heads/main '{}'
hook_case "schedule runs"                0 schedule refs/heads/main '{}'
# R3: workflow_dispatch and same-repo PRs run only for the operator's accounts.
HOOK_ACTOR=mallory HOOK_TRIG=mallory hook_case "dispatch by a non-owner refused" 1 workflow_dispatch refs/heads/main '{}'
HOOK_ACTOR=mallory HOOK_TRIG=mallory hook_case "same-repo PR by a non-owner refused" 1 pull_request refs/pull/1/merge "$same"
HOOK_ACTOR=yotamleo11-test HOOK_TRIG=yotamleo11-test hook_case "same-repo PR by the test account runs" 0 pull_request refs/pull/1/merge "$same"
HOOK_ACTOR=yotamleo HOOK_TRIG=mallory hook_case "dispatch re-run by a non-owner refused" 1 workflow_dispatch refs/heads/main '{}'
HOOK_ACTOR='' HOOK_TRIG='' hook_case "dispatch with no actor refused" 1 workflow_dispatch refs/heads/main '{}'
HOOK_ACTOR=mallory HOOK_TRIG=mallory hook_case "push to main needs no owner" 0 push refs/heads/main '{}'
# The repository itself must be the pinned one, whatever the event says.
printf '%s' "$same" > "$TMP/event.json"
GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge GITHUB_REPOSITORY=mallory/Himmel \
    GITHUB_EVENT_PATH="$TMP/event.json" HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel \
    bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "hook: other repository refused"; else bad "hook: other repository (rc=$rc)"; fi
GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=yotamleo/Himmel \
    GITHUB_EVENT_PATH="$TMP/missing.json" HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel \
    bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "hook: missing event file refused"; else bad "hook: missing event file (rc=$rc)"; fi

# --- host loop stubs ------------------------------------------------------
# gh stub: answers the three reads the loop makes and logs every call's argv.
# GH_APPROVAL / GH_KILL steer the fork-approval policy and the kill-switch var.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/gh.argv"
case "$*" in
    *fork-pr-contributor-approval*) echo "${GH_APPROVAL:-all_external_contributors}" ;;
    *actions/variables/HIMMEL_VM_RUNNER*)
        [ -n "${GH_KILL:-}" ] || exit 1
        if [ -e "$STUB_LOG/kill-off" ]; then echo off; else echo "$GH_KILL"; fi ;;
    *generate-jitconfig*) printf '%s\n%s\n' 4242 "JITSECRET-not-for-argv" ;;
    *"-X DELETE"*) : > "$STUB_LOG/deleted"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
cat > "$TMP/bin/VBoxManage" <<'EOF'
#!/usr/bin/env bash
[ "$1" = snapshot ] && [ "$3" = take ] && echo "snapshot-take $4" >> "$STUB_LOG/vm.calls"
exit 0
EOF
chmod +x "$TMP/bin/VBoxManage"
# VM lib stub: records which primitives ran; vm_ssh logs its argv and stdin.
cat > "$TMP/vmlib.sh" <<'EOF'
vm_env_init()  { VBOXMANAGE="$STUB_LOG/../bin/VBoxManage"; }
vm_clone_ensure() { :; }
vm_guest_assert_clean() { :; }
vm_lock_acquire_waiting() { :; }
vm_lock_release() { echo "release" >> "$STUB_LOG/vm.calls"; }
vm_restore()   { echo "restore $1" >> "$STUB_LOG/vm.calls"; PORT=2299; }
vm_boot()      { echo "boot" >> "$STUB_LOG/vm.calls"; }
vm_poweroff()  { echo "poweroff" >> "$STUB_LOG/vm.calls"; return "${STUB_POWEROFF_RC:-0}"; }
nat_localhost_off() { echo "nat-localhost-off" >> "$STUB_LOG/vm.calls"; }
clipboard_dnd_off() { echo "clipboard-dnd-off" >> "$STUB_LOG/vm.calls"; }
clipboard_dnd_disabled() { [ -z "${STUB_CLIPBOARD_ON:-}" ]; }
localhost_unreachable() { [ -z "${STUB_LOCALHOST_REACHABLE:-}" ]; }
vm_ssh() {
    printf '%s\n' "$*" >> "$STUB_LOG/ssh.argv"; cat >> "$STUB_LOG/ssh.stdin"
    case "$*" in
        sync) echo "sync" >> "$STUB_LOG/vm.calls"; return ;;
        *"test -s"*) echo "test-s" >> "$STUB_LOG/vm.calls"; [ -z "${STUB_EMPTY_WRAPPER:-}" ]; return ;;
    esac
    case "$*" in *himmel-ci-egress-refresh*) [ -z "${STUB_NO_REFRESH:-}" ]; return ;; esac
    case "$*" in *"nft list table inet himmel_egress"*) [ -z "${STUB_NO_EGRESS:-}" ]; return ;; esac
    [ -n "${STUB_SSH_HARD_SLEEP:-}" ] && case "$*" in *himmel-ci-run-job*) sleep "$STUB_SSH_HARD_SLEEP" ;; esac
    if [ -n "${STUB_SSH_SLEEP:-}" ]; then
        for _ in $(seq 1 $((STUB_SSH_SLEEP * 5))); do [ -e "$STUB_LOG/deleted" ] && break; sleep 0.2; done
    fi
    return "${STUB_SSH_RC:-0}"
}
EOF

run_loop() {
    STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
        HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
        bash "$LOOP" "$@"
}
reset_log() { rm -rf "$TMP/log"; mkdir -p "$TMP/log"; : > "$TMP/log/gh.argv"; }

echo "T2 preflight refuses a weaker fork-approval policy"
reset_log
GH_APPROVAL=first_time_contributors GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && [ ! -s "$TMP/log/vm.calls" ]; then
    ok "weaker policy: refused before any VM or mint (rc=$rc)"
else
    bad "weaker policy: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T3 kill switch"
for k in off "" ; do
    reset_log
    GH_KILL="$k" run_loop run --once >"$TMP/out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && [ ! -s "$TMP/log/vm.calls" ]; then
        ok "variable '${k:-unset}': exits 0, mints nothing, boots nothing"
    else
        bad "variable '${k:-unset}': rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
    fi
done
reset_log
: > "$TMP/stop"
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
rm -f "$TMP/stop"
if [ "$rc" -eq 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv"; then
    ok "local stop file: exits 0, mints nothing"
else
    bad "local stop file: rc=$rc"
fi

echo "T4 one job: restore, boot, JIT config on stdin only, deregister, power off"
reset_log
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "run --once exits 0"; else bad "run --once rc=$rc: $(cat "$TMP/out")"; fi
if [ "$(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)" = "restore ci-runner-v3|nat-localhost-off|clipboard-dnd-off|boot|poweroff|release|" ]; then
    ok "restored ci-runner-v3, hid the station loopback, turned clipboard and drag-and-drop off, booted, powered off, released the lock"
else
    bad "vm calls: $(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)"
fi
if grep -q "JITSECRET" "$TMP/log/ssh.stdin" 2>/dev/null; then
    ok "JIT config reached the guest on stdin"
else
    bad "JIT config never reached the guest"
fi
grep -q "JITSECRET" "$TMP/log/ssh.argv" "$TMP/log/gh.argv" "$TMP/out"
rc=$?
case "$rc" in
    1) ok "JIT config absent from every argv and the output" ;;
    0) bad "JIT config leaked into an argv or the log" ;;
    *) bad "leak scan could not read its inputs (grep rc=$rc)" ;;
esac
if grep -q -- "generate-jitconfig" "$TMP/log/gh.argv" && grep -q "labels\[\]=himmel-vm" "$TMP/log/gh.argv"; then
    ok "minted a repo-level JIT runner labelled himmel-vm"
else
    bad "mint call: $(grep jit "$TMP/log/gh.argv")"
fi
if grep -q -- "-X DELETE repos/yotamleo/Himmel/actions/runners/4242" "$TMP/log/gh.argv"; then
    ok "runner 4242 deregistered after the job"
else
    bad "no deregister: $(tr '\n' '|' < "$TMP/log/gh.argv")"
fi
grep -rq "JITSECRET" "$TMP" --exclude-dir=log --exclude-dir=bin --exclude=out --exclude=hook.out
rc=$?
case "$rc" in
    1) ok "JIT config written to no file" ;;
    0) bad "JIT config written to a file" ;;
    *) bad "file leak scan could not read the tree (grep rc=$rc)" ;;
esac

echo "T4b an image that reaches the station loopback refuses to serve"
reset_log
STUB_LOCALHOST_REACHABLE=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "station loopback" "$TMP/out"; then
    ok "loopback-reachable image: refused before mint (rc=$rc)"
else
    bad "loopback-reachable image: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T4g R1: a restore with the clipboard or drag-and-drop on refuses to serve"
reset_log
STUB_CLIPBOARD_ON=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "clipboard" "$TMP/out"; then
    ok "clipboard on after restore: refused before mint (rc=$rc)"
else
    bad "clipboard on: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T4h R2: a boot without the himmel_egress table refuses to mint"
reset_log
STUB_NO_EGRESS=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "himmel_egress" "$TMP/out" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "no egress table in the guest: refused before mint, VM powered off (rc=$rc)"
else
    bad "no egress table: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi
grep -q "nft list table inet himmel_egress" "$TMP/log/ssh.argv" 2>/dev/null || bad "egress check never ran"
# 5070(b): the per-boot check asks for every private-range reject, not just the LAN one.
reset_log
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
for r in '10\.0\.0\.0/8' '172\.16\.0\.0/12' '192\.168\.0\.0/16' '169\.254\.0\.0/16' '100\.64\.0\.0/10'; do
    if grep -qF -- "[{ ,]${r}[ ,}]" "$TMP/log/ssh.argv" 2>/dev/null; then ok "egress check requires reject of $r"; else bad "egress check ignores $r"; fi
done

echo "T4i R5: off during the job wait deregisters the idle runner promptly"
reset_log
STUB_SSH_SLEEP=20 GH_KILL=on STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
    HIMMEL_CI_RUNNER_WATCH_SECS=1 HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
    bash "$LOOP" run --once >"$TMP/out" 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do grep -q himmel-ci-run-job "$TMP/log/ssh.argv" 2>/dev/null && break; sleep 0.2; done
t0=$SECONDS
: > "$TMP/log/kill-off"
wait "$loop_pid"
rc=$?
if [ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -lt 10 ] && [ "$(grep -c -- "-X DELETE" "$TMP/log/gh.argv")" = 1 ]; then
    ok "off: runner deregistered once within $((SECONDS - t0))s, loop ended (rc=$rc)"
else
    bad "off during wait: rc=$rc after $((SECONDS - t0))s, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T4i2 5070(d): a guest that outlives the deregistration does not hold the loop"
reset_log
STUB_SSH_HARD_SLEEP=25 GH_KILL=on STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
    HIMMEL_CI_RUNNER_WATCH_SECS=1 HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
    bash "$LOOP" run --once >"$TMP/out" 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do grep -q himmel-ci-run-job "$TMP/log/ssh.argv" 2>/dev/null && break; sleep 0.2; done
t0=$SECONDS
: > "$TMP/log/kill-off"
wait "$loop_pid"
rc=$?
if [ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -lt 10 ]; then
    ok "idle deregistration ends the loop within $((SECONDS - t0))s"
else
    bad "loop held $((SECONDS - t0))s after deregistration (rc=$rc)"
fi

echo "T4c a failed guest job fails run --once, and still cleans up"
reset_log
STUB_SSH_RC=7 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 7 ] && grep -q -- "-X DELETE" "$TMP/log/gh.argv" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "guest job rc=7 propagated; runner deregistered, VM powered off"
else
    bad "failed job: rc=$rc, vm=$(tr '\n' '|' < "$TMP/log/vm.calls")"
fi

echo "T4d a power-off that fails keeps the vm-lock"
reset_log
STUB_POWEROFF_RC=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -qx release "$TMP/log/vm.calls" && grep -q "still running" "$TMP/out"; then
    ok "power-off failure: lock kept, run fails (rc=$rc)"
else
    bad "power-off failure: rc=$rc, vm=$(tr '\n' '|' < "$TMP/log/vm.calls")"
fi

echo "T4e SIGTERM mid-job still deregisters and powers off"
reset_log
# Not through run_loop: $! must be the loop's own pid, not a wrapper subshell's.
STUB_SSH_SLEEP=5 GH_KILL=on STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
    HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
    bash "$LOOP" run --once >"$TMP/out" 2>&1 &
loop_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q himmel-ci-run-job "$TMP/log/ssh.argv" 2>/dev/null && break
    sleep 0.2
done
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid"
rc=$?
if [ "$rc" -ne 0 ] && grep -q -- "-X DELETE" "$TMP/log/gh.argv" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "SIGTERM: runner deregistered, VM powered off (rc=$rc)"
else
    bad "SIGTERM: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv"), vm=$(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)"
fi

echo "T4f a zero or non-numeric job bound is refused before any mint"
for m in 0 abc; do
    reset_log
    HIMMEL_CI_RUNNER_JOB_MAX="$m" GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
    rc=$?
    if [ "$rc" -eq 2 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv"; then
        ok "JOB_MAX='$m' refused (rc=$rc)"
    else
        bad "JOB_MAX='$m': rc=$rc"
    fi
done

echo "T5 guest provisioner refuses bare metal"
cat > "$TMP/bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none; exit 1
EOF
chmod +x "$TMP/bin/systemd-detect-virt"
PATH="$TMP/bin:$PATH" bash "$PROVISION" >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && grep -q "not a VM" "$TMP/out"; then
    ok "bare metal refused (rc=$rc)"
else
    bad "bare metal: rc=$rc: $(cat "$TMP/out")"
fi

echo "T6 R1/R6 static: image purges guest utils, build disables clipboard before the snapshot, no jitconfig argv"
if grep -q 'apt-get purge.*virtualbox-guest-utils' "$PROVISION"; then ok "provisioner removes virtualbox-guest-utils"; else bad "provisioner keeps virtualbox-guest-utils"; fi
bstart=$(grep -n '^build()' "$LOOP" | cut -d: -f1)
# shellcheck disable=SC2016 # literal text to find in ci-runner.sh
tline=$(grep -n 'take "$RUNNER_SNAPSHOT"' "$LOOP" | head -1 | cut -d: -f1)
if [ -n "$bstart" ] && [ -n "$tline" ] && sed -n "${bstart},${tline}p" "$LOOP" | grep -q '^[[:space:]]*clipboard_dnd_off'; then
    ok "build turns clipboard and drag-and-drop off before the snapshot"
else
    bad "build does not disable clipboard before snapshotting"
fi
wrapper=$(sed -n '/^cat > \/usr\/local\/sbin\/himmel-ci-run-job/,/^EOF/p' "$PROVISION")
if ! printf '%s\n' "$wrapper" | grep -v '^#' | grep -q -- '--jitconfig' && printf '%s\n' "$wrapper" | grep -q ACTIONS_RUNNER_INPUT_JITCONFIG; then
    ok "run-job wrapper hands the JIT config over by environment, not argv"
else
    bad "run-job wrapper still passes --jitconfig in argv"
fi

# --- the egress allow-list --------------------------------------------------
echo "T16 the guest egress is an allow-list, not a deny-private list"
nftconf=$(sed -n "/^cat > \/etc\/nftables.conf/,/^EOF/p" "$PROVISION")
if printf '%s\n' "$nftconf" | grep -q 'chain output' && printf '%s\n' "$nftconf" | grep -q 'policy drop' \
    && ! printf '%s\n' "$nftconf" | grep -q 'policy accept' \
    && printf '%s\n' "$nftconf" | grep -q 'ip daddr @allowed4 accept' && printf '%s\n' "$nftconf" | grep -q 'ip6 daddr @allowed6 accept'; then
    ok "nftables.conf: output policy drop, accept only the allowed4/allowed6 sets"
else
    bad "nftables.conf is still a deny list: $(printf '%s' "$nftconf" | grep -E 'policy|allowed')"
fi
if printf '%s\n' "$nftconf" | grep -q 'set allowed4' && printf '%s\n' "$nftconf" | grep -q 'set allowed6'; then ok "nftables.conf declares both sets"; else bad "nftables.conf has no allowed4/allowed6 set"; fi
chain_rules=$(printf '%s\n' "$nftconf" | sed -n '/chain output/,/^    }/p' | grep -E '^[[:space:]]+(counter|ip|ip6|oifname|ct) ')
if [ "$(printf '%s\n' "$chain_rules" | tail -n 1 | sed 's/^[[:space:]]*//')" = "counter reject" ]; then ok "the output chain ends in the catch-all counter reject"; else bad "the output chain does not end in counter reject: $(printf '%s' "$chain_rules" | tail -n 1)"; fi
stray=$(printf '%s\n' "$chain_rules" | grep 'accept' | grep -vE '^[[:space:]]+(oifname "lo" accept|ct state established,related accept|ip daddr 10\.0\.2\.3 (udp|tcp) dport 53 accept|ip6? daddr @allowed[46] accept)')  # leak-allow: private-lan-ip egress filter ranges
if [ -z "$stray" ]; then ok "every accept is lo, conntrack, NAT DNS or an allowed set"; else bad "a rule accepts beyond lo/ct/DNS/allowed sets: $stray"; fi
rej_line=$(printf '%s\n' "$chain_rules" | grep -n '10\.0\.0\.0/8.*reject' | head -n 1 | cut -d: -f1)  # leak-allow: private-lan-ip egress filter ranges
acc_line=$(printf '%s\n' "$chain_rules" | grep -n '@allowed4 accept' | head -n 1 | cut -d: -f1)
if [ -n "$rej_line" ] && [ -n "$acc_line" ] && [ "$rej_line" -lt "$acc_line" ]; then ok "the private-range reject comes before the allowed4 accept"; else bad "private reject (line ${rej_line:-none}) is not before allowed4 accept (line ${acc_line:-none})"; fi

reset_log
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
refresh_line=$(grep -n 'himmel-ci-egress-refresh' "$TMP/log/ssh.argv" 2>/dev/null | head -n 1 | cut -d: -f1)
check_line=$(grep -n 'nft list table inet himmel_egress' "$TMP/log/ssh.argv" 2>/dev/null | head -n 1 | cut -d: -f1)
if [ -n "$refresh_line" ] && [ -n "$check_line" ] && [ "$refresh_line" -lt "$check_line" ]; then ok "the loop refreshes the allow-list before it checks the table"; else bad "refresh before check (refresh=$refresh_line check=$check_line)"; fi
if grep -q "policy drop" "$TMP/log/ssh.argv" 2>/dev/null && grep -q "allowed4" "$TMP/log/ssh.argv" 2>/dev/null; then ok "the per-boot check requires policy drop and a filled allowed4 set"; else bad "per-boot check ignores policy drop / allowed4"; fi
if grep -q "nft list chain inet himmel_egress output" "$TMP/log/ssh.argv" 2>/dev/null && grep -q "counter .\*reject" "$TMP/log/ssh.argv" 2>/dev/null; then ok "the per-boot check requires the output chain to end in counter reject"; else bad "per-boot check never inspects the last rule of the output chain"; fi
# Run the recorded last-rule probe against nft listings: a trailing bare accept
# (or any rule after the reject) must fail it, a chain ending in the reject must pass.
lastrule=$(sed -n 's/.*\(sudo nft list chain inet himmel_egress output [^&]*\).*/\1/p' "$TMP/log/ssh.argv" | head -n 1)
mkdir -p "$TMP/nftbin"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$TMP/nftbin/sudo"
# shellcheck disable=SC2016 # the stub body must expand STUB_NFT_LISTING at run time
printf '#!/usr/bin/env bash\ncat "$STUB_NFT_LISTING"\n' > "$TMP/nftbin/nft"
chmod +x "$TMP/nftbin/sudo" "$TMP/nftbin/nft"
printf 'table inet himmel_egress {\n\tchain output {\n\t\ttype filter hook output priority filter; policy drop;\n\t\toifname "lo" accept\n\t\tip daddr @allowed4 accept\n\t\tcounter packets 0 bytes 0 reject\n\t}\n}\n' > "$TMP/listing-good"
printf 'table inet himmel_egress {\n\tchain output {\n\t\ttype filter hook output priority filter; policy drop;\n\t\toifname "lo" accept\n\t\tcounter packets 0 bytes 0 reject\n\t\taccept\n\t}\n}\n' > "$TMP/listing-bare-accept"
printf 'table inet himmel_egress {\n\tchain output {\n\t\ttype filter hook output priority filter; policy drop;\n\t\toifname "lo" accept\n\t\tcounter packets 0 bytes 0 reject\n\t\tip daddr @allowed4 accept\n\t}\n}\n' > "$TMP/listing-accept-after"
if [ -n "$lastrule" ] && STUB_NFT_LISTING="$TMP/listing-good" PATH="$TMP/nftbin:$PATH" bash -c "$lastrule"; then ok "the last-rule probe passes a chain that ends in counter reject"; else bad "last-rule probe rejects a good chain: $lastrule"; fi
for l in listing-bare-accept listing-accept-after; do
    if [ -n "$lastrule" ] && ! STUB_NFT_LISTING="$TMP/$l" PATH="$TMP/nftbin:$PATH" bash -c "$lastrule"; then ok "the last-rule probe fails $l"; else bad "last-rule probe passes $l"; fi
done

reset_log
STUB_NO_REFRESH=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "a failed allow-list refresh: refused before mint, VM powered off (rc=$rc)"
else
    bad "failed refresh: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T16b build stages every file guest-provision installs"
if sed -n '/^build()/,/^}/p' "$LOOP" | grep -q 'for f in .*egress-refresh.sh'; then ok "build stages egress-refresh.sh into the guest"; else bad "build never stages egress-refresh.sh (guest-provision's install would fail)"; fi

echo "T16c build syncs the guest and refuses an empty wrapper before the hard power-off (the v2 image shipped 0-byte scripts)"
reset_log
run_loop build >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(tr '\n' '|' < "$TMP/log/vm.calls")" = "restore suite-ready-v4|clipboard-dnd-off|boot|sync|test-s|poweroff|snapshot-take ci-runner-v3|poweroff|release|" ]; then
    ok "build: sync, then the wrapper size check, then power-off, then the ci-runner-v3 snapshot"
else
    bad "build call order (rc=$rc): $(tr '\n' '|' < "$TMP/log/vm.calls")"
fi
reset_log
STUB_EMPTY_WRAPPER=1 run_loop build >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q '^snapshot-take' "$TMP/log/vm.calls" && grep -qx poweroff "$TMP/log/vm.calls" && grep -q 'empty' "$TMP/out"; then
    ok "build: an empty wrapper in the guest fails the bake, no snapshot taken, VM powered off (rc=$rc)"
else
    bad "empty wrapper: rc=$rc, calls=$(tr '\n' '|' < "$TMP/log/vm.calls"), out=$(cat "$TMP/out")"
fi

echo "T17 egress-refresh fills the sets from /meta and the mirror hosts"
REFRESH="$REPO_ROOT/scripts/vm/ci-runner/egress-refresh.sh"
mkdir -p "$TMP/rbin"
cat > "$TMP/rbin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/curl.argv"
[ -z "${STUB_CURL_FAIL:-}" ] || exit 22
cat "${STUB_META:?}"
EOF
cat > "$TMP/rbin/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$STUB_LOG/getent.hosts"
[ "$2" != "${STUB_NO_RESOLVE:-}" ] || exit 2
[ "$2" != "${STUB_EMPTY_RESOLVE:-}" ] || exit 0
case "$2" in
    api.github.com) printf '%s STREAM api.github.com\n' 140.82.112.5 ;;
    archive.ubuntu.com) printf '%s STREAM archive.ubuntu.com\n%s STREAM archive.ubuntu.com\n' 185.125.190.82 2620:2d:4000:1::1a ;;
    *) printf '%s STREAM %s\n' 198.51.100.7 "$2" ;;
esac
EOF
cat > "$TMP/rbin/nft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/nft.argv"
EOF
chmod +x "$TMP/rbin/curl" "$TMP/rbin/getent" "$TMP/rbin/nft"
run_refresh() {
    STUB_LOG="$TMP/log" PATH="$TMP/rbin:$PATH" STUB_META="${META:-$REPO_ROOT/scripts/vm/fixtures/github-meta-sample.json}" bash "$REFRESH"
}
reset_log
run_refresh >"$TMP/out" 2>&1
rc=$?
nftlog=$(cat "$TMP/log/nft.argv" 2>/dev/null)
if [ "$rc" -eq 0 ]; then ok "refresh exits 0 on a real /meta sample"; else bad "refresh rc=$rc: $(cat "$TMP/out")"; fi
for want in '192.30.252.0/22' '185.199.108.0/22' '4.148.0.0/16' '140.82.121.33/32' '140.82.112.5' '185.125.190.82'; do
    if printf '%s\n' "$nftlog" | grep 'allowed4' | grep -qF -- "$want"; then ok "allowed4 gets $want"; else bad "allowed4 lacks $want"; fi
done
for want in '2a0a:a440::/29' '2602:fd5e:1::/63' '2620:2d:4000:1::1a'; do
    if printf '%s\n' "$nftlog" | grep 'allowed6' | grep -qF -- "$want"; then ok "allowed6 gets $want"; else bad "allowed6 lacks $want"; fi
done
for h in api.github.com archive.ubuntu.com security.ubuntu.com pypi.org files.pythonhosted.org registry.npmjs.org; do
    if grep -qx "$h" "$TMP/log/getent.hosts" 2>/dev/null; then ok "mirror host $h resolved"; else bad "mirror host $h never resolved"; fi
done
if printf '%s\n' "$nftlog" | grep -qF '8.8.8.8'; then bad "a non-allow-listed address reached a set"; else ok "no non-allow-listed address in the sets"; fi
reset_log
STUB_CURL_FAIL=1 run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "an unreachable /meta fails closed (rc=$rc)"; else bad "unreachable /meta exited 0"; fi
printf '{}' > "$TMP/empty-meta.json"
reset_log
META="$TMP/empty-meta.json" run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "an empty /meta fails closed (rc=$rc)"; else bad "empty /meta exited 0"; fi
reset_log
STUB_NO_RESOLVE=pypi.org run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "a mirror host that does not resolve fails closed (rc=$rc)"; else bad "unresolvable mirror host exited 0"; fi
reset_log
STUB_EMPTY_RESOLVE=pypi.org run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "a mirror host that resolves to no addresses fails closed (rc=$rc)"; else bad "mirror host with empty addresses exited 0"; fi
reset_log
STUB_NO_RESOLVE=api.github.com run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q . "$TMP/log/curl.argv" 2>/dev/null; then ok "an unresolvable bootstrap host fails closed before /meta is fetched (rc=$rc)"; else bad "bootstrap resolve failure: rc=$rc, curl=$(cat "$TMP/log/curl.argv" 2>/dev/null)"; fi
reset_log
STUB_EMPTY_RESOLVE=api.github.com run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "a bootstrap host with no addresses fails closed (rc=$rc)"; else bad "bootstrap host with empty addresses exited 0"; fi
printf 'not json' > "$TMP/bad-meta.json"
reset_log
META="$TMP/bad-meta.json" run_refresh >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "an unparseable /meta fails closed (rc=$rc)"; else bad "unparseable /meta exited 0"; fi

echo
echo "test-ci-runner: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
