#!/usr/bin/env bash
# ci-cadence.sh — the chief watches every scheduled CI workflow.
#
#   ci-cadence.sh last              one TSV row per scheduled workflow, read at most once per
#                                   CI_CADENCE_INTERVAL_SEC (default 1800), else served from the cache:
#                                   <workflow>\t<status>\t<conclusion>\t<created epoch>\t<run id>
#   ci-cadence.sh field             the tick's cadence= value: <name>:<state>:<age>:<run id>[:RED|:SKIP|:MISSED],...
#                                   or `?` when gh cannot be read and nothing fresh is cached
#   ci-cadence.sh review            the tick's review= value: the daily failure review as one more scheduled
#                                   row (see cmd_review): <date>:<age>:<failures>:<new>:<new 5+>:<filed>[:CAPPED][:STALE]
#   ci-cadence.sh cause <workflow> <run id> <RED|SKIP|MISSED>
#                                   one line for the wake: the run URL and why (the first failing job and
#                                   step, the skip, or the missing run)
#   ci-cadence.sh run | arm [--time HH:MM] [--force] [--dry-run] | status | disarm [--dry-run]
#                                   the station row for the ledger-drift check (see below)
#
# WATCHED: every workflow under .github/workflows with a `schedule:` trigger, listed in WORKFLOWS below
# with its period in hours. The last SCHEDULED run (`--event schedule`) is the one that counts, so a
# pull_request run of macos-cadence.yml that skipped for want of the ci:macos label never shows.
#   RED     the run concluded failure or timed_out.
#   SKIP    the run concluded skipped. A gate that skips on purpose (SNYK_TOKEN unset, a non-main ref) skips
#           a STEP or a JOB and the run still concludes success, so a skipped run is always a wrong skip.
#   MISSED  the newest scheduled run is older than 1.5 times the period.
# A run still queued or in progress shows `running` and flags nothing. A workflow with no scheduled run
# yet shows `none`.
#
# STATION ROW: fork-drift is already covered at the station (drift-fix-cadence.sh runs
# check-plugin-drift.sh, the guard fork-drift.yml runs); ledger-drift had no row, so `arm` installs a
# daily cron row that runs scripts/ci/ledger-drift.sh and reports a failure through
# scripts/luna/cadence-alert.sh. The crontab is edited ONLY through crontab_locked_rmw (the cadence lock).
# Pages, ci-image, macos-cadence and the ci nightly are CI-only: watched here, not mirrored. The Snyk
# station row belongs to snyk-scan-cadence.sh; this file only watches snyk-weekly.
#
# Exit (last/field/cause): 0 always, a failed read prints `?`. Exit (arm etc.): 0 ok; 1 usage; 2 no cron
# or checkout; 3 arm: already armed; 4 crontab or runner write failed; 77 test-run guard refusal.
#
# Seams (tests): CI_CADENCE_GH (the gh command; default scripts/lib/gh-read.sh), CI_CADENCE_STATE (the cache
# file), CI_CADENCE_NOW (epoch), CI_CADENCE_DIR (where gh runs), CICADENCE_CRONTAB, CICADENCE_RUNNER_DIR,
# CICADENCE_LEDGER_SCRIPT, CICADENCE_ALERT.
# Platform: Linux (GNU date).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
. "$SCRIPT_DIR/../../lib/git-clean.sh" && git_env_scrub
# shellcheck source=../../lib/timeout-bin.sh
. "$SCRIPT_DIR/../../lib/timeout-bin.sh"
GH_CMD="${CI_CADENCE_GH:-$SCRIPT_DIR/../../lib/gh-read.sh}"
STATE_FILE="${CI_CADENCE_STATE:-${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}/ci-cadence.cache}"
# <workflow file>:<period in hours>. ci.yml fires a nightly and a 7 h main sweep; its period is the nightly's.
# macos-cadence runs Tue and Fri, so its longest gap is Friday to Tuesday, 4 days.
WORKFLOWS="ci.yml:24 ledger-drift.yml:24 fork-drift.yml:24 pages.yml:24 ci-image.yml:168 macos-cadence.yml:96 snyk-weekly.yml:168"

now() { local n="${CI_CADENCE_NOW:-}"; case "$n" in ''|*[!0-9]*) date +%s ;; *) printf '%s\n' "$n" ;; esac; }

# gh_run <args...> — gh in the repo checkout, bounded.
gh_run() {
    local dir="${CI_CADENCE_DIR:-$PWD}"
    # 7 sequential reads at 5 s each stay inside the tick's 40 s bound, so a slow gh cannot starve the cache write
    (cd "$dir" 2>/dev/null && ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 5} "$GH_CMD" "$@")
}

