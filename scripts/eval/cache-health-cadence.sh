#!/usr/bin/env bash
# cache-health-cadence.sh — hourly scripted prompt-cache health check.
#
# WHY: a prompt-cache break silently multiplies cost until someone runs a probe
# by hand. This runs cache-health.py (no LLM, no claude -p) on a cron cadence,
# writes ~/.himmel/state/cache-health/metrics.json, and notifies ONLY on a real
# threshold crossing: one Telegram DM and one line in the live chief's bridge
# inbox. Hysteresis and thresholds live in cache-health.py.
#
#   cache-health-cadence.sh run     [--repo <path>] [--chief <session>] [--dry-run]
#   cache-health-cadence.sh notify  <message>      (what cache-health.py calls)
#   cache-health-cadence.sh arm     [--minute 0-59] [--every-hours 1|2|3|4|6|8|12] [--force] [--dry-run]
#   cache-health-cadence.sh status
#   cache-health-cadence.sh disarm  [--dry-run]
#
# The live chief is resolved at RUN time: the newest held
# `*-chief` queue lock from `queue-lock.sh status --sweep`; --chief pins one.
# Delivery: Telegram via vault-stall-alert.sh and the inbox
# `<bridge root>/consoles/<session>.md` (append-only, never created). `notify`
# exits 0 when EITHER channel delivered; a failed run alerts via cadence-alert.sh.
#
# ponytail: one delivered channel counts as delivered, so a Telegram outage with a live inbox is not retried on Telegram, upgrade path: per-channel sentinels if outages recur.
#
# OFF by default: only `arm` installs it; arming on a station is an operator step
# after a VM proof.
#
# Seams (tests): CACHE_HEALTH_STATE_DIR, CACHE_HEALTH_ROOT (transcripts),
# CACHE_HEALTH_NOW, CACHE_HEALTH_CRONTAB, CACHE_HEALTH_RUNNER_DIR,
# CACHE_HEALTH_SWEEP_CMD, CACHE_HEALTH_TELEGRAM_CMD, BRIDGE_ROOT, plus
# cadence-alert.sh's CADENCE_ALERT_*. Platform: cron (Linux/macOS).
set -uo pipefail

TASK_NAME="HIMMEL-CacheHealth"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$SCRIPT_DIR/../luna/cadence-alert.sh"
STATE_DIR="${CACHE_HEALTH_STATE_DIR:-${HOME:-}/.himmel/state/cache-health}"
CRONTAB_BIN="${CACHE_HEALTH_CRONTAB:-crontab}"
RUNNER_DIR="${CACHE_HEALTH_RUNNER_DIR:-${HOME:-}/.claude/cache-health-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# live_chief <repo>: newest held *-chief / *-console queue lock's session name ("" if none).
live_chief() {
    local line slug age st best="" best_age=-1
    while IFS= read -r line; do
        case "$line" in slug=*) ;; *) continue ;; esac
        slug="${line#slug=}"; slug="${slug%% *}"
        age="${line#*age=}"; age="${age%%s *}"
        st="${line##*status=}"
        case "$slug" in *-console|*-chief) ;; *) continue ;; esac
        case "$st" in OK|'IDLE-HELD?') ;; *) continue ;; esac
        [[ "$age" =~ ^[0-9]+$ ]] || continue
        if [ "$best_age" -lt 0 ] || [ "$age" -lt "$best_age" ]; then best="${slug##*__}"; best_age="$age"; fi
    done < <(if [ -n "${CACHE_HEALTH_SWEEP_CMD:-}" ]; then "$CACHE_HEALTH_SWEEP_CMD" 2>/dev/null
             else bash "$1/scripts/handover/queue-lock.sh" status --sweep 2>/dev/null; fi)
    printf '%s' "$best"
}

