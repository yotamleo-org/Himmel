#!/usr/bin/env bash
# scripts/handover/console-kit/leg-jira-status.sh - the ONE writer of a
# ticket's Jira status and of its worker record. An event says only "look
# again": the status written is derived from the ticket's present ship-flow
# state (scripts/lib/ticket-status.sh, rules D0-D7), never from the event, so a
# late or duplicate event re-derives the same answer and a re-push after IN CI
# moves the ticket back.
#
# Usage: leg-jira-status.sh <TICKET> --event <e> [--pr <n> --head <sha>] [--repo <owner/repo>] [--doc <path>] [--resume-brief <path>]
#        leg-jira-status.sh <TICKET> <target-status> [--allow-back]
#   --repo names the repository whose PRs and checks the derive reads (GH_REPO);
#   without it gh reads the current checkout's.
#   The second form is the legacy call: the target is a hint logged as
#   event=legacy:<target>, never written.
#
# Under a per-key flock it derives, re-reads Jira and the open-PR heads (a
# change re-derives once; a second change defers), transitions, reads the
# status back, updates the worker record and appends one outcome row to
# status-events.jsonl (moved | noop | skip | deferred | miss | disabled).
#
# Best-effort by design: every failure prints a WARN on stderr and exits 0, so
# a Jira or GitHub problem never blocks a leg; the whole run is bounded by
# TICKET_STATUS_BUDGET seconds (default 20), and a run cut off logs
# miss stage=timeout.
#
# Env: WORKER_SESSION_JIRA_STATUS=0 opts out (a disabled row). TICKET_STATUS_LOCK_WAIT
# (default 10) bounds the flock wait. The rest is read by the lib.
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -u

usage() {
    echo "usage: leg-jira-status.sh <TICKET> --event <e> [--pr <n> --head <sha>] [--repo <owner/repo>] [--doc <path>] [--resume-brief <path>]" >&2
    echo "       leg-jira-status.sh <TICKET> <target-status> [--allow-back]" >&2
    exit 2
}
[ "$#" -ge 2 ] || usage
KEY="$1"
shift
EVENT="" PR="" HEAD="" REPO="" DOC="" RESUME=""
if [ "${1#--}" = "$1" ]; then
    EVENT="legacy:$1"
    shift
    [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = "--allow-back" ]; } || usage
    set --
fi
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --event) EVENT="$2" ;;
        --pr) PR="$2" ;;
        --head) HEAD="$2" ;;
        --repo) REPO="$2" ;;
        --doc) DOC="$2" ;;
        --resume-brief) RESUME="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$EVENT" ] || usage

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub

warn() { echo "WARN leg-jira-status: $* (continuing; the leg is not blocked)" >&2; exit 0; }

[[ "$KEY" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || warn "'$KEY' is not a ticket key"
if [ -n "$REPO" ]; then
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || warn "'$REPO' is not an owner/repo"
    export GH_REPO="$REPO"
fi
command -v jq >/dev/null 2>&1 || warn "jq not found; $KEY not synced"

# shellcheck source=../../lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/ticket-status.sh"

row() {
    status_event event="$EVENT" key="$KEY" ${PR:+"pr=$PR"} ${HEAD:+"head=$HEAD"} "$@"
}

if [ "${WORKER_SESSION_JIRA_STATUS:-${LEG_JIRA_STATUS:-1}}" = 0 ]; then
    row result=disabled
    exit 0
fi

# The budget wraps the whole run in a re-exec, so one hung call cannot hold the
# caller (append-results, check-ci, merge-on-green) past it.
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"
if [ -z "${TICKET_STATUS_IN_BUDGET:-}" ] && [ -n "$_TIMEOUT_BIN" ]; then
    budget="${TICKET_STATUS_BUDGET:-20}"
    case "$budget" in ''|*[!0-9]*) budget=20 ;; esac
    rc=0
    TICKET_STATUS_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 "$budget" bash "${BASH_SOURCE[0]}" "$KEY" --event "$EVENT" \
        ${PR:+--pr "$PR"} ${HEAD:+--head "$HEAD"} ${REPO:+--repo "$REPO"} ${DOC:+--doc "$DOC"} ${RESUME:+--resume-brief "$RESUME"} || rc=$?
    case "$rc" in
        124|137)
            row result=miss stage=timeout
            warn "$KEY not synced within ${budget}s" ;;
    esac
    exit 0
