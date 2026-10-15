#!/usr/bin/env bash
# steering-cull-cadence.sh — weekly read-only steering-file cull run.
#
# WHY: steering files grow with every agent mistake and nobody deletes lines;
# without a recurring pass the savings erode within weeks. This runs
# the vendored /writing-for-agents skill over himmel CLAUDE.md,
# ~/.claude/CLAUDE.md, ~/.claude/RTK.md and the auto-memory MEMORY.md index,
# writes a dated PROPOSAL doc, and tells the supervisor session (console) where
# it is. It PROPOSES; it never edits a live file (claude runs with
# --permission-mode plan and only the Read tool).
#
#   steering-cull-cadence.sh run  --proposal-dir <dir> [--console <session>] [--repo <path>]
#   steering-cull-cadence.sh arm  --proposal-dir <dir> [--console <session>]
#                                 [--day 0-6] [--time HH:MM] [--force] [--dry-run]
#   steering-cull-cadence.sh status
#   steering-cull-cadence.sh disarm [--dry-run]
#
# The model emits one line per cut: `- [LOW|MEDIUM] <path>:<lines> — <why>`.
# THIS script classifies, not the model: a cut counts as LOW only when the model
# said LOW and <path> is repo-relative (not a live ~/.claude or memory file);
# every other cut is ESCALATED. The console inbox line
# (`<bridge root>/consoles/<session>.md`, append-only, never created) carries
# the proposal path and the two counts. --console is an OVERRIDE; without it
# the run resolves the live console at RUN time: the newest held
# `*-console` queue lock from `queue-lock.sh status --sweep`, since console
# sessions are renamed on every succession and a general user has none. No live
# console, or no inbox for it, alerts via cadence-alert.sh instead.
#
# ponytail: LOW repo cuts are listed in the proposal doc but not auto-opened as a PR, upgrade path: follow-up ticket for an apply pass in a worktree.
# ponytail: a cut whose path the model mis-spells is escalated rather than counted low (fails safe), upgrade path: none needed unless the escalation volume grows.
#
# OFF by default: only `arm` installs it; arming on a station is an operator
# step after a VM proof. Unattended claude -p draws the same subscription
# budget as interactive use, so a run first asks scripts/lib/bank-preflight.sh
# and skips (rc 0) unless it prints PROCEED.
#
# Seams (tests): STEERING_CULL_CLAUDE, STEERING_CULL_PREFLIGHT_CMD,
# STEERING_CULL_STATE_DIR, STEERING_CULL_DATE, STEERING_CULL_CRONTAB,
# STEERING_CULL_RUNNER_DIR, STEERING_CULL_SWEEP_CMD, BRIDGE_ROOT, plus cadence-alert.sh's CADENCE_ALERT_*.
# Platform: cron (Linux/macOS). Windows development is parked.
set -uo pipefail

TASK_NAME="HIMMEL-SteeringCull"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT="$SCRIPT_DIR/../luna/cadence-alert.sh"
STATE_DIR="${STEERING_CULL_STATE_DIR:-${HOME:-}/.himmel/state/steering-cull}"
CRONTAB_BIN="${STEERING_CULL_CRONTAB:-crontab}"
RUNNER_DIR="${STEERING_CULL_RUNNER_DIR:-${HOME:-}/.claude/steering-cull-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# live_console <repo>: print the session name of the newest held *-console queue
# lock ("" if none). Lines look like `slug=<user>__<repo>__<session> ... age=<n>s
# status=<TOKEN>`; a lock the sweep cannot vouch for is not live.
live_console() {
    local line slug age st best="" best_age=-1
    while IFS= read -r line; do
        case "$line" in slug=*) ;; *) continue ;; esac
        slug="${line#slug=}"; slug="${slug%% *}"
        age="${line#*age=}"; age="${age%%s *}"
        st="${line##*status=}"
        case "$slug" in *-console) ;; *) continue ;; esac
        case "$st" in OK|'IDLE-HELD?') ;; *) continue ;; esac
        [[ "$age" =~ ^[0-9]+$ ]] || continue
        if [ "$best_age" -lt 0 ] || [ "$age" -lt "$best_age" ]; then best="${slug##*__}"; best_age="$age"; fi
    done < <(if [ -n "${STEERING_CULL_SWEEP_CMD:-}" ]; then "$STEERING_CULL_SWEEP_CMD" 2>/dev/null
             else bash "$1/scripts/handover/queue-lock.sh" status --sweep 2>/dev/null; fi)
    printf '%s' "$best"
}

