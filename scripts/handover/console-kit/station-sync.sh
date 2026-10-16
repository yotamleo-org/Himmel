#!/usr/bin/env bash
# scripts/handover/console-kit/station-sync.sh - bring the station back to main
# after a merge. Maps the merged diff's paths to himmel-update.sh --only steps,
# runs them, then --versions; any component still behind is reported, and a
# station-local edit against the shipped version is reported, never discarded.
#
# Usage: station-sync.sh --pr <n> | --files <file | ->
#   --pr <n>      the merged PR; its changed paths come from `gh pr view`.
#   --files <f>   one changed path per line (the test seam, also usable by hand).
#
# Path -> step:
#   marketplace/                    marketplace
#   scripts/jira/                   jira_cli
#   scripts/lib/qmd-bin.sh          qmd_fork      (the fork pin)
#   scripts/lib/graphify-bin.sh     graphify      (the graphify pin)
#   templates/luna-second-brain/    luna_template (only after the local-edit check)
#
# luna_template check: `upgrade.sh --dry-run` names each file it would withhold for
# a local edit and prints the hunk. A hunk with any non-comment changed line, or a
# withheld edit with no hunk to read (snapshot baseline), refuses the apply and
# prints `LOCAL-DIFF luna_template <file>: <line>` so it is upstreamed or dropped.
# A tracked edit in the qmd fork clone prints `LOCAL-DIFF qmd_fork <file>`.
#
# Output: `STEP <step> rc=<n>` per step, any LOCAL-DIFF lines, then
# `STATION=OK` or `STATION=BEHIND:<component>,...`. The same value (`ok` or
# `BEHIND:...`) is written to the state file tick.sh reads as station=; it
# clears on the next sync. Exit 0 whatever the station state; 2 on usage.
#
# Test seams (env): SS_UPDATE SS_UPGRADE SS_GH SS_PRIMARY SS_VAULT SS_QMD_CLONE SS_STATE.
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
usage() { echo "usage: station-sync.sh --pr <n> | --files <file | ->" >&2; exit 2; }

PR=""; FILES=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pr|--files) [ "$#" -ge 2 ] || usage
            case "$1" in --pr) PR="$2" ;; --files) FILES="$2" ;; esac
            shift 2 ;;
        *) usage ;;
    esac
done
{ [ -n "$PR" ] && [ -z "$FILES" ]; } || { [ -z "$PR" ] && [ -n "$FILES" ]; } || usage

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

if [ -n "$PR" ]; then
    GH="${SS_GH:-gh}"
    paths="$(cd "$PRIMARY" && "$GH" pr view "$PR" --json files -q '.files[].path' 2>/dev/null)" \
        || { echo "STATION=failed:gh-pr-view"; exit 0; }
elif [ "$FILES" = "-" ]; then paths="$(cat)"
else paths="$(cat "$FILES")" || usage
fi

want=""
add() { case " $want " in *" $1 "*) ;; *) want="$want $1" ;; esac; }
while IFS= read -r p; do
    case "$p" in
        marketplace/*) add marketplace ;;
        scripts/jira/*) add jira_cli ;;
        scripts/lib/qmd-bin.sh) add qmd_fork ;;
        scripts/lib/graphify-bin.sh) add graphify ;;
        templates/luna-second-brain/*) add luna_template ;;
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
    [ -d "$vault" ] || return 0
    "${UPGRADE[@]}" --template-dir "$TEMPLATE" --vault-dir "$vault" --dry-run 2>&1 | awk '
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

refused=""
for step in marketplace jira_cli qmd_fork graphify luna_template; do
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
    "${UPDATE[@]}" --only "$step" >/dev/null 2>&1; rc=$?
    echo "STEP $step rc=$rc"
done

clone="${SS_QMD_CLONE:-$HOME/.himmel/qmd-fork}"
if [ -d "$clone/.git" ]; then
    git -C "$clone" status --porcelain --untracked-files=no 2>/dev/null | while IFS= read -r l; do
        echo "LOCAL-DIFF qmd_fork ${l#???}"
    done
fi

behind="$("${UPDATE[@]}" --versions 2>/dev/null | awk '$2 == "behind" { print $1 }' | paste -sd, -)"
[ -z "$refused" ] || case ",$behind," in *",$refused,"*) ;; *) behind="${behind:+$behind,}$refused" ;; esac

if [ -n "$behind" ]; then val="BEHIND:$behind"; echo "STATION=BEHIND:$behind"
else val="ok"; echo "STATION=OK"
fi
mkdir -p "$(dirname "$STATE")" 2>/dev/null && printf '%s\n' "$val" > "$STATE" 2>/dev/null
exit 0
