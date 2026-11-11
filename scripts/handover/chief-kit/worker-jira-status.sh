#!/usr/bin/env bash
# scripts/handover/chief-kit/worker-jira-status.sh - the ONE writer of a
# ticket's Jira status and of its worker record. An event says only "look
# again": the status written is derived from the ticket's present ship-flow
# state (scripts/lib/ticket-status.sh, rules D0-D7), never from the event, so a
# late or duplicate event re-derives the same answer and a re-push after IN CI
# moves the ticket back.
#
# Usage: worker-jira-status.sh <TICKET> --event <e> [--pr <n> --head <sha>] [--repo <owner/repo>] [--doc <path>] [--resume-brief <path>]
#        worker-jira-status.sh <TICKET> --event phase-label --phase <p>
#        worker-jira-status.sh <TICKET> --event phase-label --after <event> --rule <R> [--doc <path>] [--pr <n>]
#        worker-jira-status.sh <TICKET> <target-status> [--allow-back]
#   --repo names the repository whose PRs and checks the derive reads (GH_REPO);
#   without it gh reads the current checkout's.
#   The second form is the legacy call: the target is a hint logged as
#   event=legacy:<target>, never written.
#   --event phase-label writes the ticket's one phase:* label and nothing else (no derive, no status, no
#   record): the chief's form takes --phase, the wrapper's own second child takes --after and --rule.
#   Exactly one of those forms; either flag with any other event exits 2.
#
# Under a per-key flock it derives, re-reads Jira and the open-PR heads (a
# change re-derives once; a second change defers), transitions, reads the
# status back, updates the worker record and appends one outcome row to
# status-events.jsonl (moved | noop | skip | deferred | miss | disabled).
#
# Best-effort by design: every failure prints a WARN on stderr and exits 0, so
# a Jira or GitHub problem never blocks a worker; the whole run is bounded by
# TICKET_STATUS_BUDGET seconds (default 20), and a run cut off logs
# miss stage=timeout.
#
# The phase label: after the status child has exited, the wrapper runs a second child,
# --event phase-label --after <event> --rule <R>, in the budget the first left. It reads the ticket's
# phase:* labels and, on a change, swaps them with one `edit --phase`. Its rows are event=phase-label
# result=phase-set|phase-miss only (a cut-off one is phase-miss stage=timeout), never a status-shaped
# row, so a slow phase write cannot read as a status miss. This script is the one caller of that edit.
#
# Env: WORKER_SESSION_JIRA_STATUS=0 opts out (a disabled row); HIMMEL_RELEASE_MANAGER=1 skips (a skip rule=RM row). TICKET_STATUS_LOCK_WAIT
# (default 10) bounds the flock wait; TICKET_STATUS_PHASE_MIN (default 3) is the seconds the phase child
# needs left, else one phase-miss stage=budget row. The rest is read by the lib.
#
# Platform guard: POSIX bash 3.2+ (shell-only harness).
set -u

usage() {
    echo "usage: worker-jira-status.sh <TICKET> --event <e> [--pr <n> --head <sha>] [--repo <owner/repo>] [--doc <path>] [--resume-brief <path>]" >&2
    echo "       worker-jira-status.sh <TICKET> --event phase-label --phase <p>" >&2
    echo "       worker-jira-status.sh <TICKET> <target-status> [--allow-back]" >&2
    exit 2
}
[ "$#" -ge 2 ] || usage
KEY="$1"
shift
EVENT="" PR="" HEAD="" REPO="" DOC="" RESUME="" PHASE="" AFTER="" RULE="" HP="" HA="" HR=""
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
        --phase) PHASE="$2" HP=1 ;;
        --after) AFTER="$2" HA=1 ;;
        --rule) RULE="$2" HR=1 ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$EVENT" ] || usage
# phase-label takes exactly --phase <p>, or --after <event> with --rule <R>; no other event takes any of the three
if [ "$EVENT" = phase-label ]; then
    if [ -n "$HP" ]; then
        [ -z "$HA$HR" ] && [ -n "$PHASE" ] || usage
    else
        [ -n "$AFTER" ] && [ -n "$RULE" ] || usage
    fi
