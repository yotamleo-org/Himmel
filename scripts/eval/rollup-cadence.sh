#!/usr/bin/env bash
# rollup-cadence.sh — the weekly roll-up job.
#
#   rollup-cadence.sh run   [--repo <path>]                       one pass (what cron fires)
#   rollup-cadence.sh arm   [--day 0-6] [--time HH:MM] [--force] [--dry-run]
#   rollup-cadence.sh status
#   rollup-cadence.sh disarm [--dry-run]
#
# Exit: 0 ok. 1 usage or a bad argument, or status could not read the crontab. 2 arm cannot run here (Windows,
# no crontab binary, no primary checkout). 3 arm found it already armed (--force replaces). 4 a crontab or runner
# write or read failed (arm, disarm). 77 test-run-guard refused a real crontab write from a test. `run` exits
# with weekly-rollup.py's own code when it fails.
set -uo pipefail

TASK_NAME="HIMMEL-WeeklyRollup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CRONTAB_BIN="${ROLLUP_CRONTAB:-crontab}"
RUNNER_DIR="${ROLLUP_RUNNER_DIR:-${HOME:-}/.claude/rollup-cadence}"
ROLLUP_PY="${ROLLUP_PY:-$SCRIPT_DIR/weekly-rollup.py}"
LOG="$RUNNER_DIR/rollup-cadence.log"

# shellcheck source=../lib/crontab-locked-rmw.sh
. "$SCRIPT_DIR/../lib/crontab-locked-rmw.sh" || exit 2

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

cmd_run() {
    local repo="" rc
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo) [ $# -ge 2 ] || { echo "ERR rollup-cadence: --repo needs a value" >&2; return 1; }; repo="$2"; shift 2 ;;
            *) echo "ERR rollup-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [ -n "$repo" ] || repo="$(resolve_primary)" || { echo "ERR rollup-cadence: cannot resolve the repo" >&2; return 1; }
    python3 -I "$ROLLUP_PY" write --repo "$repo" --versions 2
    rc=$?
    if [ "$rc" -ne 0 ]; then
        bash "$ROOT/scripts/luna/cadence-alert.sh" fail rollup "the weekly roll-up run failed (exit $rc)" "$LOG" \
            "the Trends tab keeps last week's numbers" "read the log for the error, then rerun the cadence runner by hand"
        return "$rc"
    fi
    bash "$ROOT/scripts/luna/cadence-alert.sh" clear rollup
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
        *) echo "ERR rollup-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

ARM_FORCE=0
ARM_ENTRY=""
arm_edit() {
    [ -z "$(cron_entry)" ] || [ "$ARM_FORCE" -eq 1 ] || return 3
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$ARM_ENTRY"; }
}
disarm_edit() { { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; }; }

cmd_arm() {
    local time="06:00" day=1 force=0 dry=0 root runner bash_bin entry guard_rc=0 rc was_armed=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --time|--day) [ $# -ge 2 ] || { echo "ERR rollup-cadence: $1 needs a value" >&2; return 1; }
                    case "$1" in --time) time="$2" ;; *) day="$2" ;; esac; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR rollup-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR rollup-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    [[ "$day" =~ ^[0-6]$ ]] || { echo "ERR rollup-cadence: --day must be 0-6, got: $day" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR rollup-cadence: cron only; Windows is parked" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR rollup-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR rollup-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ]; then
        was_armed=1
        if [ "$force" -eq 0 ]; then
            echo "ERR rollup-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
            return 3
        fi
    fi
    runner="$RUNNER_DIR/rollup-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * $day \"${runner//%/\\%}\" # $TASK_NAME"
    ARM_FORCE="$force"; ARM_ENTRY="$entry"
    if [ "$dry" -eq 1 ]; then
        echo "DRY rollup-cadence: would write $runner and install: $entry"
        return 0
    fi
    bash "$SCRIPT_DIR/../lib/test-run-guard" check --tool "$CRONTAB_BIN" rollup-cadence-arm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log and $rc must stay literal
    {
        printf '#!/usr/bin/env bash\n# rollup-cadence runner — generated by rollup-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$LOG"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf 'echo "[fired $(date "+%%F %%T")]" >> "$log"\n'
        printf '%q %q run --repo %q >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/eval/rollup-cadence.sh" "$root"
        printf 'rc=$?\necho "[exit rc=$rc]" >> "$log"\nexit "$rc"\n'
    } > "$runner.new" || { rm -f "$runner.new"; echo "ERR rollup-cadence: cannot write the runner $runner.new" >&2; return 4; }
    chmod +x "$runner.new" || { rm -f "$runner.new"; echo "ERR rollup-cadence: cannot chmod the runner $runner.new" >&2; return 4; }
    mv -f "$runner.new" "$runner" || { rm -f "$runner.new"; echo "ERR rollup-cadence: cannot install the runner $runner" >&2; return 4; }
    crontab_locked_rmw "$CRONTAB_BIN" arm_edit || {
        rc=$?
        [ "$was_armed" -eq 1 ] || [ "$rc" -eq 3 ] || rm -f "$runner"
        case "$rc" in
            3) echo "ERR rollup-cadence: already armed: $TASK_NAME (use --force to replace)" >&2 ;;
            *) echo "ERR rollup-cadence: crontab install failed" >&2; rc=4 ;;
        esac
        return "$rc"
    }
    echo "rollup-cadence ARMED: weekly day $day at $time — $runner"
}

cmd_status() {
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    if [ -f "$LOG" ]; then
        echo "  run log    $LOG (last write: $(date -r "$LOG" '+%F %H:%M'))"
        echo "             last line: $(tail -n 1 "$LOG")"
    fi
    return 0
}

cmd_disarm() {
    local dry=0 guard_rc=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "rollup-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY rollup-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    bash "$SCRIPT_DIR/../lib/test-run-guard" check --tool "$CRONTAB_BIN" rollup-cadence-disarm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    crontab_locked_rmw "$CRONTAB_BIN" disarm_edit || { echo "ERR rollup-cadence: crontab write failed" >&2; return 4; }
    rm -f "$RUNNER_DIR/rollup-cadence.sh"
    echo "rollup-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: rollup-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
