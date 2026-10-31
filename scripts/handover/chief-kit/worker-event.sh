#!/usr/bin/env bash
# scripts/handover/chief-kit/worker-event.sh - route one worker message to the
# one-shot that handles it, or say ESCALATE. A script, never a model: the
# chief runs it once per worker message instead of spending the several
# full-context turns the hand sequence takes.
#
# Usage: worker-event.sh --doc <chief doc> --fleet <manifest> <message-file | ->
#
#   MERGED / WRAPPED  -> wrap-merged.sh --doc <doc> --fleet <manifest> <worker doc> [--pr <n>]
#                        The worker doc is the manifest entry whose name carries the
#                        message's N<k> label; <n> is the PR in a `MERGED #<n>` line.
#                        A WRAPPED line that mentions deferred, follow-up or residual with
#                        no HIMMEL-<n> key or `no-ticket: <reason>` (residual-lines.sh)
#                        is ESCALATE unfiled-residual: <line>, before wrap-merged runs.
#                        A WRAPPED whose worker doc names no PR (a research worker) skips wrap-merged:
#                        close-wrapped-worker.sh --fleet <manifest> <worker doc> closes it, which
#                        itself refuses unless the worker's queue lock is free and its tail is WRAPPED.
#   READY <pr> <head> -> with the auto_go flag on: auto-go.sh --doc <doc> --fleet <manifest>
#                        --worker <label> --dry-run <pr> <head>, its answer passed on. Until the
#                        scripted GO writes a file (a later auto-go.sh slice) a WOULD-GO answer
#                        prints `WOULD-GO <pr> <head> dry-run, no GO written` and exits 10, so
#                        the chief still gives the GO; ESCALATE auto-go <n> <reason> is passed
#                        on as is. Any other auto-go exit is `ESCALATE auto-go-error rc=<n> ...`.
#                        Flag off: ESCALATE marker-READY, as before.
#   anything else     -> ESCALATE (READY with the flag off, and FINDING, need a judge or the chief)
#
#   after a MERGED with a PR, station-sync.sh --pr <n> runs detached to bring the
#   station back to main: ` station=pending log=<file>` is appended at once, its
#   output goes to the log and its verdict to the state file tick.sh shows.
#
# The worker is found by its N<k> label, else by its session name (the worker doc's
# stem) quoted in the message. After a handled event the script runs
# live-state.sh <doc>, which rewrites the `## Live state` legs: line; its failure
# is appended as ` live-state=failed <why>` (the wrap is done, so rc stays 0).
#
# Output: one line. `HANDLED wrap-merged|close-wrapped <label>[ station=pending log=<file>][ live-state=failed <why>]` (rc 0),
# `HANDLED noop <label>` (rc 0) when the worker is out of the manifest and the chief doc
# already records `<label> WRAPPED, window closed.` (a re-run on a closed worker), or
# `ESCALATE <reason>` (rc 10), the reason being no-label, not-in-manifest,
# marker-<X>, unfiled-residual: <line>, or wrap-merged-failed / close-wrapped-failed rc=<n> with that script's stderr after it.
# Usage errors exit 2 before anything runs.
#
# Test seams (env): LE_WRAP LE_CLOSE LE_LIST LE_LIVE LE_STATION LE_STATION_LOG LE_AUTOGO.
# Platform guard: Linux bash 3.2+ (wrap-merged.sh needs flock + jq).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/handover/chief-kit/residual-lines.sh
. "$HERE/residual-lines.sh"
if [ -n "${LE_WRAP:-}" ]; then WRAP=("$LE_WRAP"); else WRAP=(bash "$HERE/wrap-merged.sh"); fi
if [ -n "${LE_CLOSE:-}" ]; then CLOSE=("$LE_CLOSE"); else CLOSE=(bash "$HERE/close-wrapped-worker.sh"); fi
if [ -n "${LE_STATION:-}" ]; then STATION=("$LE_STATION"); else STATION=(bash "$HERE/station-sync.sh"); fi
if [ -n "${LE_LIVE:-}" ]; then LIVE=("$LE_LIVE"); else LIVE=(bash "$HERE/live-state.sh"); fi
if [ -n "${LE_LIST:-}" ]; then LIST=("$LE_LIST"); else LIST=(bash "$HERE/fleet-manifest.sh" list); fi
if [ -n "${LE_AUTOGO:-}" ]; then AUTOGO=("$LE_AUTOGO"); else AUTOGO=(bash "$HERE/auto-go.sh"); fi
# the auto_go flag (scripts/lib/flags.sh): an unregistered flag reads as off
auto_go_on() { ( . "$HERE/../../lib/flags.sh" && himmel_flag auto_go ) >/dev/null 2>&1; }