else
    [ -z "$HP$HA$HR" ] || usage
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub

warn() { echo "WARN worker-jira-status: $* (continuing; the worker is not blocked)" >&2; exit 0; }

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
    # event=merge is merge-on-green.sh's own contract row; the funnel's derive row for that event is
    # written as derive, so no reader of the last merge row sees a row without a contract.
    local ev="$EVENT"
    [ "$ev" != merge ] || ev=derive
    status_event event="$ev" key="$KEY" ${PR:+"pr=$PR"} ${HEAD:+"head=$HEAD"} "$@"
}

if [ "${WORKER_SESSION_JIRA_STATUS:-1}" = 0 ]; then
    row result=disabled
    exit 0
fi

# A release manager (HIMMEL_RELEASE_MANAGER=1, exported by its launch) owns no ticket: its doc
# is named for the ticket that planned it, and moving that ticket would misreport the work.
if [ "${HIMMEL_RELEASE_MANAGER:-0}" = 1 ]; then
    row result=skip rule=RM
    exit 0
fi

# The budget wraps the whole run in a re-exec, so one hung call cannot hold the
# caller (append-results, check-ci, merge-on-green) past it.
# shellcheck source=../../lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"
# A phase row is never row(): row() writes the run's own event, and a phase failure must not read as one.
phase_row() { status_event event=phase-label key="$KEY" ${PR:+"pr=$PR"} "$@"; }

if [ -z "${TICKET_STATUS_IN_BUDGET:-}" ] && [ -n "$_TIMEOUT_BIN" ]; then
    budget="${TICKET_STATUS_BUDGET:-20}"
    case "$budget" in ''|*[!0-9]*) budget=20 ;; esac
    t0=$(date +%s)
    rc=0
    if [ "$EVENT" = phase-label ]; then
        # the chief's form: one child, and its cut-off is a phase row, never a status miss
        TICKET_STATUS_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 "$budget" bash "${BASH_SOURCE[0]}" "$KEY" --event phase-label \
            ${HP:+--phase "$PHASE"} ${HA:+--after "$AFTER" --rule "$RULE"} \
            ${PR:+--pr "$PR"} ${REPO:+--repo "$REPO"} ${DOC:+--doc "$DOC"} || rc=$?
        case "$rc" in
            124|137)
                phase_row result=phase-miss stage=timeout
                warn "$KEY phase not written within ${budget}s" ;;
        esac
        exit 0
    fi
    # child 1, the status child, hands its rule to the wrapper through a file; with no file
    # (mktemp failed) the variable is set but empty, so the child neither writes one nor runs the phase step
    rulefile=$(mktemp "${TMPDIR:-/tmp}/ticket-status-rule.XXXXXX" 2>/dev/null) || rulefile=""  # swallow-ok: no rule file means no phase step, WARNed next
    [ -n "$rulefile" ] || echo "WARN worker-jira-status: cannot make the rule file; no phase step for $KEY (continuing; the worker is not blocked)" >&2
    TICKET_STATUS_RULE_FILE="$rulefile" TICKET_STATUS_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 "$budget" bash "${BASH_SOURCE[0]}" "$KEY" --event "$EVENT" \
        ${PR:+--pr "$PR"} ${HEAD:+--head "$HEAD"} ${REPO:+--repo "$REPO"} ${DOC:+--doc "$DOC"} ${RESUME:+--resume-brief "$RESUME"} || rc=$?
    case "$rc" in
        124|137)
            [ -z "$rulefile" ] || rm -f "$rulefile"
            row result=miss stage=timeout
            warn "$KEY not synced within ${budget}s" ;;
    esac
    # child 2, the phase child: only after child 1 returned, with the budget it left, and only for an event that can anchor
    prule=""
    [ -z "$rulefile" ] || { prule=$(cat "$rulefile"); rm -f "$rulefile"; }
    if [ -n "$prule" ] && { { [ "$EVENT" = live ] && [ -n "$DOC" ]; } || { [ "$EVENT" = merge ] && [ -n "$PR" ]; } || [ "$prule" = D5c ] || [ "$prule" = D0 ]; }; then
        pmin="${TICKET_STATUS_PHASE_MIN:-3}"
        case "$pmin" in ''|*[!0-9]*) pmin=3 ;; esac
        left=$((budget - ($(date +%s) - t0)))
        if [ "$left" -lt "$pmin" ] || [ "$left" -lt 1 ]; then
            phase_row result=phase-miss stage=budget
        else
            rc=0
            TICKET_STATUS_IN_BUDGET=1 "$_TIMEOUT_BIN" -k 2 "$left" bash "${BASH_SOURCE[0]}" "$KEY" --event phase-label --after "$EVENT" --rule "$prule" \
                ${PR:+--pr "$PR"} ${DOC:+--doc "$DOC"} || rc=$?
            case "$rc" in
                124|137)
                    phase_row result=phase-miss stage=timeout
                    echo "WARN worker-jira-status: $KEY phase not written within ${left}s (continuing; the worker is not blocked)" >&2 ;;
            esac
        fi
    fi
    exit 0
