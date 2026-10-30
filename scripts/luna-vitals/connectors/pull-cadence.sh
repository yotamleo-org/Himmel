#!/usr/bin/env bash
# scripts/luna-vitals/connectors/pull-cadence.sh
#
# ALPHA opt-in - cadence pull wrapper for the Google Health connector.
# Scheduled-pull entry point; inert until the operator arms it.
#
# Runs `bun google-health.ts pull` for a yesterday-to-today window and
# stops at the artifact file. The operator reviews the artifact and runs
# `luna-vitals write` separately. This wrapper does NOT call write.
#
# Exit codes:
#   0  - success; artifact path printed to stdout.
#   75 - re-consent needed (OAuth token expired/revoked); see stderr.
#   *  - connector error; original message already on stderr.
#
# Environment:
#   FROM                     Override pull window start (YYYY-MM-DD).
#                            Default: yesterday (UTC).
#   TO                       Override pull window end (YYYY-MM-DD).
#                            Default: today (UTC).
#   LUNA_VITALS_ARTIFACT_DIR Artifact output directory.
#                            Default: .gh-vitals/ sibling to this script.
#   PULL_CMD                 TEST SEAM: if set, passed to `bash -c` instead
#                            of the real connector. Example: PULL_CMD='exit 75'
#
# Date portability note:
#   BSD date (macOS) uses -v-1d; GNU date (Linux/Git Bash) uses
#   -d '1 day ago'. Script tries BSD first and falls back to GNU.
#   Set FROM explicitly to bypass date computation entirely.
#
# arm/status/disarm: this same file doubles as its own cadence
# controller, structural sibling of upstream-watch-cadence.sh (ONE daily task,
# no claude session, no --model). `bash pull-cadence.sh <arm|status|disarm>`
# manages crontab on Linux/macOS; ANY
# other invocation (including the existing bare `bash pull-cadence.sh`, used
# both by the operator directly and by the armed task itself) is the
# connector-pull path below, byte-for-byte unchanged.
#
#   bash pull-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   bash pull-cadence.sh status
#   bash pull-cadence.sh disarm [--dry-run]
#
# Precondition: the connector needs GOOGLE_HEALTH_CLIENT_ID/_CLIENT_SECRET/
# _REFRESH_TOKEN in the repo .env (see docs/luna/google-health-connector-
# setup.md) — arming without them still succeeds (the operator may finish
# consent right after), but `arm` WARNs when REFRESH_TOKEN is absent so an
# operator does not discover a silently-never-firing-usefully cadence only
# via its daily re-consent log lines.
#
# Test seams (used by test-pull-cadence-arm.sh):
#   PULLCADENCE_CRONTAB       command invoked instead of `crontab` (POSIX)
#   PULLCADENCE_BAT_DIR       where the persistent runner (.sh) + log live
#   PULLCADENCE_HIMMEL_ROOT   overrides the resolved primary checkout outright
#   PULLCADENCE_PLATFORM      force `posix` (else: derived from OSTYPE)
#   HIMMEL_OBSERVABILITY_CONFIG  (existing seam, scripts/lib/observability-registry.sh)
#
# Exit codes (arm/status/disarm; mirrors upstream-watch-cadence.sh exactly):
#   0  done (armed / status printed / disarmed / dry-run complete)
#   1  usage or input error (bad subcommand, flag, --time)
#   2  env unusable (no scheduler, unknown platform, missing payload script)
#   3  dedup block — already armed; --force replaces
#   4  scheduler invocation failed (create/delete/query), or the post-arm
#      verify failed
# The connector-pull path's own exit codes (0/75/*) are documented above and
# unaffected — rc=75 (re-consent needed) is a REAL failure for the cadence
# report (unlike upstream-watch's rc=10, nothing here remaps it to 0).
#
# Bash 3.2-safe (Linux/macOS).
set -euo pipefail

RECONSENT_EXIT=75

