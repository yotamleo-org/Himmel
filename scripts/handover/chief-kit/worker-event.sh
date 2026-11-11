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
#                        --worker <label> <pr> <head>, live: every check passing writes and sends
#                        the GO. Each answer leaves a bullet in the chief doc (append-results.sh):
#                          GO-SENT (exit 0)     -> `AUTO-GO #<pr> <head8> qid=<q|none> to <label>`,
#                                                  prints `HANDLED auto-go <label>`, rc 0
#                          GO-WRITTEN (exit 11) -> the same bullet ending ` bus-failed`; auto-go's
#                                                  lines (the SENDMESSAGE the chief sends) passed on, rc 11
#                          ESCALATE auto-go <n> <reason> (exit 10) -> `AUTO-GO-REFUSED #<pr> <n>`,
#                                                  the line passed on as is, rc 10
#                        A bullet that cannot be written appends ` doc-bullet=failed <why>` (its own
#                        line after a GO-WRITTEN). Any other auto-go answer is
#                        `ESCALATE auto-go-error rc=<n> ...`. Flag off: auto-go.sh --dry-run runs once, detached with its output discarded and bounded by GNU timeout where one exists (LE_DRYRUN_BOUND seconds, default 60; macOS has none, so there it is detached but unbounded; its answer is ignored, so it leaves one auto-go.jsonl row; with stacked_series on it runs under the series ledger writer's label, as the live path does), and ESCALATE marker-READY follows at once, as before.
#                        A WRAPPED whose PR wrap-merged finds still OPEN (rc 3 at its pr-state step) is closed the
#                        same way: HANDLED close-wrapped, or ESCALATE close-wrapped-failed when that close refuses.
#                        A MERGED line for an OPEN PR still escalates wrap-merged-failed.
#   anything else     -> ESCALATE (READY with the flag off, and FINDING, need a judge or the chief)
#
#   stacked_series on: series-ledger.py find (the bucket is the manifest's directory) says whether the worker's
#   doc is a series' writer or passed it on (`from`). A WRAPPED from a `from` doc goes to close-wrapped-worker,
#   never wrap-merged; a READY from either role addresses the writer's one manifest label, else
#   ESCALATE series-writer-unlisted and no auto-go call; a ledger that cannot be read is
#   ESCALATE series-find-failed rc=<n>; a stacked_series flag that cannot be read is
#   ESCALATE series-flag-unreadable rc=<n>, never off. A doc in no ledger routes as before.
#
#   after a MERGED with a PR, or a WRAPPED whose merged PR wrap-merged.sh printed, station-sync.sh --pr <n> runs detached to bring the
#   station back to main: ` station=pending log=<file>` is appended at once, its
#   output goes to the log and its verdict to the state file tick.sh shows.
#
# The worker is found by its N<k> label, else by its session name (the worker doc's
# stem) quoted in the message. After a handled event the script runs
# live-state.sh <doc>, which rewrites the `## Live state` legs: line; its failure
# is appended as ` live-state=failed <why>` (the wrap is done, so rc stays 0).
#
# Output: one line (a READY's GO-WRITTEN passes on auto-go's lines, see above).
# `HANDLED wrap-merged|close-wrapped <label>[ station=pending log=<file>][ live-state=failed <why>]` (rc 0),
# `HANDLED auto-go <label>[ doc-bullet=failed <why>]` (rc 0) for a READY whose GO auto-go.sh sent,
# `HANDLED noop <label>` (rc 0) when the worker is out of the manifest and the chief doc
# already records `<label> WRAPPED, window closed.` (a re-run on a closed worker), or
# `ESCALATE <reason>` (rc 10), the reason being no-label, not-in-manifest,
# marker-<X>, unfiled-residual: <line>, auto-go <n> <why> (auto-go.sh refused), auto-go-error rc=<n>,
# or wrap-merged-failed / close-wrapped-failed rc=<n> with that script's stderr after it, or
# auto-go.sh's `GO-WRITTEN …` lines (rc 11: the GO file stands, the bus send failed).
# Usage errors exit 2 before anything runs.
#
# Test seams (env): LE_WRAP LE_CLOSE LE_LIST LE_LIVE LE_STATION LE_STATION_LOG LE_AUTOGO LE_DRYRUN_BOUND.
# Platform guard: Linux bash 3.2+ (wrap-merged.sh needs flock + jq).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/handover/chief-kit/residual-lines.sh
. "$HERE/residual-lines.sh"
# shellcheck source=scripts/lib/worker-identity.sh
. "$HERE/../../lib/worker-identity.sh"
if [ -n "${LE_WRAP:-}" ]; then WRAP=("$LE_WRAP"); else WRAP=(bash "$HERE/wrap-merged.sh"); fi
if [ -n "${LE_CLOSE:-}" ]; then CLOSE=("$LE_CLOSE"); else CLOSE=(bash "$HERE/close-wrapped-worker.sh"); fi
if [ -n "${LE_STATION:-}" ]; then STATION=("$LE_STATION"); else STATION=(bash "$HERE/station-sync.sh"); fi
if [ -n "${LE_LIVE:-}" ]; then LIVE=("$LE_LIVE"); else LIVE=(bash "$HERE/live-state.sh"); fi
if [ -n "${LE_LIST:-}" ]; then LIST=("$LE_LIST"); else LIST=(bash "$HERE/fleet-manifest.sh" list); fi
if [ -n "${LE_AUTOGO:-}" ]; then AUTOGO=("$LE_AUTOGO"); else AUTOGO=(bash "$HERE/auto-go.sh"); fi
# the auto_go flag (scripts/lib/flags.sh): an unregistered flag reads as off
auto_go_on() { ( . "$HERE/../../lib/flags.sh" && himmel_flag auto_go ) >/dev/null 2>&1; }
# exit 0 on, 1 off, 2 the flag could not be read (an unknown name, an unreadable registry or an invalid value)
stacked_series_state() { ( . "$HERE/../../lib/flags.sh" && himmel_flag stacked_series ) >/dev/null 2>&1; }

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
while [[ "$line" =~ ^(N[0-9]+[a-z]*|[A-Z]+-[0-9]+)[[:space:]]+ ]]; do line="${line#"${BASH_REMATCH[0]}"}"; done
marker="${line%%[^A-Za-z-]*}"

