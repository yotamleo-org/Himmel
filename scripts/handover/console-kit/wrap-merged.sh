#!/usr/bin/env bash
# scripts/handover/console-kit/wrap-merged.sh - HIMMEL-5594: a leg's MERGED and
# WRAPPED in one call. Replaces the console's separate turns: check the merge,
# close the window, drop the leg from the fleet, pull the primary, log it,
# re-render the board.
#
# Usage: wrap-merged.sh --doc <console doc> --fleet <manifest> <leg doc> [--pr <n>]
#
# Steps, in order; the first failure stops the run, names the step on stderr and
# exits with the rc shown:
#   1. pr-state   `gh pr view <n>` must be MERGED (rc 3 if not; rc 2 if no PR can
#                 be found). <n> is --pr, else the newest `READY <n>` / `PR <n>`
#                 in the leg doc. The sha recorded is mergeCommit.oid - never
#                 the head a leg's own READY bullet names, which is the PR head.
#   2. close      close-wrapped-leg.sh --fleet <manifest> <leg doc> (its rc is
#                 propagated: 3 lock held, 4 not WRAPPED, 5 session count, 6
#                 subtree alive, 7 subagent alive). Skipped when the leg is no
#                 longer in the manifest - a re-run after a later step failed.
#   3. pull       git -C <primary> pull --ff-only (rc 5).
#   4. log        one console-doc bullet, skipped when `MERGED #<n> → <sha8>`
#                 is already in the doc (rc 6):
#                 MERGED #<n> → <sha8> (<label>, <ticket> <status>). <label> WRAPPED, window closed.
#                 <status> is read with the Jira CLI `get`; this script never
#                 transitions a ticket. An unreadable status is `?`.
#   5. board      board.mjs --doc <console doc> --changed (rc 7); its output is
#                 passed through.
# A re-run therefore finishes whatever an earlier run stopped before, and writes
# nothing twice. Calls the existing console-kit scripts and modifies none.
#
# Test seams (env): WM_GH WM_CLOSE WM_GIT WM_BOARD WM_JIRA WM_PRIMARY.
# Platform guard: Linux bash 3.2+ (fleet-manifest.sh needs flock + jq).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
GH="${WM_GH:-gh}"
CLOSE="${WM_CLOSE:-bash $HERE/close-wrapped-leg.sh}"
GIT="${WM_GIT:-git}"
BOARD="${WM_BOARD:-node $HERE/board.mjs}"

usage() { echo "usage: wrap-merged.sh --doc <console doc> --fleet <manifest> <leg doc> [--pr <n>]" >&2; exit 2; }
fail()  { echo "wrap-merged: step $1 failed: $2" >&2; exit "$3"; }

DOC=""; FLEET=""; LEG=""; PR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc|--fleet|--pr) [ "$#" -ge 2 ] || usage
            case "$1" in --doc) DOC="$2" ;; --fleet) FLEET="$2" ;; --pr) PR="$2" ;; esac
            shift 2 ;;
        -*) usage ;;
        *) [ -z "$LEG" ] || usage; LEG="$1"; shift ;;
    esac
done
[ -n "$DOC" ] && [ -n "$FLEET" ] && [ -n "$LEG" ] || usage
[ -f "$DOC" ] && [ -f "$LEG" ] || { echo "wrap-merged: console doc or leg doc is not a file" >&2; exit 2; }

if [ -z "$PR" ]; then
    PR="$(grep -E '^- .*(READY|PR) #?[0-9]+' "$LEG" | tail -n 1 | grep -oE '(READY|PR) #?[0-9]+' | tail -n 1 | grep -oE '[0-9]+')" || PR=""
fi
case "$PR" in ''|*[!0-9]*) echo "wrap-merged: no PR in $LEG and no --pr given" >&2; exit 2 ;; esac

# 1. pr-state
view="$($GH pr view "$PR" --json state,mergeCommit 2>&1)" || fail pr-state "gh pr view $PR: $view" 3
state="$(printf '%s' "$view" | jq -r '.state // empty' 2>/dev/null)"
sha="$(printf '%s' "$view" | jq -r '.mergeCommit.oid // empty' 2>/dev/null)"
[ "$state" = MERGED ] && [ -n "$sha" ] || fail pr-state "PR #$PR is '${state:-unreadable}', not MERGED" 3
sha8="${sha:0:8}"

# 2. close (only while the leg is still in the manifest)
if bash "$HERE/fleet-manifest.sh" list "$FLEET" 2>/dev/null | grep -Fxq "$LEG"; then
    $CLOSE --fleet "$FLEET" "$LEG"; rc=$?
    [ "$rc" -eq 0 ] || fail close-wrapped-leg "close-wrapped-leg.sh exited $rc" "$rc"
else
    echo "wrap-merged: $LEG is not in the fleet manifest - window already closed, skipping close"
fi

# 3. pull
PRIMARY="${WM_PRIMARY:-}"
if [ -z "$PRIMARY" ]; then
    common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    [ -n "$common" ] && PRIMARY="$(dirname "$common")"
fi
[ -n "$PRIMARY" ] || fail pull "cannot resolve the primary checkout" 5
$GIT -C "$PRIMARY" pull --ff-only || fail pull "git -C $PRIMARY pull --ff-only" 5

# 4. log
base="${LEG##*/}"
ticket=""; label=""
[[ $base =~ ^([A-Za-z][A-Za-z]*-[0-9]+)- ]] && ticket="${BASH_REMATCH[1]}"
[[ $base =~ -(N[0-9]+)- ]] && label="${BASH_REMATCH[1]}"
[ -n "$label" ] || label="${base%.md}"
if grep -Fq "MERGED #$PR → $sha8" "$DOC"; then
    echo "wrap-merged: MERGED #$PR → $sha8 already logged"
else
    status="?"
    if [ -n "$ticket" ]; then
        jira="${WM_JIRA:-node $(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")/scripts/jira/dist/index.js}"
        got="$(JIRA_PROJECT_KEY="${ticket%%-*}" $jira get "$ticket" 2>/dev/null | head -n 1 | cut -f3)" && [ -n "$got" ] && status="$got"
    fi
    text="MERGED #$PR → $sha8 ($label, ${ticket:-no-ticket} $status). $label WRAPPED, window closed."
    bash "$HERE/append-results.sh" "$DOC" "$text" || fail log "append-results.sh" 6
fi

# 5. board
$BOARD --doc "$DOC" --changed || fail board "board.mjs --doc $DOC --changed" 7
