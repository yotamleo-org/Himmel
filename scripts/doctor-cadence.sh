#!/usr/bin/env bash
# doctor-cadence.sh — run himmel-doctor daily and tell the operator when it
# finds something new.
#
# WHY: himmel-doctor flagged the missing pre-commit/commit-msg hooks (C16) for
# nine days and nobody saw it, because nothing ran the doctor on a
# schedule. This is the visibility half; repair is `himmel-update`'s drift pass.
# Nothing here fixes anything.
#
#   doctor-cadence.sh run                  one pass (what cron fires)
#   doctor-cadence.sh arm [--time HH:MM] [--force] [--dry-run]
#   doctor-cadence.sh status
#   doctor-cadence.sh disarm [--dry-run]
#
# `run` executes scripts/himmel-doctor.sh from the PRIMARY checkout (resolved
# via git-common-dir: a worktree run gives false C16 reds), then keeps the
# result under ~/.himmel/state/doctor-cadence/:
#   last.tsv     "<SEV> <id>" per FAIL/WARN of the latest run (any full
#                primary doctor run writes it, with counts, via doctor_state_publish)
#   alerted.tsv  the findings this script last alerted on (what its next
#                run diffs against; an ad-hoc doctor run never moves it)
#   counts       "fail=<n> warn=<n>" — read by the statusline segment
# An alert goes out (through scripts/luna/cadence-alert.sh, the existing
# Telegram path) when a FAIL or a WARN is absent from the previous run. The
# first-ever run is a baseline: only FAILs alert, so arming does not DM the
# operator every standing WARN. A doctor that prints no Summary line (crashed)
# alerts and leaves the state alone.
#
# The diff baseline advances only after the sender reports a delivered alert; a
# failed send leaves it, so the next run alerts on the same findings again.
#
# ponytail: "delivered" means the sender handed the message on: the bridge's
# outbox send is asynchronous and does not report a later Telegram refusal,
# upgrade path: have the poller's outbox flush keep an entry its send refused.
#
# Seams (tests): HIMMEL_DOCTOR_STATE_DIR, DOCTORCAD_CRONTAB, DOCTORCAD_RUNNER_DIR.
# Platform: cron (Linux/macOS). Windows development is parked.
set -uo pipefail

TASK_NAME="HIMMEL-Doctor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HIMMEL_DOCTOR_STATE_DIR:-${HOME:-}/.himmel/state/doctor-cadence}"
# shellcheck source=doctor-counts.sh
. "$SCRIPT_DIR/doctor-counts.sh"
CRONTAB_BIN="${DOCTORCAD_CRONTAB:-crontab}"
RUNNER_DIR="${DOCTORCAD_RUNNER_DIR:-${HOME:-}/.claude/doctor-cadence}"

resolve_primary() {
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common" ] || return 1
    (cd "$(dirname "$common")" 2>/dev/null && pwd)
}