dry_run_ready() {
    local dpr dhead dlabels
    [[ $line =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})([^0-9a-f]|$) ]] || return 0
    dpr="${BASH_REMATCH[1]}"; dhead="${BASH_REMATCH[2]}"
    dlabels="$(printf '%s\n' "$body" | grep -oE '\<N[0-9]+[a-z]*\>' | sort -u)"
    case "$dlabels" in ''|*$'\n'*) return 0 ;; esac
    (
        if stacked_series_state; then
            dw="$("${LIST[@]}" "$FLEET" | grep -F -- "-${dlabels}-" | head -n 1)"
            if [ -n "$dw" ] && dfind="$(python3 -I "$HERE/series-ledger.py" find --bucket "$(dirname "$FLEET")" --doc "$dw" --manifest "$FLEET")" \
                && [ -n "$dfind" ] && [ "${dfind##* }" != "-" ]; then
                dlabels="${dfind##* }"
            fi
        fi
        . "$HERE/../../lib/timeout-bin.sh"
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 "${LE_DRYRUN_BOUND:-60}"} "${AUTOGO[@]}" --dry-run --doc "$DOC" --fleet "$FLEET" --worker "$dlabels" "$dpr" "$dhead"
    ) >/dev/null 2>&1 </dev/null &
    return 0
}

case "$marker" in
    MERGED|WRAPPED) ;;
    READY) auto_go_on || { dry_run_ready; escalate "marker-READY"; } ;;
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
labels="$(printf '%s\n' "$body" | grep -oE '\<N[0-9]+[a-z]*\>' | sort -u)" || labels=""
if [ -n "$labels" ]; then
    [ "$(printf '%s\n' "$labels" | wc -l)" -eq 1 ] || escalate "ambiguous-label"
    label="$labels"
    listing="$("${LIST[@]}" "$FLEET" 2>/dev/null)" || listing=""
    worker="$(printf '%s\n' "$listing" | grep -F -- "-${label}-" | head -n 1)" || worker=""
    # a resumed worker's manifest entry carries a successor letter (N4304b) the message may not;
    # matched on each doc's worker label, never on a directory or slug that mentions it
    if [ -z "$worker" ]; then
        succ=""
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            [[ "$(worker_label "$cand")" =~ ^${label}[a-z]+$ ]] && succ="$succ$cand"$'\n'
        done <<EOF
