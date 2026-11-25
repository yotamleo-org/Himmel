#!/usr/bin/env bash
# scripts/handover/chief-kit/station-sync.sh - bring the station back to main
# after a merge. Maps the merged diff's paths to himmel-update.sh --only steps,
# runs them, then --versions; any component still behind is reported, and a
# station-local edit against the shipped version is reported, never discarded.
#
# Usage: station-sync.sh --pr <n> | --files <file | -> | --heal --bucket <dir> --chief <name>
#   --pr <n>      the merged PR; its changed paths come from `gh pr view`.
#   --files <f>   one changed path per line (the test seam, also usable by hand).
#   --heal        no PR: retry a station whose state file reads BEHIND:<components> (see Heal below).
#
# Path -> step:
#   marketplace/                    marketplace
#   scripts/jira/                   jira_cli
#   scripts/config-ui/              config_ui     (rebuild the UI bundle, restart himmel-ui.service if active;
#                                   the merge path pulls the primary first, so a full update sees no range;
#                                   also added whenever ~/.himmel/state/config-ui-rebuild-pending exists, and
#                                   while it exists the state reads BEHIND:config_ui-failed, never ok)
#   scripts/lib/qmd-bin.sh          qmd_fork      (the fork pin)
#   scripts/lib/graphify-bin.sh     graphify      (the graphify pin)
#   templates/luna-second-brain/    luna_template (only after the local-edit check)
#   scripts/telegram/ lanes/ lib/   bridge_restart (systemctl --user restart telegram-bridge.service,
#                                   at most once per 10 min, stamp ~/.himmel/state/bridge-restart.ts;
#                                   prints `SKIP bridge_restart <reason>` when it does not run)
#
# Not mapped: the hermes step and plugin pins outside marketplace/ have no single
# path that identifies them, so a merge touching only those is caught by the
# --versions check below (a behind row), not by a step run here.
#
# luna_template check: `upgrade.sh --dry-run` names each file it would withhold for
# a local edit and prints the hunk. A hunk with any non-comment changed line, or a
# withheld edit with no hunk to read (snapshot baseline), refuses the apply and
# prints `LOCAL-DIFF luna_template <file>: <line>` so it is upstreamed or dropped.
# A tracked edit in the qmd fork clone prints `LOCAL-DIFF qmd_fork <file>`.
#
# Heal (--heal): worker-event.sh starts it, detached, on an event wake while the state reads BEHIND:<components>.
# It reads the state file and runs the step each behind component maps to, then re-checks with --versions and
# rewrites the state file as a sync does (no usage build):
#   plugins -> marketplace, jira_cli -> jira_cli, hermes -> hermes, qmd_fork -> qmd_fork
# Any other behind component (himmel, luna_template, codex, claude, cli_proxy, node, npm, bun, a probe tool,
# unverified, a *-failed marker) has no step here and stays reported, never healed. The hermes step keeps its own
# 3-day age rule: inside the window it is reported, not forced.
# It takes the sync's lock without waiting (`SKIP heal sync-running` when a sync holds it) and keeps a back-off stamp
# ~/.himmel/state/station-heal.ts (SS_HEAL_WINDOW seconds, default 1800; SS_HEAL_NOW replaces the clock): a heal that
# ran inside the window prints `SKIP heal backoff` and runs nothing, so a broken step never loops. A failed step
# writes ONE owed row (owe.sh add, kind step, in --bucket for --chief), its identity the component list and the day,
# so a replay returns the same row. Other skips: `SKIP heal not-behind` (ok, or no state), `SKIP heal nothing-healable`.
#
# Output: `STEP <step> rc=<n>` per step, any LOCAL-DIFF lines, then
# `STATION=OK` or `STATION=BEHIND:<component>,...`, then a `STEP usage_compute rc=<n>` or
# `SKIP usage_compute <reason>` line. The same station value (`ok` or
# `BEHIND:...`) is written to the state file tick.sh reads as station=; it
# clears on the next sync. Runs are serialized on a flock next to the state file. While a run is in flight the state reads
# `BEHIND:pending`, so a run that is killed never leaves a stale `ok`. Exit 0 whatever the station state; 2 on usage.
#
# Test seams (env): SS_UPDATE SS_UPGRADE SS_GH SS_PRIMARY SS_VAULT SS_QMD_CLONE SS_STATE SS_SYSTEMCTL
# SS_USAGE_COMPUTE SS_TIMEOUT SS_HEAL_NOW SS_HEAL_WINDOW.
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GH_READ_BIN="$HERE/../../lib/gh-read.sh"
[ -f "$GH_READ_BIN" ] || GH_READ_BIN=gh
# shellcheck source=scripts/lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
usage() { echo "usage: station-sync.sh --pr <n> | --files <file | -> | --heal --bucket <dir> --chief <name>" >&2; exit 2; }

