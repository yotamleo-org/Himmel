#!/usr/bin/env bash
# pipeline-cadence.sh — arm/status/disarm the recurring clip-pipeline
# cadence.
#
# The luna vault's runbooks table gives only loose guidance
# (/synthesize-clips = "after a clip batch", /obsidian-health = "after
# big ingests") — but nothing was scheduled; every run was operator-
# remembered. The pipeline is idempotent at every stage by design
# (markers: harvested_at, processed, synthesis dedup window, _done/
# move) — exactly the cron-safe shape. This script registers the four
# recurring jobs with the OS scheduler, following the
# scripts/handover/arm-resume.sh precedent:
#
#   HIMMEL-Pipeline-FetchHealth daily  (default 01:30, no LLM)
#       python fetch-health.py
#   HIMMEL-Pipeline-Harvest     daily   (default 02:00, model: claude-sonnet-5-5)
#       claude --model claude-sonnet-5-5 "/harvest-clips ... then /triage-clips ... then /ig-media-enrich ..." < /dev/null
#   HIMMEL-Pipeline-Synthesize  daily   (default 03:00, model: claude-sonnet-5-5)
#       claude --model claude-sonnet-5-5 "/synthesize-clips … then /archive-clips …" < /dev/null
#   HIMMEL-Pipeline-Health      daily   (default 04:00, model: haiku)
#       claude --model haiku "vault-lint (obsidian-triage:vault-lint) …" < /dev/null
#
# Defaults:
# harvest+triage+ig-media-enrich daily at 02:00 (cheap, idempotent,
# keeps the Clippings/ inbox flowing and drains pending Instagram media
# across nights); synthesize+archive DAILY at 03:00 — synthesis is now
# cheap enough to run nightly once pinned to a cheap model, so cross-clip
# themes surface without a week's lag (archive only graduates clips
# synthesis has wikilinked, so it follows synth in the SAME session);
# health DAILY at 04:00 (the weekly cadence meant vault
# drift was only visible once a week, and the haiku pin makes nightly
# affordable); machine assumed awake. Every worker
# launches with an explicit --model pin (harvest/synth=claude-sonnet-5-5,
# health=haiku) so the cadence never inherits the operator's saved
# default (the scarcest tier) — the cheap pins are what make the higher
# frequencies affordable. All overridable via flags.
#
# The armed command is interactive-claude shaped — `claude "<prompt>"`
# with stdin redirected from /dev/null (the bounded-run primitive: the session
# runs the full turn, then exits clean). NOT headless (`-p`/`--print`)
# (billing rule: headless invocations bill to a separate
# Agent SDK credit bucket from 2026-06-15; interactive stays on Max
# quota). Each task fires a runner .sh that
# cd's into the luna vault so the obsidian-triage skills operate on the
# right tree.
#
# macOS/Linux use crontab entries,
# following the arm-resume.sh crontab-fallback precedent: each entry
# fires a persistent runner .sh (log
# rotation + fire stamp + cd into the vault + bounded claude run) and
# carries a trailing `# HIMMEL-Pipeline-*` marker so dedup/status/
# disarm can find it (cron hands the whole line to /bin/sh, which reads
# the marker as a shell comment at fire time — same trick as
# arm-resume's crontab entry).
#
# Usage:
#   bash scripts/luna/pipeline-cadence.sh arm [--fetch-health-time HH:MM]
#       [--harvest-time HH:MM] [--ig-limit N] [--synth-time HH:MM]
#       [--health-time HH:MM] [--harvest-model M] [--synth-model M]
#       [--health-model M] [--vault PATH] [--force] [--dry-run]
#   bash scripts/luna/pipeline-cadence.sh status
#   bash scripts/luna/pipeline-cadence.sh disarm
#
# Test seams (used by test-pipeline-cadence.sh):
#   PIPELINE_CRONTAB   — command invoked instead of `crontab`
#   PIPELINE_BAT_DIR   — where the persistent runners (.sh) live
#
# Exit codes (mirrors arm-resume.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no crontab; unsupported platform; query tool errored)
#   3  dedup block — HIMMEL-Pipeline-* task(s) already armed; use --force
#   4  scheduler invocation failed (crontab rewrite)
set -euo pipefail

TASK_PREFIX="HIMMEL-Pipeline-"
TASK_FETCH_HEALTH="${TASK_PREFIX}FetchHealth"
TASK_HARVEST="${TASK_PREFIX}Harvest"
TASK_SYNTH="${TASK_PREFIX}Synthesize"
TASK_HEALTH="${TASK_PREFIX}Health"
CRONTAB_BIN="${PIPELINE_CRONTAB:-crontab}"

# Cross-platform user-home resolution + default_vault, extracted into a
# shared lib so other cadence scripts can source the
# same resolver instead of carrying their own copy.
# shellcheck source=../lib/resolve-user-home.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/resolve-user-home.sh"

# Persistent runner home (.sh runners) — NOT mktemp
# like arm-resume's one-shot task: these tasks recur indefinitely, and
# /tmp is subject to cleanup sweeps that would silently kill
# the cadence.
BAT_DIR="${PIPELINE_BAT_DIR:-$(resolve_user_home)/.claude/pipeline-cadence}"

# A `claude --settings` fragment that wires himmel's
# auto-approve-safe-bash PreToolUse hook by ABSOLUTE path. The cadence fires in
# the luna vault cwd, which carries no himmel .claude/settings.json — so without
# this an autonomous run STALLS on the compound-bash permission
# prompt (the static matcher bails on any `$var`/`$()`/pipe/compound command and
# prompts; an unattended `< /dev/null` run has nobody to answer it, wasting the run).
# Injecting the hook by absolute himmel path — resolved here at arm time —
# restores the auto-approve posture in the luna cwd. The hook only ever GRANTS
# (fail-open; never blocks), so this widens nothing the block-* hooks guard.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
AUTO_APPROVE_HOOK="$HIMMEL_ROOT/scripts/hooks/auto-approve-safe-bash.sh"
SETTINGS_FRAGMENT="$BAT_DIR/cadence-settings.json"

# The bank guard the three claude workers launch behind (CLAUDE.md's billing rule:
# a scheduled or unattended site preflights before spending the shared
# 5h/weekly subscription bank). The generated runners
# branch on the helper's VERDICT TOKEN, never its exit code: usage-preflight.sh
# always exits 0 by design, and its BANK-STALE / BANK-UNKNOWN verdicts are
# deliberately fail-open (a box with no usage cache must still run its cadence).
# Only SKIPPED-BANK stops a worker.
BANK_PREFLIGHT="$HIMMEL_ROOT/scripts/lib/usage-preflight.sh"

# The free precondition for the synthesize worker. Answers NEW/NONE
# from the filesystem so a night with no newly triaged clips costs no session.
SYNTH_GATE="$HIMMEL_ROOT/scripts/luna/synth-input-check.sh"

# The shared failure sink. Every generated runner calls it on a
# failed worker (alert-file line + one deduped Telegram DM) and on a completed one
# (clears the dedupe). Baked by absolute path at arm time like the libs above.
CADENCE_ALERT="$HIMMEL_ROOT/scripts/luna/cadence-alert.sh"

# The marker line a runner writes to its log when a gate refused the worker. The
# sibling of WORKER_SESSION_DONE_MARKER: DONE means the session ran and finished, SKIPPED
# means no session was ever launched. Distinct words on purpose — a skipped
# night must not read as a parked one.
WORKER_SESSION_SKIPPED_MARKER="PIPELINE-WORKER-SKIPPED"
# The log line a runner writes when a launched worker failed: a
# non-zero rc, or a zero rc without WORKER_SESSION_DONE_MARKER (a no-op is not green).
WORKER_SESSION_FAILED_MARKER="PIPELINE-WORKER-FAILED"

# CLAUDE.md § billing: every scheduled claude launch declares an
# explicit --permission-mode instead of inheriting the operator's saved default
# (a cadence must not change behaviour because someone toggled a mode in an
# interactive session). `acceptEdits` is the mode these workers have effectively
# been running under: file writes proceed, and every Bash call still goes
# through the cadence hook stack this script's --settings fragment wires.
# NEVER bypassPermissions — that is the one mode the billing rule forbids.
CADENCE_PERMISSION_MODE="acceptEdits"