fi

miss() { row result=miss rule="${TS_RULE:-}" stage="$1" from="${TS_J_STATUS:-}"; warn "$KEY not synced (stage $1)"; }

lockdir="$(ts_state_dir)/status-locks"
mkdir -p "$lockdir" 2>/dev/null || warn "cannot create $lockdir"
# ponytail: no flock binary (stock macOS) takes a mkdir lease for the key; it
# expires after 300s even for a live owner; upgrade path = a heartbeat.
# lease is script-level, not local: the EXIT trap runs after take_key_lease has returned.
lease="$lockdir/$KEY.lease.d"
take_key_lease() {
    local limit="${TICKET_STATUS_LOCK_WAIT:-10}" waited=0 stamp got=0 reclaim="$lockdir/$KEY.reclaim.d"
    # ponytail: the reclaim mutex is a mkdir held for microseconds; a process killed inside it leaves
    # it behind for good. upgrade path = the owner-token lease of pr-stall.sh.
    while [ "$got" = 0 ]; do
        if mkdir "$lease" 2>/dev/null; then got=1; break; fi # prim-ok: this no-flock lease spans the whole event, not one with_lock command
        # Reclaim under a mutex: check, rmdir and re-take happen as one step, so a second reclaimer
        # never removes the lease a first one just took.
        if mkdir "$reclaim" 2>/dev/null; then # prim-ok: the reclaim mutex covers the lease check only
            stamp=$(stat -c %Y "$lease" 2>/dev/null || stat -f %m "$lease" 2>/dev/null) || stamp=0
            if [ $(( $(date +%s) - stamp )) -ge 300 ]; then
                rmdir "$lease" 2>/dev/null && mkdir "$lease" 2>/dev/null && got=1
            fi
            rmdir "$reclaim" 2>/dev/null || :
            [ "$got" = 0 ] || break
        fi
        [ "$waited" -lt "$limit" ] || return 1
        sleep 1; waited=$((waited + 1))
    done
    trap 'rmdir "$lease" 2>/dev/null || :' EXIT
}
lock_miss() { # in phase-label mode a lock miss is a phase row, never a status-shaped deferred
    if [ "$EVENT" = phase-label ]; then phase_row result=phase-miss stage=lock; else row result=deferred stage=lock; fi
}
if command -v flock >/dev/null 2>&1; then
    exec 9>>"$lockdir/$KEY" || warn "cannot open the $KEY status lock"
    if ! flock -w "${TICKET_STATUS_LOCK_WAIT:-10}" 9; then # prim-ok: a bounded wait that logs deferred; with_lock has no deadline
        lock_miss
        exit 0
    fi
else
    take_key_lease || { lock_miss; exit 0; }
fi