case "${1:-}" in
  arm|status|disarm|-h|--help)
    TASK_NAME="HIMMEL-LunaVitalsPull"
    CRONTAB_BIN="${PULLCADENCE_CRONTAB:-crontab}"

    _CADENCE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../../lib/prim.sh
    . "$_CADENCE_SCRIPT_DIR/../../lib/prim.sh"

    resolve_user_home() {
        if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
            cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
        else
            printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
        fi
    }
    BAT_DIR="${PULLCADENCE_BAT_DIR:-$(resolve_user_home)/.claude/pull-cadence}"

    # Resolve the himmel root to the PRIMARY checkout, never this script's own
    # location (mirrors upstream-watch-cadence.sh's resolve_himmel_root):
    # arming from a feature worktree would embed that
    # worktree's absolute path in the persistent runner, and the post-merge
    # prune then deletes it — every later fire would cd into nothing.
    resolve_himmel_root() {
        local common_dir
        command -v git >/dev/null 2>&1 || return 1
        common_dir="$(git -C "$_CADENCE_SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
        [ -n "$common_dir" ] || return 1
        case "$common_dir" in
            /*|[A-Za-z]:[/\\]*) : ;;
            *) common_dir="$_CADENCE_SCRIPT_DIR/$common_dir" ;;
        esac
        (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
    }
    if [ -n "${PULLCADENCE_HIMMEL_ROOT:-}" ]; then
        HIMMEL_ROOT="$PULLCADENCE_HIMMEL_ROOT"
    elif HIMMEL_ROOT="$(resolve_himmel_root)" && [ -n "$HIMMEL_ROOT" ]; then
        :
    else
        echo "WARN pull-cadence: could not resolve the primary checkout via git -- falling back to this script's own location. If this checkout is a worktree that gets pruned later, the armed cadence will break." >&2
        HIMMEL_ROOT="$(cd "$_CADENCE_SCRIPT_DIR/../.." 2>/dev/null && cd .. && pwd)"
    fi
    PULL_SCRIPT_SH="$HIMMEL_ROOT/scripts/luna-vitals/connectors/pull-cadence.sh"

    # shellcheck source=../../lib/cadence-format.sh
    # shellcheck disable=SC1091
    . "$_CADENCE_SCRIPT_DIR/../../lib/cadence-format.sh"
    # shellcheck source=../../lib/observability-registry.sh
    # shellcheck disable=SC1091
    . "$_CADENCE_SCRIPT_DIR/../../lib/observability-registry.sh"

    FIRE_TIME="06:30"
    DRY_RUN=0
    FORCE=0

    usage() {
        cat <<'EOF'
Usage: pull-cadence.sh <arm|status|disarm> [flags]

Arm the OS scheduler with the daily Google Health connector pull:
ONE daily task that runs `bash pull-cadence.sh` (no args -- the connector-pull
path in THIS same file) directly -- never an interactive claude session, never
--model. A re-consent-needed pull (rc=75) is a real, actionable failure and
reports as one; it is never remapped to a quiet success.

Subcommands:
  arm      Register the daily task. Dedup-guarded: refuses (rc=3) if already
           armed; --force replaces.
  status   Show whether the task is armed (+ next run time + run-log
           evidence from its last fire).
  disarm   Remove the task and its runner (idempotent; rc=0 if nothing was
           armed).

Flags (arm only, except --dry-run):
  --time <HH:MM>  Daily fire time, 24h local (default 06:30 -- after
                  upstream-watch-cadence's 06:00, well before the workday).
  --force         Replace an already-armed task.
  --dry-run       Print what would happen, touch nothing (honored by arm
                  AND disarm).

No --model flag: nothing here ever launches claude, so there is no model to
pin.
EOF
    }

    SUBCMD="$1"
    if [ "$SUBCMD" = "-h" ] || [ "$SUBCMD" = "--help" ]; then usage; exit 0; fi
    shift

    TIME_SET=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --time)
                if [ $# -lt 2 ]; then
                    echo "ERR pull-cadence: --time requires a value (HH:MM)" >&2
                    usage >&2; exit 1
                fi
                FIRE_TIME="$2"; TIME_SET=1; shift 2 ;;
            --time=*) FIRE_TIME="${1#--time=}"; TIME_SET=1; shift ;;
            --force)   FORCE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                echo "ERR pull-cadence: unknown arg: $1" >&2
                usage >&2; exit 1
                ;;
        esac
    done

    if [ "$TIME_SET" -eq 1 ] && [ "$SUBCMD" != "arm" ]; then
        echo "ERR pull-cadence: --time is arm-only" >&2; exit 1
    fi
    if ! [[ "$FIRE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERR pull-cadence: --time must be HH:MM (24h), got: $FIRE_TIME" >&2
        exit 1
    fi

    case "${PULLCADENCE_PLATFORM:-${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}}" in
        posix|linux*|darwin*|freebsd*|Linux|Darwin) PLATFORM=posix ;;
        *) PLATFORM=unknown ;;
    esac
    if [ "$PLATFORM" = "unknown" ]; then
        echo "ERR pull-cadence: unsupported platform '${OSTYPE:-unknown}'." >&2
        echo "    Supported: Linux/macOS (crontab)" >&2
        exit 2
    fi

    # Advisory-only (never blocks arm): warn when the connector has no
    # refresh token yet, so the operator learns this BEFORE the first silent
    # re-consent-needed fire rather than after (docs/luna/google-health-
    # connector-setup.md documents the one-time OAuth setup).
    warn_if_unconfigured() {
        [ "$SUBCMD" = "arm" ] || return 0
        # shellcheck source=../../lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$_CADENCE_SCRIPT_DIR/../../lib/load-dotenv.sh" 2>/dev/null || return 0
        load_dotenv --root "$HIMMEL_ROOT" GOOGLE_HEALTH_REFRESH_TOKEN 2>/dev/null || true
        if [ -z "${GOOGLE_HEALTH_REFRESH_TOKEN:-}" ]; then
            echo "WARN pull-cadence: GOOGLE_HEALTH_REFRESH_TOKEN not set in .env -- arming anyway, but every fire will report 're-consent needed' until you complete the one-time OAuth setup (docs/luna/google-health-connector-setup.md)." >&2
        fi
    }

    require_payload() {
        if [ ! -f "$PULL_SCRIPT_SH" ]; then
            echo "ERR pull-cadence: pull-cadence.sh not found at $PULL_SCRIPT_SH" >&2
            exit 2
        fi
    }

    status_log() {
        local log="$1" mtime last
        if [ -f "$log" ]; then
            mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
                || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null || echo '?')
            echo "  run log    $log (last write: $mtime)"
            last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)
            [ -n "$last" ] && echo "             last line: $last"
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

    # -- POSIX (crontab) -------------------------------------------------------

    cron_escape() {
        local s
        s=$(printf '%q' "$1")
        printf '%s' "${s//%/\\%}"
    }

    CRON_TAB=""
    cron_read() {
        local err_file rc
        err_file=$(mktemp -t pull-cadence.err.XXXXXX)
        set +e
        CRON_TAB=$(LC_ALL=C "$CRONTAB_BIN" -l 2>"$err_file")
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 1 ] && { [ ! -s "$err_file" ] || grep -qi 'no crontab' "$err_file"; }; then
                CRON_TAB=""
            else
                echo "ERR pull-cadence: crontab -l failed (rc=$rc) — refusing to treat as an empty crontab:" >&2
                cat "$err_file" >&2
                rm -f "$err_file"
                exit 2
            fi
        fi
        rm -f "$err_file"
    }

    cron_install() {
        local tab_file="$1" err_file
        err_file=$(mktemp -t pull-cadence.err.XXXXXX)
        if ! "$CRONTAB_BIN" - < "$tab_file" 2>"$err_file"; then
            echo "ERR pull-cadence: crontab install failed:" >&2
            cat "$err_file" >&2
            echo "    rejected crontab left at: $tab_file" >&2
            rm -f "$err_file"
            return 4
        fi
        rm -f "$err_file" "$tab_file"
    }

    cron_existing() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

    # shellcheck disable=SC2016  # $log / $(date) are emitted literally for the runner's own /bin/sh
    emit_runner() {
        local q_himmel="$1" payload="$2" q_log="$3"
        printf '#!/bin/sh\n'
        printf '# pull-cadence runner — generated by pull-cadence.sh arm\n'
        printf '# %s %s\n' "$CADENCE_FORMAT_MARKER" "$CADENCE_RUNNER_FORMAT_VERSION"
        printf 'log=%s\n' "$q_log"
        printf 'if [ -f "$log" ]; then mv -f "$log" "$log.prev" 2>/dev/null; fi\n'
        printf '{\n'
        printf '    echo "[fired $(date "+%%Y-%%m-%%d %%H:%%M:%%S")]"\n'
        printf '    cd %s || exit 1\n' "$q_himmel"
        printf '    %s\n' "$payload"
        printf '    _rc=$?\n'
        printf '    echo "[exit rc=$_rc]"\n'
        printf '} >> "$log" 2>&1\n'
        printf 'exit "$_rc"\n'
    }

cmd_status() {
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR pull-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
            exit 2
        }
        cron_read
        echo "pull-cadence status:"
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
        echo "  runner     $BAT_DIR/pull-cadence.sh"
        status_log "$BAT_DIR/pull-cadence.log"
    }

cmd_disarm() {
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR pull-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
            exit 2
        }
        cron_read
        local existing
        existing=$(cron_existing)
        if [ -z "$existing" ]; then
            if [ "$DRY_RUN" -eq 0 ]; then
                rm -f "$BAT_DIR/pull-cadence.sh"
                observability_unregister_cadence pull-cadence "$TASK_NAME"
            fi
            echo "pull-cadence: nothing armed — disarm is a no-op"
            return 0
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '%s\n' "$existing" | sed 's/^/DRY pull-cadence: would remove crontab entry: /'
            echo "DRY pull-cadence: no changes made"
            return 0
        fi
        local newtab
        newtab=$(mktemp -t pull-cadence.cron.XXXXXX)
        printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" > "$newtab" || true
        cron_install "$newtab" || exit 4
        rm -f "$BAT_DIR/pull-cadence.sh"
        observability_unregister_cadence pull-cadence "$TASK_NAME"
        echo "pull-cadence: cadence disarmed"
    }

cmd_arm() {
        command -v "$CRONTAB_BIN" >/dev/null 2>&1 || {
            echo "ERR pull-cadence: '$CRONTAB_BIN' not on PATH (required on Linux/macOS)" >&2
            exit 2
        }
        require_payload
        warn_if_unconfigured
        local bash_bin
        if ! bash_bin=$(command -v bash 2>/dev/null); then
            echo "ERR pull-cadence: 'bash' not on PATH at arm time" >&2
            exit 2
        fi

        cron_read
        local existing
        existing=$(cron_existing)
        if [ -n "$existing" ]; then
            if [ "$FORCE" -eq 1 ]; then
                echo "pull-cadence: --force set; replacing existing entry:" >&2
                printf '%s\n' "$existing" | sed 's/^/  /' >&2
            else
                {
                    echo "ERR pull-cadence: already armed: $TASK_NAME."
                    echo ""
                    echo "Dedup safeguard — re-run with --force to replace, or inspect with:"
                    echo "    bash scripts/luna-vitals/connectors/pull-cadence.sh status"
                } >&2
                exit 3
            fi
        fi

        local q_himmel q_bash q_script q_log payload
        q_himmel=$(printf '%q' "$HIMMEL_ROOT")
        q_bash=$(printf '%q' "$bash_bin")
        q_script=$(printf '%q' "$PULL_SCRIPT_SH")
        q_log=$(printf '%q' "$BAT_DIR/pull-cadence.log")
        payload="$q_bash $q_script"

        local runner="$BAT_DIR/pull-cadence.sh"
        local hh="${FIRE_TIME%:*}" mm="${FIRE_TIME#*:}"
        local entry_line
        entry_line="$mm $hh * * * $(cron_escape "$runner") # $TASK_NAME"

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY pull-cadence: would write $runner:"
            emit_runner "$q_himmel" "$payload" "$q_log" | sed 's/^/    /'
            echo "DRY pull-cadence: would install crontab entry:"
            echo "    $entry_line"
            echo "pull-cadence: dry-run complete (no changes made)"
            return 0
        fi

        mkdir -p "$BAT_DIR"

        local tmp_runner
        tmp_runner=$(mktemp "$BAT_DIR/.pull-cadence.sh.XXXXXX")
        emit_runner "$q_himmel" "$payload" "$q_log" > "$tmp_runner"
        chmod +x "$tmp_runner"
        if [ -e "$runner" ] && [ ! -f "$runner" ]; then
            echo "ERR pull-cadence: $runner exists and is not a regular file — refusing to publish" >&2
            rm -f "$tmp_runner"
            exit 4
        fi
        # prim-ok: the runner must already be executable at publication; atomic_write creates a mode-600 replacement.
        if ! mv -f "$tmp_runner" "$runner"; then
            echo "ERR pull-cadence: failed to publish runner to $runner" >&2
            rm -f "$tmp_runner"
            exit 4
        fi

        local newtab
        newtab=$(mktemp -t pull-cadence.cron.XXXXXX)
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

        observability_register_cadence pull-cadence 86400 "$TASK_NAME"
        cadence_prov_record "$TASK_NAME"

        arm_summary "crontab entry" "$runner" "$BAT_DIR/pull-cadence.log"
    }

    arm_summary() {
        local kind="$1" runner="$2" log="$3"
        cat <<EOF
================================================================
pull-cadence ARMED

  $TASK_NAME   daily $FIRE_TIME local — $kind — runner: $runner
  Repo:   $HIMMEL_ROOT
  Log:    $log
          (one prior run kept as .log.prev)

  Each day: bash pull-cadence.sh (no args) runs the Google Health connector
  pull directly (no claude session), writing a review artifact. A
  re-consent-needed pull (rc=75) shows up as a genuine failure in the log and
  in the scheduler's own run history — it is never silently swallowed.

  Registered with the observability registry (himmel-doctor's C24 check will
  report this task as expected).

  Status / disarm anytime:
      bash scripts/luna-vitals/connectors/pull-cadence.sh status
      bash scripts/luna-vitals/connectors/pull-cadence.sh disarm
================================================================
EOF
    }

    _cadence_rc=0
    case "$PLATFORM:$SUBCMD" in
        posix:arm)      cmd_arm ;;
        posix:status)   cmd_status || _cadence_rc=$? ;;
        posix:disarm)   cmd_disarm ;;
    esac
    exit "$_cadence_rc"
    ;;
esac

# -- resolve paths ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
# Repo root is three levels up from scripts/luna-vitals/connectors/.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# -- date window --------------------------------------------------------------

if [ -z "${TO:-}" ]; then
    TO="$(TZ=UTC date +%Y-%m-%d)"
fi

if [ -z "${FROM:-}" ]; then
    # Try BSD date (-v-1d), fall back to GNU date (-d '1 day ago').
    FROM="$(TZ=UTC date -v-1d +%Y-%m-%d 2>/dev/null || TZ=UTC date -u -d '1 day ago' +%Y-%m-%d)"
fi

# -- artifact output ----------------------------------------------------------

artifact_dir="${LUNA_VITALS_ARTIFACT_DIR:-$SCRIPT_DIR/../.gh-vitals}"
mkdir -p "$artifact_dir"
artifact="$artifact_dir/gh-${TO}.json"

# -- flow-run ledger ----------------------------------------------------------

FLOW_RUN_LEDGER="$REPO_ROOT/scripts/lib/flow-run-ledger.sh"
# host arg "" — the lib defaults it (hostname/uname fallback lives in ONE place)
FLOW_RUN_ID=$(bash "$FLOW_RUN_LEDGER" --append-start luna-vitals-pull "" "" "" "" "" "" "$$" 2>/dev/null) || FLOW_RUN_ID=""

# -- run pull -----------------------------------------------------------------

# Disable errexit so we can capture the pull exit code explicitly.
set +e
if [ -n "${PULL_CMD:-}" ]; then
    # TEST-ONLY seam (eval) — must never be set in a production scheduler env.
    # PULL_CMD is evaluated in a subshell to avoid exec'ing a new binary, keeping tests fast.
    # Example: PULL_CMD='exit 75'
    ( eval "$PULL_CMD" )
else
    # cd to repo root so bun auto-loads .env from <repo>/.env (bun reads .env from CWD).
    cd "$REPO_ROOT"
    bun "$SCRIPT_DIR/google-health.ts" pull --from "$FROM" --to "$TO" --out "$artifact"
fi
pull_rc=$?
set -e

FLOW_RUN_OUTCOME=$(bash "$FLOW_RUN_LEDGER" --classify "$pull_rc" "" 2>/dev/null) || FLOW_RUN_OUTCOME=complete
[ -n "$FLOW_RUN_OUTCOME" ] || FLOW_RUN_OUTCOME=complete
if [ -n "$FLOW_RUN_ID" ]; then
    bash "$FLOW_RUN_LEDGER" --append-end luna-vitals-pull "$FLOW_RUN_ID" "" "$pull_rc" "$FLOW_RUN_OUTCOME" "" "" >/dev/null 2>&1 || true
fi

# -- handle result ------------------------------------------------------------

if [ "$pull_rc" -eq "$RECONSENT_EXIT" ]; then
    echo "[pull-cadence] re-consent needed: Google Health OAuth token has expired or was revoked." >&2
    echo "[pull-cadence] To re-auth, run auth-url then auth-exchange:" >&2
    printf '  1. bun %s/google-health.ts auth-url\n' "$SCRIPT_DIR" >&2
    printf '     (open the printed URL in a browser and grant access)\n' >&2
    printf '  2. bun %s/google-health.ts auth-exchange --code <code>\n' "$SCRIPT_DIR" >&2
    exit "$RECONSENT_EXIT"
fi

if [ "$pull_rc" -ne 0 ]; then
    echo "[pull-cadence] error: connector pull exited with code $pull_rc" >&2
    exit "$pull_rc"
fi

# -- success ------------------------------------------------------------------

echo "$artifact"
printf '[pull-cadence] review the artifact above; operator inspects it first, then land it:\n' >&2
printf '  1. bun %s/scripts/luna-vitals/cli.ts merge --det %s --out <merged.json>\n' "$REPO_ROOT" "$artifact" >&2
printf '  2. bun %s/scripts/luna-vitals/cli.ts write <merged.json> --dir <50-Vitals path>\n' "$REPO_ROOT" >&2

exit 0
