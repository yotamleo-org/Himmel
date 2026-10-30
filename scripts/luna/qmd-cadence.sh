#!/usr/bin/env bash
# qmd-cadence.sh — arm/status/disarm the recurring qmd reindex cadence
#
# WHY: the qmd index goes stale SILENTLY. In one incident the luna
# collection sat five days stale (lastUpdated 2026-06-22, needsEmbedding 0) while
# notes written that week were simply not searchable — every qmd-backed workflow
# answered off a stale index and nothing signalled it. scripts/luna/qmd-reindex.sh
# is the RUNNER that refreshes it (`qmd update` + `qmd embed` + a completeness
# assert); what was missing is the scheduler. This is that layer: one daily
# OS-scheduler task that fires the runner off-peak.
#
# DESIGN: modelled on the sibling graphmap-cadence.sh, NOT on
# pipeline-cadence.sh. pipeline-cadence fires interactive `claude "<prompt>" < NUL`
# bounded sessions, each wired with a --settings auto-approve fragment. THIS
# scheduler fires a DETERMINISTIC SCRIPT — `bash <himmel>/scripts/luna/
# qmd-reindex.sh --qmd-bin <qmd>` — so it has NO claude SESSION, NO NUL-stdin, NO
# settings fragment and NO auto-approve hook. `qmd update` / `qmd embed` are plain
# CLI calls, so the deterministic shape is the correct precedent.
#
# Headless-claude billing does NOT apply here, not even indirectly.
# The graphmap sibling carries that caveat because its graphify backend shells the
# `claude` CLI underneath; nothing in the qmd path invokes claude at all. That says
# nothing about the network: the embed step uses the machine's CONFIGURED embed
# model, which may be remote (the station runs openai:qwen/qwen3-embedding-8b on
# OpenRouter). Read it with `bash scripts/luna/qmd-embed-model.sh check`; egress is
# governed by the egress matrix (docs/internals/qmd-embed-model.md).
#
# ONE task is registered:
#   HIMMEL-Qmd-Reindex   daily (default 05:00 local)
#       bash <himmel>/scripts/luna/qmd-reindex.sh --qmd-bin <qmd>
#
# WHY 05:00 LOCAL: it lands AFTER the whole pipeline-cadence chain has finished
# writing to the vault (HIMMEL-Pipeline-Harvest 02:00, -Synthesize 03:00,
# -Health 04:00), so the reindex actually picks up what those workers just wrote
# instead of racing them — a reindex scheduled before them would index the
# previous day's vault. It is also clear of the graphmap slots (13:00 / 13:20)
# and the 17:00 codex orphan sweep. Cost basis for daily: a full refresh
# measured 2026-07-25 ran in 16s (update) + 24s (embed) — daily is cheap, and
# daily is what bounds the observed five-day staleness to under 24h.
#
# WHY THE qmd BINARY IS PINNED AT ARM TIME: cron fires with a MINIMAL
# PATH that does not carry the bun bin dir where qmd installs (~/.bun/bin here).
# Resolving it HERE, at arm time, is what makes the failure visible — otherwise
# the arm "succeeds" and every unattended fire dies in a log nobody reads. The
# resolved ABSOLUTE invocation is passed to the runner as --qmd-bin (+ --qmd-js).
# Unlike the graphmap sibling (which must PATH-prepend, because graphify spawns
# `claude` itself), we invoke qmd directly, so passing the path is both simpler
# and stricter.
#
# HOW it is resolved, and why that matters: via
# scripts/lib/qmd-bin.sh's qmd_pinned_invocation, NOT a bare `command -v qmd`.
# The bare lookup finds the broken Claude-plugin stub
# (~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd) that shadows the bun shim on Git
# Bash $PATH inside a Claude Code session — which is exactly where an operator
# arms this from — and bakes THAT into the runner, so every fire dies with
# `Module not found "...plugins/cache/qmd/.../dist/cli/qmd.js"`. The shared
# resolver prefers the bun-served install, whose canonical invocation is
# `bun <…/dist/cli/qmd.js>`: TWO tokens, neither of them a `qmd` executable —
# which is why the runner grew a --qmd-js flag rather than the pin being
# squeezed into one path. (qmd_cmd itself is NOT usable here: it INVOKES, and a
# cadence needs a pinnable absolute invocation.)
#
# And the pin is LIVENESS-checked, not existence-checked: the resolved
# invocation is actually RUN once (`collection list`, which opens the index —
# `--version` does not, so it passes on an install whose better-sqlite3 binding
# is broken) and must exit 0 before it is written into a runner. An
# existence-only test passes on the broken stub, which is the whole failure
# class this closes.
#
# WITH --hourly the SAME single task fires every hour instead of
# once daily: the cron line is `MM * * * *`
# instead of `MM HH * * *`, using --time's minute as the fixed :MM past every
# hour — --time's hour is then irrelevant for scheduling, but the flag still
# validates as a full HH:MM so one flag serves both cadences.
#
# OPERATOR FLIP: this NEVER auto-arms. `arm` registers the task only when
# explicitly invoked, exactly like graphmap-cadence — arming is the operator's
# decision, not a side effect of installing the harness.
#
# Usage:
#   bash scripts/luna/qmd-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   bash scripts/luna/qmd-cadence.sh status
#   bash scripts/luna/qmd-cadence.sh disarm [--dry-run]
#
# Test seams (used by test-qmd-cadence.sh):
#   QMD_CADENCE_CRONTAB   — command invoked instead of `crontab`
#   QMD_CADENCE_BAT_DIR   — where the persistent runner (.sh) lives
#
# Exit codes (mirrors graphmap-cadence.sh / pipeline-cadence.sh):
#   0  done (armed / status printed / disarmed / dry-run)
#   1  usage / input error
#   2  env unusable (no crontab; unsupported platform; runner or qmd
#      missing; query tool errored)
#   3  dedup block — a HIMMEL-Qmd-* task is already armed; use --force
#   4  scheduler invocation failed (crontab rewrite)
set -euo pipefail

