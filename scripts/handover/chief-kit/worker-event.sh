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
#                          ESCALATE auto-go 2 PR <pr> is MERGED, not OPEN, with a gh read of MERGED at the READY head
#                                               -> `STALE-READY PR <pr> <head8> MERGED, <label> closed, not escalated`,
#                                                  prints `HANDLED stale-ready <label>`, rc 0
#                        A bullet that cannot be written appends ` doc-bullet=failed <why>` (its own
#                        line after a GO-WRITTEN). Any other auto-go answer is
#                        `ESCALATE auto-go-error rc=<n> ...`. Flag off: auto-go.sh --dry-run runs once, detached with its output discarded and bounded by GNU timeout where one exists (LE_DRYRUN_BOUND seconds, default 60; macOS has none, so there it is detached but unbounded; its answer is ignored, so it leaves one auto-go.jsonl row; with stacked_series on it runs under the series ledger writer's label, as the live path does), and ESCALATE marker-READY follows at once, as before.
#                        A WRAPPED whose worker doc says `Completes ticket: no` first writes the ticket's next step
#                        to the chief doc's owed ledger (owe.sh: a step row due today, `sign the design` after a
#                        READY-TO-SIGN not yet signed, else `launch the next slice`, plus one chief notification
#                        row the waiter wakes on); a row that cannot be written is ESCALATE next-step-owe-failed.
#                        A WRAPPED whose PR wrap-merged finds still OPEN (rc 3 at its pr-state step) is closed the
#                        same way: HANDLED close-wrapped, or ESCALATE close-wrapped-failed when that close refuses.
#                        A MERGED line for an OPEN PR still escalates wrap-merged-failed.
#   HALTED            -> a worker whose doc still ends on HALTED with its queue lock free is finished
#                        (worker_terminal_tail, scripts/lib/worker-tail-status.sh): one line
#                        `ESCALATE halted-closable <label> doc=<worker doc>` tells the chief to close it
#                        (close-wrapped-worker.sh closes it). A HALTED worker that is still running, a worker
#                        not found, or a doc that moved on is the old `ESCALATE marker-HALTED`; a worker
#                        already closed (the chief doc holds `<label> WRAPPED, window closed.`) is `HANDLED noop`.
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
#   on every other event wake (handled or escalated) while the state file reads BEHIND:<components> (not `pending`),
#   station-sync.sh --heal --bucket <the chief doc's directory> --chief <the chief doc's stem> runs detached the same way
#   (output to the same log), and retries the steps its behind components map to, bounded by its own back-off.
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
# `HANDLED closed-already <label>` (rc 0): a WRAPPED worker the chief already closed (the chief doc holds `<label> WRAPPED,
# window closed.`), whose doc tail is WRAPPED, queue lock free and session gone; nothing runs.
# `HANDLED closed-already <label>` also answers a wrap-merged or close step that outlives LE_STEP_BOUND seconds, one bound counted from the start of the run for the wrap and its close fallback together
# (default 200, under the waiter's 240 s limit; no GNU timeout, no bound) for a worker whose doc tail is terminal
# (worker_terminal_tail), queue lock free and session gone.
# A bullet `CLOSED-ALREADY <label> WRAPPED, window closed, relay step outlived <n>s, not escalated` is appended to the
# chief doc. The same step for a worker that is not closed is `ESCALATE relay-timeout <label> rc=<n> limit=<bound>s`.
# Test seams (env): LE_STEP_BOUND LE_LOCK LE_SESSIONS LE_WRAP LE_CLOSE LE_LIST LE_LIVE LE_STATION LE_STATION_LOG LE_STATION_STATE LE_AUTOGO LE_GH LE_DRYRUN_BOUND.
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
if [ -n "${LE_GH:-}" ]; then GH=("$LE_GH"); elif [ -f "$HERE/../../lib/gh-read.sh" ]; then GH=(bash "$HERE/../../lib/gh-read.sh"); else GH=(gh); fi
if [ -n "${LE_LOCK:-}" ]; then LOCK=("$LE_LOCK"); else LOCK=(bash "$HERE/../queue-lock.sh"); fi
# shellcheck disable=SC2016
if [ -n "${LE_SESSIONS:-}" ]; then SESSIONS=("$LE_SESSIONS"); else SESSIONS=(bash -c '. "$1/../../lanes/lib/claude-sessions.sh" && claude_sessions' _ "$HERE"); fi
# the auto_go flag (scripts/lib/flags.sh): an unregistered flag reads as off
auto_go_on() { ( . "$HERE/../../lib/flags.sh" && himmel_flag auto_go ) >/dev/null 2>&1; }
# exit 0 on, 1 off, 2 the flag could not be read (an unknown name, an unreadable registry or an invalid value)
stacked_series_state() { ( . "$HERE/../../lib/flags.sh" && himmel_flag stacked_series ) >/dev/null 2>&1; }

