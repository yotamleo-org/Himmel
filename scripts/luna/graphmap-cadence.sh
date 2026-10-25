#!/usr/bin/env bash
# graphmap-cadence.sh — arm/status/disarm the recurring graphify curated-map
# cadence.
#
# WHY: graphify graphs are point-in-time snapshots that drift as the corpus
# changes. scripts/graphify/refresh-graph-map.sh is the schedulable
# RUNNER that does a fence-safe incremental refresh + republishes a curated MOC
# for ONE corpus. What was missing is the scheduler/arm layer. This is that
# layer: a SEPARATE OS-scheduler cadence (Option B) that bounds graph drift with
# TWO tiers:
#   - STRUCTURAL/AST (`graphify update <corpus> --force`): pure local parse, no
#     LLM, no API key, no bank, no egress. Cheap enough to run HOURLY.
#   - SEMANTIC (refresh-graph-map.sh: LLM extraction of markdown docs + curated
#     MOC/community naming): the only tier that costs anything. Runs WEEKLY on
#     the claude-cli backend (see BACKEND below), drawing the SAME interactive
#     5h/weekly Anthropic bank as a live session, gated by usage-preflight.sh
#     inside refresh-graph-map.sh (SKIPPED-BANK stops the run instead of
#     draining the bank unattended).
# Cheap+free runs often, expensive+paid runs rarely: a daily semantic tier that
# bank-preflight silently no-ops whenever the 5h/weekly bank is tight would
# leave the structural graph, which needs no bank at all, stale for no reason.
#
# DESIGN DIFFERENCE from the sibling pipeline-cadence.sh: pipeline-cadence fires
# interactive `claude "<prompt>" < NUL` bounded sessions (each pipeline task = a
# claude session, wired with a --settings auto-approve fragment). THIS scheduler
# fires DETERMINISTIC commands directly — `bash <himmel>/scripts/graphify/
# refresh-graph-map.sh <args>` for the semantic pair, `bash <himmel>/scripts/
# graphify/ast-update.sh <corpus>` for the structural pair (routed
# through the promote-lock wrapper rather than a bare `graphify update` call)
# — so NEITHER pair ever opens a claude SESSION, NO NUL-stdin, NO settings
# fragment, and NO auto-approve hook.
# That keeps pipeline-cadence's "every task = a claude session" invariant
# clean, and makes this scheduler strictly simpler than its sibling.
# The semantic BACKEND is `claude-cli` (there is no kimi backend). Unlike
# pipeline-cadence's interactive `claude "<prompt>" < NUL` sessions, the
# semantic pair never opens a claude SESSION itself — graphify (shelled by
# refresh-graph-map.sh) is what shells the local `claude` CLI headlessly for
# extraction, so claude invocation billing DOES apply (the same
# 5h/weekly interactive bank as a live session), and refresh-graph-map.sh
# gates every claude-cli fire on usage-preflight.sh before it shells `claude`
# (SKIPPED-BANK stops the run rather than draining the bank unattended). The
# structural pair never talks to any provider and needs no gate.
#
# FENCE SAFETY: refresh-graph-map.sh never extracts on a live vault — it copies
# the corpus to a PID-owned scratchpad, carries the `.graphify-corpus` marker,
# and only publishes the curated MOC back into the vault's 60-Maps/. That
# discipline lives in the runner; this scheduler just fires it.
#
# OPERATOR FLIP: arming this cadence commits to an HOURLY free structural
# extraction per corpus (no bank, no egress) AND a WEEKLY semantic extraction
# per corpus on the claude-cli backend (draws the SAME
# interactive 5h/weekly Anthropic bank as a live session, gated by
# usage-preflight.sh inside refresh-graph-map.sh). It never auto-arms —
# `arm` registers all five tasks only when explicitly invoked, so the
# operator decides.
#
# Five tasks are registered:
#   HIMMEL-GraphMap-Luna       weekly, semantic (default Sunday 13:00 local)
#       bash <himmel>/scripts/graphify/refresh-graph-map.sh --name luna ...
#   HIMMEL-GraphMap-Himmel     weekly, semantic (default Sunday 13:20 local)
#       bash <himmel>/scripts/graphify/refresh-graph-map.sh --name himmel ...
#   HIMMEL-GraphMapAst-Luna    DAILY, structural, free (default 00:05 local)
#       bash <himmel>/scripts/graphify/ast-update.sh <vault>
#   HIMMEL-GraphMapAst-Himmel  hourly, structural, free (default :15 past)
#       bash <himmel>/scripts/graphify/ast-update.sh <himmel repo>
#   (ast-update.sh runs `graphify update <corpus> --force` itself, behind the
#   promote lock shared with the semantic pair -- see that
#   script's header.)
#   HIMMEL-GraphPublish-Himmel  every 6h, free (default :35 past)
#       bash <himmel>/scripts/graphify/graph-cadence.sh <himmel repo>
#   (graph-cadence.sh measures staleness against origin/main and, above its
#   --threshold, refreshes + opens/refreshes a publish PR + auto-merges it
#   through merge-on-green.sh — see that script's own header for the full
#   design, including why it operates in a DEDICATED worktree rather than
#   this repo's own checkout. himmel-only in v1 — see docs/internals/
#   graph-cadence.md for the one-line note on adding a second corpus.)
#
# WHY SUNDAY 13:00 / 13:20 LOCAL for the semantic pair (staggered 20 min apart,
# weekly): a quiet day/time
# default; the stagger REDUCES THE CHANCE of the two extraction jobs
# overlapping (it cannot guarantee no overlap — luna and himmel are different
# corpora / out dirs, so the per-out-dir promote lock does not serialize them).
# claude-cli draws the operator's own interactive bank rather than a metered
# API, so these times are a quiet-hours default, not a provider off-peak
# window. WHY :05 / :15 PAST THE HOUR for the structural pair (10 min
# apart, tighter than the semantic stagger — these legs are seconds-to-minutes,
# not the semantic legs' LLM-bound runtime): same overlap-reduction rationale,
# scaled to how fast a local AST re-parse actually is. The backend/day/hour
# offsets are fixed as BACKEND/WEEKLY_DAY_*/AST_*_TIME in this script — not
# flags; edit + re-arm to change them.
#
# Usage:
#   bash scripts/luna/graphmap-cadence.sh arm [--luna-time HH:MM]
#       [--himmel-time HH:MM] [--vault PATH] [--force] [--dry-run]
#   bash scripts/luna/graphmap-cadence.sh status
#   bash scripts/luna/graphmap-cadence.sh disarm
#
# --luna-time/--himmel-time apply ONLY to the weekly semantic pair; the
# structural pair's fire offsets are not
# operator-configurable (see WHY :05/:15 above).
#
# Test seams (used by test-graphmap-cadence.sh):
#   GRAPHMAP_CRONTAB   — command invoked instead of `crontab`
#   GRAPHMAP_BAT_DIR   — where the persistent runners (.sh) live
#
# Exit codes (mirrors pipeline-cadence.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no crontab; unsupported platform; runner missing;
#      query tool errored)
#   3  dedup block — HIMMEL-GraphMap-* task(s) already armed; use --force
#   4  scheduler invocation failed (crontab rewrite)
set -euo pipefail

TASK_PREFIX="HIMMEL-GraphMap-"
TASK_LUNA="${TASK_PREFIX}Luna"
TASK_HIMMEL="${TASK_PREFIX}Himmel"
# Structural (AST) pair: a DISTINCT prefix so these can
# never collide with the semantic pair above.
TASK_AST_PREFIX="HIMMEL-GraphMapAst-"
TASK_AST_LUNA="${TASK_AST_PREFIX}Luna"
TASK_AST_HIMMEL="${TASK_AST_PREFIX}Himmel"
# Publish leg: a FIFTH, standalone task -- refresh+publish+
# auto-merge himmel's own graphify graph via scripts/graphify/graph-cadence.sh.
# Distinct prefix from both the semantic and structural pairs above, same
# rationale as TASK_AST_PREFIX: it must never collide with an operator's own
# task, and its own dedicated match keeps it out of --ast-only's scope (see
# every "AST_ONLY" gate below -- this task is unconditional, like the AST
# pair, but tracked separately so a future v2 multi-corpus config need not
# touch the --ast-only semantics of the other two pairs).
TASK_PUBLISH_PREFIX="HIMMEL-GraphPublish-"
TASK_PUBLISH_HIMMEL="${TASK_PUBLISH_PREFIX}Himmel"
# Luna semantic leg: batch-capped claude-api semantic-update.sh over the vault.
# Opt-in (--with-luna-semantic), cron-only, arms PAUSED. Own prefix, same exact-name rule as above.
TASK_SEMANTIC_LUNA="HIMMEL-GraphSemantic-Luna"
# Exact-name match for "does this task/cron-entry belong to THIS cadence"
# is built from the owned names only, used by
# list_existing/cron_existing/the crontab own-entry filters so arm/status/
# disarm treat exactly these as one cadence family. A dash-less PREFIX
# match used to sit here and would catch an operator's own unrelated
# "HIMMEL-GraphMap*" task/cron-entry too — collateral delete on disarm, or a
# false dedup-block on arm. Adding a task later means adding it to this
# alternation, not widening a prefix.
TASK_MATCH_RE="(${TASK_LUNA}|${TASK_HIMMEL}|${TASK_AST_LUNA}|${TASK_AST_HIMMEL}|${TASK_PUBLISH_HIMMEL}|${TASK_SEMANTIC_LUNA})"
CRONTAB_BIN="${GRAPHMAP_CRONTAB:-crontab}"

# User-home resolution (mirrors pipeline-cadence's resolve_user_home). /tmp is
# the last-resort floor when HOME is unset.
resolve_user_home() {
    printf '%s' "${HOME:-/tmp}"
}

# Persistent runner home (.sh runners) — NOT mktemp: these
# tasks recur daily and %TEMP% / /tmp are subject to cleanup sweeps that would
# silently kill the cadence (same rationale as pipeline-cadence's BAT_DIR).
BAT_DIR="${GRAPHMAP_BAT_DIR:-$(resolve_user_home)/.claude/graphmap-cadence}"
# touch "$BAT_DIR/$SEMANTIC_PAUSE_MARKER" pauses the publish leg's semantic pass; rm resumes it.
SEMANTIC_PAUSE_MARKER="semantic.paused"

