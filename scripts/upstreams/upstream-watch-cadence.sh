#!/usr/bin/env bash
# upstream-watch-cadence.sh — arm/status/disarm the daily upstream-watch scan
# cadence.
#
# WHY: a resident interactive claude session used to poll himmel's open
# upstream PRs/issues every 20 minutes, burning tokens. Operator ruling
# 2026-09-01: "we should monitor it daily not as a puller and with tokens" —
# this arms ONE daily local cron task on Linux/macOS
# (structural sibling of drift-fix-cadence.sh / qmd-cadence.sh)
# that runs `bash scripts/upstreams/upstream-watch.sh` directly. There is NO
# claude session here at all — never `--model`, never a payload prompt — so
# the headless-claude billing rule does not apply even indirectly, the
# same reasoning qmd-cadence.sh's header gives for its own deterministic
# runner. ONE worker, unlike drift-fix-cadence's two: upstream-watch.sh has no
# "conflicted, a human must decide" branch that would need isolating from a
# sibling repair — it either finds a delta or it doesn't, so nothing here can
# get stuck the way a fork rebase can.
#
# This cadence self-registers with the observability registry
# (scripts/lib/observability-registry.sh) on arm/disarm, unlike
# drift-fix-cadence.sh, which does not register anywhere and is invisible to
# himmel-doctor's C24 check. That gap is not repeated here — see the
# observability_register_cadence / observability_unregister_cadence call
# sites below.
#
# Default fire time 06:00 local — after drift-fix-cadence's 05:00/05:30 workers
# (no overlap on the same machine) and still well before the workday.
#
# Usage:
#   bash scripts/upstreams/upstream-watch-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   bash scripts/upstreams/upstream-watch-cadence.sh status
#   bash scripts/upstreams/upstream-watch-cadence.sh disarm [--dry-run]
#
# Test seams (used by test-upstream-watch-cadence.sh):
#   UPSTREAMWATCH_CRONTAB        command invoked instead of `crontab` (POSIX)
#   UPSTREAMWATCH_BAT_DIR        where the persistent runner (.sh) + log live
#   UPSTREAMWATCH_HIMMEL_ROOT    overrides the resolved primary checkout outright
#   UPSTREAMWATCH_PLATFORM       override OS detection (`posix` is supported)
#   HIMMEL_OBSERVABILITY_CONFIG  (existing seam, scripts/lib/observability-registry.sh)
#                                 overrides the observability-registry path arm/disarm
#                                 register with — MUST be set in tests, real or hand
#                                 smoke-tests alike: this arm/disarm's registration
#                                 write is otherwise unscoped and lands in the real
#                                 ~/.himmel/observability.json regardless of every
#                                 other UPSTREAMWATCH_* seam above (a hand
#                                 smoke-test without this set
#                                 registered HIMMEL-UpstreamWatch as an expected task
#                                 and paged on the resulting scheduled-task-missing
#                                 alert once disarm wasn't called to match)
#
# Exit codes (mirrors drift-fix-cadence.sh's contract exactly):
#   0  done (armed / status printed / disarmed / dry-run complete)
#   1  usage or input error (bad subcommand, flag, --time)
#   2  env unusable (no scheduler, unknown platform, missing payload script)
#   3  dedup block — already armed; --force replaces
#   4  scheduler invocation failed (create/delete/query), or the post-arm
#      verify failed
set -euo pipefail

TASK_NAME="HIMMEL-UpstreamWatch"
CRONTAB_BIN="${UPSTREAMWATCH_CRONTAB:-crontab}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
. "$SCRIPT_DIR/../lib/prim.sh" || exit 4

resolve_user_home() {
    printf '%s' "${HOME:-/tmp}"
}

# Persistent runner home — deliberately not a temp directory: this task recurs
# daily and temp sweeps would silently kill the cadence.
BAT_DIR="${UPSTREAMWATCH_BAT_DIR:-$(resolve_user_home)/.claude/upstream-watch-cadence}"

