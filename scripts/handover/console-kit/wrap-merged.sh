#!/usr/bin/env bash
# scripts/handover/console-kit/wrap-merged.sh - a leg's MERGED and
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
#   2. close      close-wrapped-leg.sh --fleet <manifest> <leg doc>, ALWAYS - the
#                 manifest is never proof of a closed window. Its rc is
#                 propagated: 1 plumbing/manifest, 3 lock held, 4 not WRAPPED,
#                 5 session count, 6 subtree alive, 7 subagent alive. The one
#                 exception is a re-run: rc 5 whose message says "0 live
#                 session(s)" (lock free and tail WRAPPED already proven) means
#                 the window is gone, so the entry is retired with
#                 `fleet-manifest.sh remove` (rc 1 if that fails) and the run
#                 goes on. <leg doc> is resolved to its absolute physical path.
#   3. pull       git -C <primary> pull --ff-only (rc 5).
#   4. log        one console-doc bullet, skipped when `MERGED #<n> → <sha8>`
#                 is already in the doc (rc 6):
#                 MERGED #<n> → <sha8> (<label>, <ticket> <status>). <label> WRAPPED, window closed.
#                 <status> is read with the Jira CLI `get`; this script never
#                 transitions a ticket. An unreadable status is `?`.
#   5. board      board.mjs --doc <console doc> --changed (rc 7); its output is
#                 passed through.
#   5. tracker    best effort, never fails the wrap: when the console doc has a
#                 `tracker:` line, jira mirror + jira versions (snapshot next to the
#                 mirror) + tracker.py render, each under WM_TRACKER_TIMEOUT (120 s).
#                 Prints tracker=CHANGED|UNCHANGED|failed:<why>|skip. Publishing the
#                 artifact stays the console's job. Seam: WM_TRACKER_PY.
#   6. board      (as above)
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
GIT="${WM_GIT:-git}"
# arrays, so a checkout path with a space stays one word; a WM_* override is one executable
if [ -n "${WM_CLOSE:-}" ]; then CLOSE=("$WM_CLOSE"); else CLOSE=(bash "$HERE/close-wrapped-leg.sh"); fi
if [ -n "${WM_BOARD:-}" ]; then BOARD=("$WM_BOARD"); else BOARD=(node "$HERE/board.mjs"); fi
if [ -n "${WM_TRACKER_PY:-}" ]; then TRACKER=("$WM_TRACKER_PY"); else TRACKER=(python3 "$HERE/tracker.py"); fi

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
# the manifest holds absolute physical paths: match on the same form (rel path, symlink, .., // all collapse)
LEG="$(cd "$(dirname "$LEG")" && pwd -P)/${LEG##*/}"

if [ -z "$PR" ]; then
    PR="$(grep -E '^- .*(READY|PR) #?[0-9]+' "$LEG" | tail -n 1 | grep -oE '(READY|PR) #?[0-9]+' | tail -n 1 | grep -oE '[0-9]+')" || PR=""
fi
case "$PR" in ''|*[!0-9]*) echo "wrap-merged: no PR in $LEG and no --pr given" >&2; exit 2 ;; esac

PRIMARY="${WM_PRIMARY:-}"
if [ -z "$PRIMARY" ]; then
    common="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    [ -n "$common" ] && PRIMARY="$(dirname "$common")"
fi
[ -n "$PRIMARY" ] || fail primary "cannot resolve the primary checkout" 5
if [ -n "${WM_JIRA:-}" ]; then jira=("$WM_JIRA"); else jira=(node "$PRIMARY/scripts/jira/dist/index.js"); fi

# 1. pr-state (run from the primary so gh resolves THIS repo, not the caller's)
view="$(cd "$PRIMARY" && "$GH" pr view "$PR" --json state,mergeCommit 2>&1)" || fail pr-state "gh pr view $PR: $view" 3
state="$(printf '%s' "$view" | jq -r '.state // empty' 2>/dev/null)"
sha="$(printf '%s' "$view" | jq -r '.mergeCommit.oid // empty' 2>/dev/null)"
[ "$state" = MERGED ] && [ -n "$sha" ] || fail pr-state "PR #$PR is '${state:-unreadable}', not MERGED" 3
sha8="${sha:0:8}"

base="${LEG##*/}"
ticket=""; label=""
[[ $base =~ ^([A-Za-z][A-Za-z]*-[0-9]+)- ]] && ticket="${BASH_REMATCH[1]}"
[[ $base =~ -(N[0-9]+)- ]] && label="${BASH_REMATCH[1]}"
[ -n "$label" ] || label="${base%.md}"