TASK_PREFIX="HIMMEL-Qmd-"
TASK_REINDEX="${TASK_PREFIX}Reindex"
CRONTAB_BIN="${QMD_CADENCE_CRONTAB:-crontab}"

# User-home resolution (mirrors graphmap-cadence's). /tmp is the last-resort
# floor when HOME is unset.
resolve_user_home() {
    printf '%s' "${HOME:-/tmp}"
}

# Persistent runner home (.sh runner) — NOT mktemp: this task
# recurs daily and /tmp is subject to cleanup sweeps that would
# silently kill the cadence (same rationale as the sibling cadences' BAT_DIR).
BAT_DIR="${QMD_CADENCE_BAT_DIR:-$(resolve_user_home)/.claude/qmd-cadence}"

# Resolve the himmel root from this script's own location (scripts/luna/..), so
# the runner fires the shipped qmd-reindex.sh by absolute path.
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
REINDEX_SCRIPT="$HIMMEL_ROOT/scripts/luna/qmd-reindex.sh"
RUNNER_SCRIPT="$REINDEX_SCRIPT"

# Runner-format version stamp: emit_runner stamps
# CADENCE_RUNNER_FORMAT_VERSION into the runner so a stale-format armed cadence
# is detectable. Shared lib, same as the sibling cadences.
# Shared qmd resolver: qmd_pinned_invocation returns the absolute
# tokens qmd_cmd would choose, so the cadence pins the SAME install every other
# consumer resolves instead of whatever `command -v qmd` happens to hit first.
# shellcheck source=../lib/qmd-bin.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/qmd-bin.sh"

# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/cadence-format.sh"

# macOS cron Full Disk Access arm-time warning.
# shellcheck source=../lib/macos-fda-warning.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/macos-fda-warning.sh"

# Off-peak default (see the header for the 05:00 rationale).
REINDEX_TIME="05:00"
FORCE=0
DRY_RUN=0
# --hourly: fire every hour instead of once daily. See the
# header for the cron-line mechanics.
HOURLY=0
# --every-hours N (cron only): fire every N hours (N divides 24). Every fire is
# incremental (--no-cleanup) except the one at --time's hour: the full run with
# cleanup, so one task covers both the frequent and the nightly refresh.
EVERY_HOURS=0

# Resolved by validate_arm_inputs: the absolute qmd invocation handed to the
# runner. QMD_BIN is the executable (--qmd-bin); QMD_JS is the optional script
# argument (--qmd-js), set only when the bun-served install wins the resolver's
# preference order — there the canonical invocation is `bun <…/dist/cli/qmd.js>`,
# two tokens, neither of which is a `qmd` executable. See the
# header for why this is pinned at arm time.
QMD_BIN=""
QMD_JS=""

