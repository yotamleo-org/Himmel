#!/usr/bin/env bash
# vault-sweep-cadence.sh — the luna vault's scheduled committer: cron runs the
# template's sweeper (vault-autosync.sh) every 10 min, so the vault commits and
# pushes without Obsidian's github-sync plugin.
#
#   vault-sweep-cadence.sh arm [--vault PATH] [--force] [--dry-run]
#   vault-sweep-cadence.sh run          one pass now, through the armed runner
#   vault-sweep-cadence.sh status
#   vault-sweep-cadence.sh disarm [--dry-run]
#
# The vault defaults to $LUNA_VAULT_PATH, else ~/Documents/luna.
#
# The generated runner sets LUNA_VAULT_AUTOSYNC=1 and points LUNA_VAULT_ALERT_CMD
# at scripts/luna/vault-stall-alert.sh (the live chief first, Telegram when no
# chief is live). The stall threshold defaults to 45 min, past the stall
# cadence's own 25 min + 15 min cron, so a known-benign refusal is repaired
# before it is reported. Both env values can be overridden in the runner's env.
#
# Single writer: github-sync commits the same tree, so arm refuses while it is
# listed in the vault's .obsidian/community-plugins.json. The runner and
# vault-stall-cadence.sh both take <git-dir>/vault-writer.lock (flock -n): a
# run that finds it held skips.
#
# Exit (arm): 0 armed (or dry-run), 1 bad argument, 2 environment (Windows, no crontab or
# flock, not a git repo, no primary checkout, sweeper missing), 3 already armed (no --force),
# 4 crontab read/write or runner write failed, 5 github-sync is enabled in the vault,
# 77 refused by the test guard. run: the runner's own rc (0 committed/clean/busy), 2 not armed.
# disarm: 0 (also nothing armed), 4 crontab write failed, 77 test guard.
# Seams (tests): VAULT_SWEEP_CRONTAB, VAULT_SWEEP_RUNNER_DIR, VAULT_SWEEP_ROOT (the checkout whose
# scripts the runner bakes in, instead of the primary checkout).
# Platform: cron (Linux/macOS). Windows development is parked.
set -uo pipefail

TASK_NAME="HIMMEL-VaultSweep"
WORKER="vault-sweep"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/observability-registry.sh
. "$SCRIPT_DIR/../lib/observability-registry.sh"
CRONTAB_BIN="${VAULT_SWEEP_CRONTAB:-crontab}"
RUNNER_DIR="${VAULT_SWEEP_RUNNER_DIR:-${HOME:-}/.claude/vault-sweep-cadence}"
RUNNER="$RUNNER_DIR/vault-sweep-cadence.sh"

default_vault() { printf '%s\n' "${LUNA_VAULT_PATH:-${HOME:-}/Documents/luna}"; }