# refresh — read every workflow's newest scheduled run into the cache; stop at the first gh failure.
refresh() {
    local wf row tmp status concl created id epoch
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || return 1
    tmp="$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null)" || return 1  # swallow-ok: a failed mktemp returns 1, the tick reads cadence=?
    trap 'rm -f "$tmp"' EXIT  # a read killed mid-way (the tick's bound) leaves no half file
    printf '%s\n' "$(now)" > "$tmp"
    for wf in $WORKFLOWS; do
        wf="${wf%%:*}"
        row="$(gh_run run list --workflow "$wf" --event schedule --limit 1 --json databaseId,status,conclusion,createdAt --jq '.[0] // empty | [.status, (.conclusion | if . == null or . == "" then "-" else . end), .createdAt, .databaseId] | @tsv' 2>/dev/null)" || { rm -f "$tmp"; return 1; }  # swallow-ok: a failed read leaves the cache as it was and the tick reads cadence=?
        if [ -z "$row" ]; then
            printf '%s\tnone\t-\t0\t0\n' "$wf" >> "$tmp"
            continue
        fi
        # an answer that is not a run row (a stand-in gh, a proxy page) is no data at all, not an unreadable gh
        # the stamp alone is kept, so the next tick inside the interval makes no gh call
        [[ "$row" =~ ^[a-z_]+$'\t'[a-z_-]+$'\t'[0-9T:Z.+-]+$'\t'[0-9]+$ ]] || { head -n 1 "$tmp" > "$tmp.stamp" && mv -f "$tmp.stamp" "$STATE_FILE"; rm -f "$tmp"; return 2; }  # prim-ok: the temp file sits beside the cache, so the rename is atomic
        IFS=$'\t' read -r status concl created id <<< "$row"
        epoch="$(date -d "$created" +%s 2>/dev/null)" || epoch=0  # gnu-ok: Linux-only kit; swallow-ok: an unparsable time reads as age unknown
        printf '%s\t%s\t%s\t%s\t%s\n' "$wf" "$status" "$concl" "$epoch" "$id" >> "$tmp"
    done
    mv -f "$tmp" "$STATE_FILE"  # prim-ok: the temp file sits beside the cache, so the rename is atomic
}

# cmd_last — the cached rows, refreshed when older than the interval.
cmd_last() {
    local interval="${CI_CADENCE_INTERVAL_SEC:-1800}" stamp age
    case "$interval" in ''|*[!0-9]*) interval=1800 ;; esac
    stamp=""
    [ -f "$STATE_FILE" ] && stamp="$(head -n 1 "$STATE_FILE" 2>/dev/null)"  # swallow-ok: an unreadable cache reads as stale
    case "$stamp" in ''|*[!0-9]*) stamp="" ;; esac
    if [ -z "$stamp" ] || [ $(( $(now) - stamp )) -ge "$interval" ]; then
        refresh || return $?
    fi
    # a stamp-only cache is an answer that held no run rows: nothing to show until the interval passes
    [ "$(wc -l < "$STATE_FILE")" -gt 1 ] || return 2
    tail -n +2 "$STATE_FILE"
}

fmt_age() { # <seconds>
    local s="$1"
    if [ "$s" -lt 3600 ]; then printf '%sm' $(( s / 60 ))
    elif [ "$s" -lt 172800 ]; then printf '%sh' $(( s / 3600 ))
    else printf '%sd' $(( s / 86400 )); fi
}

cmd_field() {
    local rows rc=0 out="" wf status concl epoch id period state age flag name p t
    t="$(now)"
    rows="$(cmd_last)" || rc=$?
    # 1 = gh unreadable (the tick shows ?); 2 = gh answered with no run rows (nothing to show)
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] || printf '?\n'; return 0; }
    while IFS=$'\t' read -r wf status concl epoch id; do
        [ -n "$wf" ] || continue
        name="${wf%.yml}"
        if [ "$status" = none ]; then out="${out:+$out,}$name:none"; continue; fi
        period=24
        for p in $WORKFLOWS; do [ "${p%%:*}" = "$wf" ] && period="${p##*:}"; done
        state="$concl"; [ "$status" = completed ] || state=running
        age=$(( t - epoch )); [ "$age" -ge 0 ] || age=0
        flag=""
        case "$concl" in failure|timed_out) flag=RED ;; skipped) flag=SKIP ;; esac
        [ -n "$flag" ] || [ "$status" != completed ] || [ "$epoch" -eq 0 ] || [ "$age" -le $(( period * 5400 )) ] || flag=MISSED
        out="${out:+$out,}$name:$state:$(fmt_age "$age"):$id${flag:+:$flag}"
    done <<< "$rows"
    printf '%s\n' "${out:-?}"
}