# shellcheck source=scripts/lib/timeout-bin.sh
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
STEP_BOUND="${LE_STEP_BOUND:-200}"
STEP_T0=$SECONDS
bounded() { local left=$((STEP_BOUND - (SECONDS - STEP_T0))); [ "$left" -ge 1 ] || left=1; ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 5 "$left"} "$@"; }
worker_closed() {
    local lock_state=held wstem wsess
    [ -r "$worker" ] || return 1
    "${LOCK[@]}" status "$worker" >/dev/null 2>&1 && lock_state=free
    [ "$lock_state" = free ] || return 1
    # shellcheck source=scripts/lib/worker-tail-status.sh
    . "$HERE/../../lib/worker-tail-status.sh"
    worker_terminal_tail "$(results_tail "$worker")" "$lock_state" || return 1
    wstem="${worker##*/}"; wstem="${wstem%.md}"
    wsess="$("${SESSIONS[@]}")" || return 1
    ! printf '%s\n' "$wsess" | awk -F'\t' -v s="$wstem" '$2 == s { f = 1 } END { exit !f }'
}

usage() { echo "usage: worker-event.sh --doc <chief doc> --fleet <manifest> <message-file | ->" >&2; exit 2; }
escalate() { if [ -n "${halted:-}" ] && [ "${1%% *}" != halted-closable ]; then echo "ESCALATE marker-HALTED"; else echo "ESCALATE $1"; fi; exit 10; }
results_tail() {
    awk '/^## Results( |$)/ { seen = 1; r = 1; next } /^## / { r = seen && ($0 ~ /^## (Chief|Console) Rulings( |$)/); next } r && match($0, /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/) { m = substr($0, RSTART, RLENGTH); sub(/^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?/, "", m); sub(/[^A-Za-z0-9_]$/, "", m); last = m } END { print last }' "$1"
}
listed_doc() {
    local cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        [ "$(worker_label "$cand")" = "$1" ] && { printf '%s' "$cand"; return 0; }
    done <<EOF
$2
EOF
    return 1
}
successor_docs() {
    local cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        [[ "$(worker_label "$cand")" =~ ^${1}[a-z]+$ ]] && printf '%s\n' "$cand"
    done <<EOF
$2
EOF
    return 0
}

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

heal_station() {
    [ -z "${station_started:-}" ] || return 0
    local st="${LE_STATION_STATE:-${SS_STATE:-$HOME/.himmel/state/station-sync.state}}" cur hlog
    [ -f "$st" ] || return 0
    cur="$(cat "$st")" || return 0
    case "$cur" in BEHIND:pending|BEHIND:) return 0 ;; BEHIND:*) ;; *) return 0 ;; esac
    hlog="${LE_STATION_LOG:-$HOME/.himmel/state/station-sync.out}"
    mkdir -p "$(dirname "$hlog")" || return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid "${STATION[@]}" --heal --bucket "${DOC%/*}" --chief "$(basename "$DOC" .md)" >>"$hlog" 2>&1 </dev/null &
    else
        "${STATION[@]}" --heal --bucket "${DOC%/*}" --chief "$(basename "$DOC" .md)" >>"$hlog" 2>&1 </dev/null &
    fi
    return 0
}
trap heal_station EXIT

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
        dlist="$("${LIST[@]}" "$FLEET")" || dlist=""
        dw="$(listed_doc "$dlabels" "$dlist")" || dw=""
        if [ -z "$dw" ]; then
            dsucc="$(successor_docs "$dlabels" "$dlist")"
            [ "$(printf '%s' "$dsucc" | grep -c .)" -ne 1 ] || dw="$dsucc"
        fi
        [ -z "$dw" ] || dlabels="$(worker_label "$dw")"
        if stacked_series_state; then
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

halted=""
case "$marker" in
    MERGED|WRAPPED) ;;
    HALTED) halted=1 ;;
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
    listing="$("${LIST[@]}" "$FLEET" 2>/dev/null)" || listing=""
    if [ "$(printf '%s\n' "$labels" | wc -l)" -ne 1 ]; then
        listed_labels=""
        while IFS= read -r cand_label; do
            if listed_doc "$cand_label" "$listing" >/dev/null || [ -n "$(successor_docs "$cand_label" "$listing")" ]; then
                listed_labels="$listed_labels$cand_label"$'\n'
            fi
        done <<EOF