# Resolve the himmel root to the PRIMARY checkout, never this script's own
# location (mirrors drift-fix-cadence.sh's resolve_himmel_root): arming from a feature worktree would embed that worktree's
# absolute path in the persistent runner, and the post-merge prune then
# deletes it — every later fire would cd into nothing.
resolve_himmel_root() {
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

if [ -n "${UPSTREAMWATCH_HIMMEL_ROOT:-}" ]; then
    HIMMEL_ROOT="$UPSTREAMWATCH_HIMMEL_ROOT"
elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
    :
else
    echo "WARN upstream-watch-cadence: could not resolve the primary checkout via git -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence will break." >&2
    HIMMEL_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && cd .. && pwd)"
fi
WATCH_SCRIPT="$HIMMEL_ROOT/scripts/upstreams/upstream-watch.sh"

# The anchor for HANDOVER_DIR resolution (below) is ALWAYS this script's own
# primary checkout, even when UPSTREAMWATCH_HIMMEL_ROOT overrides HIMMEL_ROOT
# for testing: go_resolve_root needs a real repo (scripts/lib/load-dotenv.sh
# present) to read `.env` from, which a stub payload root is not.
# UPSTREAMWATCH_ANCHOR_ROOT is a test-only seam (same shape as the other
# UPSTREAMWATCH_* overrides) so tests can pin a stub `.env`-bearing anchor
# instead of reading this station's real one.
if [ -n "${UPSTREAMWATCH_ANCHOR_ROOT:-}" ]; then
    ANCHOR_ROOT="$UPSTREAMWATCH_ANCHOR_ROOT"
else
    ANCHOR_ROOT="$(resolve_himmel_root)" || ANCHOR_ROOT=""
    [ -n "$ANCHOR_ROOT" ] || ANCHOR_ROOT="$HIMMEL_ROOT"
fi

# Runner-format version stamp — shared with the sibling cadences.
# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh"
# shellcheck source=../lib/observability-registry.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/observability-registry.sh"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
# shellcheck source=../lib/go-gate.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/go-gate.sh"

# Resolve HANDOVER_DIR for the generated cron wrapper the same way the rest
# of himmel does (live env / anchor .env / Mode A default) — and refuse the
# Mode A inline stub outright rather than silently baking it in:
# a wrapper armed without an external root would fire daily into
# <repo>/handovers, invisible to the real handover system.
resolve_watch_handover_dir() {
    local resolved
    resolved="$(go_resolve_root "$ANCHOR_ROOT")" || return 2
    _go_in_harness "$resolved" "$ANCHOR_ROOT" && return 3
    printf '%s' "$resolved"
}

FIRE_TIME="06:00"
DRY_RUN=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: upstream-watch-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the daily upstream-watch cadence: ONE
daily task that runs `bash scripts/upstreams/upstream-watch.sh` directly --
never an interactive claude session, never --model. The script itself decides
whether anything changed (exit 0 = no delta, 10 = delta reported + telegram
sent, 2 = instrument failure); every one of those is a normal scheduler run,
so none of them is treated as a scheduler-level failure here.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if already
           armed; --force replaces.
  status   Show whether the task is armed (+ next run time + run-log
           evidence from its last fire).
  disarm   Remove the task and its runner (idempotent; rc=0 if nothing was
           armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>  Daily fire time, 24h local (default 06:00 -- after
                  drift-fix-cadence's 05:00/05:30 workers, well before the
                  workday).
  --force         Replace an already-armed task.
  --dry-run       Print what would happen, touch nothing (honored by arm
                  AND disarm).

No --model flag: nothing here ever launches claude, so there is no model to
pin.
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR upstream-watch-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR upstream-watch-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

TIME_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            if [ $# -lt 2 ]; then
                echo "ERR upstream-watch-cadence: --time requires a value (HH:MM)" >&2
                usage >&2; exit 1
            fi
            FIRE_TIME="$2"; TIME_SET=1; shift 2 ;;
        --time=*) FIRE_TIME="${1#--time=}"; TIME_SET=1; shift ;;
        --force)   FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "ERR upstream-watch-cadence: unknown arg: $1" >&2
            usage >&2; exit 1
            ;;
    esac