# cmd_review — the daily failure review as one more scheduled row (operator decision 593). A read-only
# look at the newest failure-review-<date>.md and its .json sidecar (scripts/eval/worker-digest):
#   <date>:<age>:<failures>:<new classes>:<new classes with 5+ rows>:<filed keys joined by +, or ->[:CAPPED][:STALE]
# `new` = classes the ledger had no earlier row of (recurring false); filed = the routing decisions that
# filed a ticket; CAPPED = the router hit its daily create cap; STALE = no review for 26 hours.
# `none` = no review file; a missing or unreadable sidecar reads `?` for the counts.
cmd_review() {
    local dir md day mtime age counts rows new big filed flags=""
    dir="${HIMMEL_FAILURE_REVIEW_DIR:-${TICK_STATE_DIR:-${HOME:-/tmp}/.himmel/state}/failure-review}"
    # shellcheck disable=SC2012  # names are failure-review-YYYY-MM-DD.md only
    md="$(ls -1 "$dir"/failure-review-????-??-??.md 2>/dev/null | sort | tail -n 1)"  # swallow-ok: no review file reads as none
    [ -n "$md" ] || { printf 'none\n'; return 0; }
    day="${md##*failure-review-}"; day="${day%.md}"
    mtime="$(stat -c %Y "$md" 2>/dev/null)" || mtime=0  # gnu-ok: Linux-only kit; swallow-ok: an unreadable mtime reads as age unknown
    age=$(( $(now) - mtime )); [ "$age" -ge 0 ] || age=0
    counts="$(jq -r '[(.totals.rows // 0), ([.classes[] | select(.recurring == false and (.class | startswith("traj/") | not))] | length), ([.classes[] | select(.recurring == false and .rows >= 5 and (.class | startswith("traj/") | not))] | length), ([.routing[] | select(.decision == "filed") | .ticket] | map(select(. != null and . != "")) | join("+") | if . == "" then "-" else . end), (any(.routing[]; .decision == "capped" or .decision == "would-cap") | tostring)] | @tsv' "${md%.md}.json" 2>/dev/null)" || counts=""  # swallow-ok: a missing sidecar reads ? for the counts
    if [ -n "$counts" ]; then
        IFS=$'\t' read -r rows new big filed capped <<< "$counts"
        [ "$capped" != true ] || flags="$flags:CAPPED"
    else
        rows='?'; new='?'; big='?'
    fi
    [ "$age" -lt 93600 ] || flags="$flags:STALE"
    printf '%s:%s:%s:%s:%s:%s%s\n' "$day" "$(fmt_age "$age")" "$rows" "$new" "$big" "${filed:--}" "$flags"
}

cmd_cause() { # <workflow name or file> <run id> <RED|SKIP|MISSED>
    local wf="${1:-}" id="${2:-}" kind="${3:-}" view url why
    wf="${wf%.yml}"
    case "$id" in ''|*[!0-9]*) echo "ERR ci-cadence: cause needs a numeric run id" >&2; return 1 ;; esac
    view="$(gh_run run view "$id" --json url,jobs --jq '[.url, (first(.jobs[]? | select(.conclusion == "failure" or .conclusion == "timed_out")) // {} | [.name // "", (first(.steps[]? | select(.conclusion == "failure" or .conclusion == "timed_out") | .name) // "")] | join(" / "))] | @tsv' 2>/dev/null)" || view=""  # swallow-ok: an unreadable run view still wakes, with the cause said unreadable
    IFS=$'\t' read -r url why <<< "$view"
    [ -n "$url" ] || url="run $id (url unreadable)"
    case "$kind" in
        RED) why="${why:+first failing job / step: $why}"; why="${why:-first failing job unreadable, open the run}" ;;
        SKIP) why="the run concluded skipped: every job's if: gate was false" ;;
        MISSED) why="no newer scheduled run than this one, past 1.5 times its period" ;;
        *) why="${why:-?}" ;;
    esac
    printf '%s run=%s %s %s cause: %s\n' "$wf" "$id" "$kind" "$url" "$why"
}

# ---- the station row for ledger-drift ----
TASK_NAME="HIMMEL-LedgerDrift"
CRONTAB_BIN="${CICADENCE_CRONTAB:-crontab}"
RUNNER_DIR="${CICADENCE_RUNNER_DIR:-${HOME:-}/.claude/ledger-drift-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1  # swallow-ok: failure returns 1 on this line
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)  # swallow-ok: caller checks for an empty result
}