# Resolve the himmel root from this script's own location (scripts/luna/..),
# so the runner fires the shipped refresh-graph-map.sh by absolute path.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
REFRESH_SCRIPT="$HIMMEL_ROOT/scripts/graphify/refresh-graph-map.sh"
# ONE resolver for the out-of-corpus promote destination — see
# graph-out-root.sh for why (Obsidian hangs on the vault-internal
# graphify-out/ churn). Empty for himmel (its graphify-out/ stays tracked +
# in-corpus). Used by both the semantic pair (cron_payload --out-root) and
# the structural pair (ast_cron_payload GRAPHIFY_OUT=) below, so the two legs
# that share one promote lock keep resolving the SAME directory.
# shellcheck source=../graphify/graph-out-root.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/graphify/graph-out-root.sh"
# Structural (AST) pair: routes through the promote-lock
# wrapper, by absolute path, same rationale as REFRESH_SCRIPT above -- see
# ast-update.sh's own header for why (promote lock, shared graphify-out).
AST_UPDATE_SCRIPT="$HIMMEL_ROOT/scripts/graphify/ast-update.sh"
# Publish leg: fires by absolute path, same rationale as
# AST_UPDATE_SCRIPT/REFRESH_SCRIPT above.
PUBLISH_CADENCE_SCRIPT="$HIMMEL_ROOT/scripts/graphify/graph-cadence.sh"
# Luna semantic leg: graph-cadence.sh only wires himmel, so this leg calls semantic-update.sh directly.
SEMANTIC_UPDATE_SCRIPT="$HIMMEL_ROOT/scripts/graphify/semantic-update.sh"
# The observability-registry FLOW NAME must be DERIVED from the same
# corpus-slug computation graph-cadence.sh itself uses (basename(HIMMEL_ROOT),
# sanitized) -- never hardcoded separately: a LITERAL
# "graph-publish-himmel" agreed on both sides still drifts the moment either side's corpus resolution changes -- e.g. a
# checkout named anything but "himmel" -- because a literal is not a
# derivation. Identical sanitization to graph-cadence.sh's own CORPUS_SLUG /
# graph-publish.sh's own corpus_slug (documented duplication, small + stable
# -- same rationale as those two). ONE source (this variable), used at every
# register/unregister call site below.
_publish_corpus_basename="$(basename "$HIMMEL_ROOT")"
PUBLISH_CORPUS_SLUG="$(printf '%s' "$_publish_corpus_basename" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$PUBLISH_CORPUS_SLUG" ] || PUBLISH_CORPUS_SLUG="repo"
PUBLISH_FLOW_NAME="graph-publish-${PUBLISH_CORPUS_SLUG}"

# Runner-format version stamp: emit_bat / emit_runner stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner so a stale-format armed cadence
# is detectable. Reused from the shared lib (same as pipeline-cadence).
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"
# shellcheck source=../lib/observability-registry.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/observability-registry.sh"
# macOS cron Full Disk Access arm-time warning.
# shellcheck source=../lib/macos-fda-warning.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/macos-fda-warning.sh"

# Off-peak defaults for the WEEKLY semantic legs (see the header for the
# Sunday 13:00 / 13:20 local rationale).
LUNA_TIME="13:00"
HIMMEL_TIME="13:20"
# Weekly day-of-week, semantic legs only. Sunday: quiet, low odds
# of colliding with weekday operator work; ONE fixed day shared by both legs
# (the 20-min stagger still separates them within that day).
WEEKLY_DAY_CRON="0"        # cron day-of-week field (0 = Sunday)

# Structural (AST) legs: free, no bank, no claude session.
# Fixed offsets, not operator flags — there's no cost/off-peak reason to make
# these configurable (see the header's WHY :05/:15); 10 minutes apart so the two
# corpora's `graphify update` calls never start in the same instant.
#
# CADENCE IS ASYMMETRIC: himmel fires
# HOURLY, luna only DAILY. Both legs are free either way — the asymmetry is
# about the artifact, not the cost. luna is a live personal vault with an
# auto-committer, so an hourly in-place `graphify update` meant ~24 commits a
# day of graph churn in it; himmel has no auto-committer (/graph-publish owns
# shipping its graph), so nothing accumulates there. For luna these times are
# a time-of-day; for himmel AST_HIMMEL_TIME is the hourly repetition's
# start-of-day anchor, so its minute is what actually recurs.
AST_LUNA_TIME="00:05"
AST_HIMMEL_TIME="00:15"

# Publish leg: every 6 hours, anchored at :35 past. Stagger
# rationale, extending the header's WHY :05/:15-PAST-THE-HOUR note: this leg
# is NOT free like the AST pair -- it can run ast-update.sh, open/refresh a
# PR, and drive merge-on-green.sh's own check-ci watch, all in one fire, so
# it gets the WIDEST offset of any leg on this file (20 min clear of
# AST_HIMMEL_TIME's :15, vs the AST pair's own 10-min mutual stagger) to
# minimize the odds of overlapping a concurrent AST_HIMMEL fire on the SAME
# corpus (both would otherwise contend for ast-update.sh's
# promote lock — skip-not-wait, so a collision just means the publish leg's
# refresh is skipped-and-retried next fire, not a failure, but the wider
# offset makes that the exception rather than the rule). :35 keeps it inside
# the same hour as the other himmel legs (readable in `status`) without
# landing on either one's own minute.
GRAPH_PUBLISH_TIME="00:35"
# Luna semantic leg: every 2h at :50 (publish is :35), capped per fire. ponytail: the cap and the 2.00 USD run
# cap are the proposed defaults awaiting the operator's spend ruling; make them flags if the ruling differs.
LUNA_SEMANTIC_MINUTE="50"
LUNA_SEMANTIC_EVERY_HOURS=2
LUNA_SEMANTIC_MAX_FILES=20
LUNA_SEMANTIC_RUN_USD="2.00"
LUNA_SEMANTIC_PAUSE_MARKER="semantic-luna.paused"

# Default vault resolution (mirrors pipeline-cadence). Honors
# LUNA_VAULT_PATH first, else <home>/Documents/luna. Explicit --vault overrides.
default_vault() {
    if [ -n "${LUNA_VAULT_PATH:-}" ]; then
        printf '%s' "$LUNA_VAULT_PATH"
        return
    fi
    printf '%s/Documents/luna' "$(resolve_user_home)"
}
VAULT="$(default_vault)"
FORCE=0
DRY_RUN=0
# --ast-only: arm/dedup-check ONLY the free structural (AST)
# pair, leaving the weekly semantic pair (and its backend credential
# requirement) untouched/absent. Lets the free legs re-arm independently of
# an operator ruling on the semantic pair's backend/egress. arm-only flag;
# ignored by status/disarm (both already report/remove per-task).
AST_ONLY=0

# --with-publish: the publish leg
# (HIMMEL-GraphPublish-Himmel) opens graph-refresh PRs on a schedule, so
# `arm` registers it only when asked for explicitly. disarm still removes
# it unconditionally if present (idempotent either way).
WITH_PUBLISH=0
# --publish-every-hours N / --publish-semantic: the publish leg's cron interval
# (default 6) and the claude-api semantic pass on top of it.
PUBLISH_EVERY_HOURS=6
PUBLISH_SEMANTIC=0
SEMANTIC_ACTIVE=0
WITH_LUNA_SEMANTIC=0

# Fixed per-corpus map identity (titles/slugs/tags).
LUNA_TITLE="Graphify Luna Map"
LUNA_SLUG="graphify-luna-map"
LUNA_TAG="luna"
HIMMEL_TITLE="Graphify Himmel Map"
HIMMEL_SLUG="graphify-himmel-map"
HIMMEL_TAG="himmel"
# The semantic legs run WEEKLY on the `claude-cli` backend: a semantic leg once
# a week, gated by usage-preflight.sh inside refresh-graph-map.sh (SKIPPED-BANK
# stops the run instead of draining the bank unattended), avoids a daily-drain
# failure mode without needing a second provider. claude-cli authenticates via
# the operator's own Claude Code subscription (no API key) and needs no
# egress-matrix ratification the way an external API backend would.
# Already-armed tasks keep their baked-in --backend until re-armed with this
# default.
BACKEND="claude-cli"

# Resolved by validate_arm_inputs (both arm paths call it): `graphify` itself,
# and its directory. ALL FIVE tasks need it on PATH at fire time — the
# semantic legs (refresh-graph-map.sh shells graphify with --backend
# $BACKEND) and the structural/publish legs (ast-update.sh shells `graphify
# update`) — the scheduler's minimal PATH carries
# neither node nor graphify by default. Both runner formats prepend the
# directory to PATH — see the note in validate_arm_inputs.
GRAPHIFY_BIN=""
GRAPHIFY_DIR=""
# Resolved the same way, semantic pair only (see validate_arm_inputs): under
# BACKEND=claude-cli, graphify shells the local `claude` CLI internally at
# fire time, so its directory must ALSO be on the runner's PATH. Empty when
# --ast-only skips the semantic pair (nothing shells claude then).
CLAUDE_BIN=""
CLAUDE_DIR=""