PR=""; FILES=""; HEAL=""; BUCKET=""; CHIEF=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --heal) HEAL=1; shift ;;
        --pr|--files|--bucket|--chief) [ "$#" -ge 2 ] || usage
            case "$1" in --pr) PR="$2" ;; --files) FILES="$2" ;; --bucket) BUCKET="$2" ;; --chief) CHIEF="$2" ;; esac
            shift 2 ;;
        *) usage ;;
    esac
done
if [ -n "$HEAL" ]; then
    { [ -z "$PR" ] && [ -z "$FILES" ] && [ -n "$BUCKET" ] && [ -n "$CHIEF" ]; } || usage
else
    { [ -z "$BUCKET" ] && [ -z "$CHIEF" ]; } || usage
    { [ -n "$PR" ] && [ -z "$FILES" ]; } || { [ -z "$PR" ] && [ -n "$FILES" ]; } || usage
fi

PRIMARY="${SS_PRIMARY:-}"
if [ -z "$PRIMARY" ]; then
    common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    [ -n "$common" ] && PRIMARY="$(dirname "$common")"
fi
[ -n "$PRIMARY" ] || { echo "station-sync: cannot resolve the primary checkout" >&2; exit 2; }
if [ -n "${SS_UPDATE:-}" ]; then UPDATE=("$SS_UPDATE"); else UPDATE=(bash "$PRIMARY/scripts/himmel-update.sh"); fi
STATE="${SS_STATE:-$HOME/.himmel/state/station-sync.state}"
TEMPLATE="$PRIMARY/templates/luna-second-brain"
if [ -n "${SS_UPGRADE:-}" ]; then UPGRADE=("$SS_UPGRADE"); else UPGRADE=(bash "$TEMPLATE/scripts/upgrade.sh"); fi

# One sync at a time: two merges close together queue here, so the update steps never
# run twice at once and an earlier run's verdict never lands over a later run's pending.
mkdir -p "$(dirname "$STATE")" 2>/dev/null
# prim-ok: a blocking lock held on fd 9 until the script exits; with_lock wraps one command
exec 9>"$STATE.lock"
# prim-ok: a heal only tries the lock; a sync in flight owns the state, so the heal skips
if [ -z "$HEAL" ]; then flock 9; elif ! flock -n 9; then echo "SKIP heal sync-running"; exit 0; fi
heal_want=""
if [ -n "$HEAL" ]; then
    cur="$(cat "$STATE" 2>/dev/null)"  # swallow-ok: no state file reads as not behind, the case below skips
    case "$cur" in BEHIND:*) ;; *) echo "SKIP heal not-behind"; exit 0 ;; esac
    for comp in $(printf '%s' "${cur#BEHIND:}" | tr , ' '); do
        case "$comp" in
            plugins) step=marketplace ;;
            jira_cli|hermes|qmd_fork) step="$comp" ;;
            *) continue ;;
        esac
        case " $heal_want " in *" $step "*) ;; *) heal_want="$heal_want $step" ;; esac
    done
    [ -n "$heal_want" ] || { echo "SKIP heal nothing-healable ${cur#BEHIND:}"; exit 0; }
    HEAL_STAMP="$(dirname "$STATE")/station-heal.ts"
    heal_now="${SS_HEAL_NOW:-$(date +%s)}"
    last="$(cat "$HEAL_STAMP" 2>/dev/null)"  # swallow-ok: no stamp yet means never healed; the case below reads empty as 0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((heal_now - last)) -lt "${SS_HEAL_WINDOW:-1800}" ]; then echo "SKIP heal backoff"; exit 0; fi
    echo "$heal_now" > "$HEAL_STAMP" 2>/dev/null
    echo "HEAL$heal_want"
fi
# Pending until the run ends: a sync killed mid-way must not leave the previous `ok`.
echo "BEHIND:pending" > "$STATE" 2>/dev/null

if [ -n "$HEAL" ]; then paths=""
elif [ -n "$PR" ]; then
    GH="${SS_GH:-$GH_READ_BIN}"
    paths="$(cd "$PRIMARY" && "$GH" pr view "$PR" --json files -q '.files[].path' 2>/dev/null)" \
        || { mkdir -p "$(dirname "$STATE")" 2>/dev/null && echo "BEHIND:unverified" > "$STATE" 2>/dev/null
             echo "STATION=failed:gh-pr-view"; exit 0; }