# A WARN present in two consecutive runs files ONE Jira ticket:
# an open ticket carrying the check id is commented on instead of re-filed, and
# ticketed.tsv remembers the ids already handled so a standing WARN does not
# comment every day. A Jira failure leaves the id unrecorded (retried next run).
file_persisting_warns() { # <root> <keys> <log>; STATE_DIR/alerted.tsv = previous run
    local root="$1" keys="$2" log="$3" k id found desc proj="${JIRA_PROJECT_KEY:-HIMMEL}" tf="$STATE_DIR/ticketed.tsv"
    local mirror="${DOCTORCAD_MIRROR_DIR:-${HOME:-}/.himmel/state/jira-mirror/$proj}" f candidate query
    local -a J
    if [ -n "${DOCTORCAD_JIRA_CMD:-}" ]; then read -ra J <<< "$DOCTORCAD_JIRA_CMD"
    elif [ -f "$root/scripts/jira/dist/index.js" ]; then J=(node "$root/scripts/jira/dist/index.js")
    else return 0; fi
    touch "$tf"
    # forget ids whose WARN is gone, so one that returns is looked up again
    printf '%s\n' "$keys" | sed -n 's/^WARN //p' | grep -xFf - "$tf" > "$tf.new" || true
    mv -f "$tf.new" "$tf"
    while IFS= read -r k; do
        case "$k" in WARN\ *) ;; *) continue ;; esac
        grep -qxF "$k" "$STATE_DIR/alerted.tsv" || continue
        id="${k#WARN }"
        grep -qxF "$id" "$tf" && continue
        # Search the local mirror first, then verify candidates live: the mirror
        # may lag a ticket closure. Do not require our label on existing work.
        query="project = $proj AND statusCategory != Done AND text ~ \"\\\"$id\\\"\""
        for f in "$mirror"/"$proj"-*.md; do
            [ -f "$f" ] || continue
            grep -wF "$id" "$f" >/dev/null || continue
            grep -q '^statusCategory: "Done"$' "$f" && continue
            candidate="${f##*/}"; candidate="${candidate%.md}"
            [[ "$candidate" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || continue
            query="project = $proj AND statusCategory != Done AND (key = $candidate OR text ~ \"\\\"$id\\\"\")"
            break
        done
        found="$(JIRA_PROJECT_KEY="$proj" "${J[@]}" list --jql "$query" 2>/dev/null)" || continue
        found="$(printf '%s\n' "$found" | grep -oE -m1 '^[A-Z][A-Z0-9]*-[0-9]+')" || found=""
        desc="## Impact
The station has a persistent tool-health warning ($id).

## What
Resolve the warning or correct the doctor check if it is inaccurate.

## Why
The warning was present in two consecutive daily runs; leaving it unresolved teaches operators to ignore tool health.

## Plan
1. Check scripts/himmel-doctor.sh ($id), then fix the cause or correct the check.

## DoD
- Running scripts/himmel-doctor.sh no longer prints WARN $id, or the check reports it with an accurate paste-ready remedy.

## Agent detail
Regression suite: scripts/test-himmel-doctor.sh.
$(grep -A1 -E "^WARN +$id:" "$log" | head -2)"
        if [ -n "$found" ]; then
            JIRA_PROJECT_KEY="$proj" "${J[@]}" comment "$found" "$desc" >/dev/null 2>&1 || continue
        else
            JIRA_PROJECT_KEY="$proj" "${J[@]}" create --type Task --title "[doctor] $id persists" --desc "$desc" --labels doctor,standalone --sector Visibility --backlog >/dev/null 2>&1 || continue
        fi
        printf '%s\n' "$id" >> "$tf"
    done <<< "$keys"
}

# cmd_run is a plain pass; cmd_arm/cmd_status/cmd_disarm are the contract
# test-wizard-cadence-registry.sh lints every registry row for.
cmd_run() (
    local root out keys new="" k sev lock_rc id detail="" item new_n=0 shown=0 knock_on=0 todo="" cause="" graph_alerts="" delivered=1
    local sent_dir="${CADENCE_ALERT_DEDUPE_DIR:-${HOME:-}/.himmel/state/cadence-alert-sent}"
    root="$(resolve_primary)" || { echo "doctor-cadence: cannot resolve the primary checkout" >&2; return 2; }
    mkdir -p "$STATE_DIR" || return 2
    # Hold through doctor, alerts and Jira filing. Keep the lock file's inode:
    # the kernel releases the descriptor lock even after SIGKILL or a reboot.
    exec 9>"$STATE_DIR/.run-lock" || return 2
    if command -v flock >/dev/null 2>&1; then
        # prim-ok: a non-blocking try-lock held on fd 9 for the rest of cmd_run; with_lock blocks and wraps one command
        flock -n 9; lock_rc=$?
    else
        # macOS lacks the flock utility; Perl uses the same process-scoped lock
        # on the inherited descriptor, which this shell keeps open until exit.
        perl -MFcntl=LOCK_EX,LOCK_NB -e '
            open(my $lock, ">&=9") or exit 2;
            flock($lock, LOCK_EX | LOCK_NB) or exit(($!{EWOULDBLOCK} || $!{EAGAIN}) ? 1 : 2);
        '; lock_rc=$?
    fi
    [ "$lock_rc" -eq 1 ] && return 0
    [ "$lock_rc" -eq 0 ] || { echo "doctor-cadence: cannot acquire the run lock" >&2; return 2; }
    out="$STATE_DIR/last-run.log"
    (cd "$root" && bash "$root/scripts/himmel-doctor.sh" --no-color </dev/null) > "$out" 2>&1
    if ! grep -q '^Summary: ' "$out"; then
        bash "$root/scripts/luna/cadence-alert.sh" fail himmel-doctor "the doctor crashed before printing its Summary line" "$out" \
            "himmel-doctor.sh stopped part-way, so no finding could be read" "run bash scripts/himmel-doctor.sh by hand and read where it stops"
        return 1
    fi
    keys="$(sed -n -E 's/^(FAIL|WARN) +([A-Za-z0-9_-]+):.*/\1 \2/p' "$out" | sort -u)"
    local first=0 kf
    # alerted.tsv is THIS script's alert baseline; an ad-hoc doctor run never
    # touches it, so a finding it first saw still alerts here.
    [ -f "$STATE_DIR/alerted.tsv" ] || first=1
    kf="$(mktemp "$STATE_DIR/.keys.XXXXXX")" || return 2
    printf '%s\n' "$keys" | sed '/^$/d' > "$kf"
    doctor_state_publish "$STATE_DIR" "$kf" \
        "$(grep -c '^FAIL ' "$kf")" "$(grep -c '^WARN ' "$kf")" || true
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        [ "$first" -eq 0 ] && grep -qxF "$k" "$STATE_DIR/alerted.tsv" && continue
        sev="${k%% *}"
        [ "$first" -eq 1 ] && [ "$sev" != FAIL ] && continue
        new="${new:+$new, }$k"
        new_n=$((new_n + 1))
        id="${k#* }"
        # Telegram refuses a message over 4096 characters: each finding is cut to 120,
        # the list stops at 2400, and the rest is counted in a "+N more" tail.
        item="$k: $(sed -n -E "s/^$sev +$id: *//p" "$out" | head -n 1 | cut -c1-120)"
        if [ $((${#detail} + ${#item} + 2)) -le 2400 ]; then
            detail="${detail:+$detail; }$item"
            shown=$((shown + 1))
        fi
        [ -n "$todo" ] || todo="$(grep -A1 -E "^$sev +$id:" "$out" | sed -n -E '2s/^ *→ *//p' | sed -E 's/ +#.*//' | cut -c1-300)"
        # a standing graph-*-backoff alert is a skipped file on a run that succeeded, so it does not explain a stale graph
        if [ "$id" = C33-graph-stale ]; then
            graph_alerts=$(compgen -G "$sent_dir/graph-*" | grep -v -- '-backoff[.]')
            [ -z "$graph_alerts" ] || knock_on=1
        fi
    done <<< "$keys"
    if [ -n "$new" ]; then
        [ "$knock_on" -eq 1 ] && cause="C33-graph-stale follows from the failing graph cadence and clears when that runs clean"
        # clear first: the sender's per-reason dedupe must not mute a key that
        # went away and came back; THIS script's prev-diff is the dedupe.
        bash "$root/scripts/luna/cadence-alert.sh" clear himmel-doctor
        [ "$shown" -lt "$new_n" ] && detail="$detail; +$((new_n - shown)) more, see $out"
        CADENCE_ALERT_EXIT_ON_SEND_FAIL=1 bash "$root/scripts/luna/cadence-alert.sh" fail himmel-doctor "$new_n new finding$([ "$new_n" -eq 1 ] || echo s): $detail" "$out" \
            "${cause:-a doctor check reports a problem it did not at the previous run}" \
            "${todo:-run bash scripts/himmel-doctor.sh and read the lines for the ids above}" || delivered=0
    fi
    # alerted.tsv is still the PREVIOUS run here: a WARN in both is persisting.
    [ "$first" -eq 0 ] && file_persisting_warns "$root" "$keys" "$out"
    # advance the baseline only after a delivered alert; a disappeared finding
    # leaves it, so one that comes back alerts again.
    if [ "$delivered" -eq 0 ]; then rm -f "$kf"; return 1; fi
    mv -f "$kf" "$STATE_DIR/alerted.tsv"
    return 0
)

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
        *) echo "ERR doctor-cadence: cannot read the crontab: $err" >&2; return 1 ;;
    esac
}
cron_entry() { printf '%s\n' "$CRON_TAB" | grep -F "# $TASK_NAME" || true; }

cmd_arm() {
    local time="05:30" force=0 dry=0 root runner bash_bin entry
    while [ $# -gt 0 ]; do
        case "$1" in
            --time) [ $# -ge 2 ] || { echo "ERR doctor-cadence: --time needs a value" >&2; return 1; }
                    time="$2"; shift 2 ;;
            --force) force=1; shift ;;
            --dry-run) dry=1; shift ;;
            *) echo "ERR doctor-cadence: unknown arg: $1" >&2; return 1 ;;
        esac
    done
    [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "ERR doctor-cadence: --time must be HH:MM, got: $time" >&2; return 1; }
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) echo "ERR doctor-cadence: cron only; Windows is parked (HIMMEL-4102)" >&2; return 2 ;; esac
    command -v "$CRONTAB_BIN" >/dev/null 2>&1 || { echo "ERR doctor-cadence: '$CRONTAB_BIN' not on PATH" >&2; return 2; }
    root="$(resolve_primary)" || { echo "ERR doctor-cadence: cannot resolve the primary checkout" >&2; return 2; }
    bash_bin="$(command -v bash)"
    cron_read || return 4
    if [ -n "$(cron_entry)" ] && [ "$force" -eq 0 ]; then
        echo "ERR doctor-cadence: already armed: $TASK_NAME (use --force to replace)" >&2
        return 3
    fi
    runner="$RUNNER_DIR/doctor-cadence.sh"
    # cron reads an unescaped % as a newline, even inside quotes.
    entry="${time#*:} ${time%:*} * * * \"${runner//%/\\%}\" # $TASK_NAME"
    if [ "$dry" -eq 1 ]; then
        echo "DRY doctor-cadence: would write $runner and install: $entry"
        return 0
    fi
    mkdir -p "$RUNNER_DIR" || return 4
    # shellcheck disable=SC2016  # the runner's own $log must stay literal
    {
        printf '#!/usr/bin/env bash\n# doctor-cadence runner — generated by doctor-cadence.sh arm (HIMMEL-4251)\n'
        printf 'PATH=%q\nexport PATH\n' "$PATH"
        printf 'log=%q\n' "$RUNNER_DIR/doctor-cadence.log"
        printf '[ -f "$log" ] && mv -f "$log" "$log.prev"\n'
        printf '%q %q run >> "$log" 2>&1\n' "$bash_bin" "$root/scripts/doctor-cadence.sh"
        printf '_rc=$?\necho "[exit rc=$_rc]" >> "$log"\nexit "$_rc"\n'
    } > "$runner" || { echo "ERR doctor-cadence: cannot write the runner $runner" >&2; return 4; }
    chmod +x "$runner" || { echo "ERR doctor-cadence: cannot chmod the runner $runner" >&2; return 4; }
    { printf '%s\n' "$CRON_TAB" | { grep -vF "# $TASK_NAME" || true; } | sed '/^$/d'; printf '%s\n' "$entry"; } | "$CRONTAB_BIN" - \
        || { echo "ERR doctor-cadence: crontab install failed" >&2; return 4; }
    echo "doctor-cadence ARMED: daily $time — $runner (status: bash scripts/doctor-cadence.sh status)"
}