# Runner-format version stamp: emit_runner stamps
# CADENCE_RUNNER_FORMAT_VERSION into every runner so himmel-doctor / himmel-update
# can detect a cadence armed before a format change and nudge `arm --force`.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"

# Sourced for ONE constant: FLOW_RUN_ATTEMPT_MARKER. The emitted
# runners stamp that word into their log before each attempt and the same lib's
# --is-transient scan keys off it, so the two must never drift into separate
# copies of the same literal. (The lib is sourced, not executed — its only load
# -time effect is a guarded PATH self-heal.)
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/flow-run-ledger.sh"

# macOS cron Full Disk Access arm-time warning.
# shellcheck source=../lib/macos-fda-warning.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/macos-fda-warning.sh"

# Operator-decision defaults.
FETCH_HEALTH_TIME="01:30"
HARVEST_TIME="02:00"
IG_LIMIT="10"
SYNTH_TIME="03:00"
HEALTH_TIME="04:00"
# Health day-of-week. Evidence for the weekly default: vault-lint's finding count
# moved 363 -> 369 in FOUR DAYS, and nobody consumes a nightly 369-line report —
# a daily session bought for a weekly-or-less signal. Weekly is the default
# again; `--health-day daily` restores the every-night shape for an operator who
# genuinely wants it, so this is a default change, not a capability removal.
HEALTH_DAY="SUN"
# Human-readable cadence label for the summary blocks; recomputed by
# validate_arm_inputs once --health-day is canonicalised.
HEALTH_CADENCE_LABEL="weekly  SUN 04:00"
HARVEST_MODEL="claude-sonnet-5-5"
SYNTH_MODEL="claude-sonnet-5-5"
HEALTH_MODEL="haiku"

# Bounded retry/resume for a claude worker killed by a TRANSIENT upstream API
# error. A harvest run died 48 minutes in on
# `API Error: Server error mid-response.` with 7 clips already recorded, and
# nothing retried it — the day's harvest simply sat unfinished. Every stage is
# idempotent through its own markers, so a re-invoke RESUMES; this is a
# scheduling wrapper around that contract, not a change to any harvest logic.
# 3 attempts = the original plus 2 retries; only a non-zero exit whose own
# attempt log carries FLOW_RUN_TRANSIENT_SIGNATURE_RE is ever retried.
RETRY_MAX_ATTEMPTS=3
RETRY_BACKOFF_1=60
RETRY_BACKOFF_2=180

# default_vault is sourced from ../lib/resolve-user-home.sh above.
VAULT="$(default_vault)"
FORCE=0
DRY_RUN=0

DAILY_CHAIN="/harvest-clips + /triage-clips + /ig-media-enrich + /x-media-enrich"
# The bare completion marker the worker prompt asks for; flow_run_classify treats
# a zero exit WITHOUT this line in the log tail as `parked`.
WORKER_SESSION_DONE_MARKER="PIPELINE-WORKER-DONE"
COMPLETION_INSTRUCTIONS="Run every command in the foreground. Never background a command or wait for a notification. Only if this cadence worker genuinely completed all of its work, print exactly PIPELINE-WORKER-DONE as the final line of your output, on its own line with no prefix, suffix, or punctuation. If it was blocked, parked, or bailed early, do not print the marker."
HARVEST_PROMPT=""
SYNTH_PROMPT="Run /synthesize-clips to completion, then run /archive-clips. This is the scheduled daily pipeline cadence run - fully autonomous, no user prompts; report results and exit. For this worker, all of its work means both skills ran to completion and wrote their own output. When archive-clips reports clips as (stuck) in the inbox, those are structural backlog that triage owns and re-running cannot clear: report the stuck count and still print the marker. Withhold the marker when a step itself failed or aborted (a non-zero exit, a crash, a refused write) or the worker was blocked, parked, or bailed early; do not withhold it only because stuck clips remain. $COMPLETION_INSTRUCTIONS"
HEALTH_PROMPT="Use the Skill tool to run the obsidian-triage:vault-lint skill (not /obsidian-health) against this vault to completion. This is the scheduled daily pipeline cadence run - fully autonomous, no user prompts; report results and exit. $COMPLETION_INSTRUCTIONS"

usage() {
    cat <<'EOF'
Usage: pipeline-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring clip-pipeline cadence:
daily no-LLM source fetch-health probes,
daily /harvest-clips (+ /triage-clips and
/ig-media-enrich chained after in the same session), daily
/synthesize-clips (+ /archive-clips chained after) and daily
vault-lint (obsidian-triage:vault-lint), run against the
luna vault as interactive bounded claude sessions. Each worker launches
with an explicit cheap --model pin so the cadence never
inherits the operator's saved default.

Subcommands:
  arm      Register all four recurring tasks. Dedup-guarded: refuses
           (rc=3) if any HIMMEL-Pipeline-* task already exists; --force
           replaces.
  status   Show which cadence tasks are armed (+ next run time + the
           pinned model parsed back out of each runner).
  disarm   Remove all tasks (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --fetch-health-time <HH:MM> Daily no-LLM fetch-health time (default 01:30)
  --harvest-time <HH:MM> Daily harvest+triage+ig-media-enrich time,
                         24h local (default 02:00)
  --ig-limit <N>         Daily /ig-media-enrich --limit N (default 10;
                         0 = unlimited)
  --synth-time <HH:MM>   Daily synthesize time, 24h local (default 03:00)
  --health-time <HH:MM>  Health fire time, 24h local (default 04:00)
  --health-day <DOW>     Health day: MON..SUN, or DAILY (default SUN —
                         demoted from daily by the 2026-08-23 cadence
                         audit; the finding count barely moves week to
                         week and nobody reads a nightly report)
  --harvest-model <m>    claude --model for the harvest worker (default claude-sonnet-5-5)
  --synth-model <m>      claude --model for the synthesize worker (default claude-sonnet-5-5)
  --health-model <m>     claude --model for the health worker (default haiku)
  --vault <PATH>         Luna vault root (default: $LUNA_VAULT_PATH if set,
                         else $HOME/Documents/luna)
  --force                Replace existing HIMMEL-Pipeline-* tasks
  --dry-run              Print what would happen, touch nothing
                         (honored by arm AND disarm)
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR pipeline-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR pipeline-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --fetch-health-time)   FETCH_HEALTH_TIME="${2:-}"; shift 2 ;;
        --fetch-health-time=*) FETCH_HEALTH_TIME="${1#--fetch-health-time=}"; shift ;;
        --harvest-time)   HARVEST_TIME="${2:-}"; shift 2 ;;
        --harvest-time=*) HARVEST_TIME="${1#--harvest-time=}"; shift ;;
        --ig-limit)      IG_LIMIT="${2:-}"; shift 2 ;;
        --ig-limit=*)    IG_LIMIT="${1#--ig-limit=}"; shift ;;
        --synth-day|--synth-day=*)
            echo "ERR pipeline-cadence: --synth-day is no longer supported — synthesize is daily now; use --synth-time to set the time" >&2
            exit 1 ;;
        --synth-time)    SYNTH_TIME="${2:-}"; shift 2 ;;
        --synth-time=*)  SYNTH_TIME="${1#--synth-time=}"; shift ;;
        --health-day)    HEALTH_DAY="${2:-}"; shift 2 ;;
        --health-day=*)  HEALTH_DAY="${1#--health-day=}"; shift ;;
        --health-time)   HEALTH_TIME="${2:-}"; shift 2 ;;
        --health-time=*) HEALTH_TIME="${1#--health-time=}"; shift ;;
        --harvest-model)   HARVEST_MODEL="${2:-}"; shift 2 ;;
        --harvest-model=*) HARVEST_MODEL="${1#--harvest-model=}"; shift ;;
        --synth-model)   SYNTH_MODEL="${2:-}"; shift 2 ;;
        --synth-model=*) SYNTH_MODEL="${1#--synth-model=}"; shift ;;
        --health-model)  HEALTH_MODEL="${2:-}"; shift 2 ;;
        --health-model=*) HEALTH_MODEL="${1#--health-model=}"; shift ;;
        --vault)         VAULT="${2:-}"; shift 2 ;;
        --vault=*)       VAULT="${1#--vault=}"; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERR pipeline-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

