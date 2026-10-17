#!/usr/bin/env bash
# vm-runner.sh — the console's ONE entry point for the himmel-vm self-hosted
# Actions runner. The host loop is scripts/vm/ci-runner.sh;
# this wraps it in one user-level systemd unit per VM and the repo kill switch.
#
#   vm-runner.sh on  [--vms N]   check policy, ensure the clones, set the repo
#                                variable HIMMEL_VM_RUNNER=on, drop the stop
#                                file, start one unit per VM (default 2, max 2)
#   vm-runner.sh off             variable off, stop file written, every unit
#                                stopped (a loop deregisters its runner and
#                                powers its VM off on the way out)
#   vm-runner.sh status          units up/idle/busy, current job, last error
#   vm-runner.sh status --tick   the one tick token (tick.sh's vmrun= field):
#                                off | ok:<up>/<want>,busy=<n> | DEAD | STUCK | FAILING
#                                | DISAGREE:<up>/<want>,online=0 (a unit has a
#                                registered, unfinished runner but GitHub shows
#                                no himmel-vm runner online)
#   vm-runner.sh doctor          `<OK|WARN|FAIL><TAB><id><TAB><message>` rows
#                                for himmel-doctor's C64 check
#
# VM i is `himmel-ci-<i>`: VM 1 is the baked himmel-ci-1@ci-runner-v3
# (`ci-runner.sh build`), every other VM a linked clone of that snapshot.
# Nothing here boots a VM itself; the unit's ci-runner.sh loop does, one job per
# clean restore. The raw `ci-runner.sh run` is deliberately NOT in any allow rule.
#
# Platform guard (linux-only): systemd --user units and VirtualBox.
#
# ponytail: `off` stops a loop mid-job (that job is lost and must be re-run by
# hand); a drain mode that waits for in-flight jobs is the upgrade if lost jobs
# ever cost more than a stuck kill switch.
set -u

# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced before the seam guard.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "vm-runner.sh: cannot load $_csg_lib - refusing (HIMMEL-3914)" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/console-kit/vm-runner.sh || exit 96

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
REPO="${HIMMEL_CI_RUNNER_REPO:-yotamleo/Himmel}"
VAR=HIMMEL_VM_RUNNER
MAX_VMS=2
UNIT_PREFIX=himmel-ci-runner
UNIT_DIR="${HIMMEL_VM_RUNNER_UNIT_DIR:-$HOME/.config/systemd/user}"
STATE_DIR="${HIMMEL_VM_RUNNER_STATE_DIR:-$HOME/.himmel/state}"
STOP_FILE="${HIMMEL_CI_RUNNER_STOP_FILE:-$HOME/.himmel/ci-runner.stop}"
JOB_MAX="${HIMMEL_CI_RUNNER_JOB_MAX:-4500}"
BASE_VM=himmel-ci-1
SNAPSHOT=ci-runner-v3
CACHE_TTL=45

die() { echo "vm-runner: $1" >&2; exit "${2:-1}"; }

# shellcheck source=../../lib/timeout-bin.sh
. "$REPO_ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""
bounded() { ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 20} "$@"; }

vmrun_var() { bounded gh api "repos/$REPO/actions/variables/$VAR" --jq .value 2>/dev/null; }
vmrun_policy() { bounded gh api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2>/dev/null; }
unit_active() { systemctl --user is-active --quiet "$UNIT_PREFIX@$1.service" 2>/dev/null; }
vmrun_want() {
    local w
    w="$(cat "$STATE_DIR/vm-runner.vms" 2>/dev/null)" || w=""
    case "$w" in ''|*[!0-9]*|0*) w=$MAX_VMS ;; esac
    [ "$w" -le "$MAX_VMS" ] || w=$MAX_VMS
    printf '%s\n' "$w"
}