$labels
EOF
        [ "$(printf '%s' "$listed_labels" | grep -c .)" -eq 1 ] || escalate "ambiguous-label"
        labels="${listed_labels%$'\n'}"
    fi
    label="$labels"
    worker="$(listed_doc "$label" "$listing")" || worker=""
    if [ -z "$worker" ]; then
        succ="$(successor_docs "$label" "$listing")"
        [ "$(printf '%s' "$succ" | grep -c .)" -le 1 ] || escalate "ambiguous-label"
        # a label already recorded closed cannot tell the closed worker from its successor: a replay escalates
        if [ -n "$succ" ] && grep -qE "(^|[^A-Za-z0-9_])$label WRAPPED, window closed\." "$DOC" 2>/dev/null; then
            escalate "ambiguous-label"
        fi
        worker="$succ"
    fi
    # A lost response may arrive after manifest removal. Reconcile proof data
    # against the same owed identity before acknowledging that replay.
    if [ -z "$worker" ] && [ "$marker" = WRAPPED ] && [[ $body =~ proof[[:space:]]+[A-Z]+-[0-9]+ ]]; then
        proof_out=$(printf '%s\n' "$body" | python3 "$HERE/proof-validate.py" --bucket "$(dirname "$FLEET")" --label "$label" --message-stdin 2>&1); proof_rc=$?
        [ "$proof_rc" -eq 0 ] || escalate "proof-handoff-failed $proof_out"
        if [ -n "$proof_out" ]; then echo "HANDLED proof-handoff $label"; exit 0; fi
    fi
    # a worker already wrapped has left the manifest; wrap-merged's chief-doc bullet
    # (`<label> WRAPPED, window closed.`) says so, and a re-run is then a noop.
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

if [ -n "$halted" ]; then
    if [ -r "$worker" ]; then
        . "$HERE/../../lib/worker-tail-status.sh"
        lock_state=held
        "${LOCK[@]}" status "$worker" >/dev/null 2>&1 && lock_state=free
        if worker_terminal_tail "$(results_tail "$worker")" "$lock_state"; then escalate "halted-closable $label doc=$worker"; fi
    fi
    escalate "marker-HALTED"
fi

owe_next_step() {
    local stem key flag results ready sha actor=chief step due id out bucket chief
    stem="${worker##*/}"; stem="${stem%.md}"
    [[ $stem =~ ^([A-Z][A-Z0-9]*-[0-9]+)- ]] || return 0
    key="${BASH_REMATCH[1]}"
    flag="$(sed -nE '/^## Results/q; s/^> \*\*Completes ticket:\*\* (yes|no)[[:space:]]*$/\1/p' < "$worker" | head -n 1)"
    [ "$flag" = no ] || return 0
    results="$(awk '/^## Results/ { r = 1; next } r && /^- /' "$worker")"
    ready="$(printf '%s\n%s\n' "$results" "$body" | grep -F 'READY-TO-SIGN')" || ready=""
    step="launch the next slice, or close $key by hand when nothing remains"
    if [ -n "$ready" ] && ! printf '%s\n%s\n' "$(printf '%s\n' "$results" | grep -E '^- ([0-9:]+ )?WRAPPED' | tail -n 1)" "$body" | grep -qiE 'signed by'; then
        sha="$(printf '%s\n' "$ready" | grep -oiE 'spec( rev [0-9]+)?( sha256)? [0-9a-f]{8,64}' | tail -n 1 | grep -oE '[0-9a-f]+$' | cut -c1-12)" || sha=""
        step="sign the design${sha:+ (spec $sha)}, then dispatch the build"
        if printf '%s\n' "$ready" | grep -qiE "operator('s)? (signs|signature|sign-off)|signed by the operator|operator (must|to) sign"; then
            actor=operator
            step="ask the operator to sign the design${sha:+ (spec $sha)}, then dispatch the build"
        fi
    fi
    bucket="$(dirname "$DOC")"; chief="${DOC##*/}"; chief="${chief%.md}"
    due="$(date -u +%Y-%m-%d)"
    id="$(printf '%s' "worker-event-next-step $stem" | python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" || return 1
    out="$(bash "$HERE/owe.sh" add --bucket "$bucket" --chief "$chief" --kind step --key "$key" --identity "$id" \
        --text "$key next step: $step ($label wrapped with completes-ticket: no)" \
        --metadata "$(jq -nc --arg a "$actor" --arg d "$due" --arg s "$worker" --arg l "$label" '{actor: $a, due: $d, source_doc: $s, source_label: $l}')" 2>&1)" \
        || { printf '%s' "$out"; return 1; }
    local row="$out"
    id="$(printf '%s' "worker-event-next-step-wake $stem" | python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" || return 1
    out="$(bash "$HERE/owe.sh" add --bucket "$bucket" --chief "$chief" --kind ruling --identity "$id" \
        --text "$key next step owed as $row: $step" \
        --metadata "$(jq -nc --arg r "$row" '{actor: "chief", action: "notify", event: "step-due", source_id: $r, capability: "notification delivery", wake: "acknowledge delivery with owe close"}')" 2>&1)" \
        || { printf '%s' "$out"; return 1; }
}
if [ "$marker" = WRAPPED ] && [ -r "$worker" ]; then
    owe_out="$(owe_next_step)" || escalate "next-step-owe-failed $(printf '%s' "$owe_out" | tr '\n' ' ')"