HARVEST_PROMPT="Run /harvest-clips to completion, then run /triage-clips, then run /ig-media-enrich --limit $IG_LIMIT --include-evidence. The /ig-media-enrich step uses --limit $IG_LIMIT --include-evidence (triage moves finished clips into Clippings/_evidence/, which the default selection skips); 0 means unlimited, otherwise one night's batch is bounded and the ig_media_pending backlog drains across nights. If /ig-media-enrich fails due to missing ffmpeg/whisper, expired IG cookies, or media download errors, report the failure but it must not abort or fail the harvest+triage worker; finish the session normally. Then run /x-media-enrich --limit $IG_LIMIT --include-evidence. If /x-media-enrich fails due to missing ffmpeg/whisper, expired X cookies or credentials, or media download errors, report the failure but it must not abort or fail the harvest+triage worker; finish the session normally. This is the scheduled daily pipeline cadence run - fully autonomous, no user prompts; report results and exit. For this worker, all of its work means every step above ran to its budget or --limit and wrote its own completion output. A backlog left for later runs is not unfinished work (X or IG media still pending, slides-pending-digest clips, deferred harvest partials): report the remaining counts and still print the marker. Withhold the marker only when a step itself failed or aborted (a non-zero exit, a crash, a refused write), not because items remain; the /ig-media-enrich and /x-media-enrich failures named above are reported and do not withhold it. $COMPLETION_INSTRUCTIONS"

# Platform detect (same matrix as arm-resume.sh).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR pipeline-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM — cron port)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR pipeline-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

task_summary() {
    case "$1" in
        "$TASK_FETCH_HEALTH") printf ' -> clip-source fetch probes [no LLM]' ;;
        "$TASK_HARVEST") printf ' -> %s' "$DAILY_CHAIN" ;;
    esac
}

# Map a cadence task name to its generated runner .sh path so status can
# surface the pinned model.
# Returns the path on stdout; rc 1 on an unknown name.
runner_for_name() {
    local base
    case "$1" in
        "$TASK_FETCH_HEALTH") base="pipeline-fetch-health" ;;
        "$TASK_HARVEST") base="pipeline-harvest" ;;
        "$TASK_SYNTH")   base="pipeline-synthesize" ;;
        "$TASK_HEALTH")  base="pipeline-health" ;;
        *) return 1 ;;
    esac
    printf '%s/%s.sh' "$BAT_DIR" "$base"
}

# Read the --model pin back out of a generated runner .sh so
# status can flag an armed-but-wrong-model cadence. emit_runner
# injects `--model <m>` right after the binary; this greps that
# token. rc 1 when the runner is absent (not armed / dry-run), empty
# stdout when armed without a stampable pin (pre-pin runner).
runner_model() {
    local f="$1"
    [ -f "$f" ] || return 1
    grep -oE -- '--model[[:space:]]+[^[:space:]]+' "$f" 2>/dev/null \
        | head -1 | sed 's/^--model[[:space:]]*//' | tr -d '"' || true
}

# Status suffix: " [model: <m>]" when the runner carries a --model pin;
# " [runner missing]" when the scheduler entry is armed but its generated
# runner file is gone (every fire fails — distinguished from the
# intentional pre-pin case, which exists on disk and stays
# silent rather than print "model: unknown"); empty otherwise. Without this
# guard a deleted runner read identically to a healthy v1 runner, so status
# reported ARMED while every fire failed.
model_suffix() {
    local runner model
    runner=$(runner_for_name "$1" 2>/dev/null) || return 0
    [ -f "$runner" ] || { printf ' [runner missing]'; return 0; }
    model=$(runner_model "$runner") || return 0
    [ -n "$model" ] && printf ' [model: %s]' "$model"
    return 0
}

# Surface fire-time evidence: each runner writes its claude output to a
# .log next to the runner (rotated per fire — the log holds exactly the
# current run; the previous run survives as .log.prev), so "armed but
# never succeeding" is visible here.
status_log() {
    local log="$1" mtime last
    if [ -f "$log" ]; then
        # GNU `date -r <file>` (Linux/gitbash); on BSD/macOS -r means
        # epoch-seconds, so fall back to stat -f there.
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    # Rotation keeps exactly one prior run as .log.prev (the runner's
    # `mv -f`) — surface it too, so the previous run's outcome stays
    # visible right after a fresh fire truncated the current .log.
    # Absence is normal (fewer than two fires) and stays silent.
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    fi
}