# ensure_clone <i> — himmel-ci-<i> exists, as a linked clone of the baked VM.
ensure_clone() {
    local i="$1" name
    name="himmel-ci-$i"
    [ "$i" -gt 1 ] || return 0
    if [ -n "${HIMMEL_VM_RUNNER_VM_LIB:-}" ]; then
        # shellcheck source=/dev/null
        . "$HIMMEL_VM_RUNNER_VM_LIB"
    else
        # shellcheck source=../../vm/port-alloc.sh
        . "$REPO_ROOT/scripts/vm/port-alloc.sh"
        # shellcheck source=../../vm/lib/vm-clone.sh
        . "$REPO_ROOT/scripts/vm/lib/vm-clone.sh"
        # shellcheck source=../../vm/vm-lock.sh
        . "$REPO_ROOT/scripts/vm/vm-lock.sh"
    fi
    export HIMMEL_VM_AR_LIVE="${HIMMEL_VM_AR_LIVE:-1}"
    SOURCE_VM="$BASE_VM"
    GUEST_USER=himmel
    CLONE_NAME="$name"
    export SOURCE_VM GUEST_USER CLONE_NAME
    fail() { die "$1"; }
    vm_env_init
    vm_lock_acquire_waiting "$name" || die "could not take the vm-lock on $name"
    # Any exit while the lock is held (vm_clone_ensure failing, die, a signal)
    # releases it; the trap clears before the normal release.
    # shellcheck disable=SC2064
    trap "vm_lock_release '$name'" EXIT
    if ! vm_clone_ensure "$SNAPSHOT"; then
        die "could not ensure the clone $name from $BASE_VM@$SNAPSHOT"
    fi
    trap - EXIT
    vm_lock_release "$name"
}

# sed_esc <text> — text safe as a sed replacement with the # delimiter.
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }

install_unit() {
    mkdir -p "$UNIT_DIR" || die "cannot create $UNIT_DIR"
    # The units get the controller's repo and stop file, so on/off and the loops agree.
    sed -e "s#@REPO_ROOT@#$(sed_esc "$REPO_ROOT")#g" -e "s#@REPO@#$(sed_esc "$REPO")#g" -e "s#@STOP_FILE@#$(sed_esc "$STOP_FILE")#g" -e "s#@JOB_MAX@#$(sed_esc "$JOB_MAX")#g" \
        "$REPO_ROOT/scripts/vm/ci-runner/$UNIT_PREFIX@.service" \
        > "$UNIT_DIR/$UNIT_PREFIX@.service" || die "cannot write the unit template"
    systemctl --user daemon-reload || die "systemctl --user unit reload failed"
}

cmd_on() {
    local vms="$MAX_VMS" i policy
    while [ $# -gt 0 ]; do
        case "$1" in
            --vms) vms="${2:-}"; shift 2 || die "usage: vm-runner.sh on [--vms N]" 2 ;;
            *) die "usage: vm-runner.sh on [--vms N]" 2 ;;
        esac
    done
    case "$vms" in ''|*[!0-9]*|0*) die "--vms must be 1..$MAX_VMS" 2 ;; esac
    [ "$vms" -le "$MAX_VMS" ] || die "--vms must be 1..$MAX_VMS (memory: 4 GB per VM)" 2
    policy="$(vmrun_policy)" || policy=""
    [ "$policy" = all_external_contributors ] \
        || die "fork-PR approval policy on $REPO is '${policy:-unreadable}', not all_external_contributors — refusing to serve a public repo" 3
    i=1
    while [ "$i" -le "$vms" ]; do
        ensure_clone "$i"
        i=$((i + 1))
    done
    { mkdir -p "$STATE_DIR" && printf '%s\n' "$vms" > "$STATE_DIR/vm-runner.vms"; } || die "cannot write $STATE_DIR/vm-runner.vms"
    rm -f "$STOP_FILE" || die "cannot remove the stop file $STOP_FILE — the loops would exit at once"
    [ ! -e "$STOP_FILE" ] || die "stop file $STOP_FILE is still present — the loops would exit at once"
    install_unit
    bounded gh variable set "$VAR" --repo "$REPO" --body on >/dev/null || die "could not set $VAR=on on $REPO"
    i=1
    while [ "$i" -le "$vms" ]; do
        systemctl --user start "$UNIT_PREFIX@$i.service" || { cmd_off >/dev/null; die "could not start $UNIT_PREFIX@$i — switched off again"; }
        i=$((i + 1))
    done
    # Type=simple: a start that returns 0 can still die at once on a config or
    # policy refusal. One settle, then every unit must be up, or roll back.
    sleep "${HIMMEL_VM_RUNNER_SETTLE:-5}"
    i=1
    while [ "$i" -le "$vms" ]; do
        unit_active "$i" || { cmd_off >/dev/null; die "$UNIT_PREFIX@$i exited right after start (see journalctl --user -u $UNIT_PREFIX@$i) — switched off again"; }
        i=$((i + 1))
    done
    # A lower --vms than the last run: stop the units above the requested count.
    while [ "$i" -le "$MAX_VMS" ]; do
        if ! systemctl --user stop "$UNIT_PREFIX@$i.service" 2>/dev/null && unit_active "$i"; then
            cmd_off >/dev/null
            die "could not stop $UNIT_PREFIX@$i above --vms $vms — switched off again"
        fi
        i=$((i + 1))
    done
    echo "vm-runner: on —$vms VM(s) serving $REPO"
}

