#!/usr/bin/env bash
# failure-review-cadence.sh — the daily failure review on a schedule.
#
# WHY: the failure loop records failures on every worker close and the router (failure_router.py) turns
# recurring classes into tickets, but nothing ran the router or showed the operator what failed.
# This is the daily run; failure_review.py is the work. No model is ever run.
#
#   failure-review-cadence.sh run                      one pass (what cron fires)
#   failure-review-cadence.sh arm [--time HH:MM] [--vault PATH] [--live] [--force] [--dry-run]
#   failure-review-cadence.sh status
#   failure-review-cadence.sh disarm [--dry-run]
#
# DRY-RUN BY DEFAULT: a scheduled run passes the router's dry-run, so it files nothing and calls no
# Jira. Live routing is an install-time opt-in: `arm --live` bakes --live into the runner, and
# `arm --force` without it goes back to dry-run. The digest names the mode on every run.
# `arm --live` also bakes the current JIRA_PROJECT_KEY into the runner (cron has none) and refuses
# when it is unset or not a project key; dry-run needs no key.
#
# `run` asks scripts/lib/usage-preflight.sh first, like every pipeline cadence worker, and branches on
# its verdict token: SKIPPED-BANK skips the night (logged, rc 0); every other verdict runs. It then
# runs failure_review.py from the PRIMARY checkout (the runner bakes that path) and, on a router
# failure, alerts through scripts/luna/cadence-alert.sh; a clean run clears that alert.
#
# Seams (tests): FAILREV_CRONTAB, FAILREV_RUNNER_DIR, FAILURE_REVIEW_PREFLIGHT, plus
# failure_review.py's own (HIMMEL_FAILURE_REVIEW_DIR, FAILURE_REVIEW_NOTIFY_CMD) and the router's.
# Platform: cron (Linux/macOS). Windows development is parked.
set -uo pipefail

TASK_NAME="HIMMEL-FailureReview"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CRONTAB_BIN="${FAILREV_CRONTAB:-crontab}"
RUNNER_DIR="${FAILREV_RUNNER_DIR:-${HOME:-}/.claude/failure-review-cadence}"
# shellcheck source=../../lib/resolve-user-home.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/resolve-user-home.sh"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# Digest the last week's sessions that no worker close digested (chiefs, judges, interactive) before the review reads the
# ledgers. A session already digested is skipped, so a daily pass only does the new ones; a failure here never stops the review.
#
# The whole pass is bounded (FAILURE_REVIEW_DIGEST_BOUND, default 1800 s; rc 124 when cut). A session idle under six hours is left for
# the next night (--live-minutes 360), because an ok digest of a resumed session would freeze it before its later failures land.
# A failed or cut digest is logged and goes through cadence-alert as its own worker, apart from the review's.
digest_sessions() {
    local since rc=0 bf=(python3 "$SCRIPT_DIR/worker_ledger.py")
    [ -z "${FAILURE_REVIEW_BACKFILL:-}" ] || bf=("$FAILURE_REVIEW_BACKFILL")
    since="$(date -u -d '7 days ago' +%F 2>/dev/null || date -u -v-7d +%F 2>/dev/null)"
    [ -n "$since" ] || { echo "failure-review-cadence: session digest skipped, no date for the window"; return 0; }
    # shellcheck source=../../lib/timeout-bin.sh
    # shellcheck disable=SC1091
    . "$ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null
    # ponytail: no timeout binary means no bound (a stock macOS host), upgrade path: a bash watchdog.
    ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 10 "${FAILURE_REVIEW_DIGEST_BOUND:-1800}"} "${bf[@]}" backfill --since "$since" --live-minutes 360 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "failure-review-cadence: session digest failed (exit $rc), the review goes on"
        bash "$ROOT/scripts/luna/cadence-alert.sh" fail failure-review-digest "the daily session digest failed (exit $rc)" "$RUNNER_DIR/failure-review-cadence.log" \
            "the digest of the last week's sessions stopped, so some sessions are missing from the ledgers" "read the log for the error, then run worker_ledger.py backfill by hand"
    else
        bash "$ROOT/scripts/luna/cadence-alert.sh" clear failure-review-digest
    fi
}

