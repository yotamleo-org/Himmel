#!/usr/bin/env bash
# drift-fix-cadence.sh — arm/status/disarm the nightly upstream-drift REPAIR
# cadence.
#
# WHY: the nightly `fork-drift` GitHub Action only DETECTS drift.
# It opens one tracking issue and refreshes it forever; closing that loop was
# always a hand-driven ticket, and those stall — a pin advanced past a still-open
# bump ticket in unrelated PRs, and the tracking issue accumulated "still
# drifting" comments for days.
# Detection without repair is just a nag.
#
# This is the repair half, and it runs LOCALLY on purpose (operator decision,
# 2026-07-28): doing it in Actions would spend CI minutes on every nightly, and
# the private repo has Actions off by design anyway. TWO scheduled tasks fire
# an INTERACTIVE claude session each (never `-p`/`--print`, which bills against
# the subscription budget): one on
# the `/drift-fix` runbook (bump what is mechanically bumpable), one on the
# `/fork-resync` runbook (rebase the carried fork against upstream). The drift
# worker opens an ordinary PR against origin and stops; the resync worker's
# unattended run stops at the audit and opens nothing — an operator-run
# resync may go further, per its own runbook. The origin squash-merge stays
# human-authorized, unchanged.
#
# WHY a claude session and not a plain shell script: the repair has to pass the
# same rails a human PR passes — a clean /pr-check before `gh pr create` (the
# CR-marker hook HARD-blocks otherwise), attestation trailers in the FIRST
# commit, and the ordinary origin PR + review gate. A headless shell runner
# would have to bypass all three. The MECHANICAL half is still
# structural, not left to prose: scripts/upstreams/apply-drift-bump.sh owns the
# actual pin edit, so the session cannot fat-finger a version or move
# `synced_base` without moving the in-repo pin with it.
#
# TWO tasks, daily, default 05:00 (drift) / 05:30 (resync) local — after
# pipeline-cadence's 02:00/03:00/04:00 workers (no overlap on the same machine)
# and before the workday, so the drift worker's PR is already waiting when the
# operator checks (the resync worker's unattended run opens nothing — see
# above). See the WORKER_SESSION_DRIFT/WORKER_SESSION_RESYNC
# block below for why this is two tasks in one script rather than one task or
# two scripts.
#
# STOP-point derivation (re-derived after the public-repo propagation tail was
# retired): fork-resync's STOP at the end of its step 3
# protects `resync-fork.sh --push` — moving a fork branch on a remote the
# operator owns — a hazard unchanged by origin being public, so it stays.
# drift-fix's old STOP protected a SECOND review loop on a second (public)
# remote; that surface is gone now that origin IS the public repo, and what
# remains is the ordinary >=1-approval PR merge gate, which
# `merge-on-green.sh` already enforces structurally (refuses without a
# satisfied review, exit 12/17) — no separate STOP is needed for it.
#
# Usage:
#   bash scripts/upstreams/drift-fix-cadence.sh arm [--time HH:MM] [--resync-time HH:MM] [--model M] [--force] [--dry-run]
#   bash scripts/upstreams/drift-fix-cadence.sh status
#   bash scripts/upstreams/drift-fix-cadence.sh disarm [--dry-run]
#
# Test seams (used by test-drift-fix-cadence.sh):
#   DRIFTFIX_CRONTAB      command invoked instead of `crontab` (POSIX)
#   DRIFTFIX_BAT_DIR      where the persistent runner (.sh) + log live
#   DRIFTFIX_CLAUDE       claude binary override (else: command -v claude)
#   DRIFTFIX_HIMMEL_ROOT  overrides the resolved primary checkout outright
#   DRIFTFIX_PLATFORM     override OS detection (`posix` is supported)
#
# Exit codes:
#   0  done (armed / status printed / disarmed / dry-run complete)
#   1  usage or input error (bad subcommand, flag, --time, --resync-time, --model)
#   2  env unusable (no scheduler, no claude, unknown platform, missing payload)
#   3  dedup block — either worker already armed; --force replaces
#   4  scheduler invocation failed
set -euo pipefail

CRONTAB_BIN="${DRIFTFIX_CRONTAB:-crontab}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
. "$SCRIPT_DIR/../lib/prim.sh" || exit 4

resolve_user_home() {
    printf '%s' "${HOME:-/tmp}"
}