done

if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
    echo "ERR upstream-watch-cadence: --time is arm-only" >&2; exit 1
fi

# Validate input BEFORE the platform gate so a bad value is rc 1 everywhere,
# not rc 2 on whichever platform happens to gate first.
if ! [[ "$FIRE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERR upstream-watch-cadence: --time must be HH:MM (24h), got: $FIRE_TIME" >&2
    exit 1
fi

case "${UPSTREAMWATCH_PLATFORM:-${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}}" in
    posix|linux*|darwin*|freebsd*|Linux|Darwin) PLATFORM=posix ;;
    *) PLATFORM=unknown ;;
esac
if [ "$PLATFORM" = "unknown" ]; then
    echo "ERR upstream-watch-cadence: unsupported platform '${OSTYPE:-unknown}'." >&2
    echo "    Supported: Linux/macOS (crontab)" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Shared: payload presence + run-log reporting
# --------------------------------------------------------------------------

require_payload() {
    if [ ! -f "$WATCH_SCRIPT" ]; then
        echo "ERR upstream-watch-cadence: upstream-watch.sh not found at $WATCH_SCRIPT" >&2
        exit 2
    fi
}

status_log() {
    local log="$1" mtime last rc
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null || echo '?')
        echo "  run log    $log (last write: $mtime)"
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
        [ -n "$last" ] && echo "             last line: $last"
        rc=$(grep -o '\[exit rc=[0-9]*\]' "$log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || true)
        if [ -n "$rc" ] && [ "$rc" = "2" ]; then
            echo "  WARN: last fire exited rc=2 — instrument failure (gh auth / rate-limit / parse); see the log"
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

# --------------------------------------------------------------------------
# POSIX (crontab)
# --------------------------------------------------------------------------

cron_escape() {
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# posix_sh_quote <value> — single-quote-wrap (POSIX `'\''` escaping) for the
# generated runner's own `#!/bin/sh`: `printf '%q'` is a
# bash-only escaping that can emit `$'...'` ANSI-C quoting, which a stricter
# /bin/sh does not reliably parse the same way bash does. Every value baked
# into the runner is externally overridable (HANDOVER_DIR, HIMMEL_ROOT via
# UPSTREAMWATCH_HIMMEL_ROOT, the BAT_DIR log path via UPSTREAMWATCH_BAT_DIR),
# so this is the one quoting the generated `#!/bin/sh` runner ever uses.
posix_sh_quote() {
    local s
    # trailing sentinel survives $(...)'s trailing-newline stripping so a
    # HANDOVER_DIR ending in newline(s) round-trips byte-exact (codex CR).
    s=$(printf '%sX' "$1" | sed "s/'/'\\\\''/g")
    s=${s%X}
    printf "'%s'" "$s"
}

CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR upstream-watch-cadence: crontab -l failed (rc=$rc) — refusing to treat as an empty crontab:" >&2
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
    err_file=$(mktemp -t upstream-watch-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR upstream-watch-cadence: crontab install failed:" >&2
        cat "$err_file" >&2
        echo "    rejected crontab left at: $tab_file" >&2
        rm -f "$err_file"
        return 4
    fi
    rm -f "$err_file" "$tab_file"
}

cron_existing() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

# emit_runner <q_himmel> <q_handover> <payload> <q_log> —
# rotate the log, stamp the fire, cd into the checkout, run the payload with
# its rc captured, then exit WITH that rc (not the trailing echo's).
# shellcheck disable=SC2016  # $log / $(date) are emitted literally for the runner's own /bin/sh
emit_runner() {
    local q_himmel="$1" q_handover="$2" payload="$3" q_log="$4"
    printf '#!/bin/sh\n'
    printf '# upstream-watch-cadence runner — generated by upstream-watch-cadence.sh arm\n'
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    # HANDOVER_DIR: resolved at arm time and baked in here —
    # a cron-fired shell has no interactive/login env, so without this the
    # payload's own handover_root() would silently fall back to the inline
    # <repo>/handovers stub.
    printf 'HANDOVER_DIR=%s\n' "$q_handover"
    printf 'export HANDOVER_DIR\n'
    printf 'log=%s\n' "$q_log"
    printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" 2>/dev/null; fi\n'
    printf '{\n'
    printf '    echo "[fired $(date "+%%Y-%%m-%%d %%H:%%M:%%S")]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    # Shared emitter: flow-run row + cadence-
    # alert fail/clear. rc 10 is a handled delta, so it counts as success.
    local q_flow_lib q_alert_lib
    q_flow_lib=$(posix_sh_quote "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh")
    q_alert_lib=$(posix_sh_quote "$HIMMEL_ROOT/scripts/luna/cadence-alert.sh")
    cadence_posix_worker_start "$q_flow_lib" upstream-watch HIMMEL-UpstreamWatch
    printf '    %s\n' "$payload"
    printf '    _rc=$?\n'
    cadence_posix_worker_end "$q_flow_lib" "$q_alert_lib" upstream-watch "0 10"
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
    # rc=10 is upstream-watch.sh's own "delta found, handled" success code
    # (see its header) - map it to 0 so cron's own exit-code visibility
    # reflects a normal run, not a failure, on every delta day.
    printf '[ "$_rc" -eq 10 ] && _rc=0\n'
    printf 'exit "$_rc"\n'
}

cmd_status() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    echo "upstream-watch-cadence status:"
    local entry sched n_entries dup=""
    entry=$(cron_existing | head -1)
    if [ -n "$entry" ]; then
        sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
        n_entries=$(cron_existing | grep -c . || true)
        [ "$n_entries" -gt 1 ] && dup=" [DUPLICATE: $n_entries cron entries]"
        echo "ARMED      $TASK_NAME (cron: $sched)$dup"
    else
        echo "not armed  $TASK_NAME"
    fi
    echo "  runner     $BAT_DIR/upstream-watch.sh"
    status_log "$BAT_DIR/upstream-watch.log"
}

cmd_disarm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$BAT_DIR/upstream-watch.sh"
            # No live entry, but the registry may still expect one (e.g. the
            # crontab line was removed outside this script) — unregister
            # unconditionally so disarm never leaves a stale expectation
            # behind (which would page as a missing scheduled task).
            observability_unregister_cadence upstream-watch "$TASK_NAME"
        fi
        echo "upstream-watch-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "$existing" | sed 's/^/DRY upstream-watch-cadence: would remove crontab entry: /'
        echo "DRY upstream-watch-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t upstream-watch-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" > "$newtab" || true
    cron_install "$newtab" || exit 4
    rm -f "$BAT_DIR/upstream-watch.sh"
    observability_unregister_cadence upstream-watch "$TASK_NAME"
    echo "upstream-watch-cadence: cadence disarmed"
}

