#!/usr/bin/env bash
# morning-report-cadence.sh — write the morning report every morning.
#
# WHY: nothing ever scheduled scripts/handover/generate-morning-briefing.sh,
# so a report existed only when a session ran it by hand. himmel-update arms
# this cadence.
#
#   morning-report-cadence.sh run
#   morning-report-cadence.sh arm [--time HH:MM] [--force] [--dry-run] [--auto]
#   morning-report-cadence.sh status
#   morning-report-cadence.sh disarm [--dry-run]
#
# `run` calls the generator with no flags: it writes
# $HANDOVER_DIR/morning-report-<local date>.md. That default run starts no
# Claude session (no --llm), so a run costs 0 Claude tokens; it only calls gh
# and the Jira CLI through the generator. A cron job has neither the shell's
# HANDOVER_DIR nor its PATH, so `arm` bakes both into the runner.
#
# `disarm` leaves a marker; `arm --auto` (what himmel-update runs) is a quiet no-op
# when already armed or when the operator disarmed, so an update never re-arms what
# the operator turned off. A plain `arm` clears the marker.
#
# Exit: 0 ok (arm --auto also 0 when already armed or operator-disarmed);
# 1 usage or bad --time; 2 run: HANDOVER_DIR unset, or no cron / no checkout;
# 3 arm: already armed (use --force); 4 crontab or runner write failed;
# 5 arm: no handover root from the shell or the primary .env; 77 test-run guard refusal.
#
# Seams (tests): MORNINGREPORT_CRONTAB, MORNINGREPORT_RUNNER_DIR, MORNINGREPORT_GENERATOR.
# Platform: cron (Linux, macOS).
set -uo pipefail

TASK_NAME="HIMMEL-MorningReport"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRONTAB_BIN="${MORNINGREPORT_CRONTAB:-crontab}"
RUNNER_DIR="${MORNINGREPORT_RUNNER_DIR:-${HOME:-}/.claude/morning-report-cadence}"
# shellcheck source=../lib/git-clean.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
# shellcheck source=../lib/crontab-locked-rmw.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/crontab-locked-rmw.sh"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1 # swallow-ok: failure returns 1 on this line
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd) # swallow-ok: caller checks for an empty result
}

# The handover root: the shell's value wins, else the primary checkout's .env.
resolve_root() { # <primary>
    if [ -z "${HANDOVER_DIR:-}" ]; then load_dotenv --root "$1" HANDOVER_DIR >/dev/null 2>&1 || true; fi
    [ -n "${HANDOVER_DIR:-}" ] && printf '%s\n' "$HANDOVER_DIR"
}

cmd_run() {
    local root gen
    if [ -z "${HANDOVER_DIR:-}" ]; then
        echo "ERR morning-report-cadence: HANDOVER_DIR is not set; nothing written" >&2
        return 2
    fi
    root="$(resolve_primary)" || { echo "ERR morning-report-cadence: cannot resolve the primary checkout" >&2; return 2; }
    gen="${MORNINGREPORT_GENERATOR:-$root/scripts/handover/generate-morning-briefing.sh}"
    (cd "$root" && bash "$gen" </dev/null)
}

cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR morning-report-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

# The edit steps run under crontab_locked_rmw on the table it just read;
# $force, $auto and $entry are cmd_arm's locals, visible because cmd_arm is on the call stack.
arm_edit() {
    # --auto never fails on an armed table: another run armed it since the early check.
    if [ -n "$(cron_entry)" ] && [ "$auto" -eq 1 ]; then printf '%s\n' "$CRON_TAB"; return 0; fi
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR morning-report-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; }
}
disarm_edit() { { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; }; }