# cmd_run takes failure_review.py's own flags (the runner passes --vault and, when armed so, --live).
cmd_run() {
    local verdict rc
    verdict="$(bash "${FAILURE_REVIEW_PREFLIGHT:-$ROOT/scripts/lib/usage-preflight.sh}" 2>/dev/null | tail -n 1)"
    echo "failure-review-cadence: bank preflight ${verdict:-<none>}"
    if [ "$verdict" = "SKIPPED-BANK" ]; then
        echo "failure-review-cadence: SKIPPED-BANK, no run tonight"
        return 0
    fi
    digest_sessions
    python3 "$SCRIPT_DIR/failure_review.py" "$@"; rc=$?
    if [ "$rc" -eq 3 ]; then
        bash "$ROOT/scripts/luna/cadence-alert.sh" fail failure-review "the daily failure review ran, but its Telegram message was not delivered (exit $rc)" "$RUNNER_DIR/failure-review-cadence.log" \
            "the digest is written; only the send failed" "nothing, the undelivered line is sent again at the next run"
    elif [ "$rc" -ne 0 ]; then
        bash "$ROOT/scripts/luna/cadence-alert.sh" fail failure-review "the daily failure review failed (exit $rc)" "$RUNNER_DIR/failure-review-cadence.log" \
            "the review or its ticket router stopped part-way, so today's digest may be missing" "read the log for the error, then rerun the cadence runner by hand"
    else
        bash "$ROOT/scripts/luna/cadence-alert.sh" clear failure-review
    fi
    return "$rc"
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
        *) echo "ERR failure-review-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local time="06:15" vault="" live=0 force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --time|--vault) [ $# -ge 2 ] || { echo "ERR failure-review-cadence: $1 needs a value" >&2; return 1; }
                    if [ "$1" = --time ]; then time="$2"; else vault="$2"; fi; shift 2 ;;
            --live) live=1; shift ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR failure-review-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR failure-review-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    # The router fails closed without a project key and cron has none, so a live runner carries it.
    if [ "$live" -eq 1 ]; then
        [[ "${JIRA_PROJECT_KEY:-}" =~ ^[A-Z][A-Z0-9]+$ ]] || { echo "ERR failure-review-cadence: --live needs JIRA_PROJECT_KEY set to a project key (got: ${JIRA_PROJECT_KEY:-<unset>})" >&2; return 2; }
    fi
    [ -n "$vault" ] || vault="$(default_vault)"
    [ -d "$vault" ] || { echo "ERR failure-review-cadence: vault not found: $vault (pass --vault)" >&2; return 1; }
    # cron runs from $HOME, so the runner gets the absolute path.
    vault="$(cd "$vault" && pwd)" || { echo "ERR failure-review-cadence: cannot resolve the vault path" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR failure-review-cadence: cron only; Windows is parked" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR failure-review-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR failure-review-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR failure-review-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/failure-review-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY failure-review-cadence: would write $runner ($([ "$live" -eq 1 ] && echo live || echo dry-run) routing) and install: $entry"
        return 0
    fi
    # A test on the station never writes the real crontab or a runner under the real home; only exit 77 refuses.
    local guard_rc=0
    bash "$SCRIPT_DIR/../../lib/test-run-guard" check --tool "$CRONTAB_BIN" failure-review-cadence-arm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    mkdir -p "$RUNNER_DIR" || return 4
    # The new runner goes in beside the old one and replaces it only once the crontab is installed:
    # a failed install must leave the armed schedule running the runner it was armed with.
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# failure-review-cadence runner — generated by failure-review-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        [ "$live" -eq 1 ] && printf 'JIRA_PROJECT_KEY=%q\nexport JIRA_PROJECT_KEY\n' "$JIRA_PROJECT_KEY"
        printf 'log=%q\n' "$RUNNER_DIR/failure-review-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf 'echo "[fired $(date "+%%F %%T")]" >> "$log"\n'
        printf '%q %q run --vault %q%s >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/eval/worker-digest/failure-review-cadence.sh" \
            "$vault" "$([ "$live" -eq 1 ] && printf ' --live')"
    } > "$runner.new" || { rm -f "$runner.new"; echo "ERR failure-review-cadence: cannot write the runner $runner.new" >&2; return 4; }
    chmod +x "$runner.new" || { rm -f "$runner.new"; echo "ERR failure-review-cadence: cannot chmod the runner $runner.new" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { rm -f "$runner.new"; echo "ERR failure-review-cadence: crontab install failed" >&2; return 4; }
    if ! mv -f "$runner.new" "$runner"; then
        rm -f "$runner.new"
        # The new entry must not outlive its runner: put the crontab back as it was read.
        { printf '%s\n' "$CRON_TAB" | sed '/^$/d'; } | "$CRONTAB_BIN" - \
            || echo "ERR failure-review-cadence: could not restore the previous crontab; check 'crontab -l'" >&2
        echo "ERR failure-review-cadence: cannot install the runner $runner (crontab restored)" >&2
        return 4
    fi
    echo "failure-review-cadence ARMED: daily $time, $([ "$live" -eq 1 ] && echo LIVE || echo dry-run) routing — $runner"
}

cmd_status() {
    local runner="$RUNNER_DIR/failure-review-cadence.sh" mode=dry-run
    cron_read || return 1
    grep -q -- '--live' "$runner" 2>/dev/null && mode=live
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'), $mode routing)"
    else echo "not armed  $TASK_NAME"; fi
    [ -f "$RUNNER_DIR/failure-review-cadence.log" ] && echo "  last run   $(tail -n 1 "$RUNNER_DIR/failure-review-cadence.log")"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "failure-review-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY failure-review-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    # A test on the station never writes the real crontab or a runner under the real home; only exit 77 refuses.
    local guard_rc=0
    bash "$SCRIPT_DIR/../../lib/test-run-guard" check --tool "$CRONTAB_BIN" failure-review-cadence-disarm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/failure-review-cadence.sh"
    echo "failure-review-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: failure-review-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
