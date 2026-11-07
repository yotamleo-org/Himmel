#!/usr/bin/env bash
# vm-maintain-cadence.sh - the scheduled VM maintenance pass: keep every test VM current, then the station.
#
#   vm-maintain-cadence.sh run [--vms a,b]       one pass (what cron fires)
#   vm-maintain-cadence.sh arm [--day 0-6] [--time HH:MM] [--force] [--dry-run]
#   vm-maintain-cadence.sh status
#   vm-maintain-cadence.sh disarm [--dry-run]
#
# Exit: run 0 done (also when logins are expired, skipped VMs or a deferral), 1 a failed step, 64 usage.
#       arm 0 armed (or dry-run), 1 bad argument, 2 no crontab / no primary checkout, 3 already armed
#       (use --force), 4 crontab or runner write failed. status 0 (1 unreadable crontab). disarm 0 (4).
#
# Seams (tests): VMCAD_VM_MAINTAIN, VMCAD_UPDATE_CMD, VMCAD_LIVE_WORKERS_CMD (prints queue-lock
# `status --sweep` lines, rc 0 or 20), VMCAD_STATE_DIR, VMCAD_LOCK_WAIT, VMCAD_CRONTAB, VMCAD_RUNNER_DIR,
# VM_MAINTAIN_VMS (default VM list), plus cadence-alert.sh's CADENCE_ALERT_*.
# Platform guard (linux-only): VirtualBox and cron on the Linux station.
set -uo pipefail

TASK_NAME="HIMMEL-VmMaintain"
ALERT_WORKER="vm-maintain-cadence"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALERT="$ROOT/scripts/luna/cadence-alert.sh"
VMM="${VMCAD_VM_MAINTAIN:-$SCRIPT_DIR/vm-maintain.sh}"
STATE_DIR="${VMCAD_STATE_DIR:-${HOME:-}/.himmel/state/vm-maintain}"
CRONTAB_BIN="${VMCAD_CRONTAB:-crontab}"
RUNNER_DIR="${VMCAD_RUNNER_DIR:-${HOME:-}/.claude/vm-maintain-cadence}"
# shellcheck source=../lib/crontab-locked-rmw.sh
. "$ROOT/scripts/lib/crontab-locked-rmw.sh" || { echo "ERR vm-maintain-cadence: cannot source crontab-locked-rmw.sh" >&2; exit 2; }
# shellcheck source=../lib/load-dotenv.sh
. "$ROOT/scripts/lib/load-dotenv.sh" || { echo "ERR vm-maintain-cadence: cannot source load-dotenv.sh" >&2; exit 2; }

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

say() { echo "vm-maintain-cadence: $*"; }

live_workers() {
    local out rc
    if [ -n "${VMCAD_LIVE_WORKERS_CMD:-}" ]; then out="$("$VMCAD_LIVE_WORKERS_CMD" 2>/dev/null)"; rc=$?
    else out="$(bash "$ROOT/scripts/handover/queue-lock.sh" status --sweep 2>/dev/null)"; rc=$?; fi
    case "$rc" in 0|20) ;; *) return 1 ;; esac
    printf '%s\n' "$out" | grep '^slug=' | grep -v ' status=STALE-DEAD' | grep -Ev '^slug=[^ ]*-chief ' || true
}

step_fail() {
    say "CADENCE FAILED $1 - $2"
    bash "$ALERT" fail "$ALERT_WORKER" "$1 failed" "$LOGF" "$2" "read the log, fix it, the next scheduled pass retries"
}

readonly VMM_OK=0 VMM_FAILED=1 VMM_BUSY=2

probe_reported_expired_login() { [ "$1" -eq 1 ] && ! grep -qF FAILED <<<"$2"; }

vmm_step() {
    local mode="$1" vm="$2" out rc step
    out="$("$VMM" "$mode" "$vm" 2>&1)"; rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    [ "$rc" -ne 0 ] || return "$VMM_OK"
    if [ "$rc" -eq 2 ]; then
        say "SKIPPED $vm ($mode): busy or refused, see the line above; the next pass retries"
        return "$VMM_BUSY"
    fi
    if [ "$mode" = probe ] && probe_reported_expired_login "$rc" "$out"; then return "$VMM_OK"; fi
    step="$(printf '%s\n' "$out" | sed -n 's/.*FAILED \([a-z-]*\).*/\1/p' | head -n1)"
    step_fail "vm-maintain $vm ${step:-$mode}" "$(printf '%s\n' "$out" | grep FAILED | head -n1)"
    return "$VMM_FAILED"
}