cmd_arm() {
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
        echo "ERR upstream-watch-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
        exit 2
    }
    require_payload
    local bash_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR upstream-watch-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi

    local handover_dir
    if ! handover_dir=$(resolve_watch_handover_dir); then
        {
            echo "ERR upstream-watch-cadence: cannot resolve an external HANDOVER_DIR for the armed cadence -- refusing to arm into the inline handovers/ stub."
            echo "A cron-fired run has no interactive env, so this must be settled at arm time: set HANDOVER_DIR, or configure it in $ANCHOR_ROOT/.env, then retry."
        } >&2
        exit 2
    fi

    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "upstream-watch-cadence: --force set; replacing existing entry:" >&2
            printf '%s\n' "$existing" | sed 's/^/  /' >&2
        else
            {
                echo "ERR upstream-watch-cadence: already armed: $TASK_NAME."
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/upstreams/upstream-watch-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_himmel q_handover q_bash q_script q_log payload
    q_himmel=$(posix_sh_quote "$HIMMEL_ROOT")
    q_handover=$(posix_sh_quote "$handover_dir")
    q_bash=$(posix_sh_quote "$bash_bin")
    q_script=$(posix_sh_quote "$WATCH_SCRIPT")
    q_log=$(posix_sh_quote "$BAT_DIR/upstream-watch.log")
    payload="$q_bash $q_script"

    local runner="$BAT_DIR/upstream-watch.sh"
    local hh="${FIRE_TIME%:*}" mm="${FIRE_TIME#*:}"
    local entry_line
    entry_line="$mm $hh * * * $(cron_escape "$runner") # $TASK_NAME"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY upstream-watch-cadence: would write $runner:"
        emit_runner "$q_himmel" "$q_handover" "$payload" "$q_log" | sed 's/^/    /'
        echo "DRY upstream-watch-cadence: would install crontab entry:"
        echo "    $entry_line"
        echo "upstream-watch-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"

    # Stage the runner and PROMOTE (checked mv) BEFORE touching the crontab.
    # Publishing the artifact first means a failed
    # publish never reaches the scheduler at all, and a failed crontab
    # install afterward leaves a fully-published runner an operator can
    # inspect or retry against, rather than a live schedule pointing at a
    # runner that was never actually updated (the
    # opposite order would install the crontab FIRST with an unchecked mv
    # after it, so a failed mv left the crontab live against a missing or
    # stale runner while still reporting success).
    local tmp_runner
    tmp_runner=$(mktemp "$BAT_DIR/.upstream-watch.sh.XXXXXX")
    emit_runner "$q_himmel" "$q_handover" "$payload" "$q_log" > "$tmp_runner"
    chmod +x "$tmp_runner"
    if [ -e "$runner" ] && [ ! -f "$runner" ]; then
        echo "ERR upstream-watch-cadence: $runner exists and is not a regular file — refusing to publish" >&2
        rm -f "$tmp_runner"
        exit 4
    fi
    # prim-ok: the staged runner is already executable; atomic_write would remove its execute bits before cron can fire it.
    if ! mv -f "$tmp_runner" "$runner"; then
        echo "ERR upstream-watch-cadence: failed to publish runner to $runner" >&2
        rm -f "$tmp_runner"
        exit 4
    fi

    local newtab
    newtab=$(mktemp -t upstream-watch-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true
        fi
        printf '%s\n' "$entry_line"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        echo "    runner published to $runner but crontab install failed — cadence NOT armed; inspect/retry" >&2
        exit 4
    fi

    observability_register_cadence upstream-watch 86400 "$TASK_NAME"
    cadence_prov_record "$TASK_NAME"

    arm_summary "crontab entry" "$runner" "$BAT_DIR/upstream-watch.log"
}

# --------------------------------------------------------------------------

arm_summary() {
    local kind="$1" runner="$2" log="$3"
    cat <<EOF
================================================================
upstream-watch-cadence ARMED

  $TASK_NAME   daily $FIRE_TIME local — $kind — runner: $runner
  Repo:   $HIMMEL_ROOT
  Log:    $log
          (one prior run kept as .log.prev)

  Each day: bash scripts/upstreams/upstream-watch.sh runs directly (no
  claude session). It builds the open-PR/issue inventory, diffs it against
  the previous run, and only when something changed writes a dated report
  under the handover root and sends one Telegram line — a no-delta run costs
  zero tokens.

  Registered with the observability registry (himmel-doctor's C24 check will
  report this task as expected).

  Status / disarm anytime:
      bash scripts/upstreams/upstream-watch-cadence.sh status
      bash scripts/upstreams/upstream-watch-cadence.sh disarm
================================================================
EOF
}

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
