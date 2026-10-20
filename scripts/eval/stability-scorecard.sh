#!/usr/bin/env bash
# stability-scorecard.sh — append one stability row per UTC day to the scorecard TSV.
#
#   stability-scorecard.sh run    [--date YYYY-MM-DD]
#   stability-scorecard.sh arm    [--hour 0-23] [--minute 0-59] [--force] [--dry-run]
#   stability-scorecard.sh status
#   stability-scorecard.sh disarm [--dry-run]
#
# WHY: nobody can tell whether the CI and guard fixes make himmel more stable
# without a daily before/after number. `run` measures the last 24 h from existing
# sources (no LLM) and appends one row; a date already in the file is skipped, so a
# cron retry is safe. A source that fails reads `unknown` (never 0) and the run exits 1.
#
# TSV: $SCORECARD_TSV, else <handover root>/<USER_SLUG>/himmel/specs/research/stability-scorecard.tsv
# Columns: see HEADER below. stuck_playbook_hits is n/a (no ledger exists).
# Seams (tests): SCORECARD_CI_METRICS_CMD (prints ci-metrics.sh markdown),
# SCORECARD_RED_MAIN_CMD (prints a count), SCORECARD_JIRA_CMD (prints `jira list` rows),
# SCORECARD_MAIN_KEYS_CMD (prints the HIMMEL keys in main squash subjects),
# SCORECARD_DENIALS_FILE, SCORECARD_CRONTAB, SCORECARD_RUNNER_DIR, SCORECARD_VERSION.
#
# ponytail: residual_added counts every ticket created in the window on the current version (SCORECARD_VERSION, default v1.1.3), upgrade path = count only residual-depth labels once HIMMEL-6115 ships
# ponytail: shipped_strict counts Done non-Epic tickets resolved in the window whose key is in a main squash subject `(#N)` of the last 30 days, so fork-repo PRs and body-only keys are missed, upgrade path = the fresh/broad forms in throughput-model-2026-10-17.md section 1 once the undercount matters
# ponytail: the per-class and per-priority escape split rides the free-text note cell (the column schema stays fixed), upgrade path = own columns once a reader parses it
# Escapes are labelled by scripts/cr/mark-deferred-escape.sh (class-<id> copied from the residual).
# OFF by default: only `arm` installs the cron entry. Platform: cron (Linux/macOS).
set -uo pipefail

TASK_NAME="HIMMEL-StabilityScorecard"
LEGACY_HEADER=$'date\tts_utc\tci_queue_p50_s\tci_queue_p90_s\tred_job_rate_pct\tred_main_count\tguard_denials_24h\tstuck_playbook_hits\tresidual_added_v113\tdeferred_escapes\tcancelled_runner_share_pct\tnote'
HEADER=$'date\tts_utc\tci_queue_p50_s\tci_queue_p90_s\tred_job_rate_pct\tred_main_count\tguard_denials_24h\tstuck_playbook_hits\tresidual_added_v113\tdeferred_escapes\tcancelled_runner_share_pct\tshipped_strict\tadmin_closes\tnote'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${SCORECARD_REPO:-yotamleo/Himmel}"
VERSION="${SCORECARD_VERSION:-v1.1.3}"
CRONTAB_BIN="${SCORECARD_CRONTAB:-crontab}"
RUNNER_DIR="${SCORECARD_RUNNER_DIR:-${HOME:-}/.claude/stability-scorecard-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

tsv_path() {
    local lib root
    [ -z "${SCORECARD_TSV:-}" ] || { printf '%s' "$SCORECARD_TSV"; return 0; }
    lib="$(resolve_primary)/scripts/lib/handover-path.sh"
    # shellcheck disable=SC1090
    if [ -f "$lib" ]; then . "$lib"; root="$(handover_root)" || root=""; fi
    [ -n "${root:-}" ] || { echo "ERR scorecard: no handover root (set HANDOVER_DIR or SCORECARD_TSV)" >&2; return 1; }
    printf '%s/%s/himmel/specs/research/stability-scorecard.tsv' "$root" "${USER_SLUG:-${USER:-unknown}}"
}

# main_keys <primary>: HIMMEL keys in the squash subjects (`(#N)` suffix) of main over the last 30 days;
# fails (cells read unknown) when origin/main cannot be refreshed, so a stale ref never undercounts.
main_keys() {
    local subjects
    git -C "$1" fetch -q origin main 2>/dev/null || return 1
    subjects="$(git -C "$1" log origin/main --since='30 days ago' --format=%s 2>/dev/null)" || return 1
    printf '%s\n' "$subjects" | grep -E '\(#[0-9]+\)$' | grep -oE 'HIMMEL-[0-9]+' | sort -u || true
}