# cmd_notify <message>: Telegram + chief inbox; 0 when either delivered.
cmd_notify() {
    local msg="${1:-}" repo chief root inbox ok=1 tg
    [ -n "$msg" ] || { echo "ERR cache-health: notify needs a message" >&2; return 64; }
    repo="${CACHE_HEALTH_REPO:-$(resolve_primary)}" || repo=""
    tg="${CACHE_HEALTH_TELEGRAM_CMD:-$SCRIPT_DIR/../luna/vault-stall-alert.sh}"
    if "$tg" "$msg"; then ok=0; else echo "cache-health: Telegram send failed" >&2; fi
    chief="${CACHE_HEALTH_CHIEF:-}"
    [ -n "$chief" ] || { [ -z "$repo" ] || chief="$(live_chief "$repo")"; }
    root="${BRIDGE_ROOT:-${HOME:-}/.claude/handover/bridge}"
    if [ -n "$chief" ]; then
        inbox="$root/consoles/$chief.md"
        if [ -f "$inbox" ] && printf -- '- %s [cache-health] %s\n' "$(date +%H:%M)" "$(printf '%s' "$msg" | tr '\n' ' ')" >> "$inbox"; then
            ok=0
        else
            echo "cache-health: no inbox for chief $chief" >&2
        fi
    else
        echo "cache-health: no live chief" >&2
    fi
    return "$ok"
}

cmd_run() {
    local repo="" chief="" dry=0 rc
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|--chief)
                [ $# -ge 2 ] || { echo "ERR cache-health: $1 needs a value" >&2; return 64; }
                case "$1" in --repo) repo="$2" ;; --chief) chief="$2" ;; esac
                shift 2 ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR cache-health: unknown arg: $1" >&2; return 64 ;;
        esac
    done
    [ -n "$repo" ] || repo="$(resolve_primary)" || { echo "ERR cache-health: cannot resolve the repo" >&2; return 64; }
    export CACHE_HEALTH_REPO="$repo"
    [ -z "$chief" ] || export CACHE_HEALTH_CHIEF="$chief"
    local args=(check --state-dir "$STATE_DIR" --notify-cmd "bash $(printf '%q' "$SCRIPT_DIR/cache-health-cadence.sh") notify")
    [ -z "${CACHE_HEALTH_ROOT:-}" ] || args+=(--root "$CACHE_HEALTH_ROOT")
    [ -z "${CACHE_HEALTH_NOW:-}" ] || args+=(--now "$CACHE_HEALTH_NOW")
    [ "$dry" -eq 0 ] || args+=(--dry-run)
    python3 -I "$SCRIPT_DIR/cache-health.py" "${args[@]}"
    rc=$?
    [ "$dry" -eq 0 ] || return "$rc"
    if [ "$rc" -ne 0 ]; then
        bash "$ALERT" fail cache-health "rc-$rc" "$STATE_DIR"
        return 1
    fi
    bash "$ALERT" clear cache-health
    return 0
}

cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR cache-health: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local minute=7 every=1 force=0 dry=0 root runner bash_bin entry hours
    while [ $# -gt 0 ]; do
        case "$1" in
            --minute|--every-hours)
                [ $# -ge 2 ] || { echo "ERR cache-health: $1 needs a value" >&2; return 1; }
                case "$1" in --minute) minute="$2" ;; --every-hours) every="$2" ;; esac
                shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR cache-health: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]] || { echo "ERR cache-health: --minute must be 0-59, got: $minute" >&2; return 1; }
    [[ "$every" =~ ^(1|2|3|4|6|8|12)$ ]] || { echo "ERR cache-health: --every-hours must divide 24 (1 2 3 4 6 8 12), got: $every" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR cache-health: cron only; Windows is parked" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR cache-health: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR cache-health: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR cache-health: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/cache-health-cadence.sh"
    hours="*"; [ "$every" -eq 1 ] || hours="*/$every"
    entry="$minute $hours * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY cache-health: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# cache-health-cadence runner — generated by cache-health-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/cache-health-cadence.log"
        printf '[ -f "$log" ] && [ "$(wc -c < "$log")" -gt 1000000 ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run --repo %q >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/eval/cache-health-cadence.sh" "$root"
    } > "$runner" || { echo "ERR cache-health: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR cache-health: cannot chmod the runner $runner" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR cache-health: crontab install failed" >&2; return 4; }
    echo "cache-health-cadence ARMED: minute $minute every $every h — $runner (status: bash scripts/eval/cache-health-cadence.sh status)"
}

cmd_status() {
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    [ ! -f "$STATE_DIR/metrics.json" ] || echo "  last run   $(date -r "$STATE_DIR/metrics.json" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "cache-health-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY cache-health: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/cache-health-cadence.sh"
    echo "cache-health-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    notify) cmd_notify "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: cache-health-cadence.sh <run|notify|arm|status|disarm>" >&2; exit 64 ;;
esac