status_log() { # <log>: the run log's last write and last line, in the shape every cadence prints
    local log="$1" mtime last
    if [ -f "$log" ]; then
        mtime=$(date -r "$log" '+%Y-%m-%d %H:%M' 2>/dev/null \
            || stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$log" 2>/dev/null \
            || echo '?')
        last=$(tail -n 1 "$log" 2>/dev/null | tr -d '\r' || true)  # read-sink-ok: $log is the cadence runner's own log path, never argv or env
        echo "  run log    $log (last write: $mtime)"
        [ -z "$last" ] || echo "             last line: $last"
    else
        echo "  run log    $log (absent — task has not fired yet)"
    fi
}

cmd_status() {
    local m stamp="" entry n_entries dup=""
    cron_read || return 1
    entry="$(cron_entry | head -1)"
    if [ -n "$entry" ]; then
        n_entries="$(cron_entry | grep -c . || true)"
        [ "$n_entries" -gt 1 ] && dup=" [DUPLICATE: $n_entries cron entries]"
        echo "ARMED      $TASK_NAME ($(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}'))$dup"
        status_log "$RUNNER_DIR/doctor-cadence.log"
    else echo "not armed  $TASK_NAME"; fi
    if [ -f "$STATE_DIR/counts" ]; then
        m="$(stat -c %Y "$STATE_DIR/counts" 2>/dev/null || stat -f %m "$STATE_DIR/counts" 2>/dev/null || true)"
        case "$m" in
            ''|*[!0-9]*) ;;
            *) stamp="$(date -d "@$m" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$m" '+%Y-%m-%d %H:%M' 2>/dev/null || true)" ;;
        esac
        echo "  last run   $(cat "$STATE_DIR/counts") ($stamp)"
    fi
    return 0
}

cmd_disarm() {
    local dry=0
    [ "${1:-}" = "--dry-run" ] && dry=1
    cron_read || return 4
    if [ -z "$(cron_entry)" ]; then echo "doctor-cadence: nothing armed — disarm is a no-op"; return 0; fi
    if [ "$dry" -eq 1 ]; then echo "DRY doctor-cadence: would remove the $TASK_NAME crontab entry"; return 0; fi
    { printf '%s\n' "$CRON_TAB" | grep -vF "# $TASK_NAME" || true; } | "$CRONTAB_BIN" - || return 4
    rm -f "$RUNNER_DIR/doctor-cadence.sh"
    echo "doctor-cadence: disarmed"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    run) cmd_run ;;
    arm) cmd_arm "$@" ;;
    status) cmd_status ;;
    disarm) cmd_disarm "$@" ;;
    *) echo "Usage: doctor-cadence.sh <run|arm|status|disarm>" >&2; exit 1 ;;
esac