cmd_run() {
    local root script alert log rc
    root="$(resolve_primary)" || { echo "ERR ci-cadence: cannot resolve the primary checkout" >&2; return 2; }
    script="${CICADENCE_LEDGER_SCRIPT:-$root/scripts/ci/ledger-drift.sh}"
    alert="${CICADENCE_ALERT:-$root/scripts/luna/cadence-alert.sh}"
    log="$RUNNER_DIR/ledger-drift-cadence.log"
    (cd "$root" && bash "$script" </dev/null)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        bash "$alert" clear ledger-drift >/dev/null 2>&1 || true  # swallow-ok: the alert sink never changes the runner's own status
    else
        bash "$alert" fail ledger-drift "the shard ledger check exited $rc" "$log" \
            "$([ "$rc" -eq 1 ] && echo 'the shards are out of balance against the last green main runs' || echo 'no usable input or a usage error')" \
            "read the log, then re-measure the ledger (scripts/ci/ledger-drift.sh)" >/dev/null 2>&1 || true  # swallow-ok: the alert sink never changes the runner's own status
    fi
    return "$rc"
}

cron_read() {
    local err
    CRON_TAB=""
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C "$CRONTAB_BIN" -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR ci-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

# Run under crontab_locked_rmw on the table it just read; $force and $entry are cmd_arm's locals.
arm_edit() {
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR ci-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; }
}
disarm_edit() { { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; }; }

cmd_arm() {
    local time="09:20" force=0 dry=0 root runner entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --time) [ $# -ge 2 ] || { echo "ERR ci-cadence: --time needs a value" >&2; return 1; }
                    time="$2"; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR ci-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR ci-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR ci-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR ci-cadence: cannot resolve the primary checkout" >&2; return 2; }
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR ci-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/ledger-drift-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY ci-cadence: would write $runner and install: $entry"
        return 0
    fi
    # A test on the station never writes the real crontab or a runner under the real home; only exit 77 refuses.
    local guard_rc=0
    bash "$SCRIPT_DIR/../../lib/test-run-guard" check --tool "$CRONTAB_BIN" ci-cadence-arm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# ci-cadence runner — generated by ci-cadence.sh arm\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/ledger-drift-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run >> "$log" 2>&1\n' "$(command -v bash)" "$root/scripts/handover/chief-kit/ci-cadence.sh"
        printf '_rc=$?\necho "[exit rc=$_rc]" >> "$log"\nexit "$_rc"\n'
    } > "$runner" || { echo "ERR ci-cadence: cannot write the runner $runner" >&2; return 4; }
    chmod 700 "$runner" || return 4
    crontab_locked_rmw "$CRONTAB_BIN" arm_edit || return $?
    echo "ci-cadence ARMED: daily $time — $runner (status: bash scripts/handover/chief-kit/ci-cadence.sh status)"
}

cmd_status() {
    local entry n dup="" log mtime last
    cron_read || return 1
    entry="$(cron_entry | head -1)"
    if [ -n "$entry" ]; then
        n="$(cron_entry | grep -c . || true)"  # swallow-ok: no match means zero entries
        [ "$n" -gt 1 ] && dup=" [DUPLICATE: $n cron entries]"
        echo "ARMED      $TASK_NAME ($(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}'))$dup"
        log="$RUNNER_DIR/ledger-drift-cadence.log"
        if [ -f "$log" ]; then
            mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')  # swallow-ok: an unreadable mtime prints ?
            last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r')  # read-sink-ok: this cadence runner's own log # swallow-ok: a missing last line prints nothing
            echo "  run log    $log (last write: $mtime)"
            [ -z "$last" ] || echo "             last line: $last"
        else echo "  run log    $log (absent — task has not fired yet)"; fi
    else echo "not armed  $TASK_NAME"; fi
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ "$dry" -eq 1 ]; then echo "DRY ci-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    local guard_rc=0
    bash "$SCRIPT_DIR/../../lib/test-run-guard" check --tool "$CRONTAB_BIN" ci-cadence-disarm "$RUNNER_DIR" || guard_rc=$?
    [ "$guard_rc" -ne 77 ] || return 77
    if [ -z "$(cron_entry)" ]; then echo "ci-cadence: nothing armed"; return 0; fi
    crontab_locked_rmw "$CRONTAB_BIN" disarm_edit || return $?
    rm -f "$RUNNER_DIR/ledger-drift-cadence.sh"
    echo "ci-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    last) cmd_last; [ $? -ne 1 ] || printf '?\n' ;;
    field) cmd_field ;;
    review) cmd_review ;;
    cause) cmd_cause "$@" ;;
    run|arm|status|disarm)
        # shellcheck source=../../lib/crontab-locked-rmw.sh
        . "$SCRIPT_DIR/../../lib/crontab-locked-rmw.sh"
        "cmd_$sub" "$@" ;;
    *) echo "Usage: ci-cadence.sh <last|field|cause|run|arm|status|disarm>" >&2; exit 1 ;;
esac