cmd_run() {
    local vms="${VM_MAINTAIN_VMS:-ubuntu_new}" vm live out rc
    while [ $# -gt 0 ]; do
        case "$1" in
            --vms) [ $# -ge 2 ] || { echo "ERR vm-maintain-cadence: --vms needs a value" >&2; return 64; }
                   vms="$2"; shift 2 ;;
            *) echo "ERR vm-maintain-cadence: unknown arg: $1" >&2; return 64 ;;
        esac
    done
    for vm in ${vms//,/ }; do
        case "$vm" in *[!A-Za-z0-9_-]*|'') echo "ERR vm-maintain-cadence: invalid vm name '$vm'" >&2; return 64 ;; esac
    done
    export HIMMEL_VM_LOCK_WAIT="${HIMMEL_VM_LOCK_WAIT:-${VMCAD_LOCK_WAIT:-1800}}"
    for vm in ${vms//,/ }; do
        vmm_step run "$vm"; rc=$?
        [ "$rc" -ne "$VMM_FAILED" ] || return 1
        [ "$rc" -eq "$VMM_OK" ] || continue
        vmm_step probe "$vm"; rc=$?
        [ "$rc" -ne "$VMM_FAILED" ] || return 1
    done
    if ! live="$(live_workers)"; then
        say "DEFERRED station-update: the live-worker census failed, so a worker may be live; the next pass retries"
    elif [ -n "$live" ]; then
        say "DEFERRED station-update: worker sessions are live; the next pass retries"
        printf '  %s\n' "$live"
    else
        if [ -n "${VMCAD_UPDATE_CMD:-}" ]; then out="$("$VMCAD_UPDATE_CMD" 2>&1)"; rc=$?
        else out="$(bash "$ROOT/scripts/himmel-update.sh" 2>&1)"; rc=$?; fi
        printf '%s\n' "$out"
        if [ "$rc" -ne 0 ]; then step_fail station-update "himmel-update.sh rc=$rc: $(printf '%s\n' "$out" | tail -n 1)"; return 1; fi
        say "station-update done"
    fi
    bash "$ALERT" clear "$ALERT_WORKER"
    return 0
}

# "no crontab for <user>" is an empty table; any other read failure is an error
# (installing over it would drop the operator's other jobs).
cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR vm-maintain-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

arm_edit() {
    if [ -n "$(cron_entry)" ] && [ "$ARM_FORCE" -eq 0 ]; then
        echo "ERR vm-maintain-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$ARM_ENTRY"; }
}
disarm_edit() { { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; }; }

cmd_arm() {
    local day=0 time="03:30" dry=0 root runner bash_bin
    ARM_FORCE=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --day|--time)
                [ $# -ge 2 ] || { echo "ERR vm-maintain-cadence: $1 needs a value" >&2; return 1; }
                case "$1" in --day) day="$2" ;; --time) time="$2" ;; esac
                shift 2 ;;
            --force) ARM_FORCE=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR vm-maintain-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$day" =~ ^[0-6]$ ]] || { echo "ERR vm-maintain-cadence: --day must be 0-6, got: $day" >&2; return 1; }
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR vm-maintain-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR vm-maintain-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR vm-maintain-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    # cron has no HANDOVER_DIR (the live-worker census needs it): the shell's value wins, else the primary checkout's .env
    if [ -z "${HANDOVER_DIR:-}" ]; then load_dotenv --root "$root" HANDOVER_DIR >/dev/null 2>&1 || true; fi
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$ARM_FORCE" -eq 0 ]; then
        echo "ERR vm-maintain-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/vm-maintain-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    ARM_ENTRY="${time#*:} ${time%:*} * * $day \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY vm-maintain-cadence: would write $runner and install: $ARM_ENTRY"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# vm-maintain-cadence runner - generated by vm-maintain-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'cd %q || exit 2\n' "$root"
        if [ -n "${HANDOVER_DIR:-}" ]; then
            printf 'HANDOVER_DIR=%q\nexport HANDOVER_DIR\n' "$HANDOVER_DIR"
        fi
        if [ -n "${VM_MAINTAIN_VMS:-}" ]; then
            printf 'VM_MAINTAIN_VMS=%q\nexport VM_MAINTAIN_VMS\n' "$VM_MAINTAIN_VMS"
        fi
        printf 'log=%q\n' "$RUNNER_DIR/vm-maintain-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/vm/vm-maintain-cadence.sh"
    } > "$runner" || { echo "ERR vm-maintain-cadence: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR vm-maintain-cadence: cannot chmod the runner $runner" >&2; return 4; }
    crontab_locked_rmw "$CRONTAB_BIN" arm_edit || return $?
    echo "vm-maintain-cadence ARMED: weekly day $day $time - $runner (status: bash scripts/vm/vm-maintain-cadence.sh status)"
}

cmd_status() {
    local last
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    last="$(ls -1t "$STATE_DIR/cadence-last-run.log" 2>/dev/null)"
    [ -z "$last" ] || echo "  last run   $(date -r "$last" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "vm-maintain-cadence: nothing armed - disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY vm-maintain-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    crontab_locked_rmw "$CRONTAB_BIN" disarm_edit || return $?
    rm -f "$RUNNER_DIR/vm-maintain-cadence.sh"
    echo "vm-maintain-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run)
        mkdir -p "$STATE_DIR" || exit 2
        LOGF="$STATE_DIR/cadence-last-run.log"
        cmd_run "$@" 2>&1 | tee "$LOGF"
        exit "${PIPESTATUS[0]}" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: vm-maintain-cadence.sh <run|arm|status|disarm>" >&2; exit 64 ;;
esac