# 2. close - always. The manifest is never proof of a closed window (it stores the
# doc as the dispatcher typed it, and every leg is WRAPPED before its close).
errf="$(mktemp "${TMPDIR:-/tmp}/wrap-merged-close.XXXXXX")" || fail close-wrapped-leg "mktemp failed" 1
"${CLOSE[@]}" --fleet "$FLEET" "$LEG" 2>"$errf"; rc=$?
cat "$errf" >&2
if [ "$rc" -eq 5 ] && grep -Fq 'refusing - 0 live session(s)' "$errf"; then
    # close-wrapped-leg proved the lock free and the tail WRAPPED, then found no session:
    # the window is already gone (a re-run). It stopped before its own manifest removal,
    # so retire the entry here, by label as well as path (the manifest keeps the as-typed doc).
    rm -f "$errf"
    echo "wrap-merged: no live session for $LEG - window already closed"
    bash "$HERE/fleet-manifest.sh" remove "$FLEET" "$LEG" "$label" >/dev/null \
        || fail close-wrapped-leg "window already closed but fleet-manifest.sh remove failed - run: fleet-manifest.sh remove $FLEET $label" 1
else
    rm -f "$errf"
    [ "$rc" -eq 0 ] || fail close-wrapped-leg "close-wrapped-leg.sh exited $rc" "$rc"
fi

# 3. pull
"$GIT" -C "$PRIMARY" pull --ff-only || fail pull "git -C $PRIMARY pull --ff-only" 5

# 4. log
if grep -Fq "MERGED #$PR → $sha8" "$DOC"; then
    echo "wrap-merged: MERGED #$PR → $sha8 already logged"
else
    status="?"
    if [ -n "$ticket" ]; then
        got="$(JIRA_PROJECT_KEY="${ticket%%-*}" "${jira[@]}" get "$ticket" 2>/dev/null | head -n 1 | cut -f3)" && [ -n "$got" ] && status="$got"
    fi
    text="MERGED #$PR → $sha8 ($label, ${ticket:-no-ticket} $status). $label WRAPPED, window closed."
    bash "$HERE/append-results.sh" "$DOC" "$text" || fail log "append-results.sh" 6
fi

# 5. tracker - best effort, never fails the wrap. The console doc's `tracker:` line
# opts in (the same line, plan dir and paths tick.sh's tracker= reads). Mirror Jira,
# snapshot the versions, re-render when the page's fingerprint moved. Artifact
# publishing stays the console's job. Prints tracker=CHANGED|UNCHANGED|failed:<why>|skip.
tracker_refresh() {
    local url dir plan out tmo mir rc want
    url="$(sed -n 's/^tracker:[[:space:]]*//p' "$DOC" | head -n 1)"
    case "$url" in ''|none*) echo "tracker=skip"; return 0 ;; esac
    dir="${DOC%/*}"
    plan="$(sed -n 's/^tracker-plan:[[:space:]]*//p' "$DOC" | head -n 1)"
    [ -n "$plan" ] || plan="$dir/specs/plan/HIMMEL-3882"
    out="$dir/roadmap-tracker.html"
    tmo="${WM_TRACKER_TIMEOUT:-120}"
    mir="${TICK_TRACKER_MIRROR_DIR:-$HOME/.himmel/state/jira-mirror/HIMMEL}"
    mkdir -p "${mir%/*}" 2>/dev/null
    JIRA_PROJECT_KEY=HIMMEL timeout -k 5 "$tmo" "${jira[@]}" mirror >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
    [ "$rc" -eq 0 ] || { echo "tracker=failed:mirror-rc$rc"; return 0; }
    JIRA_PROJECT_KEY=HIMMEL timeout -k 5 "$tmo" "${jira[@]}" versions > "$mir.versions.tsv.tmp.$$" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
    if [ "$rc" -ne 0 ]; then rm -f "$mir.versions.tsv.tmp.$$"; echo "tracker=failed:versions-rc$rc"; return 0; fi
    mv -f "$mir.versions.tsv.tmp.$$" "$mir.versions.tsv" || { echo "tracker=failed:versions-write"; return 0; }
    set -- --plan-dir "$plan" --out "$out" --luna-map "$dir/roadmap-luna-map.json" --mirror-dir "$mir"
    want="$(timeout -k 5 "$tmo" "${TRACKER[@]}" --emit-fp "$@" 2>/dev/null)" || want=""  # gnu-ok: Linux-only kit
    if [ -n "$want" ] && [ -f "$out" ] && [ "$(cat "$out.fp" 2>/dev/null)" = "$want" ]; then
        echo "tracker=UNCHANGED"; return 0
    fi
    timeout -k 5 "$tmo" "${TRACKER[@]}" "$@" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
    if [ "$rc" -eq 0 ]; then echo "tracker=CHANGED"; else echo "tracker=failed:render-rc$rc"; fi
    return 0
}
tracker_refresh

# 6. board
"${BOARD[@]}" --doc "$DOC" --changed || fail board "board.mjs --doc $DOC --changed" 7