$listing
EOF
        succ="${succ%$'\n'}"
        [ "$(printf '%s' "$succ" | grep -c .)" -le 1 ] || escalate "ambiguous-label"
        # a label already recorded closed cannot tell the closed worker from its successor: a replay escalates
        if [ -n "$succ" ] && grep -qE "(^|[^A-Za-z0-9_])$label WRAPPED, window closed\." "$DOC" 2>/dev/null; then
            escalate "ambiguous-label"
        fi
        worker="$succ"
    fi
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
    [[ $stem =~ -(N[0-9]+[a-z]*)- ]] && label="${BASH_REMATCH[1]}"
fi

# stacked_series only: the ledger says whether this worker's doc is a series' writer or passed it on, and who the
# writer's manifest label is. This script reads series-ledger.py find's one line and nothing else of the ledger.
series_role=""; series_label=""
series_flag=0; stacked_series_state || series_flag=$?
# an unreadable flag is not an off flag: off routes a series READY to the doc that sent it
[ "$series_flag" -le 1 ] || escalate "series-flag-unreadable rc=$series_flag"
if [ "$series_flag" -eq 0 ] && [ -n "$worker" ]; then
    fout="$(python3 -I "$HERE/series-ledger.py" find --bucket "$(dirname "$FLEET")" --doc "$worker" --manifest "$FLEET" 2>&1)"; frc=$?
    # a ledger that cannot be read could be hiding the series: no guess at a route
    [ "$frc" -eq 0 ] || escalate "series-find-failed rc=$frc $(printf '%s' "$fout" | tr '\n' ' ')"
    # fields: sid ledger role label, read from the right: the ledger path may hold a space, role and label never do
    if [ -n "$fout" ]; then
        series_label="${fout##* }"; fout="${fout% *}"; series_role="${fout##* }"
    fi
fi

if [ "$marker" = READY ]; then
    # a series READY addresses the ledger writer's one manifest label, whoever sent it
    if [ -n "$series_role" ]; then
        [ -n "$series_label" ] && [ "$series_label" != "-" ] || escalate "series-writer-unlisted"
        label="$series_label"
    else
        # the manifest row's label is worker_label of its doc: a message that named the bare label of a resumed worker still reaches auto-go under it
        label="$(worker_label "$worker")"
    fi
    [[ $line =~ ^READY[[:space:]]+#?([0-9]+)[[:space:]]+([0-9a-f]{40})([^0-9a-f]|$) ]] || escalate "ready-unparsed"
    rpr="${BASH_REMATCH[1]}"; rhead="${BASH_REMATCH[2]}"
    aout="$("${AUTOGO[@]}" --doc "$DOC" --fleet "$FLEET" --worker "$label" "$rpr" "$rhead" 2>&1)"; arc=$?
    # the answer is auto-go's first answer line: a stderr warning printed before it must not hide it
    afirst="$(printf '%s\n' "$aout" | grep -m1 -E '^(GO-SENT|GO-WRITTEN|ESCALATE|WOULD-GO) ')" || afirst=""
    # bullet <text>: the chief doc's record of the scripted answer; a failed append is reported, never fatal
    bullet() { local e; e="$(bash "$HERE/append-results.sh" "$DOC" "$1" 2>&1)" || echo " doc-bullet=failed $(printf '%s' "$e" | tr '\n' ' ')"; }
    go_re="^GO-SENT $rpr $rhead to [^ ]+ bus=#[0-9]+ qid=([A-Za-z0-9._-]+)\$"
    gw_re="^GO-WRITTEN $rpr $rhead qid=([A-Za-z0-9._-]+) bus-failed: "
    if [ "$arc" -eq 0 ] && [[ $afirst =~ $go_re ]]; then
        echo "HANDLED auto-go $label$(bullet "AUTO-GO #$rpr ${rhead:0:8} qid=${BASH_REMATCH[1]} to $label")"
        exit 0
    fi
    if [ "$arc" -eq 11 ] && [[ $afirst =~ $gw_re ]]; then
        # the SENDMESSAGE line stays whole: a failed append is reported on a line of its own
        bres="$(bullet "AUTO-GO #$rpr ${rhead:0:8} qid=${BASH_REMATCH[1]} to $label bus-failed")"
        # the answer lines first (the relay wakes on the first line), any warning after them
        printf '%s\n' "$aout" | grep -E '^(GO-WRITTEN|SENDMESSAGE) '
        printf '%s\n' "$aout" | grep -vE '^(GO-WRITTEN|SENDMESSAGE) |^[[:space:]]*$'
        [ -z "$bres" ] || printf '%s\n' "${bres# }"
        exit 11
    fi
    if [ "$arc" -eq 10 ] && [[ $afirst =~ ^ESCALATE\ auto-go\ ([0-9]+)\  ]]; then
        echo "$afirst$(bullet "AUTO-GO-REFUSED #$rpr ${BASH_REMATCH[1]}")"
        exit 10
    fi
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
if [ "$marker" = WRAPPED ] && [ "$series_role" = from ]; then
    # a doc that passed its series on has nothing to merge: the PRs belong to the series' writer
    close_only=1
elif [ "$marker" = WRAPPED ] && [ -r "$worker" ] \
    && ! grep -qE '^- .*(READY|PR) #?[0-9]+' "$worker"; then
    close_only=1
    # a resumed worker's PR may be named only in the doc of the worker it continues (or of a
    # sibling successor): any doc of the same worker base naming a PR keeps the merge verification
    # a listing or read that fails keeps the verified path: the direct close is the one that kills
    wk_base="$(worker_base "$worker")"
    # every doc in the directory is listed: the worker_base filter below decides who is a sibling, so a
    # legacy -legN<k>-/-leg<k>- original or a multi-letter successor is never missed by a name glob
    # worker_base forks several processes and the live handovers directory holds thousands of docs, so a
    # pure-bash prefilter runs first: every doc of an N<digits> base carries those digits in its name (a
    # canonical N<k>[a-z]*, a legacy -legN<k>- or -leg<k>-), so a name without them is no sibling. Any
    # other base (a whole-stem fallback label) skips the prefilter.
    sib_key=""
    if [[ $wk_base =~ ^N[0-9]+$ ]]; then sib_key="${wk_base#N}"; fi
    if ! sibs="$(find "$(dirname "$worker")" -maxdepth 1 -type f -name '*.md')"; then
        close_only=""
    else
        while IFS= read -r sib; do
            [ -n "$sib" ] && [ "$sib" != "$worker" ] || continue
            if [ -n "$sib_key" ]; then case "${sib##*/}" in *"$sib_key"*) ;; *) continue ;; esac; fi
            [ "$(worker_base "$sib")" = "$wk_base" ] || continue
            sib_rc=0; grep -qE '^- .*(READY|PR) #?[0-9]+' "$sib" || sib_rc=$?
            if [ "$sib_rc" -ne 1 ]; then close_only=""; break; fi
        done <<EOF