usage() {
    cat <<'EOF'
Usage: qmd-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the recurring qmd reindex cadence:
one daily `qmd update` + `qmd embed` + completeness assert over ALL
configured collections, fired as a DETERMINISTIC script
(bash qmd-reindex.sh ...) — NO claude session.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if a
           HIMMEL-Qmd-* task already exists; --force replaces.
  status   Show whether the cadence is armed (+ next run time + run log).
  disarm   Remove the task (idempotent; rc=0 if nothing was armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>  Anchor time, 24h local (default 05:00). Daily cadence
                  (the default): fires once, at this time, every day. With
                  --hourly, only the minute is used — it becomes the fixed
                  :MM the hourly cadence fires past every hour.
  --hourly        Fire hourly instead of once daily (an hourly crontab
                  line `MM * * * *`).
  --every-hours N Fire every N hours (N divides 24; cron only). Each fire is
                  incremental (`qmd-reindex.sh --no-cleanup`) except the one
                  at --time's hour, the full run with cleanup. Not with
                  --hourly.
  --force         Replace an existing HIMMEL-Qmd-* task
  --dry-run       Print what would happen, touch nothing
                  (honored by arm AND disarm)

WHY 05:00 local: it runs AFTER the pipeline-cadence workers that WRITE to the
vault (Harvest 02:00, Synthesize 03:00, Health 04:00), so the reindex picks
up what they wrote rather than racing them; and it is clear of the graphmap
slots (13:00/13:20). A full refresh measured 16s + 24s, so daily is cheap.

Collection scope is ALL configured collections — `qmd update` / `qmd embed`
default to everything and take -c only to narrow, so nothing is hardcoded
here and a collection added later needs no edit.

This never auto-arms: arming is an explicit operator flip, and disarm is
always available:
    bash scripts/luna/qmd-cadence.sh disarm
EOF
}

SUBCMD="${1:-}"
if [ -z "$SUBCMD" ]; then
    echo "ERR qmd-cadence: subcommand required (arm|status|disarm)" >&2
    usage >&2
    exit 1
fi
shift
case "$SUBCMD" in
    arm|status|disarm) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "ERR qmd-cadence: unknown subcommand: $SUBCMD" >&2
        usage >&2
        exit 1
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --time)
            # Demand a real operand: a trailing `--time` would otherwise make
            # `shift 2` fail under set -e and exit with no message at all.
            if [ $# -lt 2 ]; then
                echo "ERR qmd-cadence: --time requires a value (HH:MM)" >&2
                usage >&2
                exit 1
            fi
            REINDEX_TIME="$2"; shift 2 ;;
        --time=*)   REINDEX_TIME="${1#--time=}"; shift ;;
        --hourly)   HOURLY=1; shift ;;
        --every-hours)
            if [ $# -lt 2 ]; then
                echo "ERR qmd-cadence: --every-hours requires a value (hours, divides 24)" >&2
                usage >&2
                exit 1
            fi
            EVERY_HOURS="$2"; shift 2 ;;
        --every-hours=*) EVERY_HOURS="${1#--every-hours=}"; shift ;;
        --force)   FORCE=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            echo "ERR qmd-cadence: unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

RUNNER_DESC="qmd update + qmd embed"
RUNNER_NAME=$(basename "$RUNNER_SCRIPT")
# The banner's schedule line has to say hourly when it is —
# --hourly changes how often the task fires, not what it runs.
CADENCE_DESC="daily $REINDEX_TIME"
if [ "$HOURLY" -eq 1 ]; then
    CADENCE_DESC="hourly, :${REINDEX_TIME#*:} past the hour"
fi
case "$EVERY_HOURS" in
    0) ;;
    1|2|3|4|6|8|12)
        if [ "$HOURLY" -eq 1 ]; then
            echo "ERR qmd-cadence: --every-hours and --hourly are mutually exclusive" >&2
            exit 1
        fi
        CADENCE_DESC="every $EVERY_HOURS h, :${REINDEX_TIME#*:} past the hour (full run at ${REINDEX_TIME%:*}:${REINDEX_TIME#*:})"
        ;;
    *)
        echo "ERR qmd-cadence: --every-hours must be one of 1 2 3 4 6 8 12 (divides 24), got: $EVERY_HOURS" >&2
        exit 1
        ;;
esac

# Platform detect (same matrix as the sibling cadences).
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    linux*|Linux*)               PLATFORM=linux ;;
    darwin*|Darwin*)             PLATFORM=macos ;;
    *)                           PLATFORM=unknown ;;
esac
case "$PLATFORM" in
    linux|macos)
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR qmd-cadence: '$CRONTAB_BIN' not on PATH (required on $PLATFORM)" >&2
            exit 2
        }
        ;;
    *)
        echo "ERR qmd-cadence: unsupported platform (OSTYPE=${OSTYPE:-})" >&2
        echo "    Supported: Linux/macOS (crontab)" >&2
        exit 2
        ;;
esac

task_summary() {
    case "$1" in
        "$TASK_REINDEX") printf ' -> qmd-reindex (update + embed, all collections, daily)' ;;
    esac
}

# Surface fire-time evidence: the runner writes its output to a .log next to
# itself (rotated per fire), so "armed but never succeeding" is visible here.
status_log() {
    local log="$1" mtime last
    if [ -f "$log" ]; then
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
    if [ -f "$log.prev" ]; then
        # Same macOS-compatible fallback chain as the primary log above: BSD
        # `date` has no -r, so without the `stat -f` worker this would always
        # print '?' on macOS while the primary log resolved fine.
        mtime=$(date -r "$log.prev" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log.prev" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log.prev" 2>/dev/null | tr -d '\r' || true)
        echo "  prev log   $log.prev (last write: $mtime)"
        if [ -n "$last" ]; then
            echo "             last line: $last"
        fi
    fi
}