cmd_off() {
    local i=1 rc=0
    # Variable first: routed jobs fall back to hosted runners at once.
    if ! bounded gh variable set "$VAR" --repo "$REPO" --body off >/dev/null; then
        echo "vm-runner: WARNING could not set $VAR=off on $REPO — the stop file and units still go down" >&2
        rc=1
    fi
    if ! { mkdir -p "$(dirname "$STOP_FILE")" && : > "$STOP_FILE"; }; then
        echo "vm-runner: WARNING could not write $STOP_FILE" >&2
        rc=1
    fi
    while [ "$i" -le "$MAX_VMS" ]; do
        if ! systemctl --user stop "$UNIT_PREFIX@$i.service" 2>/dev/null && unit_active "$i"; then
            echo "vm-runner: WARNING $UNIT_PREFIX@$i is still running" >&2
            rc=1
        fi
        i=$((i + 1))
    done
    rm -f "$STATE_DIR/tick-vmrun-cache"
    if [ "$rc" -eq 0 ]; then echo "vm-runner: off"; else echo "vm-runner: off INCOMPLETE — see warnings" >&2; fi
    return "$rc"
}

# unit_journal <i> — the unit's recent log, one `<epoch> <message>` per line.
# Returns 1 when journalctl itself fails, so "unreadable" is not read as "no lines yet".
unit_journal() {
    local raw
    raw="$(journalctl --user -u "$UNIT_PREFIX@$1.service" -o short-unix --no-pager -n 2000 2>/dev/null)" || return 1  # swallow-ok: only stderr text is dropped; the exit status is returned, callers fail closed
    printf '%s\n' "$raw" | sed -n 's/^\([0-9][0-9]*\)\.[0-9]* [^ ]* [^ ]*: \(.*\)$/\1 \2/p'
}

# unit_job <i> — `idle`, or `<age seconds>` since the in-flight job's runner registered.
unit_job() {
    local reg fin now
    reg="$(unit_journal "$1" | awk '/ci-runner: runner [0-9]+ registered on/ { t = $1 } END { print t }')"
    fin="$(unit_journal "$1" | awk '/ci-runner: runner [0-9]* done \(rc=|deregistered/ { t = $1 } END { print t }')"
    [ -n "$reg" ] || { echo idle; return; }
    if [ -n "$fin" ] && [ "$fin" -ge "$reg" ]; then echo idle; return; fi
    now="$(date +%s)"
    echo $((now - reg))
}

unit_last_error() {
    unit_journal "$1" | grep -E 'ci-runner: ' | grep -vE 'registered on|done \(rc=0|deregistered' | tail -n 1 | cut -d' ' -f2-
}

# unit_failing <i> — true when the newest `ci-runner:` line is an error, so the
# loop is up but minting nothing. Ephemeral runners register only while a job
# runs, so GitHub's runner count cannot say this; the journal can. An
# unreadable journal is failing too: nothing can be vouched for.
unit_failing() {
    local last jr
    jr="$(unit_journal "$1")" || return 0
    last="$(printf '%s\n' "$jr" | grep -E 'ci-runner: ' | tail -n 1)"
    [ -n "$last" ] && ! printf '%s\n' "$last" | grep -qE 'registered on|done \(rc=0|deregistered'
}