# The phase label is moved by its own mode (after the lock, before any derive or record write), so a
# chief's backfill call never moves a status and never touches the worker record.
phase_furthest() { # <space-joined phase names> - the furthest one the funnel knows, else empty
    local want="" p
    for p in design ready build sliced last-step; do
        case " $1 " in *" $p "*) want=$p ;; esac
    done
    printf '%s' "$want"
}

# phase_next <anchor> <remainder> <status category> <p0> - PH_NEXT is the phase to hold (none = no label), empty = no write
phase_next() {
    local f
    PH_NEXT=""
    if [ "$3" = "done" ]; then PH_NEXT=none; return 0; fi
    f=$(phase_furthest "$4")
    case "$1" in
        chief) PH_NEXT=$PHASE ;;
        design-leg) PH_NEXT=${f:-design} ;;
        build-leg) case "$f" in build|sliced|last-step) PH_NEXT=$f ;; *) PH_NEXT=build ;; esac ;;
        merge-partial) case "$2" in owed|handed-off) PH_NEXT=last-step ;; *) PH_NEXT=sliced ;; esac ;;
        partial-seen) case "$f" in sliced|last-step) PH_NEXT=$f ;; *) PH_NEXT=sliced ;; esac ;;
    esac
    return 0
}

# phase_step - move the ticket's one phase label to the phase the event anchors, or leave it. The first
# anchor that matches wins; no anchor reads nothing and writes nothing. Never fails the funnel: a miss is a
# WARN and one phase-miss row.
phase_step() {
    local contract ev="${AFTER:-$EVENT}" rule="${RULE:-${TS_RULE:-}}" anchor="" remainder="" kind mrow json p0 cat out log
    if [ "$EVENT" = phase-label ] && [ -n "$HP" ]; then
        anchor=chief
    elif [ "$ev" = live ] && [ -n "$DOC" ] && [ -f "$DOC" ]; then
        kind=$(sed -nE '/^## Results/q; s/^> \*\*Leg kind:\*\* (design|build)[[:space:]]*$/\1/p' "$DOC" | head -n 1)
        [ -z "$kind" ] || anchor="$kind-leg"
    fi
    if [ -z "$anchor" ] && [ "$ev" = merge ] && [ -n "$PR" ]; then
        log="$(ts_state_dir)/status-events.jsonl"
        mrow=$(grep -F "\"key\":\"$KEY\"" "$log" 2>/dev/null | jq -c --arg p "$PR" 'select(.event == "merge" and .pr == $p and has("contract"))' | tail -n 1)  # swallow-ok: no log or no merge row is no anchor
        if [ -n "$mrow" ]; then
            contract=$(jq -r '.contract // ""' <<<"$mrow")
            if [ "$contract" = no ]; then
                anchor=merge-partial
                remainder=$(jq -r '.remainder // ""' <<<"$mrow")
            fi
        fi
    fi
    if [ -z "$anchor" ]; then
        case "$rule" in D5c) anchor=partial-seen ;; D0) anchor=maybe-closed ;; esac
    fi
    [ -n "$anchor" ] || return 0
    json=$(ts_jira get "$KEY" --json 2>/dev/null) || json=""  # swallow-ok: an unread ticket is one phase-miss stage=get row below
    p0="" cat=""
    if [ -n "$json" ]; then
        p0=$(jq -r '[.fields.labels[]? | select(type == "string" and startswith("phase:")) | .[6:]] | join(" ")' <<<"$json" 2>/dev/null) || json=""  # swallow-ok: an unparsable ticket is the same stage=get miss
        cat=$(jq -r '.fields.status.statusCategory.key // ""' <<<"$json" 2>/dev/null) || json=""  # swallow-ok: an unparsable ticket is the same stage=get miss
    fi
    if [ -z "$json" ]; then
        phase_row result=phase-miss stage=get
        echo "WARN worker-jira-status: $KEY phase not read (continuing; the worker is not blocked)" >&2
        return 0
    fi
    if [ "$anchor" = maybe-closed ] && [ "$cat" != "done" ]; then return 0; fi
    phase_next "$anchor" "$remainder" "$cat" "$p0"
    [ -n "$PH_NEXT" ] || return 0
    if [ "$PH_NEXT" = none ]; then [ -n "$p0" ] || return 0; else [ "$p0" != "$PH_NEXT" ] || return 0; fi
    if out=$(ts_jira edit "$KEY" --phase "$PH_NEXT" 2>&1); then
        phase_row result=phase-set from="${p0// /+}" to="$PH_NEXT" cause="$anchor"
    else
        phase_row result=phase-miss stage=edit to="$PH_NEXT"
        echo "WARN worker-jira-status: $KEY phase '$PH_NEXT' not written: $(printf '%s' "$out" | tr '\n' ' ') (continuing; the worker is not blocked)" >&2
    fi
    return 0
}