usage() { echo "usage: worker-event.sh --doc <chief doc> --fleet <manifest> <message-file | ->" >&2; exit 2; }
escalate() { echo "ESCALATE $1"; exit 10; }

DOC=""; FLEET=""; MSG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc|--fleet) [ "$#" -ge 2 ] || usage
            case "$1" in --doc) DOC="$2" ;; --fleet) FLEET="$2" ;; esac
            shift 2 ;;
        -) [ -z "$MSG" ] || usage; MSG="-"; shift ;;
        -*) usage ;;
        *) [ -z "$MSG" ] || usage; MSG="$1"; shift ;;
    esac
done
if [ -z "$DOC" ] || [ -z "$FLEET" ] || [ -z "$MSG" ]; then usage; fi

if [ "$MSG" = "-" ]; then body="$(cat)"; else body="$(cat "$MSG")" || usage; fi  # read-sink-ok: MSG is the message file the caller asks to post
line="$(printf '%s\n' "$body" | grep -m1 -E '[^[:space:]]')" || line=""
line="${line#- }"
# a message may lead with its own N<k> label and ticket key before the marker
while [[ "$line" =~ ^(N[0-9]+|[A-Z]+-[0-9]+)[[:space:]]+ ]]; do line="${line#"${BASH_REMATCH[0]}"}"; done
marker="${line%%[^A-Za-z-]*}"

case "$marker" in
    MERGED|WRAPPED) ;;
    READY) auto_go_on || escalate "marker-READY" ;;
    *) escalate "marker-${marker:-none}" ;;
esac

if [ "$marker" = WRAPPED ]; then
    mf="$(mktemp "${TMPDIR:-/tmp}/worker-event-msg.XXXXXX")" || escalate "wrap-merged-failed rc=1 mktemp"
    printf '%s\n' "$body" > "$mf"
    unfiled="$(unfiled_residual_mention_lines "$mf")"
    rm -f "$mf"
    if [ -n "$unfiled" ]; then
        escalate "unfiled-residual: $(printf '%s' "$unfiled" | tr '\n' ' ')"
    fi
fi

# the worker is named by its N<k> label, or failing that by its session name (the
# worker doc's stem, which a wrap message may quote without any N<k>)
labels="$(printf '%s\n' "$body" | grep -oE '\<N[0-9]+\>' | sort -u)" || labels=""
if [ -n "$labels" ]; then
    [ "$(printf '%s\n' "$labels" | wc -l)" -eq 1 ] || escalate "ambiguous-label"
    label="$labels"
    worker="$("${LIST[@]}" "$FLEET" 2>/dev/null | grep -F -- "-${label}-" | head -n 1)" || worker=""
    # a worker already wrapped has left the manifest; wrap-merged's chief-doc bullet
    # (`<label> WRAPPED, window closed.`) says so, and a re-run is then a noop.
    # ponytail: a worker closed by close-wrapped (no such bullet) or named only by its
    # stem still escalates, upgrade to a closed-workers record if such a re-run ever wakes a chief
    if [ -z "$worker" ] && grep -qE "(^|[^A-Za-z0-9_])$label WRAPPED, window closed\." "$DOC" 2>/dev/null; then
        echo "HANDLED noop $label"; exit 0
    fi
    [ -n "$worker" ] || escalate "not-in-manifest $label"
else
    workers=""
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        stem="${cand##*/}"; stem="${stem%.md}"
        # the stem must stand alone: a longer, unlisted session name never matches a listed one
        [[ $body =~ (^|[^A-Za-z0-9_-])"$stem"([^A-Za-z0-9_-]|$) ]] && workers="$workers$cand"$'\n'
    done <<EOF