# runner_counts — "<busy> <online>" from ONE gh call, cached: the himmel-vm
# runners GitHub reports busy, and the himmel-vm runners it reports online
# (the ground truth the unit count is checked against; an unrelated runner
# must not mask them). Prints nothing and caches nothing when GitHub is
# unreadable, so the caller fails closed. One page of 100: the repo registers
# at most MAX_VMS ephemeral himmel-vm runners, so a second page cannot hold them.
runner_counts() {
    local f="$STATE_DIR/tick-vmrun-cache" now ts busy online val
    now="$(date +%s)"
    if [ -r "$f" ] && read -r ts busy online < "$f" 2>/dev/null && [ -n "$ts" ] && [ $((now - ts)) -lt "$CACHE_TTL" ]; then
        case "$busy" in ''|*[!0-9]*) ;; *) case "$online" in ''|*[!0-9]*) ;; *) printf '%s %s\n' "$busy" "$online"; return ;; esac ;; esac
    fi
    val="$(bounded gh api "repos/$REPO/actions/runners?per_page=100" --jq '"\([.runners[] | select(.busy and (.name | startswith("himmel-vm-")))] | length) \([.runners[] | select(.status == "online" and (.name | startswith("himmel-vm-")))] | length)"' 2>/dev/null)" || return 0
    case "$val" in [0-9]*\ [0-9]*) ;; *) return 0 ;; esac
    case "${val// /}" in *[!0-9]*) return 0 ;; esac
    { mkdir -p "$STATE_DIR" && printf '%s %s\n' "$now" "$val" > "$f"; } 2>/dev/null || true
    printf '%s\n' "$val"
}

# tick_token — off | ok:<up>/<want>,busy=<n> | DISAGREE:<up>/<want>,online=0 | DEAD | STUCK | FAILING
tick_token() {
    local var up=0 want i=1 stuck=0 failing=0 inflight=-1 j counts busy online
    # Never set up on this station: no gh call, nothing to report.
    [ -e "$UNIT_DIR/$UNIT_PREFIX@.service" ] || { echo off; return; }
    var="$(vmrun_var)" || var=""
    want="$(vmrun_want)"
    while [ "$i" -le "$MAX_VMS" ]; do
        if unit_active "$i"; then
            up=$((up + 1))
            ! unit_failing "$i" || failing=1
            j="$(unit_job "$i")"
            case "$j" in idle) ;; *) [ "$j" -le "$inflight" ] || inflight="$j"; [ "$j" -gt $((JOB_MAX + 600)) ] && stuck=1 ;; esac
        fi
        i=$((i + 1))
    done
    # An unreadable variable (gh down, auth) with a unit up is judged as on, so
    # DEAD/STUCK stay visible; an explicit off with a unit up is a shutdown.
    # Unreadable with no unit up: the variable may still be on (a gh outage also
    # stops the loops), so never say off. No stop file means the operator turned
    # it on: DEAD. A stop file means it was turned off: unknown.
    if [ "$var" != on ] && [ -n "$var" ]; then echo off; return; fi
    if [ -z "$var" ] && [ "$up" -eq 0 ]; then
        if [ -e "$STOP_FILE" ]; then echo unknown; else echo DEAD; fi
        return
    fi
    if [ "$up" -eq 0 ]; then echo DEAD; return; fi
    if [ "$stuck" -eq 1 ]; then echo STUCK; return; fi
    if [ "$failing" -eq 1 ]; then echo FAILING; return; fi
    # The unit count is this station's claim; GitHub's online-runner count is
    # the check. An unreadable count is never ok. A loop mints its JIT runner
    # late and deletes it after each job, so zero online is normal between jobs:
    # it disagrees only while a unit has a registered, unfinished runner that
    # has had CACHE_TTL + 60 s to connect: inflight is the oldest such age, -1 if none.
    counts="$(runner_counts)"
    if [ -z "$counts" ]; then echo FAILING; return; fi
    read -r busy online <<< "$counts"
    if [ "$online" -eq 0 ] && [ "$inflight" -gt $((CACHE_TTL + 60)) ]; then echo "DISAGREE:$up/$want,online=0"; return; fi
    echo "ok:$up/$want,busy=$busy"
}