usage() {
    cat <<'EOF'
Usage: graphmap-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring graphify graph cadence: an HOURLY
free structural (AST) refresh per corpus (`graphify update <corpus> --force`,
via the promote-lock wrapper — no bank, no claude session) AND a WEEKLY
semantic refresh per corpus (fence-safe incremental extraction + curated-MOC
republish, `bash refresh-graph-map.sh ...` on the claude-cli backend — draws
the SAME interactive 5h/weekly Anthropic bank as a live session, gated by
usage-preflight.sh inside refresh-graph-map.sh). The structural pair never
opens a claude session; the semantic pair's claude-cli fire does (headless).

Subcommands:
  arm      Register all four tasks. Dedup-guarded: refuses (rc=3) if any
           HIMMEL-GraphMap-* task already exists; --force replaces.
  status   Show which cadence tasks are armed (+ next run time).
  disarm   Remove all four tasks (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --luna-time <HH:MM>    Weekly luna-map time, 24h local   (default 13:00,
                         semantic leg only)
  --himmel-time <HH:MM>  Weekly himmel-map time, 24h local (default 13:20,
                         semantic leg only; staggered 20min after luna to
                         reduce the chance of the two extraction jobs
                         overlapping — different corpora/out-dirs, so no
                         shared lock serializes them)
  --vault <PATH>         Luna vault root (default: $LUNA_VAULT_PATH if set,
                         else <user-profile>/Documents/luna). The vault's
                         60-Maps/ is where the curated MOCs are published.
  --force                Replace existing HIMMEL-GraphMap-* tasks
  --dry-run              Print what would happen, touch nothing
                         (honored by arm AND disarm)
  --ast-only             Arm/dedup-check ONLY the free structural (AST) pair.
                         The weekly semantic pair is left
                         absent/untouched and its backend credential is not
                         required. Re-arm without --ast-only later to add the
                         semantic pair back in (--force to replace).
  --with-publish         Also register the publish leg
                         (HIMMEL-GraphPublish-Himmel, every 6h). Opt-in:
                         arm leaves it out by default.
  --publish-every-hours N  Publish leg interval in hours (1,2,3,4,6,8,12;
                         default 6). Cron only.
  --publish-semantic     With --with-publish: the publish leg also runs the
                         claude-api semantic pass (graph-cadence --semantic).
                         Cron only. Arms PAUSED: arm writes the
                         semantic.paused marker; rm it to resume.
  --semantic-active      With --publish-semantic or --with-luna-semantic: arm
                         without the marker, so the semantic pass runs from the
                         first fire.
  --with-luna-semantic   Also register the luna semantic leg
                         (HIMMEL-GraphSemantic-Luna, every 2h): capped
                         claude-api semantic-update over the vault. Cron only.
                         Arms PAUSED: arm writes semantic-luna.paused; rm it
                         to resume.

The structural (AST) pair's offsets (luna daily 00:05, himmel hourly at :15)
are NOT flags — see WEEKLY_DAY_*/AST_*_TIME in this script.

WHY Sunday 13:00 / 13:20 local for the semantic pair: a quiet day/time
default, staggered 20min to reduce the chance of the two extraction jobs
overlapping (not a guarantee — they use different corpora/out-dirs, so no
shared lock serializes them). claude-cli draws the operator's own interactive
bank rather than a metered API, so the times are a quiet-hours default, not a
provider off-peak window. The extraction backend is NOT a flag here — it is
fixed as BACKEND in this script (claude-cli); edit it there and re-arm to
change it.
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR graphmap-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR graphmap-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --luna-time)     LUNA_TIME="${2:-}"; shift 2 ;;
        --luna-time=*)   LUNA_TIME="${1#--luna-time=}"; shift ;;
        --himmel-time)   HIMMEL_TIME="${2:-}"; shift 2 ;;
        --himmel-time=*) HIMMEL_TIME="${1#--himmel-time=}"; shift ;;
        --vault)         VAULT="${2:-}"; shift 2 ;;
        --vault=*)       VAULT="${1#--vault=}"; shift ;;
        --force)         FORCE=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --ast-only)      AST_ONLY=1; shift ;;
        --with-publish)  WITH_PUBLISH=1; shift ;;
        --publish-every-hours)   PUBLISH_EVERY_HOURS="${2:-}"; shift 2 ;;
        --publish-every-hours=*) PUBLISH_EVERY_HOURS="${1#--publish-every-hours=}"; shift ;;
        --publish-semantic)      PUBLISH_SEMANTIC=1; shift ;;
        --semantic-active)       SEMANTIC_ACTIVE=1; shift ;;
        --with-luna-semantic)    WITH_LUNA_SEMANTIC=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERR graphmap-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Platform detect (same matrix as pipeline-cadence.sh).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR graphmap-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR graphmap-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

case "$PUBLISH_EVERY_HOURS" in
    1|2|3|4|6|8|12) ;;
    *) echo "ERR graphmap-cadence: --publish-every-hours must be one of 1 2 3 4 6 8 12 (got '$PUBLISH_EVERY_HOURS')" >&2; exit 1 ;;
esac
if [ "$PUBLISH_SEMANTIC" -eq 1 ] && [ "$WITH_PUBLISH" -ne 1 ]; then
    echo "ERR graphmap-cadence: --publish-semantic needs --with-publish" >&2; exit 1
fi

# The semantic pair's backend label must come from the INSTALLED runner's
# baked-in --backend, not this script's current BACKEND constant -- a runner
# armed under an older BACKEND still carries it until re-armed, so reading
# BACKEND here would assert a migration that has not happened on that
# station. "installed: X" (read from the runner file) vs "configured: X"
# (BACKEND, no runner armed yet) stay visually distinct so a reader can tell
# which one they are looking at; a runner that exists but carries no
# --backend flag gets its own explicit label rather than silently falling
# back to "configured".
installed_semantic_backend() {
    local name="$1" runner match
    runner="$BAT_DIR/$name.sh"
    if [ -f "$runner" ]; then
        match=$(grep -o -- '--backend [^[:space:]]*' "$runner" | head -1 || true)
        if [ -n "$match" ]; then
            printf 'installed: %s' "${match#--backend }"
        else
            printf 'installed: no --backend flag in runner'
        fi
    else
        printf 'configured: %s' "$BACKEND"
    fi
}

task_summary() {
    case "$1" in
        "$TASK_LUNA")       printf ' -> refresh-graph-map luna (weekly, semantic, %s)' "$(installed_semantic_backend graphmap-luna)" ;;
        "$TASK_HIMMEL")     printf ' -> refresh-graph-map himmel (weekly, semantic, %s)' "$(installed_semantic_backend graphmap-himmel)" ;;
        "$TASK_AST_LUNA")   printf ' -> graphify update luna (daily, structural, free)' ;;
        "$TASK_AST_HIMMEL") printf ' -> graphify update himmel (hourly, structural, free)' ;;
        "$TASK_PUBLISH_HIMMEL") printf ' -> graph-cadence publish himmel (auto-merge; interval = cron schedule; --publish-semantic adds a billed claude-api pass)' ;;
        "$TASK_SEMANTIC_LUNA") printf ' -> semantic-update luna (every 2h, billed claude-api, capped; pause marker %s)' "$LUNA_SEMANTIC_PAUSE_MARKER" ;;
    esac
}

# Runaway summary for one run log. Prints ONE line, or
# nothing when the file carries none of the three markers (not a graphify run
# log, or a run that died before its first chunk).
#
# Why post-hoc from the log instead of "emit tokens: on abnormal termination":
# graphify accumulates the token counters in memory and prints its `tokens:`
# line only on the normal write path, so a run killed by the run deadline --
# or by the 2026-08-17 reboot -- leaves no token totals ANYWHERE. The numbers
# do not exist to be emitted, by us or by the runner. What the log does carry,
# line by line as it happens, is the runaway's own signature: every hollow
# response graphify reclassifies as truncation so adaptive retry bisects the
# chunk. Counting those alongside the last chunk-progress line reconstructs
# the storm after ANY termination mode -- including the one where no shell of
# ours survives to print anything -- which is what "visible without reading
# the whole log" needs. Emitting real totals on an abnormal exit, and not
# treating hollow as truncation in the first place, are upstream
# (Graphify-Labs/graphify#2880; this repo has read-only access there).
log_summary() {
    # A trailing CR, if any, is stripped before matching.
    # STORM threshold: one chunk bisecting to graphify's max_retry_depth=3 cap
    # issues at most 15 calls, so >15 hollow responses is more than a single
    # bad chunk -- i.e. the sustained storm this ticket exists to catch.
    awk '
        { sub(/\r$/, "") }
        /returned a hollow response/ { hollow++ }
        /[[:space:]]tokens:[[:space:]]/ { tok = substr($0, index($0, "tokens:") + 8) }
        /chunk [0-9]+\/[0-9]+ done/ {
            if (match($0, /chunk [0-9]+\/[0-9]+/)) chunk = substr($0, RSTART, RLENGTH)
        }
        END {
            if (hollow == 0 && tok == "" && chunk == "") exit 0
            out = (tok != "" ? tok : "NO tokens summary (run did not finish)")
            if (chunk != "") out = out " | last " chunk
            # Coerced on its own line: concatenating hollow + 0 inline leans on
            # concatenation binding looser than +, which POSIX awk does but is
            # not worth betting the mawk run on the public mirror against.
            n = hollow + 0
            out = out " | " n " hollow responses"
            if (hollow > 15) out = out " -- HOLLOW-BISECT STORM"
            print out
        }
    ' "$1" 2>/dev/null || true
}

# Surface fire-time evidence: each runner writes its output to a .log next to the
# runner (rotated per fire), so "armed but never succeeding" is visible here.
status_log() {
    local log="$1" mtime last summary
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        echo "  run log    $log (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
        summary=$(log_summary "$log")
        if [ -n "$summary" ]; then
            echo "             run summary: $summary"
        fi
    elif [ -f "$log.prev" ]; then
        echo "  run log    $log (rotated — see .log.prev; no run since last rotation)"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
    if [ -f "$log.prev" ]; then
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
        summary=$(log_summary "$log.prev")
        if [ -n "$summary" ]; then
            echo "             run summary: $summary"
        fi
    fi
}

