#!/usr/bin/env bash
# scripts/handover/chief-kit/wrap-merged.sh - a worker's MERGED and
# WRAPPED in one call. Replaces the chief's separate turns: check the merge,
# close the window, drop the worker from the fleet, pull the primary, log it,
# re-render the board.
#
# Usage: wrap-merged.sh --doc <chief doc> --fleet <manifest> <worker doc> [--pr <n>]
#
# Steps, in order; the first failure stops the run, names the step on stderr and
# exits with the rc shown. A failure after pr-state proved the merge still re-renders
# the board (its rc ignored), so a stopped wrap never leaves the board stale:
#   1. pr-state   `gh pr view <n>` must be MERGED (rc 3 if not; rc 2 if no PR can
#                 be found). <n> is --pr, else the newest `READY <n>` / `PR <n>`
#                 in the worker doc. The sha recorded is mergeCommit.oid - never
#                 the head a worker's own READY bullet names, which is the PR head.
#   2. close      close-wrapped-worker.sh --fleet <manifest> <worker doc>, ALWAYS - the
#                 manifest is never proof of a closed window. Its rc is
#                 propagated: 1 plumbing/manifest, 3 lock held, 4 not WRAPPED,
#                 5 session count, 6 subtree alive, 7 subagent alive. The one
#                 exception is a re-run: rc 5 whose message says "0 live
#                 session(s)" (lock free and tail WRAPPED already proven) means
#                 the window is gone, so the entry is retired with
#                 `fleet-manifest.sh remove` (rc 1 if that fails) and the run
#                 goes on. <worker doc> is resolved to its absolute physical path.
#   3. pull       git -C <primary> pull --ff-only (rc 5).
#   4. log        one chief-doc bullet, skipped when `MERGED #<n> → <sha8>`
#                 is already in the doc (rc 6):
#                 MERGED #<n> → <sha8> (<label>, <ticket> <status>). <label> WRAPPED, window closed.
#                 <status> is read with the Jira CLI `get`; this script never
#                 transitions a ticket. An unreadable status is `?`.
#   5. board      board.mjs --doc <chief doc> --changed (rc 7); its output is
#                 passed through.
#   5. tracker    best effort, never fails the wrap: when the chief doc has a
#                 `tracker:` line, jira mirror + jira versions (snapshot next to the
#                 mirror) + tracker.py render, each under WM_TRACKER_TIMEOUT (120 s).
#                 Prints tracker=CHANGED|UNCHANGED|failed:<why>|skip. Publishing the
#                 artifact stays the chief's job. Seam: WM_TRACKER_PY. With a
#                 `focus-version:` line (or `auto`, or none beside a `release:` line) the page belongs to focus-refresh.sh (step 5c):
#                 mirror + versions still run, the render does not (tracker=skip:focus).
#   5b. remaining the chief doc's `remaining-board: <version>` line renders that version's open tickets,
#                 grouped by the plan's priority line, to <doc dir>/roadmap-remaining-<version>.md from the
#                 mirror step 5 just refreshed. Prints remaining=CHANGED|UNCHANGED|failed:<why>|skip[:<why>].
#   5c. focus     best effort, never fails the wrap: the chief doc's `focus-version:` line (a version, `auto`,
#                 or no line beside `release: <R>`; `none` skips) runs focus-refresh.sh under WM_FOCUS_TIMEOUT (300 s) and prints focus=ok|busy|DIRTY:<age>|
#                 FAILED:<stage>|skip. Seam: WM_FOCUS. After focus=ok each line of
#                 <doc dir>/focus-drift.txt is printed as `drift: <line>`.
#   6. board      (as above)
# A re-run therefore finishes whatever an earlier run stopped before, and writes
# nothing twice. Calls the existing chief-kit scripts and modifies none.
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
if [ -n "${WM_CLOSE:-}" ]; then CLOSE=("$WM_CLOSE"); else CLOSE=(bash "$HERE/close-wrapped-worker.sh"); fi
if [ -n "${WM_BOARD:-}" ]; then BOARD=("$WM_BOARD"); else BOARD=(node "$HERE/board.mjs"); fi
if [ -n "${WM_TRACKER_PY:-}" ]; then TRACKER=("$WM_TRACKER_PY"); else TRACKER=(python3 "$HERE/tracker.py"); fi
if [ -n "${WM_FOCUS:-}" ]; then FOCUS=("$WM_FOCUS"); else FOCUS=(bash "$HERE/focus-refresh.sh"); fi