# Persistent runner home — deliberately not a temp directory: this task recurs
# daily and temp sweeps would silently kill the cadence.
BAT_DIR="${DRIFTFIX_BAT_DIR:-$(resolve_user_home)/.claude/drift-fix-cadence}"

# Resolve the himmel root to the PRIMARY checkout, never this script's own
# location: arming from a feature worktree
# would embed that worktree's absolute path in the persistent runner, and the
# post-merge prune then deletes it — every later fire would cd into nothing.
# `--git-common-dir` resolves to the PRIMARY .git even from a linked worktree.
resolve_himmel_root() {
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;                 # already absolute
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

if [ -n "${DRIFTFIX_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$DRIFTFIX_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "WARN drift-fix-cadence: could not resolve the primary checkout via git -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence will break." >&2
    HIMMEL_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && cd .. && pwd)"
fi

GUARD_SCRIPT="$HIMMEL_ROOT/scripts/check-plugin-drift.sh"
BUMP_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/apply-drift-bump.sh"
TOOL_UPGRADE_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/apply-tool-upgrade.sh"
RESYNC_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/resync-fork.sh"

# Runner-format version stamp — shared with the sibling cadences so
# himmel-doctor / himmel-update can spot a runner armed before a format change.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh"

FIRE_TIME="05:00"
RESYNC_TIME="05:30"
MODEL="sonnet"
DRY_RUN=0
FORCE=0

# TWO workers, because upstream drift has two genuinely different repairs and one
# must not block the other. The `drift` worker is mechanical and lands nightly
# (a version pin moves, a vendor CLI upgrades). The `resync` worker is a fork
# REBASE — it is a no-op most nights (upstream tags rarely) and, when it does
# fire, it can legitimately end in "conflicted, a human must decide". Folding
# that into the drift worker would let a stuck fork re-sync block routine pin
# bumps. They are separate scheduled tasks for the same reason pipeline-cadence
# arms its workers separately.
#
# Deliberately ONE script rather than a second near-identical cadence file: the
# arm/status/disarm/dedup/rollback machinery below is the part that is hard to
# get right (fail-closed crontab reads and runner restoration), and a copy of
# it would drift from this one.
WORKER_SESSION_DRIFT="HIMMEL-DriftFix"
WORKER_SESSION_RESYNC="HIMMEL-ForkResync"

# Payload invocations; the real runbooks live in
# .claude/commands/{drift-fix,fork-resync}.md.
PROMPT_DRIFT="Run /drift-fix to completion. This is the scheduled nightly upstream-drift repair cadence (HIMMEL-1323) - fully autonomous, no user prompts; follow the runbook exactly, STOP at the open PR, and report what landed."
PROMPT_RESYNC="Run /fork-resync to completion. This is the scheduled nightly carried-fork re-sync cadence (HIMMEL-1323/HIMMEL-1435) - fully autonomous, no user prompts; audit every BEHIND scripts/upstreams.json entry with a fork block (each entry's own note says whether a non-additive result is a regression to report or an expected known gap), then STOP at the end of step 3; NEVER run resync-fork.sh --push and do not open a branch or PR; report every result."

# worker_prompt / worker_log / worker_runner <task-name> — the per-worker lookups, kept as
# functions rather than an associative array (bash 3.2 has none; macOS ships 3.2).
worker_prompt() {
    if [ "$1" = "$WORKER_SESSION_RESYNC" ]; then printf '%s' "$PROMPT_RESYNC"; else printf '%s' "$PROMPT_DRIFT"; fi
}
worker_slug() {
    if [ "$1" = "$WORKER_SESSION_RESYNC" ]; then printf 'fork-resync'; else printf 'drift-fix'; fi
}
worker_time() {
    if [ "$1" = "$WORKER_SESSION_RESYNC" ]; then printf '%s' "$RESYNC_TIME"; else printf '%s' "$FIRE_TIME"; fi
}

usage() {
    cat <<'EOF'
Usage: drift-fix-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the nightly upstream-drift REPAIR cadence:
TWO daily tasks. HIMMEL-DriftFix fires an interactive claude
session on the /drift-fix runbook -- bump what is mechanically bumpable, open
an ordinary PR against origin, and stop.
HIMMEL-ForkResync fires one on the /fork-resync runbook -- rebase the carried
fork against upstream; its unattended run stops at the audit and opens
nothing (an operator-run resync may go further, per its own runbook).

Subcommands:
  arm      Register both daily tasks. Dedup-guarded: refuses (rc=3) if
           EITHER task is already armed, naming which; --force replaces.
  status   Show whether each worker is armed (+ next run time + run-log
           evidence from its last fire).
  disarm   Remove both tasks and their runners (idempotent; rc=0 if
           nothing was armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>         Daily fire time for HIMMEL-DriftFix, 24h local
                         (default 05:00 -- clear of pipeline-cadence's
                         02:00/03:00/04:00 workers, and early enough that the
                         PR is waiting by the workday).
  --resync-time <HH:MM>  Daily fire time for HIMMEL-ForkResync, 24h local
                         (default 05:30 -- right after the drift worker).
  --model <name>  claude --model pin for BOTH sessions (default sonnet --
                  the runbooks are well-specified; never inherit the
                  operator's saved default tier).
  --force         Replace an already-armed worker (either or both).
  --dry-run       Print what would happen, touch nothing (honored by
                  arm AND disarm).
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR drift-fix-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR drift-fix-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

TIME_SET=0
RESYNC_TIME_SET=0
MODEL_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            # Guard the value slot: `arm --time` with nothing after it would
            # otherwise die on a raw "shift count out of range" under set -e.
            if [ $# -lt 2 ]; then
                echo "ERR drift-fix-cadence: --time requires a value (HH:MM)" >&2
                usage >&2; exit 1
            fi
            FIRE_TIME="$2"; TIME_SET=1; shift 2 ;;
        --time=*)  FIRE_TIME="${1#--time=}"; TIME_SET=1; shift ;;
        --resync-time)
            if [ $# -lt 2 ]; then
                echo "ERR drift-fix-cadence: --resync-time requires a value (HH:MM)" >&2
                usage >&2; exit 1
            fi
            RESYNC_TIME="$2"; RESYNC_TIME_SET=1; shift 2 ;;
        --resync-time=*) RESYNC_TIME="${1#--resync-time=}"; RESYNC_TIME_SET=1; shift ;;
        --model)
            if [ $# -lt 2 ]; then
                echo "ERR drift-fix-cadence: --model requires a value" >&2
                usage >&2; exit 1
            fi
            MODEL="$2"; MODEL_SET=1; shift 2 ;;
        --model=*) MODEL="${1#--model=}"; MODEL_SET=1; shift ;;
        --force)   FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERR drift-fix-cadence: unknown arg: $1" >&2
            usage >&2; exit 1
            ;;
    esac
done

# arm-only flags: reject on status/disarm so the error names the real reason.
if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR drift-fix-cadence: --time is arm-only" >&2; exit 1
fi
if [ "$RESYNC_TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR drift-fix-cadence: --resync-time is arm-only" >&2; exit 1
fi
if [ "$MODEL_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR drift-fix-cadence: --model is arm-only" >&2; exit 1
fi

# Validate input BEFORE the platform gate so a bad value is rc 1 everywhere,
# not rc 2 on whichever platform happens to gate first.
if ! [[ "$FIRE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR drift-fix-cadence: --time must be HH:MM (24h), got: $FIRE_TIME" >&2
    exit 1
fi
if ! [[ "$RESYNC_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR drift-fix-cadence: --resync-time must be HH:MM (24h), got: $RESYNC_TIME" >&2
    exit 1
fi
# The model lands inside a generated runner; keep it to the shape a
# model name actually has rather than escaping arbitrary text into a shell.
if ! [[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERR drift-fix-cadence: --model must be a plain model name (letters, digits, . _ -), got: $MODEL" >&2
    exit 1
fi

case "${DRIFTFIX_PLATFORM:-${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}}" in
    posix|linux*|darwin*|freebsd*|Linux|Darwin) PLATFORM=posix ;;
    *) PLATFORM=unknown ;;
esac
if [ "$PLATFORM" = "unknown" ]; then
    echo "ERR drift-fix-cadence: unsupported platform '${OSTYPE:-unknown}'." >&2
    echo "    Supported: Linux/macOS (crontab)" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Shared: payload presence + run-log reporting
# --------------------------------------------------------------------------

require_payload() {
    if [ ! -f "$GUARD_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: drift guard not found at $GUARD_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$BUMP_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: pin bumper not found at $BUMP_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$TOOL_UPGRADE_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: vendor-CLI upgrader not found at $TOOL_UPGRADE_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$HIMMEL_ROOT/.claude/commands/drift-fix.md" ]; then
        echo "ERR drift-fix-cadence: /drift-fix runbook not found at $HIMMEL_ROOT/.claude/commands/drift-fix.md" >&2
        exit 2
    fi
    if [ ! -f "$HIMMEL_ROOT/.claude/commands/fork-resync.md" ]; then
        echo "ERR drift-fix-cadence: /fork-resync runbook not found at $HIMMEL_ROOT/.claude/commands/fork-resync.md" >&2
        exit 2
    fi
    if [ ! -f "$RESYNC_SCRIPT" ]; then
        echo "ERR drift-fix-cadence: fork resync script not found at $RESYNC_SCRIPT" >&2
        exit 2
    fi
}

# Resolve the claude binary. Absolute, so the scheduler's minimal PATH (cron in
# particular) does not decide whether the cadence can run at all.
#
# The override is existence-checked but the PATH lookup is not: `command -v`
# already guarantees an executable, whereas a hand-set DRIFTFIX_CLAUDE pointing
# at nothing would arm a cadence that fails silently every night.
resolve_claude() {
    if [ -n "${DRIFTFIX_CLAUDE:-}" ]; then
        [ -x "$DRIFTFIX_CLAUDE" ] || return 1
        printf '%s' "$DRIFTFIX_CLAUDE"; return 0
    fi
    command -v claude 2>/dev/null
}

# Explain which arm-time lookup failed.
claude_unresolved_msg() {
    if [ -n "${DRIFTFIX_CLAUDE:-}" ]; then
        echo "ERR drift-fix-cadence: DRIFTFIX_CLAUDE is set to '$DRIFTFIX_CLAUDE' but that is not an executable file" >&2
    else
        echo "ERR drift-fix-cadence: 'claude' not on PATH at arm time (set DRIFTFIX_CLAUDE to override)" >&2
    fi
}

# Surface fire evidence: "armed but never succeeding" must be visible from
# status alone. The runner rotates one prior run to .log.prev.
status_log() {
    local log="$1" mtime last rc
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null || echo '?')
        echo "  run log    $log (last write: $mtime)"
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        [ -n "$last" ] && echo "             last line: $last"
        rc=$(grep -o '\[exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        if [ -n "$rc" ] && [ "$rc" != "0" ]; then
            echo "  WARN: last fire exited rc=$rc — the drift repair did not complete"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log.prev" 2>/dev/null || echo '?')
        echo "  prev log   $log.prev (last write: $mtime)"
    fi
}

# Best-effort: pre-trust the himmel checkout so an unattended run can't
# stall on Claude Code's interactive workspace-trust prompt. Never
# fatal — a pre-seed failure must not block arming.
pretrust_workspace() {
    local lib="$HIMMEL_ROOT/scripts/lib/ensure-workspace-trust.sh"
    [ -x "$lib" ] || [ -f "$lib" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY drift-fix-cadence: would pre-trust workspace '$HIMMEL_ROOT' in ~/.claude.json"
        return 0
    fi
    bash "$lib" "$HIMMEL_ROOT" >/dev/null 2>&1 \
        || echo "WARN drift-fix-cadence: workspace-trust pre-seed failed for '$HIMMEL_ROOT' (arm continues; first run may prompt to trust the folder)" >&2
}

# --------------------------------------------------------------------------
# POSIX (crontab)
# --------------------------------------------------------------------------

# Shell-quote for a cron command line: printf %q survives the /bin/sh re-parse
# at fire time. The extra % -> \% pass is cron(5) syntax — an unescaped % ends
# the command and the remainder becomes stdin.
cron_escape() {
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the crontab into CRON_TAB. Fail-CLOSED: any nonzero rc is fatal UNLESS it
# matches the trusted no-crontab-yet signature. A failed listing must never read
# as "nothing armed".
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
    set +e
    # LC_ALL=C pins the message shape so the signature grep isn't defeated by
    # translation.
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR drift-fix-cadence: crontab -l failed (rc=$rc) — refusing to treat as an empty crontab:" >&2
            cat "$err_file" >&2
            echo "    Non-vixie crons (busybox, Solaris) phrase 'no crontab yet' differently;" >&2
            echo "    if that is what tripped this, install an empty crontab to unblock:" >&2
            echo "        crontab - </dev/null" >&2
            rm -f "$err_file"
            exit 2
        fi
    fi
    rm -f "$err_file"
}

cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t drift-fix-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR drift-fix-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        echo "    rejected crontab left at: $tab_file" >&2
        rm -f "$err_file"
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged line for one worker (empty if not armed). Two literal greps, never
# a shared "HIMMEL-" prefix filter (unlike pipeline-cadence's TASK_PREFIX) —
# other himmel cadences share that prefix in the same crontab, and a prefix
# filter here would silently sweep entries this script does not own.
worker_existing() { printf '%s\n' "$CRON_TAB" | grep -F "# $1" || true; }

# Rotate the log, stamp the fire, cd into the
# checkout, bounded interactive claude run. All values arrive pre-quoted with
# printf %q. node_dir is prepended to PATH because an nvm-managed node is not on
# cron's minimal PATH even when the claude shim itself is absolute (#317).
# shellcheck disable=SC2016  # $log / $(date) are emitted literally for the runner's own /bin/sh
emit_runner() {
    local q_root="$1" q_claude="$2" q_prompt="$3" q_log="$4" q_model="$5" q_node_dir="${6:-}"
    printf '#!/bin/sh\n'
    printf '# drift-fix-cadence runner — generated by drift-fix-cadence.sh arm\n'
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    if [ -n "$q_node_dir" ]; then
        printf 'PATH=%s:$PATH\nexport PATH\n' "$q_node_dir"
    fi
    # cron cannot read the macOS Keychain login (SCRUM-4, runner format v24).
    cadence_oauth_token_lines
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" 2>/dev/null; fi\n'
    printf '{\n'
    printf '    echo "[fired $(date "+%%Y-%%m-%%d %%H:%%M:%%S")]"\n'
    printf '    cd %s || exit 1\n' "$q_root"
    printf '    %s --model %s %s < /dev/null\n' "$q_claude" "$q_model" "$q_prompt"
    printf '    _rc=$?\n'
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
    # Exit WITH the payload's status (CR codex-3). The `{ … }` group is not a
    # subshell, so $_rc survives it. Without this the runner's last command is
    # the redirected group (effectively the `echo`), so it exited 0 no matter
    # how the run went — cron would mail nothing and any scheduler-level status
    # would read success on a failed drift repair.
    printf 'exit "$_rc"\n'
}

cmd_arm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    require_payload
    local claude_bin node_dir node_bin
    if ! claude_bin=$(resolve_claude) || [ -z "$claude_bin" ]; then
        claude_unresolved_msg
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then node_dir=$(dirname "$node_bin"); fi

    cron_read
    local worker existing dedup_names=""
    for worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
        existing=$(worker_existing "$worker")
        if [ -n "$existing" ]; then
            if [ "$FORCE" -eq 1 ]; then
                echo "drift-fix-cadence: --force set; replacing existing entry:" >&2
                printf '%s\n' "$existing" | sed 's/^/  /' >&2
            else
                if [ -z "$dedup_names" ]; then dedup_names="$worker"; else dedup_names="$dedup_names, $worker"; fi
            fi
        fi
    done
    if [ -n "$dedup_names" ]; then
        {
            echo "ERR drift-fix-cadence: already armed: $dedup_names."
            echo ""
            echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
            echo "    bash scripts/upstreams/drift-fix-cadence.sh status"
        } >&2
        exit 3
    fi

    pretrust_workspace

    local q_root q_claude q_model q_node_dir
    q_root=$(printf '%q' "$HIMMEL_ROOT")
    q_claude=$(printf '%q' "$claude_bin")
    q_model=$(printf '%q' "$MODEL")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')

    local slug time runner q_prompt q_log hh mm entry_line
    if [ "$DRY_RUN" -eq 1 ]; then
        for worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
            slug=$(worker_slug "$worker")
            time=$(worker_time "$worker")
            runner="$BAT_DIR/$slug.sh"
            q_prompt=$(printf '%q' "$(worker_prompt "$worker")")
            q_log=$(printf '%q' "$BAT_DIR/$slug.log")
            hh="${time%:*}"; mm="${time#*:}"
            entry_line="$mm $hh * * * $(cron_escape "$runner") # $worker"
            echo "DRY drift-fix-cadence: would write $runner:"
            emit_runner "$q_root" "$q_claude" "$q_prompt" "$q_log" "$q_model" "$q_node_dir" | sed 's/^/    /'
            echo "DRY drift-fix-cadence: would install crontab entry:"
            echo "    $entry_line"
        done
        echo "drift-fix-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"

    # ONE rewrite: snapshot -> filter out any prior entry for EITHER worker ->
    # append BOTH new entries -> install once. There is no half-armed state
    # to roll back — either the whole rewrite lands or neither worker does.
    # No blank-line strip here (CR glm-2): blank lines are valid crontab
    # syntax (cron_install just pipes this to `crontab -`), and stripping
    # them ate the operator's own formatting on every arm/disarm cycle while
    # disarm's equivalent rewrite below never did. Symmetric with cmd_disarm.
    local newtab
    newtab=$(mktemp -t drift-fix-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "# $WORKER_SESSION_DRIFT" | grep -vF "# $WORKER_SESSION_RESYNC" > "$newtab" || true

    # Snapshot any PRE-EXISTING runner content before overwriting it, so a
    # failed cron_install below can restore it byte-identical (CR codex-1;
    # mirrors the pin_text snapshot/restore idiom in apply-drift-bump.sh:
    # capture before write, restore on failure). A runner that does not
    # already exist gets no snapshot — see the restore comment below for why
    # that is fine.
    local snap_dir
    snap_dir=$(tmpdir)

    # restore_runner_snapshots — restore each pre-existing runner's CONTENT
    # from $snap_dir, never delete it (CR glm-3). A failed install leaves the
    # crontab UNCHANGED, so under --force the previous entries are still live
    # and still point at exactly these paths; without this restore, the loop
    # below would already have overwritten those paths with the NEW,
    # never-installed config — the operator is told the arm FAILED while the
    # already-armed cadence has silently been mutated to fire the new body
    # next time it runs (CR codex-1). Deleting the runners instead — the
    # ordering cmd_disarm documents (install must succeed BEFORE anything is
    # removed) — would be worse: that working cadence would fire a missing
    # file every night, silently: the arm failed AND the pre-existing arm
    # broke. A runner with no snapshot (first-arm failure, nothing
    # pre-existed) is simply left as emitted — harmless, since nothing
    # references it yet and the next successful arm overwrites it. Shared by
    # BOTH failure paths below (a write/chmod failure mid-loop, and a failed
    # cron_install) so the discipline is identical whichever one fires.
    restore_runner_snapshots() {
        local _worker _slug
        for _worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
            _slug=$(worker_slug "$_worker")
            if [ -f "$snap_dir/$_slug.sh" ]; then
                cp "$snap_dir/$_slug.sh" "$BAT_DIR/$_slug.sh"
                chmod +x "$BAT_DIR/$_slug.sh"
            fi
        done
    }

    for worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
        slug=$(worker_slug "$worker")
        time=$(worker_time "$worker")
        runner="$BAT_DIR/$slug.sh"
        q_prompt=$(printf '%q' "$(worker_prompt "$worker")")
        q_log=$(printf '%q' "$BAT_DIR/$slug.log")
        [ -f "$runner" ] && cp "$runner" "$snap_dir/$slug.sh"
        # Under set -e (line 59) a write/chmod failure here (e.g. disk full on
        # worker 2 after worker 1 was already overwritten) would otherwise exit
        # WITHOUT the restore below — a pre-existing armed runner silently
        # mutated while the crontab still points at it.
        if ! emit_runner "$q_root" "$q_claude" "$q_prompt" "$q_log" "$q_model" "$q_node_dir" > "$runner" \
           || ! chmod +x "$runner"; then
            echo "ERR drift-fix-cadence: could not write $runner — restoring any pre-existing runners." >&2
            restore_runner_snapshots
            rm -rf "$snap_dir"
            rm -f "$newtab"
            exit 4
        fi
        hh="${time%:*}"; mm="${time#*:}"
        printf '%s\n' "$mm $hh * * * $(cron_escape "$runner") # $worker" >> "$newtab"
    done
    if ! cron_install "$newtab"; then
        restore_runner_snapshots
        rm -rf "$snap_dir"
        echo "ERR drift-fix-cadence: crontab install failed — runners left in place at $BAT_DIR (any previously-armed cadence keeps working)." >&2
        exit 4
    fi
    rm -rf "$snap_dir"
    cadence_prov_record "$WORKER_SESSION_DRIFT"
    cadence_prov_record "$WORKER_SESSION_RESYNC"
    arm_summary "crontab entry"
}

cmd_status() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    echo "drift-fix-cadence status:"
    local worker slug entry sched n_entries dup
    for worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
        slug=$(worker_slug "$worker")
        entry=$(worker_existing "$worker" | head -1)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            n_entries=$(worker_existing "$worker" | grep -c . || true)
            dup=""
            [ "$n_entries" -gt 1 ] && dup=" [DUPLICATE: $n_entries cron entries]"
            echo "ARMED      $worker (cron: $sched)$dup"
        else
            echo "not armed  $worker"
        fi
        echo "  runner     $BAT_DIR/$slug.sh"
        status_log "$BAT_DIR/$slug.log"
    done
}

cmd_disarm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR drift-fix-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    local worker existing any_existing=0
    for worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
        existing=$(worker_existing "$worker")
        [ -n "$existing" ] && any_existing=1
    done
    if [ "$any_existing" -eq 0 ]; then
        # Trusted-empty read (cron_read exits 2 otherwise) — safe to sweep.
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$BAT_DIR/$(worker_slug "$WORKER_SESSION_DRIFT").sh" "$BAT_DIR/$(worker_slug "$WORKER_SESSION_RESYNC").sh"
        fi
        echo "drift-fix-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        for worker in "$WORKER_SESSION_DRIFT" "$WORKER_SESSION_RESYNC"; do
            existing=$(worker_existing "$worker")
            [ -n "$existing" ] && printf '%s\n' "$existing" | sed 's/^/DRY drift-fix-cadence: would remove crontab entry: /'
        done
        echo "DRY drift-fix-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t drift-fix-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "# $WORKER_SESSION_DRIFT" | grep -vF "# $WORKER_SESSION_RESYNC" > "$newtab" || true
    # Ordering invariant: the install must succeed BEFORE the runners are
    # removed — a failed install leaves the entries live and they must keep
    # pointing at files that exist.
    cron_install "$newtab" || exit 4
    rm -f "$BAT_DIR/$(worker_slug "$WORKER_SESSION_DRIFT").sh" "$BAT_DIR/$(worker_slug "$WORKER_SESSION_RESYNC").sh"
    echo "drift-fix-cadence: cadence disarmed"
}

# --------------------------------------------------------------------------

arm_summary() {
    local kind="$1" runner_drift runner_resync log_drift log_resync
    runner_drift="$BAT_DIR/$(worker_slug "$WORKER_SESSION_DRIFT").sh"
    runner_resync="$BAT_DIR/$(worker_slug "$WORKER_SESSION_RESYNC").sh"
    log_drift="$BAT_DIR/$(worker_slug "$WORKER_SESSION_DRIFT").log"
    log_resync="$BAT_DIR/$(worker_slug "$WORKER_SESSION_RESYNC").log"
    cat <<EOF
================================================================
drift-fix-cadence ARMED

  $WORKER_SESSION_DRIFT   daily $FIRE_TIME local   — $kind — runner: $runner_drift
  $WORKER_SESSION_RESYNC  daily $RESYNC_TIME local — $kind — runner: $runner_resync
  Model:  $MODEL
  Repo:   $HIMMEL_ROOT
  Logs:   $log_drift
          $log_resync
          (one prior run kept as .log.prev, per worker)

  Each night:
    - $WORKER_SESSION_DRIFT runs /drift-fix: upgrade the installed vendor CLIs whose
      registry entry is marked upgrade.unattended:true, bump every repo
      pin apply-drift-bump.sh can bump, then open an ordinary PR against
      origin and STOP.
    - $WORKER_SESSION_RESYNC runs /fork-resync: rebase every BEHIND registry fork
      against upstream and audit it — a no-op most nights. The unattended
      run ALWAYS stops after each audit (clean, conflicted, or deliberately
      non-additive alike): it never pushes or opens anything, leaving that
      for a human instead.

  The squash-merge stays yours — neither worker ever merges it.

  Status / disarm anytime:
      bash scripts/upstreams/drift-fix-cadence.sh status
      bash scripts/upstreams/drift-fix-cadence.sh disarm
================================================================
EOF
}

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