# Input validation for the cron arm path.
validate_arm_inputs() {
    if ! [[ "$REINDEX_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR qmd-cadence: --time must be HH:MM (24h), got: $REINDEX_TIME" >&2
        exit 1
    fi
    if [ ! -f "$RUNNER_SCRIPT" ]; then
        echo "ERR qmd-cadence: runner not found at $RUNNER_SCRIPT" >&2
        exit 2
    fi
    # FAIL FAST on a missing `qmd`. The scheduler fires with a MINIMAL PATH that
    # does not carry qmd's bin dir (bun installs to ~/.bun/bin), so this must
    # resolve HERE — without it the arm "succeeds" and the first unattended fire
    # dies in a log nobody reads. The resolved absolute invocation is handed to
    # the runner as --qmd-bin (+ --qmd-js when the bun-served install wins).
    #
    # Resolve through the SHARED resolver's preference order, NOT a bare
    # `command -v qmd`. The bare lookup finds the broken
    # Claude-plugin stub (~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd) that
    # shadows the bun shim on Git Bash $PATH inside a Claude Code session —
    # which is exactly where an operator arms this from — and bakes THAT into
    # the runner. Every unattended fire then dies with
    # `Module not found "...plugins/cache/qmd/.../dist/cli/qmd.js"`.
    # qmd_pinned_invocation is not qmd_cmd: qmd_cmd INVOKES (wrong shape for a
    # cadence, which needs a pinnable absolute invocation), this returns the
    # absolute tokens qmd_cmd would have chosen.
    local _resolved
    if ! _resolved=$(qmd_pinned_invocation 2>/dev/null); then
        {
            echo "ERR qmd-cadence: no usable qmd found at arm time, but the cadence runs it at fire time."
            echo "    The scheduler fires with a minimal PATH, so this must resolve HERE — arming now"
            echo "    would produce a cadence that fails on every fire. Install qmd (or put it on PATH)"
            echo "    and re-arm."
        } >&2
        exit 2
    fi
    QMD_BIN=$(printf '%s\n' "$_resolved" | sed -n '1p')
    QMD_JS=$(printf '%s\n' "$_resolved" | sed -n '2p')
    # `command -v` resolves more than on-PATH executables: a shell FUNCTION or
    # ALIAS resolves to its own name/definition, and a relative PATH entry
    # resolves to a relative path. Either would be meaningless in a runner that
    # has cd'd elsewhere under a different PATH — the exact failure this check
    # exists to prevent (same guard the graphmap sibling applies to `claude`).
    # Demand a real, absolute, executable file.
    case "$QMD_BIN" in
        /*) : ;;
        *)
            echo "ERR qmd-cadence: 'qmd' resolved to a non-absolute path ('$QMD_BIN') — a shell function/alias or a relative PATH entry cannot be pinned into a scheduled runner. Install qmd on PATH as a real executable and re-arm." >&2
            exit 2 ;;
    esac
    if [ ! -f "$QMD_BIN" ] || [ ! -x "$QMD_BIN" ]; then
        echo "ERR qmd-cadence: 'qmd' resolved to '$QMD_BIN', which is not an executable file — refusing to pin it into a scheduled runner." >&2
        exit 2
    fi
    # The script arg gets the absolute + real-file discipline too. NOT the -x
    # test: it is a .js handed to an interpreter, never executed directly.
    if [ -n "$QMD_JS" ]; then
        case "$QMD_JS" in
            /*|[A-Za-z]:[/\\]*) : ;;
            *)
                echo "ERR qmd-cadence: qmd script path resolved non-absolute ('$QMD_JS') — cannot be pinned into a scheduled runner." >&2
                exit 2 ;;
        esac
        if [ ! -f "$QMD_JS" ]; then
            echo "ERR qmd-cadence: qmd script path '$QMD_JS' is not a file — refusing to pin it into a scheduled runner." >&2
            exit 2
        fi
    fi

    # LIVENESS, not existence. Everything above proves "a file
    # exists and is executable" — which the broken plugin stub also satisfies.
    # It is the exact class of failure the arm-time fail-fast was written to
    # prevent, reintroduced one layer up. So RUN the resolved invocation once
    # and require rc 0 before pinning it.
    #
    # `collection list` is the probe, deliberately NOT `--version`: --version
    # never opens the index, so it passes even when better-sqlite3's native
    # binding is missing or wrong-ABI — a qmd that answers
    # --version and then dies on every real op is precisely what must not get
    # armed. `collection list` opens the DB, which is what the cadence's
    # `update`/`embed` do. It is also the same probe the shared resolver's own
    # has_index() uses, so this agrees with the rest of the repo.
    # BOUNDED. A probe that HANGS is the third failure mode, and an unbounded
    # one would wedge `arm` forever with no output — a worse outcome than the
    # broken stub this check exists for, since the operator gets nothing to act
    # on. qmd opens a SQLite index that another process may hold, so a stall is
    # a live possibility, not a hypothetical. The bound is qmd_bounded, not timeout(1):
    # timeout returns when qmd's node launcher
    # dies and orphans its bun child.
    # Build the probe as ONE argv rather than branching on QMD_JS — two copies
    # of the same command line is two places for a future change to half-land.
    local probe_out probe_rc=0 probe_timeout="${QMD_PROBE_TIMEOUT_SECS:-60}"
    local probe_cmd=("$QMD_BIN")
    [ -n "$QMD_JS" ] && probe_cmd+=("$QMD_JS")
    probe_out=$(qmd_bounded "$probe_timeout" "${probe_cmd[@]}" collection list 2>&1) || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
        {
            # 124/137 are timeout's own codes — name that case, because "rc=124"
            # alone reads as a qmd error and sends the operator hunting the
            # wrong thing.
            case "$probe_rc" in
                124|137)
                    echo "ERR qmd-cadence: the resolved qmd HUNG (no answer in ${probe_timeout}s) — refusing to arm a cadence that would stall on every fire."
                    echo "    A hung probe usually means the index is locked by another qmd process"
                    echo "    (a resident 'qmd mcp' daemon, or a reindex still running)."
                    echo "    Raise the bound with QMD_PROBE_TIMEOUT_SECS if this machine is just slow."
                    ;;
                *)
                    echo "ERR qmd-cadence: the resolved qmd is NOT USABLE (rc=$probe_rc) — refusing to arm a cadence that would fail on every fire."
                    ;;
            esac
            echo "    invocation: $(qmd_invocation_desc)"
            echo "    probe:      <invocation> collection list"
            printf '%s\n' "$probe_out" | sed 's/^/    /'
            echo "    A qmd that exists but errors here is the whole point of this check: an"
            echo "    existence-only test passes on the broken Claude-plugin stub. Fix the install"
            echo "    (bash scripts/lib/qmd-bin.sh install) and re-arm."
        } >&2
        exit 2
    fi
}

# Human-readable form of the pinned invocation, for messages and status output.
# Thin alias for the shared qmd_bin_desc() in scripts/lib/qmd-bin.sh (public-PR
# CR): this and qmd-reindex.sh's qmd_desc() were byte-identical copies, so the
# format lived in two places. Kept as a local name so the three call sites read
# unchanged.
qmd_invocation_desc() { qmd_bin_desc; }

# --- POSIX (cron) implementation -------------------------------------------
#
# arm/status/disarm against the user crontab. The runner .sh does log
# rotation, fire stamp, cd-into-himmel, then bash + qmd-reindex.sh.

CRON_RUNNER="$BAT_DIR/qmd-reindex.sh"

# Shell-quote a value for a cron command line (mirrors the sibling cadences'
# cron_escape): printf %q survives the /bin/sh re-parse; the extra % -> \% pass
# is cron(5) syntax. Control characters are rejected (rc=2).
cron_escape() {
    if printf '%s' "$1" | grep -qP '[[:cntrl:]]' 2>/dev/null \
       || printf '%s' "$1" | LC_ALL=C grep -q $'[\x01-\x1f\x7f]'; then
        echo "ERR qmd-cadence: cron_escape: argument contains control characters — rejected" >&2
        return 2
    fi
    local s
    s=$(printf '%q' "$1")
    printf '%s' "${s//%/\\%}"
}

# Read the current crontab into CRON_TAB. Fail-CLOSED.
CRON_TAB=""
cron_read() {
    local err_file rc
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    set +e
    CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
            CRON_TAB=""
        else
            echo "ERR qmd-cadence: crontab -l failed (rc=$rc) — refusing to treat as empty crontab:" >&2
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
    err_file=$(mktemp -t qmd-cadence.err.XXXXXX)
    if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
        echo "ERR qmd-cadence: crontab install failed:" >&2
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

# Emit the runner .sh body: stamp the format version, rotate the run log, stamp
# the fire time, cd into the himmel root, then fire the payload with output
# captured to the log. No PATH prepend is needed — unlike the graphmap sibling
# (whose graphify backend spawns `claude` and therefore needs it discoverable),
# we hand qmd's absolute path to the runner as --qmd-bin.
# shellcheck disable=SC2016  # single-quoted $log/$(date)/_rc are emitted literally for the runner's own /bin/sh
emit_runner() {
    local name="$1" payload="$2" q_log="$3" q_himmel="$4"
    printf '#!/bin/sh\n'
    printf '# %s runner — generated by qmd-cadence.sh arm\n' "$name"
    printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
    printf 'log=%s\n' "$q_log"
    # SELF-OVERLAP GUARD. cron has no single-instance policy, so serialize
    # local reindexes.
    # Acquired BEFORE the rotation below, which is itself destructive across
    # concurrent runs (the second run rotates the first run's live log away).
    # mkdir, not a lockfile: it is the one atomic create-or-fail primitive
    # available in POSIX sh with no flock dependency (absent on macOS).
    printf 'lock="$log.lock"\n'
    # prim-ok: generated POSIX sh must skip live owners and report stale ones; with_lock requires bash and waits.
    printf 'if ! mkdir "$lock" 2>/dev/null; then\n'
    # NO AUTOMATIC STALE-LOCK TAKEOVER — deliberately, after three attempts at
    # one. Recovering a stale lock in shell means reading an owner pid, judging
    # it dead, and then removing a directory you do not own; every version of
    # that has an identity window between the judgement and the removal, and
    # review found a distinct bug in each:
    #   1. non-atomic takeover — two contenders both saw the dead owner and both
    #      fired.
    #   2. `mv`-claim, treating pid-less as stale — stole the lock from a LIVE
    #      owner inside the un-stamped mkdir/pid window.
    #   3. `mv`-claim with a re-read — between reading a dead pid and the mv,
    #      another contender can complete its own takeover and install a live
    #      lock, which the mv then steals; and the EXIT trap removes whatever
    #      sits at $lock, not the instance this process created.
    # Each fix produced the next, which is what a lock at the wrong layer looks
    # like. The resource being protected lives on the RECEIVER, and only the
    # receiver can see every sender, so that is where real serialization belongs.
    #
    # So: mkdir is the whole protocol. It is atomic, this process runs ONLY if
    # its own mkdir succeeded, and nothing ever removes a lock it did not
    # create — which also scopes the EXIT trap correctly by construction. The
    # cost is that a SIGKILLed run leaves a lock behind and the cadence stops
    # until a human removes it. That is the SAFE direction: it stops LOUDLY
    # (every fire logs it, and the exit code is non-zero so cron reports it),
    # whereas the alternative fails toward two concurrent ships destroying each
    # other's rollback. A stopped cadence is also exactly what the staleness
    # guard in this same ticket exists to notice downstream.
    # Read the owner FIRST. A pid-less lock is then re-read once after a beat,
    # because mkdir and the pid write cannot be one atomic step: an owner that
    # has just won the lock is briefly un-stamped, and judging it on that first
    # empty read would call a live run abandoned.
    printf '    _prev=$(cat "$lock/pid" 2>/dev/null || echo "")\n'
    printf '    if [ -z "$_prev" ]; then\n'
    printf '        sleep 1\n'
    printf '        _prev=$(cat "$lock/pid" 2>/dev/null || echo "")\n'
    printf '    fi\n'
    printf '    if [ -n "$_prev" ] && kill -0 "$_prev" 2>/dev/null; then\n'
    printf '        echo "[skipped $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\''): pid $_prev still running]" >> "$log" 2>&1\n'
    printf '        exit 0\n'
    printf '    fi\n'
    printf '    echo "[BLOCKED $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\''): stale lock $lock (owner ${_prev:-unknown} is gone); this run did NOT fire. Remove that directory to resume the cadence.]" >> "$log" 2>&1\n'
    printf '    exit 75\n'
    printf 'fi\n'
    # Trap FIRST, then stamp. We own the lock the moment mkdir succeeded, so the
    # release must be armed before anything that can fail — otherwise a failed
    # stamp exits leaving the directory behind.
    printf 'trap '\''rm -f "$lock/pid" 2>/dev/null; rmdir "$lock" 2>/dev/null'\'' EXIT\n'
    # A failed stamp used to be swallowed with `|| true`, which turned a LIVE
    # run into a false BLOCKED for the next contender: an un-stamped lock reads
    # as empty after the 1s re-read, the contender takes the stale branch, and
    # cron gets a hard rc-75 failure naming a lock nobody needs to remove. No
    # corruption — but a misleading alarm is its own cost in a cadence whose
    # whole job is to be believed. Fail here instead; the trap above releases
    # the lock on the way out, so the next fire starts clean.
    printf 'if ! echo $$ > "$lock/pid" 2>/dev/null; then\n'
    printf '    echo "[BLOCKED $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\''): could not write $lock/pid (read-only or full?); refusing to run un-stamped]" >> "$log" 2>&1\n'
    printf '    exit 75\n'
    printf 'fi\n'
    printf 'if [ -f "$log" ]; then\n'
    printf '    mv -f "$log" "$log.prev" || echo "[rotation failed: mv $log -> $log.prev]" >> "$log" 2>&1\n'
    printf 'fi\n'
    printf '{\n'
    printf '    echo "[fired $(date '\''+%%Y-%%m-%%d %%H:%%M:%%S'\'')]"\n'
    printf '    cd %s || exit 1\n' "$q_himmel"
    # Shared emitter: a flow-run row for the
    # worker and a cadence-alert fail/clear on its outcome. Every non-zero rc of
    # qmd-reindex.sh is a failure (its rc 0 is the only success), so no skip
    # list is passed.
    cadence_posix_worker_start "$(printf '%q' "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh")" qmd-reindex HIMMEL-Qmd-Reindex
    printf '    _rc=0; %s || _rc=$?\n' "$payload"
    cadence_posix_worker_end "$(printf '%q' "$HIMMEL_ROOT/scripts/lib/flow-run-ledger.sh")" \
        "$(printf '%q' "$HIMMEL_ROOT/scripts/luna/cadence-alert.sh")" qmd-reindex
    printf '    echo "[exit rc=$_rc]"\n'
    printf '} >> "$log" 2>&1\n'
    # PROPAGATE the runner's exit code (CR finding [codex-1]). Without this the
    # script's status is that of the final `echo` inside the block — i.e. ALWAYS
    # 0 — so cron (and anything else keyed on exit status) reports success after
    # a failed reindex. That is precisely the silent-failure shape this ticket
    # exists to eliminate.
    # Deliberate divergence from the graphmap sibling, which swallows it too.
    printf 'exit "$_rc"\n'
}

cmd_status() {
    cron_read
    echo "qmd-cadence status:"
    local entry sched n_entries dup=""
    entry=$(printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_REINDEX" | head -1 || true)
    if [ -n "$entry" ]; then
        sched=$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')
        n_entries=$(printf '%s\n' "$CRON_TAB" | grep -cF "# $TASK_REINDEX" || true)
        [ "$n_entries" -gt 1 ] && dup=" [DUPLICATE: $n_entries cron entries]"
        echo "ARMED      $TASK_REINDEX (cron: $sched)$dup$(task_summary "$TASK_REINDEX")"
    else
        echo "not armed  $TASK_REINDEX$(task_summary "$TASK_REINDEX")"
    fi
    status_log "$BAT_DIR/qmd-reindex.log"
}

cmd_disarm() {
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -z "$existing" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            rm -f "$CRON_RUNNER"
        fi
        echo "qmd-cadence: nothing armed — disarm is a no-op"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "DRY qmd-cadence: would remove crontab entry: $line"
        done <<< "$existing"
        echo "DRY qmd-cadence: no changes made"
        return 0
    fi
    local newtab
    newtab=$(mktemp -t qmd-cadence.cron.XXXXXX)
    printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" > "$newtab" || true
    # Install must succeed BEFORE the runner is removed — a failed install leaves
    # the entry live and it must keep pointing at an existing runner.
    cron_install "$newtab" || exit 4
    rm -f "$CRON_RUNNER"
    echo "qmd-cadence: cadence disarmed"
}

cmd_arm() {
    validate_arm_inputs

    # Resolve bash to an absolute path so the runner doesn't depend on cron's
    # minimal PATH.
    local bash_bin
    if ! bash_bin=$(command -v bash 2>/dev/null); then
        echo "ERR qmd-cadence: 'bash' not on PATH at arm time" >&2
        exit 2
    fi

    # Dedup guard — never double-register the cadence.
    cron_read
    local existing
    existing=$(cron_existing)
    if [ -n "$existing" ]; then
        if [ "$FORCE" -eq 1 ]; then
            echo "qmd-cadence: --force set; replacing existing cadence entry:" >&2
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [ "$DRY_RUN" -eq 0 ]; then
                    echo "  $line" >&2
                else
                    echo "DRY qmd-cadence: would remove crontab entry: $line"
                fi
            done <<< "$existing"
        else
            {
                echo "ERR qmd-cadence: HIMMEL-Qmd-* crontab entr(ies) already armed:"
                printf '%s\n' "$existing" | sed 's/^/    /'
                echo ""
                echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                echo "    bash scripts/luna/qmd-cadence.sh status"
            } >&2
            exit 3
        fi
    fi

    local q_bash q_script q_qmd q_himmel q_log q_qmd_js=""
    q_bash=$(printf '%q' "$bash_bin")
    q_script=$(printf '%q' "$RUNNER_SCRIPT")
    q_qmd=$(printf '%q' "$QMD_BIN")
    q_himmel=$(printf '%q' "$HIMMEL_ROOT")
    q_log=$(printf '%q' "$BAT_DIR/qmd-reindex.log")
    [ -n "$QMD_JS" ] && q_qmd_js=$(printf '%q' "$QMD_JS")

    # Two-token pin: --qmd-js only when
    # the bun-served install won the resolver.
    local payload salus_payload base
    base="$q_bash $q_script --qmd-bin $q_qmd"
    [ -n "$q_qmd_js" ] && base="$base --qmd-js $q_qmd_js"
    payload="$base"
    salus_payload="$base --index salus"
    local hh mm
    hh="${REINDEX_TIME%:*}"; mm="${REINDEX_TIME#*:}"
    local q_runner entry
    q_runner=$(cron_escape "$CRON_RUNNER")
    if [ "$EVERY_HOURS" -ne 0 ]; then
        # Hours start at the anchor hour's remainder, so the anchor hour is
        # always a fire: the one that runs the full reindex + cleanup.
        entry="$mm $((10#$hh % EVERY_HOURS))-23/$EVERY_HOURS * * * $q_runner # $TASK_REINDEX"
        payload="if [ \"\$(date +%H)\" = $hh ]; then $base; else $base --no-cleanup; fi"
        salus_payload="if [ \"\$(date +%H)\" = $hh ]; then $salus_payload; else $salus_payload --no-cleanup; fi"
    elif [ "$HOURLY" -eq 1 ]; then
        # Hourly forever: fixed minute, every hour — mirrors graphmap-cadence's
        # AST-himmel cron entry, the cron(5) idiom for "hourly"
        # since cron has no repetition construct.
        entry="$mm * * * * $q_runner # $TASK_REINDEX"
    else
        entry="$mm $hh * * * $q_runner # $TASK_REINDEX"
    fi

    # The salus index is a SEPARATE named index (qmd --index salus: salus.yml,
    # salus.sqlite, local models), so the bare reindex never touches it. Fire the
    # same runner again with --index salus when salus.yml exists at FIRE time; the
    # subshell keeps the default index's rc unless only salus failed, and a failed
    # default refresh never skips salus. The path is a literal for the runner's sh.
    # shellcheck disable=SC2016  # expanded by the runner's /bin/sh at fire time
    local salus_cfg='"${QMD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd}/salus.yml"'
    # shellcheck disable=SC2016  # $_m/$_s are the runner's own variables
    payload="( $payload; _m=\$?; if [ -f $salus_cfg ]; then $salus_payload || { _s=\$?; [ \"\$_m\" -ne 0 ] || _m=\$_s; }; fi; exit \"\$_m\" )"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY qmd-cadence: would write $CRON_RUNNER:"
        emit_runner "$TASK_REINDEX" "$payload" "$q_log" "$q_himmel" | sed 's/^/    /'
        echo "DRY qmd-cadence: would add crontab entry:"
        echo "    $entry"
        echo "qmd-cadence: dry-run complete (no changes made)"
        return 0
    fi

    mkdir -p "$BAT_DIR"
    # Stage the runner at a temp path and promote (mv) it only after the crontab
    # install succeeds: writing it in place first would let a failed install
    # (exit 4) leave the OLD crontab live while the runner file already carries
    # the NEW config — a silent half-state under --force re-arm.
    local tmp_runner="$CRON_RUNNER.tmp.$$"
    emit_runner "$TASK_REINDEX" "$payload" "$q_log" "$q_himmel" > "$tmp_runner"
    chmod +x "$tmp_runner"

    # Single atomic rewrite: everything that isn't ours, then our entry.
    local newtab
    newtab=$(mktemp -t qmd-cadence.cron.XXXXXX)
    {
        if [ -n "$CRON_TAB" ]; then
            printf '%s\n' "$CRON_TAB" | grep -vF "$TASK_PREFIX" || true
        fi
        printf '%s\n' "$entry"
    } > "$newtab"
    if ! cron_install "$newtab"; then
        rm -f "$tmp_runner"
        echo "    existing runner file left untouched" >&2
        exit 4
    fi
    mv -f "$tmp_runner" "$CRON_RUNNER"  # prim-ok: publish the pre-chmod-ed runner after cron succeeds; atomic_write resets executable permissions.
    cadence_prov_record "$TASK_REINDEX"

    cat <<EOF

================================================================
  QMD REINDEX CADENCE ARMED
  $TASK_REINDEX  $CADENCE_DESC  -> $RUNNER_DESC
  Scope:  all configured qmd collections, then the salus index
          (qmd --index salus) when ~/.config/qmd/salus.yml exists
  qmd:  $(qmd_invocation_desc)
  Himmel: $HIMMEL_ROOT
  Runner .sh: $BAT_DIR

  The entry fires bash + $RUNNER_NAME directly (no claude session).
  Disarm anytime:
      bash scripts/luna/qmd-cadence.sh disarm
================================================================
EOF
    # No arguments: "all configured qmd collections" (above) is resolved by
    # qmd itself, not a path this script ever sees, so this can't check a
    # specific target the way graphmap-/pipeline-cadence do — it warns
    # unconditionally on Darwin instead of guessing at a collection path.
    macos_fda_warn_if_needed
}

case "$SUBCMD" in
    arm)    cmd_arm ;;
    status) cmd_status ;;
    disarm) cmd_disarm ;;
esac