usage() { echo "usage: wrap-merged.sh --doc <chief doc> --fleet <manifest> <worker doc> [--pr <n>]" >&2; exit 2; }
BOARD_ON_FAIL=""
fail()  {
    echo "wrap-merged: step $1 failed: $2" >&2
    [ -z "$BOARD_ON_FAIL" ] || "${BOARD[@]}" --doc "$DOC" --changed >&2 || true
    exit "$3"
}

DOC=""; FLEET=""; WORKER=""; PR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc|--fleet|--pr) [ "$#" -ge 2 ] || usage
            case "$1" in --doc) DOC="$2" ;; --fleet) FLEET="$2" ;; --pr) PR="$2" ;; esac
            shift 2 ;;
        -*) usage ;;
        *) [ -z "$WORKER" ] || usage; WORKER="$1"; shift ;;
    esac
done
{ [ -n "$DOC" ] && [ -n "$FLEET" ] && [ -n "$WORKER" ]; } || usage
{ [ -f "$DOC" ] && [ -f "$WORKER" ]; } || { echo "wrap-merged: chief doc or worker doc is not a file" >&2; exit 2; }
# the manifest holds absolute physical paths: match on the same form (rel path, symlink, .., // all collapse)
WORKER="$(cd "$(dirname "$WORKER")" && pwd -P)/${WORKER##*/}"

if [ -z "$PR" ]; then
    PR="$(grep -E '^- .*(READY|PR) #?[0-9]+' "$WORKER" | tail -n 1 | grep -oE '(READY|PR) #?[0-9]+' | tail -n 1 | grep -oE '[0-9]+')" || PR=""
fi
case "$PR" in ''|*[!0-9]*) echo "wrap-merged: no PR in $WORKER and no --pr given" >&2; exit 2 ;; esac

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
{ [ "$state" = MERGED ] && [ -n "$sha" ]; } || fail pr-state "PR #$PR is '${state:-unreadable}', not MERGED" 3
sha8="${sha:0:8}"
BOARD_ON_FAIL=1

base="${WORKER##*/}"
ticket=""; label=""
[[ $base =~ ^([A-Za-z][A-Za-z]*-[0-9]+)- ]] && ticket="${BASH_REMATCH[1]}"
[[ $base =~ -(N[0-9]+)- ]] && label="${BASH_REMATCH[1]}"
[ -n "$label" ] || label="${base%.md}"

# 2. close - always. The manifest is never proof of a closed window (it stores the
# doc as the dispatcher typed it, and every worker is WRAPPED before its close).
errf="$(mktemp "${TMPDIR:-/tmp}/wrap-merged-close.XXXXXX")" || fail close-wrapped-worker "mktemp failed" 1
"${CLOSE[@]}" --fleet "$FLEET" "$WORKER" 2>"$errf"; rc=$?
cat "$errf" >&2
# A zero-session worker now exits 0 (CLOSED-ALREADY) and close-wrapped-worker.sh retires its own entry.
# This rc-5 branch stays for a close script that still refuses with that text (test-wrap-merged.sh stubs one).
if [ "$rc" -eq 5 ] && grep -Fq 'refusing - 0 live session(s)' "$errf"; then
    # close-wrapped-worker proved the lock free and the tail WRAPPED, then found no session:
    # the window is already gone (a re-run). It stopped before its own manifest removal,
    # so retire the entry here, by label as well as path (the manifest keeps the as-typed doc).
    rm -f "$errf"
    echo "wrap-merged: no live session for $WORKER - window already closed"
    bash "$HERE/fleet-manifest.sh" remove "$FLEET" "$WORKER" "$label" >/dev/null \
        || fail close-wrapped-worker "window already closed but fleet-manifest.sh remove failed - run: fleet-manifest.sh remove $FLEET $label" 1