resolve_primary() {
    local common
    if [ -n "${VAULT_SWEEP_ROOT:-}" ]; then printf '%s\n' "$VAULT_SWEEP_ROOT"; return 0; fi
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

github_sync_on() {
    [ -f "$1/.obsidian/community-plugins.json" ] && grep -q '"github-sync"' "$1/.obsidian/community-plugins.json"
}

cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR vault-sweep: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local force=0 dry=0 vault root gitdir bash_bin entry sweeper
    vault="$(default_vault)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --vault) [ $# -ge 2 ] || { echo "ERR vault-sweep: --vault needs a path" >&2; return 1; }
                     vault="$2"; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR vault-sweep: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR vault-sweep: cron only; Windows is parked" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR vault-sweep: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    command -v flock >/dev/null 2>&1 || { echo "ERR vault-sweep: flock not on PATH (every run needs it; on macOS: brew install flock)" >&2; return 2; }
    gitdir="$(git -C "$vault" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "ERR vault-sweep: not a git repo: $vault" >&2; return 2; }
    vault="$(cd "$vault" && pwd -P)" || return 2
    if github_sync_on "$vault"; then
        echo "ERR vault-sweep: github-sync is enabled in $vault/.obsidian/community-plugins.json - remove it first (one writer per vault)" >&2
        return 5
    fi
    root="$(resolve_primary)" || { echo "ERR vault-sweep: cannot resolve the primary checkout" >&2; return 2; }
    sweeper="$root/templates/luna-second-brain/scripts/vault-autosync.sh"
    [ -f "$sweeper" ] || { echo "ERR vault-sweep: the sweeper is missing: $sweeper" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR vault-sweep: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    local pct='%' q="'" quoted
    quoted="'${RUNNER//"$q"/"'\\''"}'"
    entry="*/10 * * * * ${quoted//"$pct"/\\%} # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY vault-sweep: would write $RUNNER and install: $entry"
        return 0
    fi
    local guard_rc=0
    bash "$SCRIPT_DIR/../lib/test-run-guard" check --tool "$CRONTAB_BIN" vault-sweep-cadence-arm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log and $_rc stay literal
    {
        printf '#!/usr/bin/env bash\n# vault-sweep runner — generated by vault-sweep-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'export LUNA_VAULT_AUTOSYNC=1\n'
        printf '_alert=%q\n' "$root/scripts/luna/vault-stall-alert.sh"
        printf 'export LUNA_VAULT_ALERT_CMD="${LUNA_VAULT_ALERT_CMD:-$_alert}"\n'
        printf 'export LUNA_VAULT_STALL_THRESHOLD_MIN="${LUNA_VAULT_STALL_THRESHOLD_MIN:-45}"\n'
        printf 'log=%q\n' "$RUNNER_DIR/vault-sweep-cadence.log"
        printf 'exec 9>%q || { echo "vault-sweep: cannot open the writer lock" >> "$log"; exit 2; }\n' "$gitdir/vault-writer.lock"
        printf 'flock -n 9; _lk=$?\n'
        printf '[ "$_lk" -eq 1 ] && { echo "vault-sweep: busy (another vault writer holds the lock)" >> "$log"; exit 0; }\n'
        printf '[ "$_lk" -eq 0 ] || { echo "vault-sweep: flock failed rc=$_lk" >> "$log"; exit 2; }\n'
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf 'cd %q || exit 2\n' "$vault"
        printf '%q %q >> "$log" 2>&1\n' "$bash_bin" "$sweeper"
        printf '_rc=$?\necho "[exit rc=$_rc]" >> "$log"\nexit "$_rc"\n'
    } > "$RUNNER" || { echo "ERR vault-sweep: cannot write the runner $RUNNER" >&2; return 4; }
    chmod +x "$RUNNER" || { echo "ERR vault-sweep: cannot chmod the runner $RUNNER" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR vault-sweep: crontab install failed" >&2; return 4; }
    observability_register_cadence "$WORKER" 600 "$TASK_NAME"
    echo "vault-sweep ARMED: every 10 min — $RUNNER (status: bash scripts/luna/vault-sweep-cadence.sh status)"
}

cmd_run() {
    [ -x "$RUNNER" ] || { echo "ERR vault-sweep: not armed (no runner at $RUNNER)" >&2; return 2; }
    "$RUNNER"
}

cmd_status() {
    local entry n log="$RUNNER_DIR/vault-sweep-cadence.log"
    cron_read || return 1
    entry="$(cron_entry | head -1)"
    if [ -z "$entry" ]; then echo "not armed  $TASK_NAME"; return 0; fi
    n="$(cron_entry | grep -c . || true)"
    echo "ARMED      $TASK_NAME ($(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}'))$([ "$n" -gt 1 ] && echo " [DUPLICATE: $n cron entries]")"
    if [ -f "$log" ]; then
        echo "  run log    $log (last write: $(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'))"
        echo "             last line: $(tail -n 1 "$log" 2>/dev/null | tr -d '\r')"  # read-sink-ok: the runner's own log path, never argv or env
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "vault-sweep: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY vault-sweep: would remove the $TASK_NAME crontab entry"; return 0; fi
    local guard_rc=0
    bash "$SCRIPT_DIR/../lib/test-run-guard" check --tool "$CRONTAB_BIN" vault-sweep-cadence-disarm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER"
    observability_unregister_cadence "$WORKER" "$TASK_NAME"
    echo "vault-sweep: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    arm) cmd_arm "$@" ;;
    run) cmd_run ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: vault-sweep-cadence.sh <arm|run|status|disarm>" >&2; exit 1 ;;
esac