abs_dir() { (cd "$1" 2>/dev/null && pwd); }

# json_field <field>: print one string field of the JSON on stdin ("" if absent).
json_field() {
    node -e '
        let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
            try { const v = JSON.parse(s)[process.argv[1]]; process.stdout.write(typeof v === "string" ? v : String(v === undefined ? "" : v)); }
            catch (e) { process.exit(1); }
        });' "$1"
}

cmd_run() {
    local repo="" pdir="" console="" claude pf out rc result err iserr date doc
    local files="" f mem low=0 esc=0 cut path risk line inbox root
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|--proposal-dir|--console)
                [ $# -ge 2 ] || { echo "ERR steering-cull: $1 needs a value" >&2; return 64; }
                case "$1" in --repo) repo="$2" ;; --proposal-dir) pdir="$2" ;; --console) console="$2" ;; esac
                shift 2 ;;
            *) echo "ERR steering-cull: unknown arg: $1" >&2; return 64 ;;
        esac
    done
    [ -n "$repo" ] || repo="$(resolve_primary)" || { echo "ERR steering-cull: cannot resolve the repo" >&2; return 64; }
    [ -n "$pdir" ] || { echo "ERR steering-cull: --proposal-dir is required" >&2; return 64; }

    # bank-preflight gate: anything but PROCEED is a quiet skip, not a failure.
    if [ -n "${STEERING_CULL_PREFLIGHT_CMD:-}" ]; then pf="$("$STEERING_CULL_PREFLIGHT_CMD" 2>/dev/null | tail -n 1)"
    else pf="$(bash "$repo/scripts/lib/bank-preflight.sh" 2>/dev/null | tail -n 1)"; fi
    case "$pf" in
        PROCEED*) ;;
        *) echo "steering-cull: skipped, bank-preflight said: ${pf:-<nothing>}"; return 0 ;;
    esac

    claude="${STEERING_CULL_CLAUDE:-$(command -v claude 2>/dev/null)}"
    [ -n "$claude" ] || { echo "ERR steering-cull: claude not on PATH" >&2; bash "$ALERT" fail steering-cull no-claude ""; return 1; }

    mem="${HOME:-}/.claude/projects/$(printf '%s' "$repo" | tr / -)/memory/MEMORY.md"
    for f in "$repo/CLAUDE.md" "${HOME:-}/.claude/CLAUDE.md" "${HOME:-}/.claude/RTK.md" "$mem"; do
        [ -f "$f" ] && files="${files}- ${f}"$'\n'
    done
    [ -n "$files" ] || { echo "ERR steering-cull: no steering file found" >&2; bash "$ALERT" fail steering-cull no-files ""; return 1; }

    mkdir -p "$STATE_DIR" || return 2
    out="$STATE_DIR/last-run.json"
    ( cd "$repo" && "$claude" -p "Run the vendored writing-for-agents skill (.claude/skills/writing-for-agents/SKILL.md) READ-ONLY to find ways to cull these steering files. Never edit anything. Files (use absolute paths exactly as listed; for the repo CLAUDE.md write the path as CLAUDE.md):
${files}
Output ONLY a proposal. One line per cut, exactly: - [LOW|MEDIUM] <path>:<lines> — <why>. LOW = a line that is duplicated, derivable from the repo, or a stale pointer. MEDIUM = anything that changes behaviour or needs judgement." \
        --model sonnet --output-format json --permission-mode plan --tools Read --allowedTools Read ) > "$out" 2> "$STATE_DIR/last-run.err"
    rc=$?
    iserr="$(json_field is_error < "$out" 2>/dev/null)"
    if [ "$rc" -ne 0 ] || [ "$iserr" != "false" ]; then
        bash "$ALERT" fail steering-cull "claude-rc-$rc" "$out"
        return 1
    fi
    result="$(json_field result < "$out" 2>/dev/null)"
    if [ -z "$result" ]; then
        bash "$ALERT" fail steering-cull "empty-result" "$out"
        return 1
    fi

    while IFS= read -r line; do
        case "$line" in
            "- [LOW] "*|"- [MEDIUM] "*) ;;
            *) continue ;;
        esac
        risk="${line#- \[}"; risk="${risk%%\]*}"
        cut="${line#*\] }"; path="${cut%%:*}"
        case "$path" in
            /*|~*|.claude/*|*MEMORY.md|*RTK.md|*..*) esc=$((esc + 1)) ;;
            *) if [ "$risk" = "LOW" ] && [ -f "$repo/$path" ]; then low=$((low + 1)); else esc=$((esc + 1)); fi ;;
        esac
    done <<< "$result"

    date="${STEERING_CULL_DATE:-$(date +%Y-%m-%d)}"
    mkdir -p "$pdir" || return 2
    doc="$pdir/steering-cull-$date.md"
    {
        printf -- '---\ntype: proposal\nsource: steering-cull-cadence (HIMMEL-5634)\ndate: %s\n---\n\n' "$date"
        printf '# Steering-file cull proposal %s\n\n' "$date"
        printf -- '- low: %s (repo-file cuts, safe to batch into one PR)\n- escalated: %s (medium, or any live-file cut; supervisor session decides)\n\n' "$low" "$esc"
        printf '%s\n' "$result"
    } > "$doc" || return 2

    [ -n "$console" ] || console="$(live_console "$repo")"
    if [ -z "$console" ]; then
        bash "$ALERT" fail steering-cull no-console "$doc"
        return 1
    fi
    root="${BRIDGE_ROOT:-${HOME:-}/.claude/handover/bridge}"
    inbox="$root/consoles/$console.md"
    if [ -f "$inbox" ] && printf -- '- %s [steering-cull] proposal %s: %s low, %s escalated\n' "$(date +%H:%M)" "$doc" "$low" "$esc" >> "$inbox"; then
        bash "$ALERT" clear steering-cull
        return 0
    fi
    bash "$ALERT" fail steering-cull no-inbox "$doc"
    return 1
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
        *) echo "ERR steering-cull: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local pdir="" console="" day=1 time="07:00" force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --proposal-dir|--console|--day|--time)
                [ $# -ge 2 ] || { echo "ERR steering-cull: $1 needs a value" >&2; return 1; }
                case "$1" in
                    --proposal-dir) pdir="$2" ;; --console) console="$2" ;;
                    --day) day="$2" ;; --time) time="$2" ;;
                esac
                shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR steering-cull: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [ -n "$pdir" ] || { echo "ERR steering-cull: --proposal-dir is required" >&2; return 1; }
    case "$pdir" in /*) ;; *) pdir="$PWD/$pdir" ;; esac  # cron runs from another cwd
    [[ "$day" =~ ^[0-6]$ ]] || { echo "ERR steering-cull: --day must be 0-6, got: $day" >&2; return 1; }
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR steering-cull: --time must be HH:MM, got: $time" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR steering-cull: cron only; Windows is parked (HIMMEL-4102)" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR steering-cull: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR steering-cull: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR steering-cull: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/steering-cull-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * $day \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY steering-cull: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# steering-cull-cadence runner — generated by steering-cull-cadence.sh arm (HIMMEL-5634)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/steering-cull-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run --repo %q --proposal-dir %q' \
            "$bash_bin" "$root/scripts/cleanup/steering-cull-cadence.sh" "$root" "$pdir"
        [ -z "$console" ] || printf ' --console %q' "$console"
        printf ' >> "$log" 2>&1\n'
    } > "$runner" || { echo "ERR steering-cull: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR steering-cull: cannot chmod the runner $runner" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR steering-cull: crontab install failed" >&2; return 4; }
    echo "steering-cull-cadence ARMED: weekly day $day $time — $runner (status: bash scripts/cleanup/steering-cull-cadence.sh status)"
}

cmd_status() {
    local last
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
    last="$(ls -1t "$STATE_DIR/last-run.json" 2>/dev/null)"
    [ -z "$last" ] || echo "  last run   $(date -r "$last" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "steering-cull-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY steering-cull: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/steering-cull-cadence.sh"
    echo "steering-cull-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: steering-cull-cadence.sh <run|arm|status|disarm>" >&2; exit 64 ;;
esac