fi

miss() { row result=miss rule="${TS_RULE:-}" stage="$1" from="${TS_J_STATUS:-}"; warn "$KEY not synced (stage $1)"; }

# ponytail: no flock binary (stock macOS) runs unlocked, so two events for one
# key can interleave; upgrade path = a mkdir lock.
if command -v flock >/dev/null 2>&1; then
    lockdir="$(ts_state_dir)/status-locks"
    mkdir -p "$lockdir" 2>/dev/null || warn "cannot create $lockdir"
    exec 9>>"$lockdir/$KEY" || warn "cannot open the $KEY status lock"
    if ! flock -w "${TICKET_STATUS_LOCK_WAIT:-10}" 9; then # prim-ok: a bounded wait that logs deferred; with_lock has no deadline
        row result=deferred stage=lock
        exit 0
    fi
fi

# An event that names the owner's doc or resume brief records it first, so the
# derive sees the key as owned.
if [ -n "$DOC$RESUME" ] && ts_record_read "$KEY"; then
    leg=""
    [[ "${DOC##*/}" =~ ^$KEY-(N[0-9]+)- ]] && leg="${BASH_REMATCH[1]}"
    rec=$(jq -c --arg k "$KEY" --arg d "$DOC" --arg l "$leg" --arg rb "$RESUME" '
        .key = $k
        | if $d != "" then .docs = ((.docs // []) + [.doc // empty, $d] | unique) | .doc = $d else . end
        | if $l != "" then .leg = $l else . end
        | if $rb != "" then .resume_brief = $rb else . end' <<<"$TS_REC") \
        && ts_record_write "$KEY" "$rec" || echo "WARN leg-jira-status: cannot record the $KEY owner" >&2
fi

update_record() { # <Jira status now> [the move, "<from> -> <to>"]
    local rec cid chash ol=""
    ts_record_read "$KEY" || return 0
    # The record and the WORKER comment follow the leg that still holds the key.
    if [ -n "$TS_OWNER_DOC" ]; then
        [[ "${TS_OWNER_DOC##*/}" =~ ^$KEY-(N[0-9]+)- ]] && ol="${BASH_REMATCH[1]}"
        TS_REC=$(jq -c --arg d "$TS_OWNER_DOC" --arg l "$ol" '.doc = $d | if $l != "" then .leg = $l else del(.leg) end' <<<"$TS_REC") || return 0
    fi
    cid=$(jq -r '.comment_id // ""' <<<"$TS_REC") chash=$(jq -r '.comment_hash // ""' <<<"$TS_REC")
    if ts_worker_comment "$KEY" "$1" "${2:-$(jq -r '.last_move // ""' <<<"$TS_REC")}"; then
        cid=$TS_CID chash=$TS_CHASH
    else
        row result=miss stage=comment rule="$TS_RULE" from="$1"
    fi
    rec=$(jq -c --arg k "$KEY" --arg ev "$EVENT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg ws "$TS_WORKER_STATE" --arg mv "${2:-}" --arg prs "$TS_PR_STATE" \
        --arg seen "$TS_LOCK_SEEN" --argjson gone "$TS_GONE" --arg cid "$cid" --arg chash "$chash" '
        .key = $k | .last_event = $ev | .last_event_ts = $ts | .state = $ws
        | .lock_seen = ($seen == "true") | .lock_gone_sweeps = $gone
        | if $cid != "" then .comment_id = $cid else del(.comment_id) end
        | if $chash != "" then .comment_hash = $chash else del(.comment_hash) end
        | if $mv != "" then .last_move = $mv else . end
        | .prs = (((.prs // {}) | with_entries(.value.open = false))
            + ($prs | split("\n") | map(select(length > 0) | split("\t")
                | {key: .[0], value: {head: .[1], ci: .[2], red_latch: (.[3] == "true"), open: true}})
                | from_entries))' <<<"$TS_REC") || return 0
    ts_record_write "$KEY" "$rec" || echo "WARN leg-jira-status: cannot write the $KEY worker record" >&2
}

# A Done ticket is never moved, but its worker record still follows the doc/lock,
# so a leg that wrapped after the merge does not read live forever.
refresh_done_record() {
    local doc rec
    ts_record_read "$KEY" || return 0
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    [ -n "$doc" ] || return 0
    _ts_worker_state "$doc"
    [ "$(jq -r '.state // ""' <<<"$TS_REC")" != "$TS_WORKER_STATE" ] || return 0
    rec=$(jq -c --arg ev "$EVENT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ws "$TS_WORKER_STATE" \
        '.last_event = $ev | .last_event_ts = $ts | .state = $ws' <<<"$TS_REC") || return 0
    ts_record_write "$KEY" "$rec" || echo "WARN leg-jira-status: cannot write the $KEY worker record" >&2
}

# Derive, then re-read Jira and the PR heads before the write: Jira has no
# conditional transition, so a change in between re-derives once, and a second
# change leaves the write to the next event.
changes=0
# shellcheck disable=SC2034  # read by ts_derive
TS_EVENT="$EVENT"
while :; do
    ts_derive "$KEY"
    if [ "$TS_DERIVED" = no-write ]; then
        if [ "$TS_RESULT" = miss ]; then miss "$TS_STAGE"; fi
        if [ "$TS_RULE" = D0 ] && [ "$TS_J_STATUS" = Done ]; then refresh_done_record; fi
        row result=skip rule="$TS_RULE" from="${TS_J_STATUS:-}"
        exit 0
    fi
    if [ "$TS_DERIVED" = "$TS_J_STATUS" ]; then
        update_record "$TS_J_STATUS"
        row result=noop rule="$TS_RULE" from="$TS_J_STATUS"
        exit 0
    fi
    seen_j="$TS_J_STATUS" seen_heads="$TS_HEADS"
    ts_read_jira "$KEY" || miss get
    ts_read_prs "$KEY" || miss "$TS_STAGE"
    [ "$TS_J_STATUS" != "$seen_j" ] || [ "$TS_HEADS" != "$seen_heads" ] || break
    changes=$((changes + 1))
    if [ "$changes" -ge 2 ]; then
        row result=deferred stage=cas rule="$TS_RULE" from="$TS_J_STATUS"
        exit 0
    fi
done

from="$TS_J_STATUS" to="$TS_DERIVED"
dir=fwd
[ "$(ts_rank "$to")" -gt "$(ts_rank "$from")" ] || dir=back
out="$(ts_jira transition "$KEY" "$to" 2>&1)" || {
    row result=miss rule="$TS_RULE" stage=transition from="$from" to="$to"
    warn "transition $KEY '$from' -> '$to' failed: $(printf '%s' "$out" | tr '\n' ' ')"
}
if ! ts_read_jira "$KEY" || [ "$TS_J_STATUS" != "$to" ]; then
    row result=miss rule="$TS_RULE" stage=readback from="$from" to="$to"
    warn "$KEY reads '${TS_J_STATUS:-?}' after the move to '$to'"
fi
update_record "$to" "$from -> $to"
row result=moved rule="$TS_RULE" from="$from" to="$to" dir="$dir"
echo "leg-jira-status: $KEY $from -> $to ($TS_RULE)"
exit 0