# Input validation for the cron arm path.
validate_arm_inputs() {
    if ! [[ "$LUNA_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR graphmap-cadence: --luna-time must be HH:MM (24h), got: $LUNA_TIME" >&2
        exit 1
    fi
    if ! [[ "$HIMMEL_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR graphmap-cadence: --himmel-time must be HH:MM (24h), got: $HIMMEL_TIME" >&2
        exit 1
    fi
    if [ ! -d "$VAULT" ]; then
        echo "ERR graphmap-cadence: --vault is not a directory: $VAULT" >&2
        exit 1
    fi
    if [ ! -f "$REFRESH_SCRIPT" ]; then
        echo "ERR graphmap-cadence: refresh-graph-map.sh not found at $REFRESH_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$AST_UPDATE_SCRIPT" ]; then
        echo "ERR graphmap-cadence: ast-update.sh not found at $AST_UPDATE_SCRIPT" >&2
        exit 2
    fi
    if [ ! -f "$PUBLISH_CADENCE_SCRIPT" ]; then
        echo "ERR graphmap-cadence: graph-cadence.sh not found at $PUBLISH_CADENCE_SCRIPT" >&2
        exit 2
    fi
    # FAIL FAST on a missing `graphify`. ALL
    # FIVE tasks need graphify itself on PATH at fire time — the semantic pair
    # via refresh-graph-map.sh (which shells it with --backend $BACKEND), the
    # structural/publish pair via ast-update.sh (`graphify update ...`).
    # Resolving graphify HERE, at arm time, is what makes the failure
    # visible: cron fires with a MINIMAL PATH (no
    # npm-global/cargo bin dir), so without this the arm "succeeds" and the
    # first unattended fire dies in a log nobody reads with "graphify:
    # command not found". The resolved directory is prepended to PATH in
    # the generated .sh runner. `claude` itself is resolved
    # separately below (semantic pair only -- BACKEND is
    # claude-cli).
    if ! GRAPHIFY_BIN=$(command -v graphify 2>/dev/null); then
        {
            echo "ERR graphmap-cadence: 'graphify' not on PATH at arm time, but every armed task shells it at fire time."
            echo "    The scheduler fires with a minimal PATH, so this must resolve HERE — arming now would"
            echo "    produce a cadence that fails on every fire. Install graphify (or put it on PATH)"
            echo "    and re-arm."
        } >&2
        exit 2
    fi
    # `command -v` resolves more than on-PATH executables: a shell FUNCTION or
    # ALIAS resolves to its own name/definition, and a relative PATH entry
    # resolves to a relative path. Either would make GRAPHIFY_DIR meaningless in
    # a runner that has cd'd elsewhere and runs under a different PATH — the
    # exact failure this check exists to prevent, silently reintroduced.
    # Demand a real, absolute, executable
    # file.
    case "$GRAPHIFY_BIN" in
        /*) : ;;
        *)
            echo "ERR graphmap-cadence: 'graphify' resolved to a non-absolute path ('$GRAPHIFY_BIN') — a shell function/alias or a relative PATH entry cannot be pinned into a scheduled runner. Install it on PATH as a real executable and re-arm." >&2
            exit 2 ;;
    esac
    if [ ! -f "$GRAPHIFY_BIN" ] || [ ! -x "$GRAPHIFY_BIN" ]; then
        echo "ERR graphmap-cadence: 'graphify' resolved to '$GRAPHIFY_BIN', which is not an executable file — refusing to pin it into a scheduled runner." >&2
        exit 2
    fi
    GRAPHIFY_DIR=$(dirname "$GRAPHIFY_BIN")
    # --ast-only: the semantic pair is not being armed, so
    # neither its backend credential nor its `claude` resolution is
    # relevant here -- requiring either would defeat the whole point of the
    # flag (arm the free legs without the semantic pair's egress/credential
    # ruling).
    if [ "$AST_ONLY" -eq 0 ]; then
        validate_backend_credential
        # FAIL FAST on a missing `claude` CLI.
        # graphify shells the local `claude` CLI
        # internally under BACKEND=claude-cli, and the scheduler's minimal
        # PATH carries it no more than it carries graphify -- same
        # rationale as the GRAPHIFY_BIN check above. Gated on BACKEND itself,
        # narrowed to claude-cli only -- `claude` is
        # graphify's Anthropic API backend (ANTHROPIC_API_KEY, no local CLI
        # shelled; see refresh-graph-map.sh's seed-claude-config gate, only
        # entered `if [ "$BACKEND" = "claude-cli" ]`), so requiring the CLI
        # for it would refuse an arm the fire path never needs.
        case "$BACKEND" in
            claude-cli)
                if ! CLAUDE_BIN=$(command -v claude 2>/dev/null); then
                    {
                        echo "ERR graphmap-cadence: 'claude' not on PATH at arm time, but the semantic pair's claude-cli backend shells it at fire time."
                        echo "    The scheduler fires with a minimal PATH, so this must resolve HERE — arming now would"
                        echo "    produce a cadence that fails on every semantic fire. Install the claude CLI (or put it on"
                        echo "    PATH), or arm with --ast-only to skip the semantic pair."
                    } >&2
                    exit 2
                fi
                case "$CLAUDE_BIN" in
                    /*|[A-Za-z]:[/\\]*) : ;;
                    *)
                        echo "ERR graphmap-cadence: 'claude' resolved to a non-absolute path ('$CLAUDE_BIN') — a shell function/alias or a relative PATH entry cannot be pinned into a scheduled runner. Install it on PATH as a real executable and re-arm." >&2
                        exit 2 ;;
                esac
                if [ ! -f "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
                    echo "ERR graphmap-cadence: 'claude' resolved to '$CLAUDE_BIN', which is not an executable file — refusing to pin it into a scheduled runner." >&2
                    exit 2
                fi
                CLAUDE_DIR=$(dirname "$CLAUDE_BIN")
                ;;
        esac
    fi
}

# FAIL FAST on a missing backend credential. Sibling of the
# graphify check above and there for the same reason: an API-key backend
# (glm/deepseek) with
# nothing verifying its credential could let `arm` succeed while EVERY weekly
# semantic run then died unattended. An armed-and-inert cadence is worse than
# a refused arm -- it reports ARMED in `status` while producing nothing.
#
# WHAT COUNTS AS PROOF is the whole subtlety here. A key exported
# into the ARMING shell proves nothing about fire time: cron starts with a
# minimal environment, and the generated runners deliberately carry
# no secrets (refresh-graph-map.sh re-resolves the key itself when it fires).
# The only source that survives to fire time on its own is the primary
# checkout's .env -- which is the fallback refresh-graph-map.sh already uses. So
# .env is what this checks, in a SUBSHELL with the variable unset, because
# load_dotenv deliberately does not clobber a live non-empty value and would
# otherwise report the arming shell's own export back to us.
#
# A live env var is NOT accepted: bash cannot tell a persistent variable
# apart from a transient `export`, and a gate whose only job is to stop a SILENT unattended failure
# must not rest on an unverifiable guess. .env costs the operator one line, in
# the file this repo already keeps such keys in. Env-only -> refuse; nothing at
# all -> refuse.
#
# Only backends that need a key are checked. The structural pair needs none
# (it never calls a model), so this gates the semantic pair alone.
#
# GRAPHMAP_DOTENV_ROOT is a TEST SEAM (sibling of GRAPHMAP_CRONTAB /
# GRAPHMAP_BAT_DIR): it pins which .env is consulted so the
# suite can assert both outcomes without depending on whether the operator's
# real .env happens to carry the key. It is honoured ONLY alongside a fake
# scheduler, so a real arm can never reach it; set in production it is ignored
# and says so.
validate_backend_credential() {
    local key_var=""
    # Every backend refresh-graph-map.sh can be handed, classified. `BACKEND`
    # is a fixed constant in this script today (claude-cli) with no flag to
    # change it, so only that row is live -- but the default branch used to
    # `return 0` SILENTLY, which meant a future one-word edit to BACKEND would
    # have switched the gate off without a word. An
    # unclassified backend now says so instead of quietly passing: this whole
    # check exists because a credential problem that stays silent becomes an
    # armed-and-inert cadence.
    case "$BACKEND" in
        glm|zai-glm)   key_var="ZAI_API_KEY" ;;
        deepseek)      key_var="DEEPSEEK_API_KEY" ;;
        # Subscription/local backends need no API key at arm time: claude-cli
        # uses the operator's own Claude Code auth, ollama is local.
        claude|claude-cli|ollama) return 0 ;;
        # Fail CLOSED on anything unclassified. A warning here would be
        # read at arm time and forgotten; the cadence it permits fails silently
        # weeks later, which is the whole failure mode this gate exists for. A
        # refusal instead forces whoever changes BACKEND to classify the new
        # provider in the same edit — the cost today is zero, because the only
        # value BACKEND can hold is classified above.
        *)
            {
                echo "ERR graphmap-cadence: backend '$BACKEND' is not classified by the arm-time credential check, so arming cannot verify it will reach its provider unattended."
                echo "    Add it to validate_backend_credential (with its API-key variable, or as credential-free) and re-arm."
            } >&2
            exit 2 ;;
    esac

    if credential_in_dotenv "$key_var"; then
        return 0
    fi

    # A live env var is NOT accepted as proof: "is this export persistent?"
    # is exactly the question bash cannot answer here, and
    # a gate whose whole purpose is to stop a SILENT unattended failure must
    # not itself rest on an unverifiable guess.
    #
    # .env needs no guessing: refresh-graph-map.sh loads it at fire time on
    # both platforms (that is where its own API-key fallback, e.g.
    # ZAI_API_KEY, reads from), so a key present there provably reaches the
    # run. An operator who
    # keeps the key in a persistent environment variable loses nothing by also
    # putting it in .env, which is where this repo keeps such keys anyway --
    # a one-line workaround against a failure that would otherwise surface
    # weeks later, in a log nobody reads.
    {
        echo "ERR graphmap-cadence: the semantic pair runs on the '$BACKEND' backend, which needs $key_var, but it is not in the primary checkout's .env."
        echo "    Arming now would register tasks that report ARMED while every weekly semantic run fails unattended."
        echo "    A value exported in THIS shell is deliberately not accepted: the schedulers start with their own"
        echo "    environment and the generated runners carry no secrets, so it cannot be shown to reach the run."
        echo "    Put $key_var in .env — the source refresh-graph-map.sh reads at fire time — and re-arm."
        echo "    The structural/AST pair needs no credential."
    } >&2
    exit 2
}

# True when <key> is readable from the .env that will still be there at fire
# time. Runs in a SUBSHELL with the key unset so load_dotenv's non-clobbering
# behaviour cannot mistake this shell's own export for a .env hit, and so the
# probe never leaks a value into the arming shell. The value is never printed.
credential_in_dotenv() {
    local key_var="$1"
    # A seam that can satisfy a SAFETY gate must never do so silently.
    # GRAPHMAP_DOTENV_ROOT points this check at a different .env than the one
    # scheduled runs read, so with it set an arm can pass while the real
    # primary-checkout credential is missing -- the precise armed-and-inert
    # outcome this gate exists to prevent, reached through the gate's own test
    # hook. It stays (the suite needs both outcomes deterministically), but it
    # announces itself, so a redirected verdict can never be mistaken for a
    # verified one.
    # The seam is honoured ONLY inside the hermetic suite. Warning was
    # not enough: an unrestricted override that can satisfy this gate IS the
    # armed-and-inert failure, just with a note attached. A real arm registers
    # against the real scheduler, so it never sets GRAPHMAP_CRONTAB;
    # requiring it present makes the redirect
    # unreachable in production while leaving the suite (which always sets it)
    # exactly as deterministic as before. Set in production it is IGNORED, and
    # says so -- never silently obeyed, never silently dropped.
    local dotenv_root=""
    if [ -n "${GRAPHMAP_DOTENV_ROOT:-}" ]; then
        # THREE conditions, none of which a production arm sets.
        # Presence of a scheduler seam was too weak (GRAPHMAP_CRONTAB=crontab
        # names the REAL scheduler and would register real tasks); requiring it
        # to be a file on disk was better but an absolute path to the real
        # scheduler, or a forwarding wrapper, still satisfies it. So the
        # redirect also needs GRAPHMAP_TEST_MODE=1 -- a variable whose only
        # purpose is to say "this is the hermetic suite", which nothing else
        # sets and no legitimate value coincides with.
        #
        # This bounds MISTAKES, which is what the gate is for: no forgotten
        # credential slips through because a variable happened to be set. An
        # operator who deliberately exports three variables to defeat their own
        # arm-time check still can, and no environment-variable scheme fixes
        # that -- it is out of scope, stated rather than papered over.
        if [ "${GRAPHMAP_TEST_MODE:-}" = "1" ] \
           && [ -f "${GRAPHMAP_CRONTAB:-}" ]; then
            dotenv_root="$GRAPHMAP_DOTENV_ROOT"
        else
            echo "WARN graphmap-cadence: GRAPHMAP_DOTENV_ROOT is set but IGNORED -- it is a test seam, honoured only alongside a fake scheduler (GRAPHMAP_CRONTAB). The credential check is reading the primary checkout's .env, as a real arm must." >&2
        fi
    fi
    (
        unset "$key_var"
        # shellcheck source=../lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh" >/dev/null 2>&1 || exit 1
        if [ -n "$dotenv_root" ]; then
            load_dotenv --root "$dotenv_root" "$key_var" >/dev/null 2>&1 || exit 1
        else
            load_dotenv "$key_var" >/dev/null 2>&1 || exit 1
        fi
        [ -n "${!key_var:-}" ]
    )
}

# --- POSIX (cron) implementation -------------------------------------------
#
# arm/status/disarm against the user crontab. Both cadence entries live in ONE crontab rewrite (snapshot -> filter
# -> append -> install), so there is no half-armed state to roll back. Each runner
# .sh file does log rotation, fire stamp, cd-into-himmel,
# then bash + refresh-graph-map.sh.

CRON_RUNNER_LUNA="$BAT_DIR/graphmap-luna.sh"
CRON_RUNNER_HIMMEL="$BAT_DIR/graphmap-himmel.sh"
CRON_RUNNER_AST_LUNA="$BAT_DIR/graphmap-ast-luna.sh"
CRON_RUNNER_AST_HIMMEL="$BAT_DIR/graphmap-ast-himmel.sh"
CRON_RUNNER_PUBLISH_HIMMEL="$BAT_DIR/graphmap-publish-himmel.sh"
CRON_RUNNER_SEMANTIC_LUNA="$BAT_DIR/graphmap-semantic-luna.sh"

# Shell-quote a value for a cron command line (mirrors pipeline-cadence
# cron_escape): printf %q survives the /bin/sh re-parse; the extra % -> \% pass
# is cron(5) syntax. Control characters are rejected (rc=2).
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR graphmap-cadence: cron_escape: argument contains control characters — rejected" >&2
        return 2
    fi
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the current crontab into CRON_TAB. Fail-CLOSED like list_existing.
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR graphmap-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
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

# Install a new crontab from the given file. Returns 4 on failure; the rejected
# tab is kept for forensics.
cron_install() {
    local tab_file="$1" err_file
    err_file=$(mktemp -t graphmap-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR graphmap-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        rm -f "$err_file"
        echo "    rejected crontab left at: $tab_file" >&2
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

# Marker-tagged cadence lines in the current CRON_TAB (empty if none). Every
# entry this script writes carries a trailing "# <task-name>" comment (see
# entry_luna et al below); matching on that comment anchored at end-of-line
# against TASK_MATCH_RE (the four owned names) means an
# operator's own unrelated "# HIMMEL-GraphMap*" entry is never swept up.
cron_existing() {
    printf '%s\n' "$CRON_TAB" | grep -E "# ${TASK_MATCH_RE}\$" || true
}

# Build the argv the runner .sh hands to /bin/sh: bash + refresh-graph-map.sh +
# flags. bash/script/corpus/maps/title arrive pre-quoted (printf %q);
# name/slug/tag/backend are fixed ASCII literals.
cron_payload() {
    local q_bash="$1" q_script="$2" name="$3" q_corpus="$4" q_maps="$5" q_title="$6" slug="$7" tag="$8" q_out_root="${9:-}"
    # refresh-graph-map.sh falls back to
    # GRAPHIFY_OUT_ROOT from the environment when --out-root is absent -- clear
    # it whenever this leg omits --out-root, so an ambient value left over from
    # the OTHER leg's out-of-corpus run can't redirect this one.
    if [ -z "$q_out_root" ]; then printf 'unset GRAPHIFY_OUT_ROOT; '; fi
    printf '%s %s --name %s --corpus-root %s --maps-dir %s --title %s --slug %s --backend %s --corpus-tag %s' \
        "$q_bash" "$q_script" "$name" "$q_corpus" "$q_maps" "$q_title" "$slug" "$BACKEND" "$tag"
    if [ -n "$q_out_root" ]; then printf ' --out-root %s' "$q_out_root"; fi
}

# Structural (AST) payload builder, POSIX form (routed
# through the promote-lock wrapper): bash + ast-update.sh +
# corpus-root. q_bash/q_script/q_corpus arrive pre-quoted (printf %q).
# --force lives INSIDE ast-update.sh, not on this command line.
ast_cron_payload() {
    local q_bash="$1" q_script="$2" q_corpus="$3" q_out_dir="${4:-}"
    # ast-update.sh reads GRAPHIFY_OUT from its environment exactly the way
    # graphify itself does (paths.py) -- an absolute value is used as-is, so
    # this is the FULL out dir (out-root/graphify-out), not just the root, to
    # land on the same directory refresh-graph-map.sh's --out-root resolves to.
    # Mirror cron_payload's unset -- clear
    # an ambient GRAPHIFY_OUT whenever this leg omits its own GRAPHIFY_OUT=.
    if [ -z "$q_out_dir" ]; then printf 'unset GRAPHIFY_OUT; '; fi
    if [ -n "$q_out_dir" ]; then printf 'GRAPHIFY_OUT=%s ' "$q_out_dir"; fi
    printf '%s %s %s' "$q_bash" "$q_script" "$q_corpus"
}

# Publish leg payload builder, POSIX form: unlike ast-update.sh,
# graph-cadence.sh takes its corpus root via an explicit --corpus-root flag,
# not a bare positional.
publish_cron_payload() {
    local q_bash="$1" q_script="$2" q_corpus="$3"
    local base
    base=$(printf '%s %s --corpus-root %s --flow-name %q' "$q_bash" "$q_script" "$q_corpus" "$PUBLISH_FLOW_NAME")
    if [ "$PUBLISH_SEMANTIC" -ne 1 ]; then
        printf '%s' "$base"
        return 0
    fi
    # The pause marker is read at fire time: while it exists the fire runs the
    # publish leg without --semantic and without the api-lane env.
    local q_pause
    q_pause=$(printf '%q' "$BAT_DIR/$SEMANTIC_PAUSE_MARKER")
    printf 'if [ -e %s ]; then echo "[semantic paused: marker present]"; %s; else echo "[semantic active]"; HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api %s --semantic; fi' "$q_pause" "$base" "$base"
}

# Luna semantic leg payload, POSIX form: semantic-update.sh on the live luna graph (GRAPHIFY_OUT, the same
# out dir the luna AST leg writes), batch- and spend-capped, behind its own pause marker read at fire time.
luna_semantic_cron_payload() {
    local q_bash="$1" q_script="$2" q_corpus="$3" q_out_dir="${4:-}"
    local q_pause base
    q_pause=$(printf '%q' "$BAT_DIR/$LUNA_SEMANTIC_PAUSE_MARKER")
    base=$(printf '%s %s --name luna --corpus-root %s --corpus-class luna-personal --backend claude-api --max-files %s --max-run-usd %s' \
        "$q_bash" "$q_script" "$q_corpus" "$LUNA_SEMANTIC_MAX_FILES" "$LUNA_SEMANTIC_RUN_USD")
    local env_prefix='HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto' unset_out=''
    if [ -n "$q_out_dir" ]; then env_prefix="$env_prefix GRAPHIFY_OUT=$q_out_dir"; else unset_out='unset GRAPHIFY_OUT; '; fi
    printf 'if [ -e %s ]; then echo "[semantic paused: marker present]"; else %s%s %s; fi' "$q_pause" "$unset_out" "$env_prefix" "$base"
}

# Emit the runner .sh body for one cadence task: stamp the format version,
# rotate the run log, stamp the fire time, cd into the himmel root, then fire the
# payload with output captured to the log. PATH prepends for nvm-managed node
# (refresh-graph-map.sh calls node, semantic pair only — q_node_dir is empty
# for the structural pair), for `graphify` itself (every
# task needs graphify on PATH), and (semantic pair only) for the
# `claude` CLI graphify's claude-cli backend shells internally — under cron's
# minimal PATH. The dirs are frequently the same bin dir — a duplicate PATH
# entry is harmless, so they are emitted independently rather than deduped.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh
emit_runner() {
    local name="$1" payload="$2" q_log="$3" q_himmel="$4" q_node_dir="${5:-}" q_graphify_dir="${6:-}" declare_ollama="${7:-0}" q_claude_dir="${8:-}" flow="${9:-}" skip_rcs="${10:-}"
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by graphmap-cadence.sh arm\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    if [ -n "$q_node_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_node_dir"
    fi
    if [ -n "$q_graphify_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_graphify_dir"
    fi
    if [ -n "$q_claude_dir" ]; then
        printf 'export PATH=%s:$PATH\n' "$q_claude_dir"
    fi
    # Luna's structural leg only — see emit_bat's identical
    # rationale: satisfies the fence's LLM-free-subcommand backend declaration
    # requirement in-policy (ollama -> local-ollama, luna-personal x
    # local-ollama = allow, zero egress).
    if [ "$declare_ollama" -eq 1 ]; then
        printf 'export GRAPHIFY_DECLARED_BACKEND=ollama\n'
    fi
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    # Shared emitter (runner format v22): a flow-run row for the
    # leg and a cadence-alert fail/clear on its outcome. An empty flow name (the
    # publish leg) skips it: graph-cadence.sh alerts and writes its own rows.
    # skip_rcs are the payload's benign non-failures (semantic rc 3 = bank
    # skip, structural rc 4 = promote lock busy): neither page nor clear.
    local q_flow_lib q_alert_lib
    if [ -n "$flow" ]; then
        q_flow_lib=$(printf '%q' "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh")
        q_alert_lib=$(printf '%q' "$HIMMEL_ROOT/scripts/luna/cadence-alert.sh")
        cadence_posix_leg_start "$q_flow_lib" "$flow" "$name"
    fi
    printf '    _rc=0; %s || _rc=$?\n' "$payload"
    if [ -n "$flow" ]; then
        cadence_posix_leg_end "$q_flow_lib" "$q_alert_lib" "$flow" 0 "$skip_rcs"
    fi
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
}

cmd_status() {
    cron_read
    echo "graphmap-cadence status:"
    local name log entry sched n_entries dup
    for name in "$TASK_LUNA" "$TASK_HIMMEL" "$TASK_AST_LUNA" "$TASK_AST_HIMMEL" "$TASK_PUBLISH_HIMMEL" "$TASK_SEMANTIC_LUNA"; do
        case "$name" in
            "$TASK_LUNA")       log="$BAT_DIR/graphmap-luna.log" ;;
            "$TASK_HIMMEL")     log="$BAT_DIR/graphmap-himmel.log" ;;
            "$TASK_AST_LUNA")   log="$BAT_DIR/graphmap-ast-luna.log" ;;
            "$TASK_AST_HIMMEL") log="$BAT_DIR/graphmap-ast-himmel.log" ;;
            "$TASK_PUBLISH_HIMMEL") log="$BAT_DIR/graphmap-publish-himmel.log" ;;
            "$TASK_SEMANTIC_LUNA") log="$BAT_DIR/graphmap-semantic-luna.log" ;;
        esac
        entry=$(printf '%s\n' "$CRON_TAB" | grep -E "# ${name}\$" | head -1 || true)
        if [ -n "$entry" ]; then
            sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
            n_entries=$(printf '%s\n' "$CRON_TAB" | grep -cE "# ${name}\$" || true)
            dup=""
            [ "$n_entries" -gt 1 ] && dup=" [DUPLICATE: $n_entries cron entries]"
            echo "ARMED      $name (cron: $sched)$dup$(task_summary "$name")"
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
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER_LUNA" "$CRON_RUNNER_HIMMEL" "$CRON_RUNNER_AST_LUNA" "$CRON_RUNNER_AST_HIMMEL" "$CRON_RUNNER_PUBLISH_HIMMEL" "$CRON_RUNNER_SEMANTIC_LUNA"
        fi
        echo "graphmap-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY graphmap-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY graphmap-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t graphmap-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vE "# ${TASK_MATCH_RE}\$" > "$newtab" || true
    # Install must succeed BEFORE the runners are removed — a failed install
    # leaves the entries live and they must keep pointing at existing runners.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER_LUNA" "$CRON_RUNNER_HIMMEL" "$CRON_RUNNER_AST_LUNA" "$CRON_RUNNER_AST_HIMMEL" "$CRON_RUNNER_PUBLISH_HIMMEL" "$CRON_RUNNER_SEMANTIC_LUNA"
    observability_unregister_cadence graphmap-luna "$TASK_LUNA"
    observability_unregister_cadence graphmap-himmel "$TASK_HIMMEL"
    observability_unregister_cadence graphmap-ast-luna "$TASK_AST_LUNA"
    observability_unregister_cadence graphmap-ast-himmel "$TASK_AST_HIMMEL"
    observability_unregister_cadence "$PUBLISH_FLOW_NAME" "$TASK_PUBLISH_HIMMEL"
    observability_unregister_cadence graphmap-semantic-luna "$TASK_SEMANTIC_LUNA"
    echo "graphmap-cadence: cadence disarmed"
}

cmd_arm() {
    validate_arm_inputs

    # Resolve bash to an absolute path so the runner doesn't depend on cron's
    # minimal PATH. Capture node's directory so the runner can prepend it (nvm
    # node won't be in cron's PATH; refresh-graph-map.sh needs node).
    local bash_bin node_dir node_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR graphmap-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi
    node_dir=""
    if node_bin=$(command -v node 2>/dev/null); then
        node_dir=$(dirname "$node_bin")
    fi

    # Dedup guard — never double-register the cadence. --ast-only
    # scopes both the dedup check AND --force's replacement to the two AST
    # entries only — a pre-existing semantic pair survives an --ast-only
    # (re-)arm untouched.
    cron_read
    local existing
    existing=$(cron_existing)
    # --ast-only: see cmd_arm's identical
    # comment -- the publish leg is grouped with the AST pair here too, but
    # only when --with-publish is also asking for it this run.
    if [ "$AST_ONLY" -eq 1 ]; then
        local ast_scope_re="${TASK_AST_LUNA}|${TASK_AST_HIMMEL}"
        [ "$WITH_PUBLISH" -ne 1 ] || ast_scope_re="${ast_scope_re}|${TASK_PUBLISH_HIMMEL}"
        [ "$WITH_LUNA_SEMANTIC" -ne 1 ] || ast_scope_re="${ast_scope_re}|${TASK_SEMANTIC_LUNA}"
        existing=$(printf '%s\n' "$existing" | grep -E "# (${ast_scope_re})\$" || true)
    fi
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "graphmap-cadence: --force set; replacing existing cadence entries:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY graphmap-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR graphmap-cadence: HIMMEL-GraphMap-* crontab entries already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/graphmap-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_bash q_script q_ast_script q_publish_script q_node_dir q_graphify_dir q_claude_dir q_vault q_himmel q_maps q_luna_title q_himmel_title q_log_luna q_log_himmel q_log_ast_luna q_log_ast_himmel q_log_publish_himmel q_semantic_script q_log_semantic_luna
    q_bash=$(printf '%q' "$bash_bin")
    q_script=$(printf '%q' "$REFRESH_SCRIPT")
    q_ast_script=$(printf '%q' "$AST_UPDATE_SCRIPT")
    q_publish_script=$(printf '%q' "$PUBLISH_CADENCE_SCRIPT")
    q_semantic_script=$(printf '%q' "$SEMANTIC_UPDATE_SCRIPT")
    q_node_dir=$([ -n "$node_dir" ] && printf '%q' "$node_dir" || printf '')
    q_graphify_dir=$(printf '%q' "$GRAPHIFY_DIR")
    # CLAUDE_DIR is only resolved (validate_arm_inputs) for the semantic pair
    # (empty under --ast-only). Only the luna/himmel semantic
    # emit_runner calls below pass this through.
    q_claude_dir=$([ -n "$CLAUDE_DIR" ] && printf '%q' "$CLAUDE_DIR" || printf '')
    q_vault=$(printf '%q' "$VAULT")
    q_himmel=$(printf '%q' "$HIMMEL_ROOT")
    q_maps=$(printf '%q' "$VAULT/60-Maps")
    q_luna_title=$(printf '%q' "$LUNA_TITLE")
    q_himmel_title=$(printf '%q' "$HIMMEL_TITLE")
    q_log_luna=$(printf '%q' "$BAT_DIR/graphmap-luna.log")
    q_log_himmel=$(printf '%q' "$BAT_DIR/graphmap-himmel.log")
    q_log_ast_luna=$(printf '%q' "$BAT_DIR/graphmap-ast-luna.log")
    q_log_ast_himmel=$(printf '%q' "$BAT_DIR/graphmap-ast-himmel.log")
    q_log_publish_himmel=$(printf '%q' "$BAT_DIR/graphmap-publish-himmel.log")
    q_log_semantic_luna=$(printf '%q' "$BAT_DIR/graphmap-semantic-luna.log")

    # luna's out-of-corpus destination, resolved ONCE and shared
    # by both the semantic (--out-root) and structural (GRAPHIFY_OUT=) legs
    # below -- see graph-out-root.sh. Empty when no override is configured
    # (today's in-corpus default, byte-for-byte unchanged).
    local luna_out_root q_out_root_luna q_out_dir_ast_luna
    luna_out_root="$(graphify_out_root_for luna)"
    q_out_root_luna=""
    q_out_dir_ast_luna=""
    if [ -n "$luna_out_root" ]; then
        q_out_root_luna=$(printf '%q' "$luna_out_root")
        q_out_dir_ast_luna=$(printf '%q' "$luna_out_root/graphify-out")
    fi

    local payload_luna payload_himmel payload_ast_luna payload_ast_himmel payload_publish_himmel payload_semantic_luna
    payload_luna=$(cron_payload "$q_bash" "$q_script" luna "$q_vault" "$q_maps" "$q_luna_title" "$LUNA_SLUG" "$LUNA_TAG" "$q_out_root_luna")
    payload_himmel=$(cron_payload "$q_bash" "$q_script" himmel "$q_himmel" "$q_maps" "$q_himmel_title" "$HIMMEL_SLUG" "$HIMMEL_TAG")
    # Structural (AST) payloads (routed through the
    # promote-lock wrapper): same asymmetric corpus roots as the
    # semantic pair (luna = vault, himmel = repo).
    payload_ast_luna=$(ast_cron_payload "$q_bash" "$q_ast_script" "$q_vault" "$q_out_dir_ast_luna")
    payload_ast_himmel=$(ast_cron_payload "$q_bash" "$q_ast_script" "$q_himmel")
    # Publish leg: himmel repo only (v1).
    payload_publish_himmel=$(publish_cron_payload "$q_bash" "$q_publish_script" "$q_himmel")
    # Luna semantic leg: writes the same out dir the luna AST leg does.
    payload_semantic_luna=$(luna_semantic_cron_payload "$q_bash" "$q_semantic_script" "$q_vault" "$q_out_dir_ast_luna")

    local luna_hh luna_mm himmel_hh himmel_mm
    luna_hh="${LUNA_TIME%:*}"; luna_mm="${LUNA_TIME#*:}"
    himmel_hh="${HIMMEL_TIME%:*}"; himmel_mm="${HIMMEL_TIME#*:}"
    local ast_luna_hh ast_luna_mm ast_himmel_mm
    ast_luna_hh="${AST_LUNA_TIME%:*}"; ast_luna_mm="${AST_LUNA_TIME#*:}"
    ast_himmel_mm="${AST_HIMMEL_TIME#*:}"
    local publish_himmel_mm
    publish_himmel_mm="${GRAPH_PUBLISH_TIME#*:}"
    local q_runner_luna q_runner_himmel q_runner_ast_luna q_runner_ast_himmel q_runner_publish_himmel q_runner_semantic_luna
    q_runner_luna=$(cron_escape "$CRON_RUNNER_LUNA")
    q_runner_himmel=$(cron_escape "$CRON_RUNNER_HIMMEL")
    q_runner_ast_luna=$(cron_escape "$CRON_RUNNER_AST_LUNA")
    q_runner_ast_himmel=$(cron_escape "$CRON_RUNNER_AST_HIMMEL")
    q_runner_publish_himmel=$(cron_escape "$CRON_RUNNER_PUBLISH_HIMMEL")
    q_runner_semantic_luna=$(cron_escape "$CRON_RUNNER_SEMANTIC_LUNA")
    local entry_luna entry_himmel entry_ast_luna entry_ast_himmel entry_publish_himmel entry_semantic_luna
    # Weekly (semantic pair): day-of-week field pinned to
    # WEEKLY_DAY_CRON instead of "*".
    entry_luna="$luna_mm $luna_hh * * $WEEKLY_DAY_CRON $q_runner_luna # $TASK_LUNA"
    entry_himmel="$himmel_mm $himmel_hh * * $WEEKLY_DAY_CRON $q_runner_himmel # $TASK_HIMMEL"
    # Structural pair: himmel hourly (fixed minute, every
    # hour); luna DAILY at its full HH:MM.
    entry_ast_luna="$ast_luna_mm $ast_luna_hh * * * $q_runner_ast_luna # $TASK_AST_LUNA"
    entry_ast_himmel="$ast_himmel_mm * * * * $q_runner_ast_himmel # $TASK_AST_HIMMEL"
    # Publish leg: every 6h at its fixed minute (cron's
    # `*/6` hour-field step, standard vixie-cron syntax).
    entry_publish_himmel="$publish_himmel_mm */$PUBLISH_EVERY_HOURS * * * $q_runner_publish_himmel # $TASK_PUBLISH_HIMMEL"
    entry_semantic_luna="$LUNA_SEMANTIC_MINUTE */$LUNA_SEMANTIC_EVERY_HOURS * * * $q_runner_semantic_luna # $TASK_SEMANTIC_LUNA"

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$AST_ONLY" -eq 1 ]; then
            echo "DRY graphmap-cadence: --ast-only set; the semantic pair ($TASK_LUNA / $TASK_HIMMEL) is skipped entirely"
        else
            echo "DRY graphmap-cadence: would write $CRON_RUNNER_LUNA:"
            emit_runner "$TASK_LUNA" "$payload_luna" "$q_log_luna" "$q_himmel" "$q_node_dir" "$q_graphify_dir" 0 "$q_claude_dir" graphmap-luna 3 | sed 's/^/    /'
            echo "DRY graphmap-cadence: would write $CRON_RUNNER_HIMMEL:"
            emit_runner "$TASK_HIMMEL" "$payload_himmel" "$q_log_himmel" "$q_himmel" "$q_node_dir" "$q_graphify_dir" 0 "$q_claude_dir" graphmap-himmel 3 | sed 's/^/    /'
        fi
        echo "DRY graphmap-cadence: would write $CRON_RUNNER_AST_LUNA:"
        emit_runner "$TASK_AST_LUNA" "$payload_ast_luna" "$q_log_ast_luna" "$q_himmel" "" "$q_graphify_dir" 1 "" graphmap-ast-luna 4 | sed 's/^/    /'
        echo "DRY graphmap-cadence: would write $CRON_RUNNER_AST_HIMMEL:"
        emit_runner "$TASK_AST_HIMMEL" "$payload_ast_himmel" "$q_log_ast_himmel" "$q_himmel" "" "$q_graphify_dir" 0 "" graphmap-ast-himmel 4 | sed 's/^/    /'
        if [ "$WITH_PUBLISH" -eq 1 ]; then
            echo "DRY graphmap-cadence: would write $CRON_RUNNER_PUBLISH_HIMMEL:"
            emit_runner "$TASK_PUBLISH_HIMMEL" "$payload_publish_himmel" "$q_log_publish_himmel" "$q_himmel" "" "$q_graphify_dir" | sed 's/^/    /'
        else
            echo "DRY graphmap-cadence: --with-publish not set; $TASK_PUBLISH_HIMMEL is skipped entirely"
        fi
        if [ "$WITH_LUNA_SEMANTIC" -eq 1 ]; then
            echo "DRY graphmap-cadence: would write $CRON_RUNNER_SEMANTIC_LUNA:"
            emit_runner "$TASK_SEMANTIC_LUNA" "$payload_semantic_luna" "$q_log_semantic_luna" "$q_himmel" "" "$q_graphify_dir" 0 "" graphmap-semantic-luna "3 4" | sed 's/^/    /'
        else
            echo "DRY graphmap-cadence: --with-luna-semantic not set; $TASK_SEMANTIC_LUNA is skipped entirely"
        fi
        echo "DRY graphmap-cadence: would add crontab entries:"
        if [ "$AST_ONLY" -eq 0 ]; then
            echo "    $entry_luna"
            echo "    $entry_himmel"
        fi
        echo "    $entry_ast_luna"
        echo "    $entry_ast_himmel"
        if [ "$WITH_PUBLISH" -eq 1 ]; then
            echo "    $entry_publish_himmel"
        fi
        if [ "$WITH_LUNA_SEMANTIC" -eq 1 ]; then
            echo "    $entry_semantic_luna"
        fi
        echo "graphmap-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Arm --publish-semantic PAUSED: the marker exists before the first fire, so
    # billed semantic never starts on its own; resume is a manual rm.
    if [ "$PUBLISH_SEMANTIC" -eq 1 ] && [ "$SEMANTIC_ACTIVE" -ne 1 ]; then
        : > "$BAT_DIR/$SEMANTIC_PAUSE_MARKER"
        echo "graphmap-cadence: semantic armed PAUSED ($BAT_DIR/$SEMANTIC_PAUSE_MARKER); rm it to resume"
    fi
    # --with-luna-semantic arms PAUSED the same way: billed semantic never starts on its own.
    if [ "$WITH_LUNA_SEMANTIC" -eq 1 ] && [ "$SEMANTIC_ACTIVE" -ne 1 ]; then
        : > "$BAT_DIR/$LUNA_SEMANTIC_PAUSE_MARKER"
        echo "graphmap-cadence: luna semantic armed PAUSED ($BAT_DIR/$LUNA_SEMANTIC_PAUSE_MARKER); rm it to resume"
    fi
    # Stage the runners at temp paths and promote (mv) them only after the
    # crontab install succeeds: writing them in place first would let a failed
    # install (exit 4) leave the OLD crontab live while the runner files already
    # carry the NEW config — a silent half-state under --force re-arm.
    # --ast-only: the semantic runners are neither built nor
    # promoted, and their entries never enter $own_match_re below, so a
    # PRE-EXISTING semantic pair's crontab lines and runner files survive an
    # --ast-only (re-)arm untouched.
    local tmp_ast_luna="$CRON_RUNNER_AST_LUNA.tmp.$$" tmp_ast_himmel="$CRON_RUNNER_AST_HIMMEL.tmp.$$"
    local tmp_publish_himmel="" tmp_semantic_luna=""
    emit_runner "$TASK_AST_LUNA" "$payload_ast_luna" "$q_log_ast_luna" "$q_himmel" "" "$q_graphify_dir" 1 "" graphmap-ast-luna 4 > "$tmp_ast_luna"
    emit_runner "$TASK_AST_HIMMEL" "$payload_ast_himmel" "$q_log_ast_himmel" "$q_himmel" "" "$q_graphify_dir" 0 "" graphmap-ast-himmel 4 > "$tmp_ast_himmel"
    chmod +x "$tmp_ast_luna" "$tmp_ast_himmel"
    local own_match_re="(${TASK_AST_LUNA}|${TASK_AST_HIMMEL})"
    local new_entries="$entry_ast_luna"$'\n'"$entry_ast_himmel"
    # --with-publish: opt-in, like the semantic pair under
    # --ast-only -- left out of own_match_re/new_entries entirely so a
    # pre-existing publish entry (armed by an earlier --with-publish run)
    # survives an arm that doesn't ask for it untouched.
    if [ "$WITH_PUBLISH" -eq 1 ]; then
        tmp_publish_himmel="$CRON_RUNNER_PUBLISH_HIMMEL.tmp.$$"
        emit_runner "$TASK_PUBLISH_HIMMEL" "$payload_publish_himmel" "$q_log_publish_himmel" "$q_himmel" "" "$q_graphify_dir" > "$tmp_publish_himmel"
        chmod +x "$tmp_publish_himmel"
        own_match_re="(${own_match_re}|${TASK_PUBLISH_HIMMEL})"
        new_entries="$new_entries"$'\n'"$entry_publish_himmel"
    fi
    # --with-luna-semantic: opt-in like --with-publish; a pre-existing entry survives an arm that does not ask.
    if [ "$WITH_LUNA_SEMANTIC" -eq 1 ]; then
        tmp_semantic_luna="$CRON_RUNNER_SEMANTIC_LUNA.tmp.$$"
        emit_runner "$TASK_SEMANTIC_LUNA" "$payload_semantic_luna" "$q_log_semantic_luna" "$q_himmel" "" "$q_graphify_dir" 0 "" graphmap-semantic-luna "3 4" > "$tmp_semantic_luna"
        chmod +x "$tmp_semantic_luna"
        own_match_re="(${own_match_re}|${TASK_SEMANTIC_LUNA})"
        new_entries="$new_entries"$'\n'"$entry_semantic_luna"
    fi
    local tmp_luna="" tmp_himmel=""
    if [ "$AST_ONLY" -eq 0 ]; then
        tmp_luna="$CRON_RUNNER_LUNA.tmp.$$"; tmp_himmel="$CRON_RUNNER_HIMMEL.tmp.$$"
        emit_runner "$TASK_LUNA" "$payload_luna" "$q_log_luna" "$q_himmel" "$q_node_dir" "$q_graphify_dir" 0 "$q_claude_dir" graphmap-luna 3 > "$tmp_luna"
        emit_runner "$TASK_HIMMEL" "$payload_himmel" "$q_log_himmel" "$q_himmel" "$q_node_dir" "$q_graphify_dir" 0 "$q_claude_dir" graphmap-himmel 3 > "$tmp_himmel"
        chmod +x "$tmp_luna" "$tmp_himmel"
        own_match_re="(${own_match_re}|${TASK_LUNA}|${TASK_HIMMEL})"
        new_entries="$entry_luna"$'\n'"$entry_himmel"$'\n'"$new_entries"
    fi

    # Single atomic rewrite: everything that isn't ours (scoped by
    # own_match_re, which is AST-only or all-four per --ast-only above), then
    # this arm's own entries.
    local newtab
    newtab=$(mktemp -t graphmap-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vE "# ${own_match_re}\$" || true
        fi
        printf '%s\n' "$new_entries"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        rm -f "$tmp_luna" "$tmp_himmel" "$tmp_ast_luna" "$tmp_ast_himmel" "$tmp_publish_himmel" "$tmp_semantic_luna"
        echo "    existing runner files left untouched" >&2
        exit 4
    fi
    # --semantic-active lifts a pause marker only once the live crontab carries the new entries.
    if [ "$SEMANTIC_ACTIVE" -eq 1 ]; then
        [ "$PUBLISH_SEMANTIC" -eq 1 ] && rm -f "$BAT_DIR/$SEMANTIC_PAUSE_MARKER"
        [ "$WITH_LUNA_SEMANTIC" -eq 1 ] && rm -f "$BAT_DIR/$LUNA_SEMANTIC_PAUSE_MARKER"
    fi
    if [ -n "$tmp_luna" ]; then
        mv -f "$tmp_luna" "$CRON_RUNNER_LUNA"
        mv -f "$tmp_himmel" "$CRON_RUNNER_HIMMEL"
        # weekly (604800s), not daily -- these are the semantic pair: a wrong cadence here would make future
        # cadence-based staleness tooling flag a healthy weekly job as
        # stalled every day it hasn't fired.
        observability_register_cadence graphmap-luna 604800 "$TASK_LUNA"
        observability_register_cadence graphmap-himmel 604800 "$TASK_HIMMEL"
        cadence_prov_record "$TASK_LUNA"
        cadence_prov_record "$TASK_HIMMEL"
    fi
    mv -f "$tmp_ast_luna" "$CRON_RUNNER_AST_LUNA"
    mv -f "$tmp_ast_himmel" "$CRON_RUNNER_AST_HIMMEL"
    observability_register_cadence graphmap-ast-luna 86400 "$TASK_AST_LUNA"
    observability_register_cadence graphmap-ast-himmel 3600 "$TASK_AST_HIMMEL"
    cadence_prov_record "$TASK_AST_LUNA"
    cadence_prov_record "$TASK_AST_HIMMEL"
    # Publish leg: opt-in via --with-publish.
    # $PUBLISH_FLOW_NAME ("graph-publish-<slug>"), NOT the
    # "graphmap-*.sh/.log" runner-file naming this file's OTHER legs use --
    # it must match graph-cadence.sh's OWN FLOW_NAME byte-for-byte, or the
    # observability registry's .flows[] entry can never be joined against the
    # flow-run-ledger rows the runner actually emits (both sides DERIVE the name from
    # the same corpus-slug computation instead of a hardcoded literal).
    if [ "$WITH_PUBLISH" -eq 1 ]; then
        mv -f "$tmp_publish_himmel" "$CRON_RUNNER_PUBLISH_HIMMEL"
        observability_register_cadence "$PUBLISH_FLOW_NAME" $((PUBLISH_EVERY_HOURS * 3600)) "$TASK_PUBLISH_HIMMEL"
        cadence_prov_record "$TASK_PUBLISH_HIMMEL"
    fi
    if [ "$WITH_LUNA_SEMANTIC" -eq 1 ]; then
        mv -f "$tmp_semantic_luna" "$CRON_RUNNER_SEMANTIC_LUNA"  # prim-ok: same stage-then-promote as the sibling runners above
        observability_register_cadence graphmap-semantic-luna $((LUNA_SEMANTIC_EVERY_HOURS * 3600)) "$TASK_SEMANTIC_LUNA"
        cadence_prov_record "$TASK_SEMANTIC_LUNA"
    fi

    local semantic_lines arming_note
    if [ "$AST_ONLY" -eq 1 ]; then
        # Report the
        # semantic pair's REAL post-install crontab state, not a blanket
        # "NOT armed" — an --ast-only (re-)arm never touches it, but it can
        # already be armed from an earlier full arm.
        # Don't
        # restate this arm's $BACKEND/$LUNA_TIME/$HIMMEL_TIME for a task this
        # run never touched — point at `status` for its real config instead
        # of guessing.
        cron_read
        local luna_line himmel_line
        if printf '%s\n' "$CRON_TAB" | grep -q -E "# ${TASK_LUNA}\$"; then
            luna_line="  $TASK_LUNA       already armed (pre-existing, unaffected by this --ast-only run — see \`status\` for its schedule/backend)"
        else
            luna_line="  $TASK_LUNA       NOT armed (--ast-only)"
        fi
        if printf '%s\n' "$CRON_TAB" | grep -q -E "# ${TASK_HIMMEL}\$"; then
            himmel_line="  $TASK_HIMMEL     already armed (pre-existing, unaffected by this --ast-only run — see \`status\` for its schedule/backend)"
        else
            himmel_line="  $TASK_HIMMEL     NOT armed (--ast-only)"
        fi
        semantic_lines="$luna_line
$himmel_line"
        arming_note="  No task ever opens a claude session. --ast-only arms/replaces only the
  free structural pair; a pre-existing semantic pair (if shown above) is
  left byte-identical. Re-arm without --ast-only to add a missing
  semantic pair (--force to replace). Disarm anytime with:"
    else
        semantic_lines="  $TASK_LUNA       weekly (dow $WEEKLY_DAY_CRON) $LUNA_TIME   -> refresh-graph-map luna (semantic, $BACKEND)
  $TASK_HIMMEL     weekly (dow $WEEKLY_DAY_CRON) $HIMMEL_TIME   -> refresh-graph-map himmel (semantic, $BACKEND)"
        arming_note="  No task ever opens a claude session. Arming = weekly semantic graphify
  extraction on the $BACKEND backend (off the interactive Anthropic bank)
  + free structural refresh (himmel hourly, luna daily); disarm anytime:"
    fi
    local publish_lines=""
    if [ "$WITH_PUBLISH" -eq 1 ]; then
        publish_lines="  $TASK_PUBLISH_HIMMEL  every ${PUBLISH_EVERY_HOURS}h at :$publish_himmel_mm   -> graph-cadence publish himmel (free, auto-merge)"
        if [ "$PUBLISH_SEMANTIC" -eq 1 ]; then
            publish_lines="  $TASK_PUBLISH_HIMMEL  every ${PUBLISH_EVERY_HOURS}h at :$publish_himmel_mm   -> graph-cadence publish himmel (+ claude-api semantic, auto-merge)"
        fi
    fi
    if [ "$WITH_LUNA_SEMANTIC" -eq 1 ]; then
        publish_lines="$publish_lines
  $TASK_SEMANTIC_LUNA  every ${LUNA_SEMANTIC_EVERY_HOURS}h at :$LUNA_SEMANTIC_MINUTE   -> semantic-update luna (claude-api, max ${LUNA_SEMANTIC_MAX_FILES} files / ${LUNA_SEMANTIC_RUN_USD} USD per fire)"
    fi
    cat <<EOF

================================================================
  GRAPHMAP CADENCE ARMED
$semantic_lines
  $TASK_AST_LUNA    daily at $AST_LUNA_TIME   -> graphify update luna (structural, free)
  $TASK_AST_HIMMEL  hourly at :$ast_himmel_mm   -> graphify update himmel (structural, free)
$publish_lines
  Vault: $VAULT   (maps -> 60-Maps/)
  Himmel: $HIMMEL_ROOT
  Runner .sh: $BAT_DIR

$arming_note
      bash scripts/luna/graphmap-cadence.sh disarm
================================================================
EOF
    macos_fda_warn_if_needed "$VAULT" "$HIMMEL_ROOT"
}

# Runtime preflight on the ARM path only: arming hands this
# machine's runtime to an unattended schedule that will re-run for weeks with
# nobody reading the output, so drift gets named at the one moment a human is
# still here. status/disarm change nothing and stay silent. Advisory by default;
# HIMMEL_RUNTIME_PREFLIGHT=strict refuses, =0 silences.
if [ "$SUBCMD" = "arm" ]; then
    # shellcheck source=../lib/runtime-preflight.sh
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/../lib/runtime-preflight.sh"
    runtime_preflight "graphmap-cadence arm" || exit 1
fi

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