if [ "$EVENT" = phase-label ]; then
    phase_step
    exit 0
fi

# An event that names the owner's doc or resume brief records it first, so the
# derive sees the key as owned.
if [ -n "$DOC$RESUME" ] && ts_record_read "$KEY"; then
    worker=""
    [[ "${DOC##*/}" =~ ^$KEY-(N[0-9]+)- ]] && worker="${BASH_REMATCH[1]}"
    rec=$(jq -c --arg k "$KEY" --arg d "$DOC" --arg l "$worker" --arg rb "$RESUME" '
        .key = $k
        | if $d != "" then .docs = ((.docs // []) + [.doc // empty, $d] | unique) | .doc = $d else . end
        | if $l != "" then .leg = $l else . end
        | if $rb != "" then .resume_brief = $rb else . end' <<<"$TS_REC") \
        && ts_record_write "$KEY" "$rec" || echo "WARN worker-jira-status: cannot record the $KEY owner" >&2
fi

update_record() { # <Jira status now> [the move, "<from> -> <to>"]
    local rec cid chash ol=""
    ts_record_read "$KEY" || return 0
    # The record and the WORKER comment follow the worker that still holds the key.
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
    ts_record_write "$KEY" "$rec" || echo "WARN worker-jira-status: cannot write the $KEY worker record" >&2
}

# A Done ticket is never moved, but its worker record still follows the doc/lock,
# so a worker that wrapped after the merge does not read live forever.
refresh_done_record() {
    local doc rec
    ts_record_read "$KEY" || return 0
    doc=$(jq -r '.doc // ""' <<<"$TS_REC")
    [ -n "$doc" ] || return 0
    _ts_worker_state "$doc"
    [ "$(jq -r '.state // ""' <<<"$TS_REC")" != "$TS_WORKER_STATE" ] || return 0
    rec=$(jq -c --arg ev "$EVENT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ws "$TS_WORKER_STATE" \
        '.last_event = $ev | .last_event_ts = $ts | .state = $ws' <<<"$TS_REC") || return 0
    ts_record_write "$KEY" "$rec" || echo "WARN worker-jira-status: cannot write the $KEY worker record" >&2
}

# A moved status leaves the chief's FOCUS page behind: mark it dirty so the
# waiter's next tick rebuilds it. HIMMEL_CONSOLE_DOC names the chief doc (unset:
# nothing to mark). The mark is written here as focus-refresh.sh --mark-dirty
# writes it (dirty=<epoch> in focus-state, plus focus-state.again), so this
# script runs no unguarded code. A failed mark never fails the move.
mark_focus_dirty() {
    [ -n "${HIMMEL_CONSOLE_DOC:-}" ] || return 0
    local st; st="$(dirname "$HIMMEL_CONSOLE_DOC")/focus-state"
    { [ -f "$HIMMEL_CONSOLE_DOC" ] \
        && { grep -q '^dirty=.' "$st" \
            || { { grep -v '^dirty=' "$st"; echo "dirty=$(date +%s)"; } > "$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"; }; } \
        && date +%s > "$st.again"; } 2>/dev/null \
        || echo "WARN worker-jira-status: cannot mark the FOCUS page dirty (continuing; the move stands)" >&2
}

# A worked ticket that sits in a later version than the current one (the earliest unreleased,
# unarchived by date) gets one INTAKE request into the current version, so it folds in by the
# release manager's ruling and not by hand. A stamp per key keeps a later LIVE bullet from
# asking again; the request itself is deduplicated by the CLI. Best-effort, never blocks.
# ponytail: the release is named after the version, upgrade path = a release lookup in the CLI
# once a release declares several versions.
intake_to_current() {
    local json vers cur from out stamp="$lockdir/$KEY.intake"
    [ ! -e "$stamp" ] || return 0
    json=$(ts_jira get "$KEY" --json 2>/dev/null) || return 0  # swallow-ok: an unread ticket files no request
    vers=$(ts_jira versions --project "${KEY%%-*}" 2>/dev/null) || return 0  # swallow-ok: an unread version list files no request
    cur=$(printf '%s\n' "$vers" | awk -F'\t' '$2 == "false" && $4 != "true" { print ($3 == "" ? "9999-99-99" : $3) "\t" $1 }' | sort | head -n 1 | cut -f2)
    [ -n "$cur" ] || return 0
    ! jq -e --arg c "$cur" '[.fields.fixVersions[]?.name] | index($c) != null' <<<"$json" >/dev/null 2>&1 || return 0
    from=$(jq -r '.fields.fixVersions[]?.name' <<<"$json" 2>/dev/null | while IFS= read -r n; do
        [ "$n" != "$cur" ] && printf '%s\n' "$vers" | awk -F'\t' -v n="$n" '$1 == n && $2 == "false" && $4 != "true" { f = 1 } END { exit !f }' && { printf '%s\n' "$n"; break; }
    done)
    [ -n "$from" ] || return 0
    if out=$(ts_jira release request "$cur" --verb INTAKE --key "$KEY" --from "$from" --to "$cur" \
        --why "the ticket is worked, so it folds from $from into the current $cur" \
        --evidence "{\"event\":\"$EVENT\"}" 2>&1) && [[ "$out" == *"REQ "* ]]; then
        : > "$stamp" 2>/dev/null
        row result=intake rule=INTAKE from="$from" to="$cur"
    else
        echo "WARN worker-jira-status: $KEY sits in $from, later than the current $cur; the INTAKE request was NOT filed: $(printf '%s' "$out" | tr '\n' ' ')" >&2
    fi
}
# finish: the INTAKE request first, then the phase. A wrapper (TICKET_STATUS_RULE_FILE set, maybe empty)
# runs the phase step as its own child from the rule written here; with no wrapper (no timeout binary)
# the step runs in this process.
finish() {
    [ "$EVENT" != live ] || intake_to_current
    if [ -n "${TICKET_STATUS_RULE_FILE+x}" ]; then
        [ -z "$TICKET_STATUS_RULE_FILE" ] || printf '%s' "${TS_RULE:-}" > "$TICKET_STATUS_RULE_FILE" 2>/dev/null || :
    else
        phase_step
    fi
    exit 0
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
        finish
    fi
    # A D5c found through a merged PR with no merge row names that PR in its row, so a later
    # derive answers D5c from the log with no gh call. No other rule's row changes.
    mnr_stage="" mnr_pr=""
    if [ "$TS_RULE" = D5c ] && [ "$TS_STAGE" = merged-no-row ]; then mnr_stage=merged-no-row mnr_pr=$TS_MERGED_PR; fi
    if [ "$TS_DERIVED" = "$TS_J_STATUS" ]; then
        update_record "$TS_J_STATUS"
        row result=noop rule="$TS_RULE" from="$TS_J_STATUS" ${mnr_stage:+stage="$mnr_stage"} ${mnr_pr:+merged_pr="$mnr_pr"}
        finish
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
row result=moved rule="$TS_RULE" from="$from" to="$to" dir="$dir" ${mnr_stage:+stage="$mnr_stage"} ${mnr_pr:+merged_pr="$mnr_pr"}
mark_focus_dirty
echo "worker-jira-status: $KEY $from -> $to ($TS_RULE)"
finish