$sibs
EOF
    fi
fi

errf="$(mktemp "${TMPDIR:-/tmp}/worker-event.XXXXXX")" || escalate "wrap-merged-failed rc=1 mktemp"
if [ -n "$close_only" ]; then
    "${CLOSE[@]}" --fleet "$FLEET" "$worker" >/dev/null 2>"$errf"; rc=$?
    what=close-wrapped
else
    args=(--doc "$DOC" --fleet "$FLEET" "$worker")
    [ -z "$pr" ] || args+=(--pr "$pr")
    outf="$(mktemp "${TMPDIR:-/tmp}/worker-event-out.XXXXXX")" || { rm -f "$errf"; escalate "wrap-merged-failed rc=1 mktemp"; }
    "${WRAP[@]}" "${args[@]}" >"$outf" 2>"$errf"; rc=$?
    what=wrap-merged
    if [ "$rc" -eq 3 ] && [ "$marker" = WRAPPED ] && grep -qE "step pr-state failed: PR #[0-9]+ is 'OPEN'" "$errf"; then
        rm -f "$outf"; outf=""
        "${CLOSE[@]}" --fleet "$FLEET" "$worker" >/dev/null 2>"$errf"; rc=$?
        what=close-wrapped
    fi
fi
if [ "$rc" -ne 0 ]; then
    msg="$(tr '\n' ' ' <"$errf")"
    rm -f "$errf" "${outf:-}"
    escalate "$what-failed rc=$rc $msg"
fi
# a WRAPPED line carries no PR: take the one wrap-merged proved merged
if [ -z "$pr" ] && [ -n "${outf:-}" ]; then
    pr="$(sed -n 's/^wrap-merged: merged pr=\([0-9][0-9]*\) sha=.*/\1/p' "$outf" | head -n 1)" || pr=""
fi
rm -f "$errf" "${outf:-}"
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