# Emit the JSON settings fragment that wires the auto-approve-safe-bash hook by
# absolute path. hook_path must be a forward-slash, JSON-safe
# absolute path (no backslashes — use cygpath -m on Windows). The command is
# unquoted to match himmel's own .claude/settings.json hook wiring convention.
#
# The fragment also force-enables obsidian-triage@himmel via
# enabledPlugins. The operator disables that plugin INTERACTIVELY (user-scope
# settings.local.json {"obsidian-triage@himmel": false}) — it's the luna clip
# pipeline, unused in hand-driven sessions. But this cadence IS that pipeline,
# so the nightly run must re-enable it. `--settings` is the highest non-managed
# precedence layer (spike-confirmed), so this enabledPlugins
# override wins over the settings.local.json disable and keeps the cadence live.
emit_settings_fragment() {
    local hook_path="$1"
    # Two cadence-scoped controls live beside
    # auto-approve-safe-bash.sh. Derive their paths in the SAME form the caller
    # already resolved for hook_path (cygpath -m on Windows, POSIX elsewhere),
    # so no new path plumbing or signature change is needed. The deny wires
    # FIRST so a run_in_background deny is evaluated before any allow (an exit-2
    # deny wins over a hook allow regardless, but deny-first is unambiguous);
    # the enumerated-engine allow follows; auto-approve stays last. These three
    # are wired ONLY here (cadence-settings.json via --settings), so interactive
    # sessions are untouched.
    # A fourth control on its own matcher. Every hook above is
    # Bash-only, so the PowerShell tool is an unguarded second shell in a
    # cadence session — the health worker emitted the vault-lint engine through it
    # on 2026-08-20 and parked on an approval nobody was awake to give. Deny it
    # and redirect the model to the Bash tool, where the engine grant lives.
    local hooks_dir="${hook_path%/*}"
    local deny_bg_hook="$hooks_dir/cadence-deny-background.sh"
    local approve_engines_hook="$hooks_dir/cadence-approve-engines.sh"
    local deny_pwsh_hook="$hooks_dir/cadence-deny-powershell.sh"
    # Emit an ABSOLUTE interpreter path, never a bare `bash`.
    # Under raw CreateProcess order a bare `bash` resolves to
    # C:\Windows\System32\bash.exe — the WSL stub, which cannot read a
    # C:/Users/... Windows path (the recurring WSL trap). The
    # fragment works today only because the v8 runner format prepends a GNU
    # PATH (1b34a070); that is one PATH change away from silently breaking
    # every cadence hook, and this function emits three such commands. Resolve
    # ONCE here. Mixed (forward-slash) form to match hook_path and stay
    # JSON-safe — `cygpath -m`, never `-w`. Prefer $BASH (the interpreter
    # actually running this script) over a PATH lookup, which a hermetic-PATH
    # stub can shadow.
    local bash_cmd="${BASH:-}"
    [ -n "$bash_cmd" ] || bash_cmd=$(command -v bash 2>/dev/null) || bash_cmd="/usr/bin/bash"
    if command -v cygpath >/dev/null 2>&1; then
        bash_cmd=$(cygpath -m "$bash_cmd" 2>/dev/null || printf '%s' "$bash_cmd")
    fi
    # A System32 resolution IS the WSL stub — reject it outright rather than
    # emitting a fragment that is broken in exactly the way this fix prevents.
    # Probe the common Git-for-Windows prefixes before retaining the canonical
    # path as a legible last-resort value when no installation is executable.
    local git_bash_candidate local_appdata_fs
    # LOCALAPPDATA is Windows-form with backslashes under Git Bash. Fold to
    # forward slashes before building a candidate from it — an un-folded
    # backslash path both fails the `-x` test unreliably AND, if it somehow
    # resolved, would land in bash_cmd and get interpolated raw into the JSON
    # fragment below, where backslashes are invalid JSON escaping.
    # shellcheck disable=SC1003
    local_appdata_fs=$(printf '%s' "${LOCALAPPDATA:-}" | tr '\\' '/')
    case "$bash_cmd" in
        *[Ss]ystem32*)
            bash_cmd=""
            for git_bash_candidate in \
                "C:/Program Files/Git/bin/bash.exe" \
                "C:/Program Files (x86)/Git/bin/bash.exe" \
                "${local_appdata_fs:+${local_appdata_fs}/Programs/Git/bin/bash.exe}"
            do
                [ -n "$git_bash_candidate" ] || continue
                if [ -x "$git_bash_candidate" ]; then
                    bash_cmd="$git_bash_candidate"
                    break
                fi
            done
            # No candidate above was executable — the
            # canonical last-resort assignment below names an interpreter
            # that does NOT exist on this machine. The emitted hook commands
            # will reference it anyway, and hooks fail non-blocking (exit !=
            # 2), so this loses cadence protections SILENTLY. Warn loudly on
            # stderr before falling back (stdout is the JSON fragment the
            # caller consumes — never write this there).
            [ -n "$bash_cmd" ] || echo "WARNING: no usable Git Bash interpreter detected at any candidate prefix; hooks will reference C:/Program Files/Git/bin/bash.exe, which does not exist — cadence hooks will silently fail non-blocking until Git for Windows is installed at a probed prefix." >&2
            [ -n "$bash_cmd" ] || bash_cmd="C:/Program Files/Git/bin/bash.exe"
            ;;
    esac
    # The Git-Bash path contains a space ("C:/Program Files/..."), so the
    # interpreter is quoted in the emitted command — \" in the JSON source,
    # a literal quote in the decoded string. The hook paths are quoted for the
    # same reason (a checkout under a spaced path would otherwise split), which
    # is the convention himmel's own .claude/settings.json hook wiring uses for
    # every argument.
    # A headless cadence session cannot answer a permission ask,
    # so the 2026-10-03 harvest's Skill call came back user-rejected and the
    # whole chain no-oped. Allow exactly the obsidian-triage commands the worker
    # prompts name, plus Read of the plugin's command files as the fallback.
    cat <<JSON
{
  "enabledPlugins": {
    "obsidian-triage@himmel": true
  },
  "permissions": {
    "allow": [
      "Skill(obsidian-triage:harvest-clips)",
      "Skill(obsidian-triage:triage-clips)",
      "Skill(obsidian-triage:ig-media-enrich)",
      "Skill(obsidian-triage:x-media-enrich)",
      "Skill(obsidian-triage:synthesize-clips)",
      "Skill(obsidian-triage:archive-clips)",
      "Skill(obsidian-triage:vault-lint)",
      "Read(~/.claude/plugins/cache/himmel/obsidian-triage/*/commands/*.md)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"${bash_cmd}\" \"${deny_bg_hook}\"" },
          { "type": "command", "command": "\"${bash_cmd}\" \"${approve_engines_hook}\"" },
          { "type": "command", "command": "\"${bash_cmd}\" \"${hook_path}\"" }
        ]
      },
      {
        "matcher": "PowerShell",
        "hooks": [
          { "type": "command", "command": "\"${bash_cmd}\" \"${deny_pwsh_hook}\"" }
        ]
      }
    ]
  }
}
JSON
}

# DOW token -> cron numeric field.
cron_dow() {
    case "$1" in
        MON) printf '1' ;; TUE) printf '2' ;; WED) printf '3' ;;
        THU) printf '4' ;; FRI) printf '5' ;; SAT) printf '6' ;;
        *)   printf '0' ;;
    esac
}

# Validate a per-worker --*-model value. Defense in
# depth: a conservative identifier grammar rejects empty/whitespace and
# every shell/CMD metacharacter BEFORE the value is interpolated into a
# runner, so a model like a"&b can't break the cron re-parse (emit_runner
# additionally pre-quotes with printf '%q'). Known aliases (sonnet|opus|haiku|fable)
# and dotted full ids (containing '.' or a 'claude-' prefix) arm silently;
# any other grammar-valid value earns a non-fatal WARNING so a future
# model name never hard-breaks arming. POSIX-safe `case` (not [[ =~ ]]):
# it matches the WHOLE string, so a trailing newline can't slip a second
# line past an anchored regex the way `grep -E '^...$'` would.
validate_model_name() {
    local flag="$1" val="$2"
    # Grammar: first char [A-Za-z0-9], rest [A-Za-z0-9._:-]*. Glob, not
    # regex: `*[!class]` flags ANY disallowed char anywhere; `[._:-]*`
    # catches a leading . _ : - (and "" catches empty). The '-' is last
    # in each class so it is a literal, not a range endpoint.
    case "$val" in
        ""|*[!A-Za-z0-9._:-]*|[._:-]*)
            echo "ERR pipeline-cadence: $flag must match [A-Za-z0-9][A-Za-z0-9._:-]* (empty, whitespace, and shell/CMD metacharacters are rejected), got: $val" >&2
            return 1
            ;;
    esac
    case "$val" in
        sonnet|opus|haiku|fable) return 0 ;;
        *.*|claude-*) return 0 ;;
        *)
            echo "WARN pipeline-cadence: $flag '$val' is not a known alias (sonnet|opus|haiku|fable) or dotted full id; arming anyway - verify the model name" >&2
            return 0
            ;;
    esac
}