fi

if [ "$marker" = WRAPPED ] && [ -r "$worker" ] \
    && grep -qE "(^|[^A-Za-z0-9_])$label WRAPPED, window closed\." "$DOC" 2>/dev/null \
    && "${LOCK[@]}" status "$worker" >/dev/null 2>&1 \
    && [ "$(results_tail "$worker")" = WRAPPED ]; then
    gstem="${worker##*/}"; gstem="${gstem%.md}"
    if gsess="$("${SESSIONS[@]}")" && ! printf '%s\n' "$gsess" | awk -F'\t' -v s="$gstem" '$2 == s { f = 1 } END { exit !f }'; then
        echo "HANDLED closed-already $label"; exit 0
    fi
fi

# Record before any cleanup implementation (including an injected close). The
# direct close/sweep repeats this gate with the same idempotent writer.
if [ "$marker" = WRAPPED ] && { [ -r "$worker" ] || [[ $body =~ proof[[:space:]]+[A-Z]+-[0-9]+ ]]; }; then
    proof_out=$(printf '%s\n' "$body" | python3 "$HERE/proof-validate.py" --bucket "$(dirname "$FLEET")" --doc "$worker" --label "$(worker_label "$worker")" --message-stdin 2>&1); proof_rc=$?
    [ "$proof_rc" -eq 0 ] || escalate "proof-handoff-failed $proof_out"
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
    stale_re="^ESCALATE auto-go 2 PR $rpr is MERGED, not OPEN\$"
    if [ "$arc" -eq 10 ] && [[ $afirst =~ $stale_re ]]; then
        stale_state="MERGED"
        live_state=""
        if gh_state="$(cd "$HERE/../../.." && "${GH[@]}" pr view "$rpr" --json state,headRefOid --jq '.state + " " + .headRefOid')"; then live_state="$gh_state"; fi
        if [ "$live_state" = "$stale_state $rhead" ]; then
            echo "HANDLED stale-ready $label$(bullet "STALE-READY PR $rpr ${rhead:0:8} $stale_state, $label closed, not escalated")"
            exit 0
        fi
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
    bounded "${CLOSE[@]}" --fleet "$FLEET" "$worker" >/dev/null 2>"$errf"; rc=$?
    what=close-wrapped
else
    args=(--doc "$DOC" --fleet "$FLEET" "$worker")
    [ -z "$pr" ] || args+=(--pr "$pr")
    outf="$(mktemp "${TMPDIR:-/tmp}/worker-event-out.XXXXXX")" || { rm -f "$errf"; escalate "wrap-merged-failed rc=1 mktemp"; }
    bounded "${WRAP[@]}" "${args[@]}" >"$outf" 2>"$errf"; rc=$?
    what=wrap-merged
    if [ "$rc" -eq 3 ] && [ "$marker" = WRAPPED ] && grep -qE "step pr-state failed: PR #[0-9]+ is 'OPEN'" "$errf"; then
        rm -f "$outf"; outf=""
        bounded "${CLOSE[@]}" --fleet "$FLEET" "$worker" >/dev/null 2>"$errf"; rc=$?
        what=close-wrapped
    fi
fi
if { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && [ -n "${_TIMEOUT_BIN:-}" ]; then
    rm -f "$errf" "${outf:-}"
    if worker_closed; then
        if cerr="$(bash "$HERE/append-results.sh" "$DOC" "CLOSED-ALREADY $label WRAPPED, window closed, relay step outlived ${STEP_BOUND}s, not escalated" 2>&1)"; then cbul=""
        else cbul=" doc-bullet=failed $(printf '%s' "$cerr" | tr '\n' ' ')"; fi
        echo "HANDLED closed-already $label$cbul"; exit 0
    fi
    escalate "relay-timeout $label rc=$rc limit=${STEP_BOUND}s"
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
    station_started=1
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