else
    rm -f "$errf"
    [ "$rc" -eq 0 ] || fail close-wrapped-worker "close-wrapped-worker.sh exited $rc" "$rc"
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

# 5. tracker - best effort, never fails the wrap. The chief doc's `tracker:` line
# opts in (the same line, plan dir and paths tick.sh's tracker= reads). Mirror Jira,
# snapshot the versions, re-render when the page's fingerprint moved. Artifact
# publishing stays the chief's job. Prints tracker=CHANGED|UNCHANGED|failed:<why>|skip.
focus_owned() { # 0 when the FOCUS page is focus-refresh's: a version or `auto`, or no line beside a release: line
    local f r
    f="$(sed -n 's/^focus-version:[[:space:]]*//p' "$DOC" | head -n 1)"
    r="$(sed -n 's/^release:[[:space:]]*//p' "$DOC" | head -n 1)"
    case "$f" in none*) return 1 ;; '') case "$r" in ''|none*) return 1 ;; esac ;; esac
    return 0
}
tracker_refresh() {
    local url dir plan out tmo mir pk rc want durl furl out_done out_future split
    url="$(sed -n 's/^tracker:[[:space:]]*//p' "$DOC" | head -n 1)"
    case "$url" in ''|none*) echo "tracker=skip"; return 0 ;; esac
    dir="${DOC%/*}"
    plan="$(sed -n 's/^tracker-plan:[[:space:]]*//p' "$DOC" | head -n 1)"
    [ -n "$plan" ] || plan="$dir/specs/plan/HIMMEL-3882"
    out="$dir/roadmap-tracker.html"
    durl="$(sed -n 's/^tracker-done:[[:space:]]*//p' "$DOC" | head -n 1)"
    furl="$(sed -n 's/^tracker-future:[[:space:]]*//p' "$DOC" | head -n 1)"
    out_done="$dir/roadmap-tracker-done.html"
    out_future="$dir/roadmap-tracker-future.html"
    tmo="${WM_TRACKER_TIMEOUT:-120}"
    pk="${JIRA_PROJECT_KEY:-HIMMEL}"
    mir="${TICK_TRACKER_MIRROR_DIR:-$HOME/.himmel/state/jira-mirror/$pk}"
    mkdir -p "${mir%/*}" 2>/dev/null
    JIRA_PROJECT_KEY="$pk" timeout -k 5 "$tmo" "${jira[@]}" mirror --root "$mir" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
    [ "$rc" -eq 0 ] || { echo "tracker=failed:mirror-rc$rc"; return 0; }
    JIRA_PROJECT_KEY="$pk" timeout -k 5 "$tmo" "${jira[@]}" versions > "$mir.versions.tsv.tmp.$$" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit
    if [ "$rc" -ne 0 ]; then rm -f "$mir.versions.tsv.tmp.$$"; echo "tracker=failed:versions-rc$rc"; return 0; fi
    mv -f "$mir.versions.tsv.tmp.$$" "$mir.versions.tsv" || { echo "tracker=failed:versions-write"; return 0; }
    MIRROR_FRESH="$mir"
    # one writer per page: a focus-version chief's page is focus-refresh's
    ! focus_owned || { echo "tracker=skip:focus"; return 0; }
    set -- --plan-dir "$plan" --out "$out" --luna-map "$dir/roadmap-luna-map.json" --mirror-dir "$mir"
    split=""
    if [ -n "$durl" ] || [ -n "$furl" ]; then
        split=1
        set -- "$@" --out-done "$out_done" --out-future "$out_future" --focus-url "$url" --done-url "$durl" --future-url "$furl"
    fi
    want="$(timeout -k 5 "$tmo" "${TRACKER[@]}" --emit-fp "$@" 2>/dev/null)" || want=""  # gnu-ok: Linux-only kit
    if [ -n "$want" ] && [ -f "$out" ] && [ "$(cat "$out.fp" 2>/dev/null)" = "$want" ] \
        && { [ -z "$split" ] || { [ -f "$out_done" ] && [ -f "$out_future" ]; }; }; then
        echo "tracker=UNCHANGED"; return 0
    fi
    timeout -k 5 "$tmo" "${TRACKER[@]}" "$@" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
    if [ "$rc" -eq 0 ]; then echo "tracker=CHANGED"; else echo "tracker=failed:render-rc$rc"; fi
    return 0
}
MIRROR_FRESH=""
tracker_refresh