$("${LIST[@]}" "$FLEET" 2>/dev/null)
EOF
    [ -n "$workers" ] || escalate "no-label"
    [ "$(printf '%s' "$workers" | wc -l)" -eq 1 ] || escalate "ambiguous-label"
    worker="${workers%$'\n'}"
    stem="${worker##*/}"; stem="${stem%.md}"
    label="$stem"
    [[ $stem =~ -(N[0-9]+)- ]] && label="${BASH_REMATCH[1]}"
fi

if [ "$marker" = READY ]; then
    [[ $line =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})([^0-9a-f]|$) ]] || escalate "ready-unparsed"
    rpr="${BASH_REMATCH[1]}"; rhead="${BASH_REMATCH[2]}"
    aout="$("${AUTOGO[@]}" --doc "$DOC" --fleet "$FLEET" --worker "$label" --dry-run "$rpr" "$rhead" 2>&1)"; arc=$?
    afirst="$(printf '%s\n' "$aout" | grep -m1 '[^[:space:]]')" || afirst=""
    case "$arc:$afirst" in
        0:"WOULD-GO $rpr $rhead") echo "WOULD-GO $rpr $rhead dry-run, no GO written"; exit 10 ;;
        10:"ESCALATE auto-go "*) echo "$afirst"; exit 10 ;;
    esac
    escalate "auto-go-error rc=$arc $(printf '%s' "$aout" | tr '\n' ' ')"
fi

pr=""
if [ "$marker" = MERGED ]; then
    pr="$(printf '%s\n' "$line" | grep -oE 'MERGED #?[0-9]+' | grep -oE '[0-9]+' | head -n 1)" || pr=""
fi

# a WRAPPED worker whose doc names no PR (a research worker) has nothing to merge-check:
# close its window directly. close-wrapped-worker.sh itself refuses unless the worker's
# queue lock is free and its tail marker is WRAPPED.
close_only=""
if [ "$marker" = WRAPPED ] && [ -r "$worker" ] \
    && ! grep -qE '^- .*(READY|PR) #?[0-9]+' "$worker"; then
    close_only=1
fi

errf="$(mktemp "${TMPDIR:-/tmp}/worker-event.XXXXXX")" || escalate "wrap-merged-failed rc=1 mktemp"
if [ -n "$close_only" ]; then
    "${CLOSE[@]}" --fleet "$FLEET" "$worker" >/dev/null 2>"$errf"; rc=$?
    what=close-wrapped
else
    args=(--doc "$DOC" --fleet "$FLEET" "$worker")
    [ -z "$pr" ] || args+=(--pr "$pr")
    "${WRAP[@]}" "${args[@]}" >/dev/null 2>"$errf"; rc=$?
    what=wrap-merged
fi
if [ "$rc" -ne 0 ]; then
    msg="$(tr '\n' ' ' <"$errf")"
    rm -f "$errf"
    escalate "$what-failed rc=$rc $msg"
fi
rm -f "$errf"
# A merged PR leaves the station behind main until its components are updated:
# station-sync.sh runs the matching himmel-update steps and checks --versions. Those
# fetch and rebuild without a bound, so it runs detached: the line returns at once
# with station=pending, the sync's output (STEP, LOCAL-DIFF, STATION=) goes to the
# log, and its verdict lands in the state file tick.sh reads as station=.
station=""
if [ -n "$pr" ]; then
    slog="${LE_STATION_LOG:-$HOME/.himmel/state/station-sync.out}"
    mkdir -p "$(dirname "$slog")" 2>/dev/null || true
    # setsid is util-linux: absent on macOS, where the sync stays in this process group
    if command -v setsid >/dev/null 2>&1; then
        setsid "${STATION[@]}" --pr "$pr" >>"$slog" 2>&1 </dev/null &
    else
        "${STATION[@]}" --pr "$pr" >>"$slog" 2>&1 </dev/null &
    fi
    station=" station=pending log=$slog"
fi
# re-render the legs: line so a wrapped worker is dropped by the script, not by a chief Edit turn
live=""
if ! lerr="$("${LIVE[@]}" "$DOC" 2>&1 >/dev/null)"; then
    live=" live-state=failed $(printf '%s' "$lerr" | tr '\n' ' ')"
fi
echo "HANDLED $what $label$station$live"
