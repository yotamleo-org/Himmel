#!/usr/bin/env bash
# snyk-scan-cadence.sh — weekly station run of snyk-scan.sh.
#
# WHY: Snyk is a second scanner beside pip-audit and the lockfile work, and the
# free plan caps tests per month, so it runs once a week on the station, never
# per PR. A High/Critical finding or a failed scan (snyk missing, not
# authenticated, quota reached) is raised through the shared cadence-alert.sh
# sink so it is never silent; a clean run clears the alert.
#
#   snyk-scan-cadence.sh run   [--repo <path>]    one pass (what cron fires)
#   snyk-scan-cadence.sh arm   [--day 0-6] [--time HH:MM] [--force] [--dry-run]
#   snyk-scan-cadence.sh status
#   snyk-scan-cadence.sh disarm [--dry-run]
#
# `run` scans the PRIMARY checkout (default) and writes the JSON + summary into
# the state repo (see snyk-scan.sh). OFF by default: only `arm` installs it.
# Default schedule: Monday 06:30.
#
# Seams (tests): SNYKCAD_CRONTAB, SNYKCAD_RUNNER_DIR, SNYKCAD_SCAN, SNYK_SCAN_STATE_DIR,
# plus cadence-alert.sh's CADENCE_ALERT_*.
# Platform: cron (Linux). Windows development is parked.
set -uo pipefail

TASK_NAME="HIMMEL-SnykScan"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$SCRIPT_DIR/../luna/cadence-alert.sh"
SCAN="${SNYKCAD_SCAN:-$SCRIPT_DIR/snyk-scan.sh}"
STATE_DIR="${SNYK_SCAN_STATE_DIR:-${HOME:-}/.himmel/state/snyk-scan}"
CRONTAB_BIN="${SNYKCAD_CRONTAB:-crontab}"
RUNNER_DIR="${SNYKCAD_RUNNER_DIR:-${HOME:-}/.claude/snyk-scan-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

cmd_run() {
    local repo="" out rc
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)
                [ $# -ge 2 ] || { echo "ERR snyk-scan-cadence: --repo needs a value" >&2; return 64; }
                repo="$2"; shift 2 ;;
            *) echo "ERR snyk-scan-cadence: unknown arg: $1" >&2; return 64 ;;
        esac
    done
    [ -n "$repo" ] || repo="$(resolve_primary)" || { echo "ERR snyk-scan-cadence: cannot resolve the repo" >&2; return 64; }
    mkdir -p "$STATE_DIR" || return 2
    out="$STATE_DIR/last-run.log"
    bash "$SCAN" --repo "$repo" > "$out" 2>&1
    rc=$?
    cat "$out"
    case "$rc" in
        0) bash "$ALERT" clear snyk-scan; return 0 ;;
        1) bash "$ALERT" fail snyk-scan high-findings "$out"; return 1 ;;
        *) bash "$ALERT" fail snyk-scan "scan-rc-$rc" "$out"; return 1 ;;
    esac
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
        *) echo "ERR snyk-scan-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local day=1 time="06:30" force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --day|--time)
                [ $# -ge 2 ] || { echo "ERR snyk-scan-cadence: $1 needs a value" >&2; return 1; }
                case "$1" in --day) day="$2" ;; --time) time="$2" ;; esac
                shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR snyk-scan-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$day" =~ ^[0-6]$ ]] || { echo "ERR snyk-scan-cadence: --day must be 0-6, got: $day" >&2; return 1; }
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR snyk-scan-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR snyk-scan-cadence: cron only; Windows is parked" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR snyk-scan-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR snyk-scan-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR snyk-scan-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/snyk-scan-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * $day \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY snyk-scan-cadence: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# snyk-scan-cadence runner — generated by snyk-scan-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/snyk-scan-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run --repo %q >> "$log" 2>&1\n' \
            "$bash_bin" "$root/scripts/security/snyk-scan-cadence.sh" "$root"
    } > "$runner" || { echo "ERR snyk-scan-cadence: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR snyk-scan-cadence: cannot chmod the runner $runner" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR snyk-scan-cadence: crontab install failed" >&2; return 4; }
    echo "snyk-scan-cadence ARMED: weekly day $day $time — $runner (status: bash scripts/security/snyk-scan-cadence.sh status)"
}

cmd_status() {
    local last
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    last="$(ls -1t "$STATE_DIR/last-run.log" 2>/dev/null)"
    [ -z "$last" ] || echo "  last run   $(date -r "$last" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "snyk-scan-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY snyk-scan-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/snyk-scan-cadence.sh"
    echo "snyk-scan-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: snyk-scan-cadence.sh <run|arm|status|disarm>" >&2; exit 64 ;;
esac