cmd_arm() {
    local time="07:10" force=0 dry=0 auto=0 root runner entry ho
    while [ $# -gt 0 ]; do
        case "$1" in
            --time) [ $# -ge 2 ] || { echo "ERR morning-report-cadence: --time needs a value" >&2; return 1; }
                    time="$2"; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            --auto) auto=1; shift ;;
            *) echo "ERR morning-report-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR morning-report-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR morning-report-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR morning-report-cadence: cannot resolve the primary checkout" >&2; return 2; }
    ho="$(resolve_root "$root")" || { echo "ERR morning-report-cadence: no handover root (HANDOVER_DIR) from the shell or the primary .env; not armed" >&2; return 5; }
    cron_read || return 4
    if [ "$auto" -eq 1 ]; then
        [ -z "$(cron_entry)" ] || { echo "morning-report-cadence: already armed"; return 0; }
        [ ! -f "$RUNNER_DIR/.operator-disarmed" ] || { echo "morning-report-cadence: operator disarmed it; not re-arming"; return 0; }
    fi
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR morning-report-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/morning-report-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY morning-report-cadence: would write $runner and install: $entry"
        return 0
    fi
    # A test on the station never writes the real crontab or a runner under the real home; only exit 77 refuses.
    local guard_rc=0
    bash "$SCRIPT_DIR/../lib/test-run-guard" check --tool "$CRONTAB_BIN" morning-report-cadence-arm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# morning-report-cadence runner — generated by morning-report-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'HANDOVER_DIR=%q\nexport HANDOVER_DIR\n' "$ho"
        printf 'log=%q\n' "$RUNNER_DIR/morning-report-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run >> "$log" 2>&1\n' "$(command -v bash)" "$root/scripts/handover/morning-report-cadence.sh"
        printf '_rc=$?\necho "[exit rc=$_rc]" >> "$log"\nexit "$_rc"\n'
    } > "$runner" || { echo "ERR morning-report-cadence: cannot write the runner $runner" >&2; return 4; }
    chmod 700 "$runner" || return 4
    rm -f "$RUNNER_DIR/.operator-disarmed"
    crontab_locked_rmw "$CRONTAB_BIN" arm_edit || return $?
    echo "morning-report-cadence ARMED: daily $time — $runner (status: bash scripts/handover/morning-report-cadence.sh status)"
}

cmd_status() {
    local entry n dup="" root ho newest log mtime last
    cron_read || return 1
    entry="$(cron_entry | head -1)"
    if [ -n "$entry" ]; then
        n="$(cron_entry | grep -c . || true)" # swallow-ok: no match means zero entries
        [ "$n" -gt 1 ] && dup=" [DUPLICATE: $n cron entries]"
        echo "ARMED      $TASK_NAME ($(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}'))$dup"
        log="$RUNNER_DIR/morning-report-cadence.log"
        if [ -f "$log" ]; then
            mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?') # swallow-ok: an unreadable mtime prints ?
            last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r') # read-sink-ok: this cadence runner's own log # swallow-ok: a missing last line prints nothing
            echo "  run log    $log (last write: $mtime)"
            [ -z "$last" ] || echo "             last line: $last"
        else echo "  run log    $log (absent — task has not fired yet)"; fi
    else echo "not armed  $TASK_NAME"; fi
    root="$(resolve_primary 2>/dev/null)" || root="" # swallow-ok: status still prints without a checkout
    if ho="$(resolve_root "$root")" && [ -d "$ho" ]; then
        # shellcheck disable=SC2012  # names are morning-report-YYYY-MM-DD.md only
        newest="$(ls "$ho"/morning-report-????-??-??.md 2>/dev/null | sort | tail -n 1)" # swallow-ok: no report reads as none
        echo "  newest     ${newest:-none} (in $ho)"
    else echo "  newest     unknown (no handover root)"; fi
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ "$dry" -eq 1 ]; then echo "DRY morning-report-cadence: would remove the $TASK_NAME crontab entry and keep it off"; return 0; fi
    local guard_rc=0
    bash "$SCRIPT_DIR/../lib/test-run-guard" check --tool "$CRONTAB_BIN" morning-report-cadence-disarm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    # A disarm before the first arm still counts: the marker stops the update step from arming it.
    if [ -z "$(cron_entry)" ]; then
        mkdir -p "$RUNNER_DIR" || return 4
        : > "$RUNNER_DIR/.operator-disarmed" || { echo "ERR morning-report-cadence: cannot write the disarm marker in $RUNNER_DIR" >&2; return 4; }
        echo "morning-report-cadence: nothing armed; it stays off until you run arm"
        return 0
    fi
    crontab_locked_rmw "$CRONTAB_BIN" disarm_edit || return $?
    rm -f "$RUNNER_DIR/morning-report-cadence.sh"
    : > "$RUNNER_DIR/.operator-disarmed" || { echo "ERR morning-report-cadence: disarmed, but cannot write the marker in $RUNNER_DIR; an update may re-arm it" >&2; return 4; }
    echo "morning-report-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: morning-report-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