elif [ "$FILES" = "-" ]; then paths="$(cat)"
else paths="$(cat "$FILES")" || usage
fi

want=""; bridge=""
add() { case " $want " in *" $1 "*) ;; *) want="$want $1" ;; esac; }
# A rebuild that failed earlier (or never ran: bun missing) leaves this marker; this merge may touch no UI path, but the retry is owed.
CUI_PENDING="$HOME/.himmel/state/config-ui-rebuild-pending"
[ ! -f "$CUI_PENDING" ] || add config_ui
for step in $heal_want; do add "$step"; done
while IFS= read -r p; do
    case "$p" in
        marketplace/*) add marketplace ;;
        scripts/jira/*) add jira_cli ;;
        scripts/config-ui/*) add config_ui ;;
        scripts/lib/qmd-bin.sh) add qmd_fork ;;
        scripts/lib/graphify-bin.sh) add graphify ;;
        templates/luna-second-brain/*) add luna_template ;;
    esac
    case "$p" in
        scripts/telegram/*|scripts/lanes/*|scripts/lib/*) bridge=1 ;;
    esac
done <<EOF
$paths
EOF

# local_template_diff: print `<file>: <line>` for each withheld local edit that is
# more than comment-only changes; nothing when every withheld hunk is a comment.
local_template_diff() {
    local vault="${SS_VAULT:-${LUNA_VAULT_PATH:-}}"
    if [ -z "$vault" ] && [ -f "$PRIMARY/.env" ]; then
        vault="$(sed -n 's/^LUNA_VAULT_PATH=//p' "$PRIMARY/.env" | head -n 1 | tr -d "\"'")"
    fi
    [ -d "$vault" ] || { echo "(vault unresolved) the local-edit check did not run"; return 0; }
    local plan prc
    plan="$("${UPGRADE[@]}" --template-dir "$TEMPLATE" --vault-dir "$vault" --dry-run 2>&1)"; prc=$?
    if [ "$prc" -ne 0 ]; then echo "(upgrade.sh --dry-run) rc=$prc: the local-edit check did not run"; return 0; fi
    printf '%s\n' "$plan" | awk '
        /^  local edits withheld \(not overwritten\): / {
            if (rel != "" && !bad && !seen) print rel ": no hunk to read (snapshot baseline)"
            rel = $0; sub(/^  local edits withheld \(not overwritten\): /, "", rel); sub(/ \(backup:.*$/, "", rel)
            bad = 0; seen = 0; next
        }
        /^  could not verify local edits for / {
            if (rel != "" && !bad && !seen) print rel ": no hunk to read (snapshot baseline)"
            rel = $0; sub(/^  could not verify local edits for /, "", rel); sub(/ \(git show.*$/, "", rel)
            bad = 0; seen = 0; next
        }
        rel != "" && /^    [-+]/ && !/^    (\+\+\+|---)/ {
            seen = 1
            line = substr($0, 6); t = line; sub(/^[ \t]+/, "", t)
            if (!bad && t != "" && t !~ /^(#|\/\/|<!--|%%)/) { print rel ": " line; bad = 1 }
            next
        }
        END { if (rel != "" && !bad && !seen) print rel ": no hunk to read (snapshot baseline)" }
    '
}

refused=""; failed=""
for step in marketplace jira_cli config_ui qmd_fork hermes graphify luna_template; do
    case " $want " in *" $step "*) ;; *) continue ;; esac
    if [ "$step" = luna_template ]; then
        diffs="$(local_template_diff)"
        if [ -n "$diffs" ]; then
            while IFS= read -r d; do echo "LOCAL-DIFF luna_template $d"; done <<EOF
$diffs
EOF
            refused="luna_template"
            continue
        fi
    fi
    step_out="$("${UPDATE[@]}" --only "$step" 2>&1)"; rc=$?
    echo "STEP $step rc=$rc"
    if [ "$rc" -ne 0 ]; then
        failed="${failed:+$failed,}$step-failed"
        # The step's own words, indented (stdout is the sync's report). --only prints its status table AFTER the build
        # log, so the last lines are table rows: take the last 5 lines before the table, then the table's failed rows.
        { printf '%s\n' "$step_out" | sed '/update chain status/,$d' | tail -n 5
          printf '%s\n' "$step_out" | grep -E '^ +[a-z_]+ +failed '; } | sed "s/^/    $step: /"
    fi
done

# The bridge imports scripts/telegram, scripts/lanes and scripts/lib, so a merge there leaves
# the running poller on old code (doctor C77). Restart it once, at most every 10 minutes; the
# stamp is epoch seconds, written only by a successful restart, read by doctor C77.
BRIDGE_UNIT="telegram-bridge.service"
BRIDGE_STAMP="$(dirname "$STATE")/bridge-restart.ts"
SC="${SS_SYSTEMCTL:-systemctl}"
if [ -z "$bridge" ]; then echo "SKIP bridge_restart no-bridge-path"
elif ! command -v "$SC" >/dev/null 2>&1; then echo "SKIP bridge_restart no-systemctl"
elif ! "$SC" --user is-enabled "$BRIDGE_UNIT" >/dev/null 2>&1; then echo "SKIP bridge_restart unit-not-enabled"
else
    now="$(date +%s)"
    last="$(cat "$BRIDGE_STAMP" 2>/dev/null)"  # swallow-ok: no stamp yet means never restarted; the case below reads empty as 0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt 600 ]; then echo "SKIP bridge_restart debounce"
    else
        "$SC" --user restart "$BRIDGE_UNIT" >/dev/null 2>&1; rc=$?
        echo "STEP bridge_restart rc=$rc"
        if [ "$rc" -eq 0 ]; then echo "$now" > "$BRIDGE_STAMP" 2>/dev/null
        else failed="${failed:+$failed,}bridge_restart-failed"; fi
    fi
fi

clone="${SS_QMD_CLONE:-$HOME/.himmel/qmd-fork}"
if [ -e "$clone/.git" ]; then
    git -C "$clone" status --porcelain --untracked-files=no 2>/dev/null | while IFS= read -r l; do
        echo "LOCAL-DIFF qmd_fork ${l#???}"
    done
fi

vers="$("${UPDATE[@]}" --versions 2>/dev/null)"; vrc=$?
behind="$(printf '%s\n' "$vers" | awk '$2 == "behind" { print $1 }' | paste -sd, -)"
# --versions exits 0 all current, 1 any behind; 3 (some undetermined), any other code, or
# a report with no component row is not proof the station is current.
if [ "$vrc" -gt 1 ] || ! printf '%s\n' "$vers" | grep -qE '^ +[a-z_-]+ +(current|behind|unknown|info) '; then
    behind="${behind:+$behind,}unverified"
fi
# the marker outlives a step that ran (or never could): the UI is still behind, so the state must not read ok
if [ -f "$CUI_PENDING" ]; then case ",$failed," in *",config_ui-failed,"*) ;; *) failed="${failed:+$failed,}config_ui-failed" ;; esac; fi
[ -z "$failed" ] || behind="${behind:+$behind,}$failed"
[ -z "$refused" ] || case ",$behind," in *",$refused,"*) ;; *) behind="${behind:+$behind,}$refused" ;; esac

if [ -n "$HEAL" ] && [ -n "$failed" ]; then
    oid="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "station-heal:$((heal_now / 86400)):$failed")"
    if owed="$(bash "$HERE/owe.sh" add --bucket "$BUCKET" --chief "$CHIEF" --kind step --identity "$oid" \
        --text "station heal: himmel-update --only failed for $failed and the station reads BEHIND:$behind; run bash scripts/himmel-update.sh --only <step> by hand" 2>&1)"; then
        echo "OWED station-heal $owed"
    else echo "OWED-FAILED station-heal $owed"; fi
fi

if [ -n "$behind" ]; then val="BEHIND:$behind"; echo "STATION=BEHIND:$behind"
else val="ok"; echo "STATION=OK"
fi
mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s\n' "$val" > "$STATE" 2>/dev/null
[ -z "$HEAL" ] || exit 0

release_sync_lock() { exec 9>&-; }
USAGE_TERM_TIMEOUT_SECONDS=180
USAGE_BUDGET_SECONDS=120
release_sync_lock
USAGE_STORE="${HIMMEL_USAGE_STORE:-$HOME/.himmel/state/usage}"
if [ -n "${SS_USAGE_COMPUTE:-}" ]; then USAGE=("$SS_USAGE_COMPUTE"); else USAGE=(bash "$PRIMARY/scripts/usage/usage-compute.sh"); fi
TO="${SS_TIMEOUT:-timeout}"
if ! command -v "$TO" >/dev/null 2>&1; then echo "SKIP usage_compute no-timeout"
elif [ -d "$USAGE_STORE/.lock" ]; then echo "SKIP usage_compute store-locked"
else
    (cd "$PRIMARY" && "$TO" "$USAGE_TERM_TIMEOUT_SECONDS" "${USAGE[@]}" --budget-seconds "$USAGE_BUDGET_SECONDS" >/dev/null 2>&1); rc=$?
    echo "STEP usage_compute rc=$rc"
fi
exit 0