# 5b. remaining-only board - best effort, never fails the wrap. The chief doc's `remaining-board: <version>`
# line opts in; the priority line comes from `remaining-plan:` (a plan file), else the newest
# <doc dir>/specs/plans/<version>-approved-plan-<date>.md, else <version>-approved-plan.md (none: every ticket lands in the rest group). Reads the mirror step 5 just refreshed (no fresh mirror, no render).
# Writes <doc dir>/roadmap-remaining-<version>.md. Prints remaining=CHANGED|UNCHANGED|failed:<why>|skip[:<why>].
remaining_refresh() {
    local ver dir plan out tmp tmo rc
    ver="$(sed -n 's/^remaining-board:[[:space:]]*//p' "$DOC" | head -n 1)"
    case "$ver" in ''|none*) echo "remaining=skip"; return 0 ;; esac
    [ -n "$MIRROR_FRESH" ] || { echo "remaining=skip:no-fresh-mirror"; return 0; }
    dir="${DOC%/*}"
    plan="$(sed -n 's/^remaining-plan:[[:space:]]*//p' "$DOC" | head -n 1)"
    if [ -z "$plan" ]; then  # the newest dated plan wins; the undated name is the fallback
        for f in "$dir/specs/plans/$ver"-approved-plan-*.md; do [ -f "$f" ] && plan="$f"; done
        [ -n "$plan" ] || { [ -f "$dir/specs/plans/$ver-approved-plan.md" ] && plan="$dir/specs/plans/$ver-approved-plan.md"; } || true
    fi
    out="$dir/roadmap-remaining-$ver.md"
    tmp="$out.tmp.$$"
    tmo="${WM_TRACKER_TIMEOUT:-120}"
    timeout -k 5 "$tmo" "${TRACKER[@]}" --remaining "$ver" --mirror-dir "$MIRROR_FRESH" ${plan:+--priority-file "$plan"} --out "$tmp" >/dev/null 2>&1; rc=$?  # gnu-ok: Linux-only kit
    if [ "$rc" -ne 0 ]; then rm -f "$tmp"; echo "remaining=failed:render-rc$rc"; return 0; fi
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then rm -f "$tmp"; echo "remaining=UNCHANGED"; return 0; fi
    # prim-ok: the renderer writes $tmp itself via --out, so there is no stdin stream for atomic_write
    mv -f "$tmp" "$out" && echo "remaining=CHANGED" || echo "remaining=failed:write"
    return 0
}
remaining_refresh

# 5c. focus - best effort, never fails the wrap. The chief doc's `focus-version:` line opts in; the
# refresh (focus-refresh.sh, bounded) reuses the mirror step 5 just refreshed.
# Prints focus=ok|busy|DIRTY:<age>|FAILED:<stage>|skip.
focus_refresh() {
    local tmo got rc
    focus_owned || { echo "focus=skip"; return 0; }
    tmo="${WM_FOCUS_TIMEOUT:-300}"
    # swallow-ok: only the focus= line and the exit code decide; a missing line prints FAILED:rc<n>
    got="$(timeout -k 5 "$tmo" "${FOCUS[@]}" --doc "$DOC" ${MIRROR_FRESH:+--mirror-fresh "$MIRROR_FRESH"} 2>/dev/null)"; rc=$?  # gnu-ok: Linux-only kit
    case "$rc" in 124|137) echo "focus=FAILED:timeout"; return 0 ;; esac
    got="$(printf '%s\n' "$got" | tail -n 1)"
    case "$got" in focus=*) echo "$got" ;; *) echo "focus=FAILED:rc$rc" ;; esac
    [ "$got" = focus=ok ] || return 0
    sed 's/^/drift: /' "${DOC%/*}/focus-drift.txt" 2>/dev/null
    return 0
}
focus_refresh

# 6. board
BOARD_ON_FAIL=""
"${BOARD[@]}" --doc "$DOC" --changed || fail board "board.mjs --doc $DOC --changed" 7