cmd_status() {
    local i=1 var want j err
    if [ "${1:-}" = --tick ]; then tick_token; return; fi
    var="$(vmrun_var)" || var=""
    want="$(vmrun_want)"
    echo "vmrun: $(tick_token)"
    echo "variable $VAR=${var:-unreadable} want=$want stop-file=$([ -e "$STOP_FILE" ] && echo present || echo absent)"
    while [ "$i" -le "$MAX_VMS" ]; do
        if unit_active "$i"; then
            j="$(unit_job "$i")"
            err="$(unit_last_error "$i")"
            case "$j" in
                idle) echo "himmel-ci-$i: up idle${err:+ last-error: $err}" ;;
                *) echo "himmel-ci-$i: up job-age=${j}s${err:+ last-error: $err}" ;;
            esac
        else
            err="$(unit_last_error "$i")"
            echo "himmel-ci-$i: down${err:+ last-error: $err}"
        fi
        i=$((i + 1))
    done
}

# doctor — rows for himmel-doctor C64: runner health, snapshot, NAT, policy.
cmd_doctor() {
    local vbm="${VBOXMANAGE_PATH:-/usr/bin/VBoxManage}" var tok policy i info
    [ -x "$vbm" ] || command -v "$vbm" >/dev/null 2>&1 || { printf 'OK\tC64-vm-runner\tVirtualBox not installed (runner skipped)\n'; return; }
    if ! bounded "$vbm" showvminfo "$BASE_VM" --machinereadable >/dev/null 2>&1; then
        printf 'OK\tC64-vm-runner\t%s not registered (VM runner not set up — skipped)\n' "$BASE_VM"
        return
    fi
    if bounded "$vbm" snapshot "$BASE_VM" list --machinereadable 2>/dev/null | grep -q "^SnapshotName.*=\"$SNAPSHOT\""; then
        printf 'OK\tC64-vm-runner\t%s@%s present\n' "$BASE_VM" "$SNAPSHOT"
    else
        printf 'FAIL\tC64-vm-runner\t%s has no %s snapshot — bake it: bash scripts/vm/ci-runner.sh build\n' "$BASE_VM" "$SNAPSHOT"
    fi
    i=1
    while [ "$i" -le "$MAX_VMS" ]; do
        info="$(bounded "$vbm" showvminfo "himmel-ci-$i" --machinereadable 2>/dev/null)" || { i=$((i + 1)); continue; }
        if printf '%s\n' "$info" | grep -qx 'VMState="running"' && ! printf '%s\n' "$info" | grep -qx 'localhostReachable="0"'; then
            printf 'FAIL\tC64-vm-runner\thimmel-ci-%s is running with the station loopback reachable (NAT localhost-off lost)\n' "$i"
        fi
        i=$((i + 1))
    done
    policy="$(vmrun_policy)" || policy=""
    case "$policy" in
        all_external_contributors) printf 'OK\tC64-vm-runner\tfork-PR approval policy is all_external_contributors\n' ;;
        '') printf 'WARN\tC64-vm-runner\tfork-PR approval policy on %s unreadable (gh)\n' "$REPO" ;;
        *) printf 'FAIL\tC64-vm-runner\tfork-PR approval policy on %s is %s, not all_external_contributors\n' "$REPO" "$policy" ;;
    esac
    tok="$(tick_token)"
    case "$tok" in
        DEAD|STUCK|FAILING|DISAGREE:*) printf 'FAIL\tC64-vm-runner\trunner %s (variable on): bash scripts/handover/console-kit/vm-runner.sh status\n' "$tok" ;;
        unknown) printf 'WARN\tC64-vm-runner\trunner state unknown: the %s variable is unreadable (gh) and no unit is up\n' "$VAR" ;;
        *) printf 'OK\tC64-vm-runner\trunner %s\n' "$tok" ;;
    esac
}

case "${1:-}" in
    on) shift; cmd_on "$@" ;;
    off) [ $# -eq 1 ] || die "usage: vm-runner.sh off" 2; cmd_off ;;
    status) shift; cmd_status "$@" ;;
    doctor) cmd_doctor ;;
    *) die "usage: vm-runner.sh on [--vms N] | off | status [--tick] | doctor" 2 ;;
esac