# Input validation for the cron arm path.
validate_arm_inputs() {
    if ! [[ "$FETCH_HEALTH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --fetch-health-time must be HH:MM (24h), got: $FETCH_HEALTH_TIME" >&2
        exit 1
    fi
    if ! [[ "$HARVEST_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --harvest-time must be HH:MM (24h), got: $HARVEST_TIME" >&2
        exit 1
    fi
    if ! [[ "$SYNTH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --synth-time must be HH:MM (24h), got: $SYNTH_TIME" >&2
        exit 1
    fi
    if ! [[ "$IG_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "ERR pipeline-cadence: --ig-limit must be a non-negative integer, got: $IG_LIMIT" >&2
        exit 1
    fi
    # Canonicalise --health-day once, here, so every consumer below (the cron
    # DOW field, the summary block) reads one spelling.
    # bash 3.2 has no ${v^^}.
    HEALTH_DAY=$(printf '%s' "$HEALTH_DAY" | tr '[:lower:]' '[:upper:]')
    case "$HEALTH_DAY" in
        MON|TUE|WED|THU|FRI|SAT|SUN|DAILY) ;;
        *)
            echo "ERR pipeline-cadence: --health-day must be one of MON TUE WED THU FRI SAT SUN DAILY, got: $HEALTH_DAY" >&2
            exit 1 ;;
    esac
    if [ "$HEALTH_DAY" = DAILY ]; then
        HEALTH_CADENCE_LABEL="daily   $HEALTH_TIME"
    else
        HEALTH_CADENCE_LABEL="weekly  $HEALTH_DAY $HEALTH_TIME"
    fi
    if ! [[ "$HEALTH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pipeline-cadence: --health-time must be HH:MM (24h), got: $HEALTH_TIME" >&2
        exit 1
    fi
    # Per-worker model pins: each --*-model must match a
    # conservative identifier grammar ([A-Za-z0-9][A-Za-z0-9._:-]*) -
    # this rejects empty/whitespace AND every shell/CMD metacharacter
    # before the value reaches a runner. The cron emitter additionally
    # pre-quotes it with printf '%q' (emit_runner) - defense in depth, never the sole
    # guard. claude's own runtime error on a bad name is a last line, not
    # the first.
    validate_model_name "--harvest-model" "$HARVEST_MODEL" || exit 1
    validate_model_name "--synth-model"  "$SYNTH_MODEL"  || exit 1
    validate_model_name "--health-model" "$HEALTH_MODEL" || exit 1
    if [ ! -d "$VAULT" ]; then
        echo "ERR pipeline-cadence: --vault is not a directory: $VAULT" >&2
        exit 1
    fi
}

# --- POSIX (cron) implementation ------------------------------
#
# arm/status/disarm against the user crontab. Every cadence entry lives
# in ONE crontab rewrite (snapshot -> filter -> append -> install), so
# there is no half-armed state to roll back. Each runner .sh does log
# rotation, fire stamp, cd-into-vault, bounded interactive claude run.

CRON_RUNNER_FETCH_HEALTH="$BAT_DIR/pipeline-fetch-health.sh"
CRON_RUNNER_HARVEST="$BAT_DIR/pipeline-harvest.sh"
CRON_RUNNER_SYNTH="$BAT_DIR/pipeline-synthesize.sh"
CRON_RUNNER_HEALTH="$BAT_DIR/pipeline-health.sh"

# Shell-quote a value for a cron command line: printf %q survives the
# /bin/sh re-parse at fire time for ordinary path-shaped values (no
# control characters). The extra % -> \% pass is cron(5) syntax — an
# unescaped % ends the command and becomes stdin.
# Control characters are rejected (rc=2): bash's printf %q emits
# ANSI-C $'...' quoting for them, which dash/sh can't parse at cron
# fire time. Paths and prompts never legitimately contain them.
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR pipeline-cadence: cron_escape: argument contains control characters — rejected" >&2
        return 2
    fi
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the current crontab into the CRON_TAB global. Fail-CLOSED: any
# nonzero rc is fatal UNLESS it matches the trusted
# no-crontab-yet signature — rc=1 with EMPTY stderr or the standard
# "no crontab for <user>" message. A failed listing must never read as
# "nothing armed" (arm would double-register; disarm would no-op and
# delete the runners while the entries stay armed).
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    set +e
    # LC_ALL=C pins the message shape where locales apply, so the
    # 'no crontab' signature grep below isn't defeated by translation.
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR pipeline-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
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

# Install a new crontab from the given file (via stdin, the arm-resume
# precedent). Returns 4 on failure (callers exit 4 — cmd_arm sweeps its
# staged temp runners first); the rejected tab is kept for forensics.
cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t pipeline-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR pipeline-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        echo "    rejected crontab left at: $tab_file" >&2
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged cadence lines in the current CRON_TAB (empty if none).
cron_existing() {
    printf '%s\n' "$CRON_TAB" | grep -F "$TASK_PREFIX" || true
}

# runner_path_snapshot <path> <node_dir>
# The PATH value both cron emitters (emit_runner, emit_fetch_health_runner)
# stamp into their generated runners: the FULL arm-time $PATH
# snapshot, so under cron's minimal PATH=/usr/bin:/bin every arm-time user bin
# dir (~/.local/bin uv tools, bun, cargo, go, ...) is found — not just node's
# directory the way emit_runner's old prepend-only line
# (`export PATH=<node_dir>:$PATH`) did (the bug that left ig-media-enrich
# unable to find gallery-dl). <node_dir> (from #317: nvm-managed node is not
# on cron's PATH even when the claude shim resolves) is prepended ONLY when
# the snapshot does not already contain it, so both emitters now agree.
# Echoes the %q-quoted PATH value (printf-embeddable) on stdout.
runner_path_snapshot() {
    local path="$1" node_dir="$2" full="$1"
    if [ -n "$node_dir" ]; then
        case ":$path:" in
            *":$node_dir:"*) ;;
            *) full="$node_dir:$path" ;;
        esac
    fi
    printf '%q' "$full"
}

# Emit the runner .sh body for one cadence task: rotate the run log
# (one prior run kept as .log.prev), stamp the fire time, cd into the
# vault (a failing cd lands in the log instead of silently running
# claude from the wrong CWD), then the bounded interactive claude run
# — `< /dev/null` stdin-EOF, NO -p/--print (billing rule). All values
# arrive pre-quoted with printf %q.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh to expand at fire time
emit_runner() {
    local name="$1" q_vault="$2" q_claude="$3" q_prompt="$4" q_log="$5" q_settings="$6" q_path="${7:-}" q_model="${8:-}" flow="${9:-}" q_flow_lib="${10:-}" q_bank_lib="${11:-}" q_gate_lib="${12:-}" q_alert_lib="${13:-}" q_timeline="${14:-}"
    local q_task q_flow
    q_task=$(printf '%q' "$name")
    q_flow=$(printf '%q' "$flow")
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by pipeline-cadence.sh arm\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Restore the arm-time PATH snapshot so cron's minimal
    # PATH=/usr/bin:/bin still finds every arm-time user bin dir, with node's
    # directory folded in when it isn't already there (#317) — see
    # runner_path_snapshot's header for why this replaced the old
    # node-dir-only prepend.
    printf 'PATH=%s; export PATH\n' "$q_path"
    printf 'log=%s\n' "$q_log"
    printf '# Test log existence BEFORE the capture redirect opens $log.\n'
    printf '# The old brace-group form (`{ [ -f ] && mv; } >> "$log"`) created\n'
    printf '# $log before the test ran, so an absent .log clobbered .log.prev\n'
    printf '# with an empty file (PR430 CR regression).\n'
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    # A runner that dies here never reaches the alert below, so it
    # alerts on this path itself.
    if [ -n "$q_alert_lib" ]; then
        printf '    cd %s || { echo "[%s cd-vault]"; %s fail %s cd-vault "$log" || true; exit 1; }\n' "$q_vault" "$WORKER_SESSION_FAILED_MARKER" "$q_alert_lib" "$q_flow"
    else
        printf '    cd %s || exit 1\n' "$q_vault"
    fi
    # The two gates. Both live INSIDE the `{ } >> $log`
    # group, so each helper's stderr diagnostics land in the worker log while its
    # single verdict token is captured. `exit` from a brace group (not a
    # subshell) exits the runner, so a refused worker never reaches the claude
    # launch below.
    # Gate 1: free filesystem precondition, asked first.
    if [ -n "$q_gate_lib" ]; then
        printf '    _gate=$(%s .) || _gate=\n' "$q_gate_lib"
        printf '    if [ "$_gate" = NONE ]; then\n'
        printf '        echo "[%s no-new-input]"\n' "$WORKER_SESSION_SKIPPED_MARKER"
        printf '        _sid=$(%s --append-start %s "" "" claude %s %s "$log" "$$" 2>/dev/null) || _sid=\n' "$q_flow_lib" "$q_flow" "$q_model" "$q_task"
        printf '        test "$_sid" != "" && %s --append-end %s "$_sid" "" 0 skipped 0 no-new-input >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow"
        printf '        exit 0\n'
        printf '    fi\n'
    fi
    # Gate 2: bank preflight. Only SKIPPED-BANK refuses; the
    # helper's BANK-STALE / BANK-UNKNOWN verdicts are fail-open by design and
    # an empty capture means it could not run at all.
    if [ -n "$q_bank_lib" ]; then
        printf '    _bank=$(CADENCE_USAGE_WORKER=%s %s) || _bank=\n' "$q_flow" "$q_bank_lib"
        printf '    if [ "$_bank" = SKIPPED-BANK ]; then\n'
        printf '        echo "[%s bank-at-threshold]"\n' "$WORKER_SESSION_SKIPPED_MARKER"
        # One skipped night is the guard working; two running is
        # a worker that has silently stopped. The previous night's log is $log.prev.
        if [ -n "$q_alert_lib" ]; then
            printf '        if grep -qF "[%s bank-at-threshold]" "$log.prev" 2>/dev/null; then %s fail %s bank-skip-2-nights "$log" || true; fi\n' "$WORKER_SESSION_SKIPPED_MARKER" "$q_alert_lib" "$q_flow"
        fi
        printf '        _sid=$(%s --append-start %s "" "" claude %s %s "$log" "$$" 2>/dev/null) || _sid=\n' "$q_flow_lib" "$q_flow" "$q_model" "$q_task"
        printf '        test "$_sid" != "" && %s --append-end %s "$_sid" "" 0 skipped 0 bank-at-threshold >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow"
        printf '        exit 0\n'
        printf '    fi\n'
    fi
    # Retry/resume loop. The
    # marker line is what --is-transient scans FORWARD from, so each attempt is
    # judged on its own output; each attempt lands its own start/end ledger
    # pair, the end row tagged attempt=N/MAX.
    printf '    _attempt=1\n'
    printf '    while :; do\n'
    printf '        echo "[%s $_attempt/%s]"\n' "$FLOW_RUN_ATTEMPT_MARKER" "$RETRY_MAX_ATTEMPTS"
    printf '        _flow_run_id=$(%s --append-start %s "" "" claude %s %s "$log" "$$" 2>/dev/null) || _flow_run_id=\n' "$q_flow_lib" "$q_flow" "$q_model" "$q_task"
    # No bg-wait ceiling override here — CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
    # only affects --print mode, and cadence runners are interactive-shaped.
    # --permission-mode is EXPLICIT: never inherit a default that could be
    # bypassPermissions (billing rule).
    printf '        _rc=0; %s --model %s --permission-mode %s --settings %s %s < /dev/null || _rc=$?\n' "$q_claude" "$q_model" "$CADENCE_PERMISSION_MODE" "$q_settings" "$q_prompt"
    # Fail-closed fallback (coderabbit #1762): classifier unavailable/silent ->
    # parked on rc 0, error otherwise -- never complete by default.
    printf '        _flow_outcome=$(%s --classify "$_rc" "$log" "" %s 2>/dev/null) || _flow_outcome=\n' "$q_flow_lib" "$WORKER_SESSION_DONE_MARKER"
    printf '        if [ "$_flow_outcome" = "" ]; then if [ "$_rc" = 0 ]; then _flow_outcome=parked; else _flow_outcome=error; fi; fi\n'
    printf '        test "$_flow_run_id" != "" && %s --append-end %s "$_flow_run_id" "" "$_rc" "$_flow_outcome" "" "attempt=$_attempt/%s" >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow" "$RETRY_MAX_ATTEMPTS"
    # Retry ONLY a non-zero exit whose own attempt log carries the transient
    # upstream signature, and only within the bound. A --is-transient that
    # cannot run answers non-zero, which breaks the loop — fail-closed.
    printf '        [ "$_rc" = 0 ] && break\n'
    printf '        [ "$_attempt" -ge %s ] && break\n' "$RETRY_MAX_ATTEMPTS"
    printf '        %s --is-transient "$_rc" "$log" || break\n' "$q_flow_lib"
    printf '        _delay=%s; [ "$_attempt" -ge 2 ] && _delay=%s\n' "$RETRY_BACKOFF_1" "$RETRY_BACKOFF_2"
    printf '        echo "[retry $_attempt/%s after transient upstream API error - sleeping ${_delay}s]"\n' "$((RETRY_MAX_ATTEMPTS - 1))"
    # Sleep seam (the CHECK_CI_SLEEP_CMD shape) so the hermetic
    # suite can fire a full three-attempt run without waiting four minutes.
    printf '        ${PIPELINE_CADENCE_SLEEP_CMD:-sleep} "$_delay"\n'
    printf '        _attempt=$((_attempt + 1))\n'
    printf '    done\n'
    printf '    echo "[exit rc=$_rc]"\n'
    # A failed worker says so in its log and in the alert sink; a
    # completed one re-arms the sink's dedupe.
    printf '    if [ "$_rc" != 0 ]; then _fail="rc-$_rc"; echo "[%s rc=$_rc]"\n' "$WORKER_SESSION_FAILED_MARKER"
    printf '    elif [ "$_flow_outcome" != complete ]; then _fail=no-completion-marker; echo "[%s no-completion-marker]"\n' "$WORKER_SESSION_FAILED_MARKER"
    printf '    else _fail=; fi\n'
    if [ -n "$q_alert_lib" ]; then
        printf '    if [ "$_fail" != "" ]; then %s fail %s "$_fail" "$log" || true; else %s clear %s || true; fi\n' "$q_alert_lib" "$q_flow" "$q_alert_lib" "$q_flow"
    fi
    # Completion stamp — `complete` only.
    if [ -n "$q_gate_lib" ]; then
        printf '    { [ "$_flow_outcome" = complete ] && %s --stamp .; } || true\n' "$q_gate_lib"
    fi
    # Refresh the day note's `## Clip pipeline` + `## Daily report`
    # sections after the worker. Must-not-abort: it runs after _rc / _flow_outcome
    # are final and writes only its own _tl_rc, so a failing timeline logs and
    # the runner's exit code and the WORKER-FAILED logic above are untouched.
    if [ -n "$q_timeline" ]; then
        printf '    _tl_rc=0; node %s --vault %s --date "$(date +%%Y-%%m-%%d)" || _tl_rc=$?\n' "$q_timeline" "$q_vault"
        printf '    if [ "$_tl_rc" != 0 ]; then echo "[daily-timeline failed rc=$_tl_rc - continuing]"; fi\n'
    fi
    printf '} >> "$log" 2>&1\n'
# A parked worker (zero rc, no marker) exits 3 so cron/the operator
# sees a failure; it covers any
    # zero-rc outcome short of complete (truncated too): a no-op is not green.
    printf 'if [ "$_rc" = 0 ] && [ "$_flow_outcome" != complete ]; then exit 3; fi\n'
    printf 'exit "$_rc"\n'
}

# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh to expand at fire time
emit_fetch_health_runner() {
    local q_python="$1" q_script="$2" q_log="$3" q_path="$4" q_env_file="$5" q_flow_lib="$6" q_alert_lib="${7:-}"
    local q_task q_flow
    q_task=$(printf '%q' "$TASK_FETCH_HEALTH")
    q_flow=$(printf '%q' "pipeline-fetch-health")
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by pipeline-cadence.sh arm\n' "$TASK_FETCH_HEALTH"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # Restore the arm-time PATH snapshot (runner_path_snapshot) so
    # the probes' shelled-out CLIs (gallery-dl, twitter, gh) resolve under
    # cron's minimal PATH=/usr/bin:/bin, and source the repo's gitignored .env
    # (if present) so env-sourced credentials (Twitter/Firecrawl) are available
    # — mirrors fetch-health.py's load_repo_env. Both lines flow through printf
    # %s with pre-quoted q_ vars (SC2016-safe).
    printf 'PATH=%s; export PATH\n' "$q_path"
    printf '[ -f %s ] && . %s\n' "$q_env_file" "$q_env_file"
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" || exit 1; fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    # Flow-run ledger rows, so the FetchHealth worker is visible to stall /
    # never-started detection. Outcome derived from the rc (no LLM, so no
    # truncation/parked state to classify).
    printf '    _flow_run_id=$(%s --append-start %s "" "" python "" %s "$log" "$$" 2>/dev/null) || _flow_run_id=\n' "$q_flow_lib" "$q_flow" "$q_task"
    printf '    _rc=0; %s %s || _rc=$?\n' "$q_python" "$q_script"
    printf '    _flow_outcome=complete; [ "$_rc" = 0 ] || _flow_outcome=error\n'
    printf '    test "$_flow_run_id" != "" && %s --append-end %s "$_flow_run_id" "" "$_rc" "$_flow_outcome" "" "" >/dev/null 2>&1 || true\n' "$q_flow_lib" "$q_flow"
    printf '    echo "[exit rc=$_rc]"\n'
    # A probe going bad is a cadence failure like any other.
    if [ -n "$q_alert_lib" ]; then
        printf '    if [ "$_rc" != 0 ]; then %s fail %s probe-bad "$log" || true; else %s clear %s || true; fi\n' "$q_alert_lib" "$q_flow" "$q_alert_lib" "$q_flow"
    fi
    printf '    exit "$_rc"\n'
    printf '} >> "$log" 2>&1\n'
}

cmd_status() {
    cron_read
    echo "pipeline-cadence status:"
    local name log entry sched n_entries dup
    for name in "$TASK_FETCH_HEALTH" "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
        case "$name" in
            "$TASK_FETCH_HEALTH") log="$BAT_DIR/pipeline-fetch-health.log" ;;
            "$TASK_HARVEST") log="$BAT_DIR/pipeline-harvest.log" ;;
            "$TASK_SYNTH")  log="$BAT_DIR/pipeline-synthesize.log" ;;
            *)              log="$BAT_DIR/pipeline-health.log" ;;
        esac
        entry=$(printf '%s\n' "$CRON_TAB" | grep -F "# $name" | head -1 || true)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            n_entries=$(printf '%s\n' "$CRON_TAB" | grep -cF "# $name" || true)
            dup=""
            [ "$n_entries" -gt 1 ] && dup=" [DUPLICATE: $n_entries cron entries]"
            echo "ARMED      $name (cron: $sched)$dup$(task_summary "$name")$(model_suffix "$name")"
        else
            echo "not armed  $name$(task_summary "$name")"
        fi
        status_log "$log"
    done
}

cmd_disarm() {
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        # Trusted-empty read (cron_read exits 2 otherwise) — safe to
        # sweep the runners.
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER_FETCH_HEALTH" "$CRON_RUNNER_HARVEST" "$CRON_RUNNER_SYNTH" "$CRON_RUNNER_HEALTH" "$SETTINGS_FRAGMENT"
        fi
        echo "pipeline-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY pipeline-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY pipeline-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t pipeline-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" > "$newtab" || true
    # Ordering invariant: install must succeed BEFORE the runners are
    # removed — a failed install (exit 4) leaves the entries live and
    # they must keep pointing at existing runner files.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER_FETCH_HEALTH" "$CRON_RUNNER_HARVEST" "$CRON_RUNNER_SYNTH" "$CRON_RUNNER_HEALTH" "$SETTINGS_FRAGMENT"
    echo "pipeline-cadence: cadence disarmed"
}

cmd_arm() {
    validate_arm_inputs

    # Resolve claude to an absolute path so the cron entry doesn't
    # depend on cron's minimal PATH. Also capture node's directory so
    # the runner can prepend it to PATH — nvm-managed node won't be in
    # cron's minimal PATH even when claude_bin is an absolute shim (#317).
    local claude_bin node_dir python_bin
    if ! claude_bin=$(command -v claude 2>/dev/null); then
        echo "ERR pipeline-cadence: 'claude' not on PATH at arm time" >&2
        exit 2
    fi
    if python_bin=$(command -v python3 2>/dev/null); then
        :
    elif python_bin=$(command -v python 2>/dev/null); then
        :
    else
        echo "ERR pipeline-cadence: python3/python not on PATH at arm time (required for fetch-health)" >&2
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then
        node_dir=$(dirname "$node_bin")
    fi

    # Pre-trust the vault dir: a
    # cron-fired claude run (stdin /dev/null) has no human to answer Claude
    # Code's interactive workspace-trust prompt, so an untrusted cwd wastes
    # the run. Non-fatal: a pre-seed failure must never block the arm.
    local _pc_lib
    _pc_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/ensure-workspace-trust.sh"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would pre-trust workspace '$VAULT' in ~/.claude.json"
    else
        "$_pc_lib" "$VAULT" \
            || echo "WARN pipeline-cadence: workspace-trust pre-seed failed for '$VAULT' (arm continues; first run may prompt to trust the folder)" >&2
    fi

    # Dedup guard — never double-register the cadence. The actual
    # removal under --force happens in the single rewrite below.
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "pipeline-cadence: --force set; replacing existing cadence entries:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY pipeline-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR pipeline-cadence: HIMMEL-Pipeline-* crontab entries already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/pipeline-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_vault q_claude q_python q_fetch_script q_runner_path q_flow_lib q_bank_lib q_gate_lib q_alert_lib q_timeline q_harvest_prompt q_synth_prompt q_health_prompt q_log_fetch_health q_log_harvest q_log_synth q_log_health q_harvest_model q_synth_model q_health_model
    q_vault=$(printf '%q' "$VAULT")
    q_claude=$(printf '%q' "$claude_bin")
    q_python=$(printf '%q' "$python_bin")
    q_fetch_script=$(printf '%q' "$HIMMEL_ROOT/scripts/luna/fetch-health.py")
    q_flow_lib=$(printf '%q' "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh")
    q_bank_lib=$(printf '%q' "$BANK_PREFLIGHT")
    q_gate_lib=$(printf '%q' "$SYNTH_GATE")
    q_alert_lib=$(printf '%q' "$CADENCE_ALERT")
    q_timeline=$(printf '%q' "$HIMMEL_ROOT/marketplace/plugins/obsidian-triage/tools/daily-timeline.mjs")
    # Shared arm-time PATH snapshot — one helper, both emitters,
    # so they can no longer disagree about what a cadence runner's PATH is.
    q_runner_path=$(runner_path_snapshot "$PATH" "$node_dir")
    q_harvest_prompt=$(printf '%q' "$HARVEST_PROMPT")
    q_synth_prompt=$(printf '%q' "$SYNTH_PROMPT")
    q_health_prompt=$(printf '%q' "$HEALTH_PROMPT")
    q_log_fetch_health=$(printf '%q' "$BAT_DIR/pipeline-fetch-health.log")
    q_log_harvest=$(printf '%q' "$BAT_DIR/pipeline-harvest.log")
    q_log_synth=$(printf '%q' "$BAT_DIR/pipeline-synthesize.log")
    q_log_health=$(printf '%q' "$BAT_DIR/pipeline-health.log")
    q_harvest_model=$(printf '%q' "$HARVEST_MODEL")
    q_synth_model=$(printf '%q' "$SYNTH_MODEL")
    q_health_model=$(printf '%q' "$HEALTH_MODEL")
    # Settings fragment: the `claude --settings` target, shared by
    # the three Claude runners. The hook path inside the fragment is the POSIX absolute
    # path (JSON-safe — no backslashes — and bash-readable).
    local q_settings
    q_settings=$(printf '%q' "$SETTINGS_FRAGMENT")
    # Repo .env path for the fetch-health runner (its PATH comes from the
    # shared q_runner_path snapshot above): under real cron (no user env) the
    # probes' env-sourced credentials go missing. Sourced at fire time, never
    # embedded — secrets stay in the gitignored file.
    local q_env_file
    q_env_file=$(printf '%q' "$HIMMEL_ROOT/.env")
    [ -r "$AUTO_APPROVE_HOOK" ] || \
        echo "WARN pipeline-cadence: auto-approve hook not readable at $AUTO_APPROVE_HOOK (cadence runs may stall on compound-bash prompts)" >&2
# The cadence-scoped hooks need the same readability check as AUTO_APPROVE_HOOK.
    local hooks_dir_check="${AUTO_APPROVE_HOOK%/*}"
    [ -r "$hooks_dir_check/cadence-deny-background.sh" ] || \
        echo "WARN pipeline-cadence: deny-background hook not readable at $hooks_dir_check/cadence-deny-background.sh (background-command denies will be silently absent)" >&2
    [ -r "$hooks_dir_check/cadence-approve-engines.sh" ] || \
        echo "WARN pipeline-cadence: approve-engines hook not readable at $hooks_dir_check/cadence-approve-engines.sh (engine calls will prompt or stall)" >&2
    [ -r "$hooks_dir_check/cadence-deny-powershell.sh" ] || \
        echo "WARN pipeline-cadence: deny-powershell hook not readable at $hooks_dir_check/cadence-deny-powershell.sh (PowerShell-tool calls will bypass every cadence guardrail)" >&2

    local fetch_health_hh fetch_health_mm harvest_hh harvest_mm synth_hh synth_mm health_hh health_mm
    fetch_health_hh="${FETCH_HEALTH_TIME%:*}"; fetch_health_mm="${FETCH_HEALTH_TIME#*:}"
    harvest_hh="${HARVEST_TIME%:*}"; harvest_mm="${HARVEST_TIME#*:}"
    synth_hh="${SYNTH_TIME%:*}"; synth_mm="${SYNTH_TIME#*:}"
    health_hh="${HEALTH_TIME%:*}"; health_mm="${HEALTH_TIME#*:}"
    local entry_fetch_health entry_harvest entry_synth entry_health
    entry_fetch_health="$fetch_health_mm $fetch_health_hh * * * $(cron_escape "$CRON_RUNNER_FETCH_HEALTH") # $TASK_FETCH_HEALTH"
    entry_harvest="$harvest_mm $harvest_hh * * * $(cron_escape "$CRON_RUNNER_HARVEST") # $TASK_HARVEST"
    entry_synth="$synth_mm $synth_hh * * * $(cron_escape "$CRON_RUNNER_SYNTH") # $TASK_SYNTH"
    local health_dow='*'
    [ "$HEALTH_DAY" = DAILY ] || health_dow=$(cron_dow "$HEALTH_DAY")
    entry_health="$health_mm $health_hh * * $health_dow $(cron_escape "$CRON_RUNNER_HEALTH") # $TASK_HEALTH"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY pipeline-cadence: would write $SETTINGS_FRAGMENT:"
        emit_settings_fragment "$AUTO_APPROVE_HOOK" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_FETCH_HEALTH:"
        emit_fetch_health_runner "$q_python" "$q_fetch_script" "$q_log_fetch_health" "$q_runner_path" "$q_env_file" "$q_flow_lib" "$q_alert_lib" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_HARVEST:"
        emit_runner "$TASK_HARVEST" "$q_vault" "$q_claude" "$q_harvest_prompt" "$q_log_harvest" "$q_settings" "$q_runner_path" "$q_harvest_model" "pipeline-harvest" "$q_flow_lib" "$q_bank_lib" "" "$q_alert_lib" "$q_timeline" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_SYNTH:"
        emit_runner "$TASK_SYNTH" "$q_vault" "$q_claude" "$q_synth_prompt" "$q_log_synth" "$q_settings" "$q_runner_path" "$q_synth_model" "pipeline-synthesize" "$q_flow_lib" "$q_bank_lib" "$q_gate_lib" "$q_alert_lib" "$q_timeline" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would write $CRON_RUNNER_HEALTH:"
        emit_runner "$TASK_HEALTH" "$q_vault" "$q_claude" "$q_health_prompt" "$q_log_health" "$q_settings" "$q_runner_path" "$q_health_model" "pipeline-health" "$q_flow_lib" "$q_bank_lib" "" "$q_alert_lib" | sed 's/^/    /'
        echo "DRY pipeline-cadence: would add crontab entries:"
        echo "    $entry_fetch_health"
        echo "    $entry_harvest"
        echo "    $entry_synth"
        echo "    $entry_health"
        echo "pipeline-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the runners at temp paths and promote (mv) them only after
    # the crontab install succeeds: writing them in place first would
    # let a failed install (exit 4) leave the OLD crontab live while
    # the runner files already carry the NEW config — a silent
    # half-state under --force re-arm.
    # Stage the settings fragment alongside the runners and promote
    # it on the SAME success gate — writing it in place before the install would
    # leave an orphan cadence-settings.json on a failed fresh arm, and under a
    # --force re-arm that changes HIMMEL_ROOT then fails to install, the live old
    # runners would silently pick up the new hook path via the shared fragment.
    local tmp_fetch_health="$CRON_RUNNER_FETCH_HEALTH.tmp.$$" tmp_harvest="$CRON_RUNNER_HARVEST.tmp.$$" tmp_synth="$CRON_RUNNER_SYNTH.tmp.$$" tmp_health="$CRON_RUNNER_HEALTH.tmp.$$"
    local tmp_settings="$SETTINGS_FRAGMENT.tmp.$$"
    emit_settings_fragment "$AUTO_APPROVE_HOOK" > "$tmp_settings"
    emit_fetch_health_runner "$q_python" "$q_fetch_script" "$q_log_fetch_health" "$q_runner_path" "$q_env_file" "$q_flow_lib" "$q_alert_lib" > "$tmp_fetch_health"
    emit_runner "$TASK_HARVEST" "$q_vault" "$q_claude" "$q_harvest_prompt" "$q_log_harvest" "$q_settings" "$q_runner_path" "$q_harvest_model" "pipeline-harvest" "$q_flow_lib" "$q_bank_lib" "" "$q_alert_lib" "$q_timeline" > "$tmp_harvest"
    emit_runner "$TASK_SYNTH"  "$q_vault" "$q_claude" "$q_synth_prompt"  "$q_log_synth"  "$q_settings" "$q_runner_path" "$q_synth_model"   "pipeline-synthesize" "$q_flow_lib" "$q_bank_lib" "$q_gate_lib" "$q_alert_lib" "$q_timeline" > "$tmp_synth"
    emit_runner "$TASK_HEALTH" "$q_vault" "$q_claude" "$q_health_prompt" "$q_log_health" "$q_settings" "$q_runner_path" "$q_health_model"  "pipeline-health" "$q_flow_lib" "$q_bank_lib" "" "$q_alert_lib" > "$tmp_health"
    chmod +x "$tmp_fetch_health" "$tmp_harvest" "$tmp_synth" "$tmp_health"

    # Single atomic rewrite: everything that isn't ours, then all four
    # cadence entries.
    local newtab
    newtab=$(mktemp -t pipeline-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" || true
        fi
        printf '%s\n' "$entry_fetch_health" "$entry_harvest" "$entry_synth" "$entry_health"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        # Pre-existing runners were never touched; sweep the staged
        # new-config ones (runners + fragment) so no half-state survives.
        rm -f "$tmp_fetch_health" "$tmp_harvest" "$tmp_synth" "$tmp_health" "$tmp_settings"
        echo "    existing runner files left untouched" >&2
        exit 4
    fi
    mv -f "$tmp_fetch_health" "$CRON_RUNNER_FETCH_HEALTH"  # prim-ok: publish the pre-chmod-ed runner after cron succeeds; atomic_write resets executable permissions.
    mv -f "$tmp_harvest" "$CRON_RUNNER_HARVEST"  # prim-ok: preserve the staged executable mode at publication.
    mv -f "$tmp_synth"  "$CRON_RUNNER_SYNTH"  # prim-ok: preserve the staged executable mode at publication.
    mv -f "$tmp_health" "$CRON_RUNNER_HEALTH"  # prim-ok: preserve the staged executable mode at publication.
    mv -f "$tmp_settings" "$SETTINGS_FRAGMENT"  # prim-ok: promote the prepared fragment with its runners only after cron succeeds, without another allocation.
    for _t in "$TASK_FETCH_HEALTH" "$TASK_HARVEST" "$TASK_SYNTH" "$TASK_HEALTH"; do
        cadence_prov_record "$_t"
    done

    cat <<EOF

================================================================
  PIPELINE CADENCE ARMED
  $TASK_FETCH_HEALTH  daily   $FETCH_HEALTH_TIME  [no LLM]  -> clip-source fetch probes
  $TASK_HARVEST  daily   $HARVEST_TIME  [model: $HARVEST_MODEL]  -> $DAILY_CHAIN
  $TASK_SYNTH    daily   $SYNTH_TIME    [model: $SYNTH_MODEL]    -> /synthesize-clips + /archive-clips
  $TASK_HEALTH   $HEALTH_CADENCE_LABEL   [model: $HEALTH_MODEL]   -> vault-lint (obsidian-triage:vault-lint)
  Vault: $VAULT
  Runner .sh: $BAT_DIR

  Sessions launch as bounded interactive claude runs (stdin from
  /dev/null) in the vault directory. Disarm anytime with:
      bash scripts/luna/pipeline-cadence.sh disarm
================================================================
EOF
    macos_fda_warn_if_needed "$VAULT"
}

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
