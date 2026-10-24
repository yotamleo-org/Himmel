#!/usr/bin/env bash
# judge-accuracy-cadence.sh — the weekly judge-accuracy run and review-page render on a schedule.
#
# WHY: judge_accuracy.py (the weekly judge-outcome job) and review-page.py (the readable page) were
# built to run weekly, but nothing ran them. This is the weekly run. It draws no model and no bank:
# gh reads PR and main-run state, judge_accuracy.py appends one ledger row and queues new
# adjudication candidates for a judge-ro call to rule, decision-158-answers.py appends the answer row
# for the five open questions, and review-page.py writes the page the
# config-ui serves at GET /api/reviewers.
#
#   judge-accuracy-cadence.sh run --verdicts DIR [--mirror DIR]   one pass (what cron fires)
#   judge-accuracy-cadence.sh arm --verdicts DIR [--day 0-6] [--time HH:MM] [--force] [--dry-run]
#   judge-accuracy-cadence.sh status
#   judge-accuracy-cadence.sh disarm [--dry-run]
#
# `run` reads gh from the PRIMARY checkout (the runner bakes that path), and on a failure alerts
# through scripts/luna/cadence-alert.sh; a clean run clears that alert. Default: Monday 07:30.
#
# Seams (tests): JUDGEACC_CRONTAB, JUDGEACC_RUNNER_DIR, JUDGEACC_GH, REVIEW_PAGE_FILE, plus the
# ledger and queue paths judge_accuracy.py and review-page.py read.
# Platform: cron (Linux/macOS). Windows development is parked.
set -uo pipefail

TASK_NAME="HIMMEL-JudgeAccuracy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CRONTAB_BIN="${JUDGEACC_CRONTAB:-crontab}"
RUNNER_DIR="${JUDGEACC_RUNNER_DIR:-${HOME:-}/.claude/judge-accuracy-cadence}"
GH_BIN="${JUDGEACC_GH:-gh}"
PAGE="${REVIEW_PAGE_FILE:-${HOME:-}/.himmel/state/review-page/review-page.md}"
LOG="$RUNNER_DIR/judge-accuracy-cadence.log"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

alert_fail() {
    bash "$ROOT/scripts/luna/cadence-alert.sh" fail judge-accuracy "the weekly judge-accuracy run failed ($1)" "$LOG" \
        "this week's judge row and review page may be missing" "read the log for the error, then rerun the cadence runner by hand"
}

cmd_run() {
    local verdicts="" mirror="" tmp rc
    while [ $# -gt 0 ]; do
        case "$1" in
            --verdicts) verdicts="${2:-}"; shift 2 ;;
            --mirror) mirror="${2:-}"; shift 2 ;;
            *) echo "ERR judge-accuracy-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [ -n "$verdicts" ] || { echo "ERR judge-accuracy-cadence: run needs --verdicts DIR" >&2; return 1; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/judge-accuracy-cadence.XXXXXX")" || return 1  # prim-ok: cron scratch dir, removed by the RETURN trap below
    # shellcheck disable=SC2064  # $tmp is expanded now on purpose
    trap "rm -rf '$tmp'" RETURN
    if ! (cd "$ROOT" && "$GH_BIN" pr list --state all --limit 3000 --json number,state,mergedAt,headRefOid,mergeCommit >"$tmp/prs.json") ||
       ! (cd "$ROOT" && "$GH_BIN" run list --branch main --limit 1000 --json databaseId,headSha,conclusion,createdAt >"$tmp/runs.json"); then
        echo "judge-accuracy-cadence: gh could not read PR or main-run state" >&2
        alert_fail "gh failed"
        return 3
    fi
    local args=(run --verdicts "$verdicts" --prs "$tmp/prs.json" --main-runs "$tmp/runs.json")
    [ -n "$mirror" ] && args+=(--mirror "$mirror")
    python3 "$SCRIPT_DIR/judge_accuracy.py" "${args[@]}"; rc=$?
    if [ "$rc" -eq 0 ]; then
        python3 "$ROOT/scripts/eval/decision-158-answers.py" --record; rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        mkdir -p "$(dirname "$PAGE")" && python3 "$ROOT/scripts/eval/review-page.py" --out "$PAGE.tmp" && mv -f "$PAGE.tmp" "$PAGE"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        alert_fail "exit $rc"
    else
        bash "$ROOT/scripts/luna/cadence-alert.sh" clear judge-accuracy
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
        *) echo "ERR judge-accuracy-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local time="07:30" day=1 verdicts="" force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --time|--day|--verdicts) [ $# -ge 2 ] || { echo "ERR judge-accuracy-cadence: $1 needs a value" >&2; return 1; }
                    case "$1" in --time) time="$2" ;; --day) day="$2" ;; *) verdicts="$2" ;; esac; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR judge-accuracy-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR judge-accuracy-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    [[ "$day" =~ ^[0-6]$ ]] || { echo "ERR judge-accuracy-cadence: --day must be 0-6, got: $day" >&2; return 1; }
    [ -d "$verdicts" ] || { echo "ERR judge-accuracy-cadence: verdict dir not found: '$verdicts' (pass --verdicts, the bucket's verdicts/ tree)" >&2; return 1; }
    # cron runs from $HOME, so the runner gets the absolute path.
    verdicts="$(cd "$verdicts" && pwd)" || return 1
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR judge-accuracy-cadence: cron only; Windows is parked" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR judge-accuracy-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR judge-accuracy-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR judge-accuracy-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/judge-accuracy-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * $day \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY judge-accuracy-cadence: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # The new runner goes in beside the old one and replaces it only once the crontab is installed.
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# judge-accuracy-cadence runner — generated by judge-accuracy-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$LOG"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf 'echo "[fired $(date "+%%F %%T")]" >> "$log"\n'
        printf '%q %q run --verdicts %q >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/eval/judge-accuracy/judge-accuracy-cadence.sh" "$verdicts"
    } > "$runner.new" || { rm -f "$runner.new"; echo "ERR judge-accuracy-cadence: cannot write the runner $runner.new" >&2; return 4; }
    chmod +x "$runner.new" || { rm -f "$runner.new"; echo "ERR judge-accuracy-cadence: cannot chmod the runner $runner.new" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { rm -f "$runner.new"; echo "ERR judge-accuracy-cadence: crontab install failed" >&2; return 4; }
    if ! mv -f "$runner.new" "$runner"; then
        rm -f "$runner.new"
        { printf '%s\n' "$CRON_TAB" | sed '/^$/d'; } | "$CRONTAB_BIN" - \
            || echo "ERR judge-accuracy-cadence: could not restore the previous crontab; check 'crontab -l'" >&2
        echo "ERR judge-accuracy-cadence: cannot install the runner $runner (crontab restored)" >&2
        return 4
    fi
    echo "judge-accuracy-cadence ARMED: weekly day $day at $time — $runner"
}

cmd_status() {
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    [ -f "$LOG" ] && echo "  last run   $(tail -n 1 "$LOG")"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "judge-accuracy-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY judge-accuracy-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/judge-accuracy-cadence.sh"
    echo "judge-accuracy-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: judge-accuracy-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