# src <seam-var> <default command...>: run the seam command if set, else the default.
src() { local v="$1"; shift; if [ -n "${!v:-}" ]; then bash -c "${!v} \"\$@\"" _ "$@"; else "$@"; fi; }
# count_rows <seam-var> <cmd...>: rows the command prints; fails (cell reads unknown) when the command fails.
count_rows() {
    local out n
    out="$(src "$@" 2>/dev/null)" || return 1
    n="$(printf '%s\n' "$out" | grep -c . || true)"
    [ "$n" -lt 500 ] || return 1
    printf '%s\n' "$n"
}

cmd_run() {
    local date_arg="" tsv ts since ci q50 q90 share jobs fail pct red den resid esc escrows escnote bycls byp p n got bad=0 jira primary row locked all dn mk shipped admin
    while [ $# -gt 0 ]; do
        case "$1" in
            --date) [ $# -ge 2 ] || { echo "ERR scorecard: --date needs a value" >&2; return 64; }; date_arg="$2"; shift 2 ;;
            *) echo "ERR scorecard: unknown arg: $1" >&2; return 64 ;;
        esac
    done
    [[ -z "$date_arg" || "$date_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERR scorecard: --date must be YYYY-MM-DD" >&2; return 64; }
    tsv="$(tsv_path)" || return 1
    ts="$(date -u +%FT%TZ)"
    date_arg="${date_arg:-${ts%%T*}}"
    if [ -f "$tsv" ]; then
        [ "$(head -n 1 "$tsv")" = "$HEADER" ] || [ "$(head -n 1 "$tsv")" = "$LEGACY_HEADER" ] || { echo "ERR scorecard: $tsv has a foreign header, refusing to append" >&2; return 1; }
        if cut -f1 "$tsv" | grep -qx "$date_arg"; then echo "scorecard: $date_arg already recorded"; return 0; fi
    fi
    since="$(date -u -d '24 hours ago' +%FT%TZ 2>/dev/null || date -u -v-24H +%FT%TZ 2>/dev/null)" \
        || { echo "ERR scorecard: cannot compute the 24h window start" >&2; return 1; }

    ci="$(src SCORECARD_CI_METRICS_CMD bash "$SCRIPT_DIR/ci-metrics.sh" --days 1 --top 1)" || ci=""
    q50="$(printf '%s\n' "$ci" | awk -F'|' '/^\| job queue wait p50/ { split($3, a, "/"); gsub(/ /, "", a[1]); print a[1] }')"
    q90="$(printf '%s\n' "$ci" | awk -F'|' '/^\| job queue wait p50/ { split($3, a, "/"); gsub(/ /, "", a[2]); print a[2] }')"
    share="$(printf '%s\n' "$ci" | awk -F'|' '/^\| cancelled share of runner-min/ { gsub(/[ %]/, "", $3); print $3 }')"
    jobs="$(printf '%s\n' "$ci" | awk -F'|' '/^\| CI \|/ { gsub(/ /, "", $4); print $4; exit }')"
    fail="$(printf '%s\n' "$ci" | awk -F'|' '/^\| CI \|/ { gsub(/ /, "", $6); print $6; exit }')"
    pct=""
    [[ "$jobs" =~ ^[0-9]+$ && "$fail" =~ ^[0-9]+$ && "$jobs" -gt 0 ]] && pct="$(awk -v f="$fail" -v j="$jobs" 'BEGIN { printf "%.2f", f * 100 / j }')"

    red="$(src SCORECARD_RED_MAIN_CMD gh run list --repo "$REPO" --branch main --workflow CI --status failure --created ">=$since" --limit 100 --json databaseId --jq length 2>/dev/null)" || red=""
    [[ "$red" =~ ^[0-9]+$ && "$red" -ge 100 ]] && red=""

    den=""
    if [ -f "${SCORECARD_DENIALS_FILE:-${HOME:-}/.himmel/state/classifier-denials.jsonl}" ]; then
        den="$(jq -r --arg s "$since" 'select(.ts >= $s) | .ts' "${SCORECARD_DENIALS_FILE:-${HOME:-}/.himmel/state/classifier-denials.jsonl}" 2>/dev/null)" \
            && den="$(printf '%s' "$den" | grep -c . || true)" || den=""
    fi

    # The jira CLI finds its .env through git from its cwd; cron starts in $HOME, so run it from the primary checkout.
    primary="$(resolve_primary)" || primary=""
    if [ -z "$primary" ]; then
        echo "ERR scorecard: cannot resolve the primary checkout, the Jira cells read unknown" >&2
        resid=""; esc=""; shipped=""; admin=""
    else
        jira=(node "$primary/scripts/jira/dist/index.js")
        resid="$(cd "$primary" && count_rows SCORECARD_JIRA_CMD env JIRA_PROJECT_KEY=HIMMEL "${jira[@]}" list --jql "project = HIMMEL AND fixVersion = \"$VERSION\" AND created >= -24h" --limit 500)" || resid=""
        escrows="$(cd "$primary" && src SCORECARD_JIRA_CMD env JIRA_PROJECT_KEY=HIMMEL "${jira[@]}" list --jql 'project = HIMMEL AND labels = deferred-escape' --labels --limit 500 2>/dev/null)" \
            && esc="$(printf '%s\n' "$escrows" | grep -c . || true)" && [ "$esc" -lt 500 ] || { esc=""; escrows=""; }
    fi

    # Escapes split per class-<id> label (unclassified when none) and per priority, carried in the note cell.
    escnote=""
    if [[ "$esc" =~ ^[0-9]+$ && "$esc" -gt 0 ]]; then
        bycls="$(printf '%s\n' "$escrows" | awk -F'\t' 'NF { n = split($5, l, ","); c = 0; for (i = 1; i <= n; i++) { gsub(/ /, "", l[i]); if (l[i] ~ /^class-/) { t[l[i]]++; c = 1 } } if (!c) t["unclassified"]++ }
            END { for (k in t) print t[k], k }' | sort -k1,1nr -k2 | awk '{ printf "%s%s=%s", (NR > 1 ? " " : ""), $2, $1 }')"
        byp=""; got=0
        for p in Highest High Medium Low Lowest; do
            n="$(cd "$primary" && count_rows SCORECARD_JIRA_CMD env JIRA_PROJECT_KEY=HIMMEL "${jira[@]}" list --jql "project = HIMMEL AND labels = deferred-escape AND priority = $p" --limit 500)" || { n=unknown; bad=1; got=""; }
            [ "$n" = 0 ] || byp="$byp${byp:+ }$p=$n"
            [ -z "$got" ] || got=$((got + n))
        done
        # An escape with no priority matches none of the five queries.
        [[ -n "$got" && "$esc" -gt "$got" ]] && byp="$byp${byp:+ }unprioritized=$((esc - got))"
        escnote="; escapes by class: $bycls; by priority: $byp"
    fi

    if [ -n "$primary" ]; then
        all="$(cd "$primary" && count_rows SCORECARD_JIRA_CMD env JIRA_PROJECT_KEY=HIMMEL "${jira[@]}" list --jql 'project = HIMMEL AND resolved >= -24h' --limit 500)" || all=""
        shipped=""; admin=""
        if dn="$(cd "$primary" && src SCORECARD_JIRA_CMD env JIRA_PROJECT_KEY=HIMMEL "${jira[@]}" list --jql 'project = HIMMEL AND resolution = Done AND type != Epic AND resolved >= -24h' --limit 500 2>/dev/null)" \
            && [ "$(printf '%s\n' "$dn" | grep -c .)" -lt 500 ] && mk="$(src SCORECARD_MAIN_KEYS_CMD main_keys "$primary" 2>/dev/null)"; then
            shipped="$(comm -12 <(printf '%s\n' "$dn" | grep -oE '^HIMMEL-[0-9]+' | sort -u) <(printf '%s\n' "$mk" | sort -u) | grep -c . || true)"
            [[ "$all" =~ ^[0-9]+$ && "$shipped" =~ ^[0-9]+$ && "$all" -ge "$shipped" ]] && admin=$((all - shipped))
        fi
    fi

    for v in q50 q90 share pct red den resid esc shipped admin; do
        [[ "${!v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf -v "$v" unknown; bad=1; }
    done
    row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tn/a\t%s\t%s\t%s\t%s\t%s\tdaily, 24h window ending %s%s' \
        "$date_arg" "$ts" "$q50" "$q90" "$pct" "$red" "$den" "$resid" "$esc" "$share" "$shipped" "$admin" "$ts" "$escnote")"
    mkdir -p "$(dirname "$tsv")" || return 1
    # ponytail: mkdir lock, 30s wait; a kill -9 mid-append leaves tsv.lock to remove by hand, upgrade to flock if it recurs
    locked=0
    for _ in $(seq 1 30); do mkdir "$tsv.lock" 2>/dev/null && { locked=1; break; }; sleep 1; done
    [ "$locked" -eq 1 ] || { echo "ERR scorecard: cannot take $tsv.lock" >&2; return 1; }
    if [ -f "$tsv" ] && cut -f1 "$tsv" | grep -qx "$date_arg"; then
        rmdir "$tsv.lock"; echo "scorecard: $date_arg already recorded"; return 0
    fi
    if [ -f "$tsv" ] && [ "$(head -n 1 "$tsv")" = "$LEGACY_HEADER" ]; then
        if ! { awk -F'\t' -v h="$HEADER" 'NR == 1 { print h; next } { for (i = 1; i <= 11; i++) printf "%s\t", $i; printf "n/a\tn/a\t%s\n", $12 }' "$tsv" >"$tsv.mig" \
            && mv -f "$tsv.mig" "$tsv"; }; then
            rm -f "$tsv.mig"; rmdir "$tsv.lock"; echo "ERR scorecard: cannot migrate $tsv to the shipped columns" >&2; return 1
        fi
    fi
    if ! { [ -f "$tsv" ] || printf '%s\n' "$HEADER" >"$tsv"; } || ! printf '%s\n' "$row" >>"$tsv"; then
        rmdir "$tsv.lock"; return 1
    fi
    rmdir "$tsv.lock"
    echo "scorecard: wrote $date_arg to $tsv"
    [ "$bad" -eq 0 ] || { echo "ERR scorecard: a source failed, its cell reads unknown" >&2; return 1; }
}

cron_read() {
    local err
    CRON_TAB=""
    command -v "${CRONTAB_BIN%% *}" >/dev/null 2>&1 || return 0
    if CRON_TAB="$(LC_ALL=C $CRONTAB_BIN -l 2>&1)"; then return 0; fi
    err="$CRON_TAB"; CRON_TAB=""
    case "$err" in
        *"no crontab"*) return 0 ;;
        *) echo "ERR scorecard: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local hour=6 minute=20 force=0 dry=0 root runner entry slug
    while [ $# -gt 0 ]; do
        case "$1" in
            --hour|--minute)
                [ $# -ge 2 ] || { echo "ERR scorecard: $1 needs a value" >&2; return 1; }
                case "$1" in --hour) hour="$2" ;; --minute) minute="$2" ;; esac
                shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR scorecard: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || { echo "ERR scorecard: --hour must be 0-23, got: $hour" >&2; return 1; }
    [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]] || { echo "ERR scorecard: --minute must be 0-59, got: $minute" >&2; return 1; }
    slug="${USER_SLUG:-}"
    if [ -z "${HANDOVER_DIR:-}" ] || [ -z "$slug" ]; then
        echo "ERR scorecard: arm needs HANDOVER_DIR and USER_SLUG (the cron would write its row to the wrong TSV)" >&2
        return 1
    fi
    root="$(resolve_primary)" || { echo "ERR scorecard: cannot resolve the primary checkout" >&2; return 2; }
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR scorecard: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/stability-scorecard.sh"
    entry="$minute $hour * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY scorecard: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# stability-scorecard runner — generated by stability-scorecard.sh arm (HIMMEL-6131)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'HANDOVER_DIR=%q\nexport HANDOVER_DIR\n' "$HANDOVER_DIR"
        printf 'USER_SLUG=%q\nexport USER_SLUG\n' "$slug"
        printf 'log=%q\n' "$RUNNER_DIR/stability-scorecard.log"
        printf '[ -f "$log" ] && [ "$(wc -c < "$log")" -gt 1000000 ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run >> "$log" 2>&1\n' "$(command -v bash)" "$root/scripts/eval/stability-scorecard.sh"
    } >"$runner" || { echo "ERR scorecard: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || return 4
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; }; printf '%s\n' "$entry"; } | $CRONTAB_BIN - \
        || { echo "ERR scorecard: crontab install failed" >&2; return 4; }
    echo "stability-scorecard ARMED: $hour:$minute daily — $runner (status: bash scripts/eval/stability-scorecard.sh status)"
}

cmd_status() {
    cron_read || return 1
    if [ -n "$(cron_entry)" ]; then echo "ARMED      $TASK_NAME ($(cron_entry | awk '{print $1, $2, $3, $4, $5}'))"
    else echo "not armed  $TASK_NAME"; fi
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "stability-scorecard: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY scorecard: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | $CRONTAB_BIN - || return 4
    rm -f "$RUNNER_DIR/stability-scorecard.sh"
    echo "stability-scorecard: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run "$@" ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: stability-scorecard.sh <run|arm|status|disarm>" >&2; exit 64 ;;
esac
