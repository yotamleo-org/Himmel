#!/usr/bin/env bash
# scripts/handover/chief-kit/ticket-hold.sh - put a ticket on hold, or release
# it. A hold is the Jira label `held`, not a status: the derive ignores it, the
# dispatcher (next-dispatchable.sh) excludes it and the FOCUS page shows the
# chain step as `held`.
#
# Usage: ticket-hold.sh <KEY> --reason <text> --owner <who> [--until <YYYY-MM-DD>]
#                      [--kind chain-order|gate|file-collision|operator|date] [--on <KEY>] [--thread <id>]
#        ticket-hold.sh <KEY> --release [--owner <who>]
#        ticket-hold.sh <KEY> --release --cloud-session <session_id> --reason <text> --owner <who>
#   The last form takes a cloud-owned ticket over: it writes one cloud-takeover row to status-events.jsonl and makes no
#   Jira call; the dispatcher then stops counting that session as the key's owner. Nothing calls it automatically.
#   --owner is chief, operator or a lowercase name (a-z, 0-9, -; at most 32); --until must be a real date.
#   The hold row records owner, reason and any until (nothing releases the hold on it; the Chains tab reads a
#   date hold as date-gated until then); status-drift.sh flags a started ticket that is still held as stuck
#   whatever the date; --kind date needs it.
#   --kind and --on (the ticket it waits on) go into the HOLD comment and the event row;
#   with --kind, so does --until.
#   --thread is the threadId (scripts/t3/thread-list.sh) of the T3 thread that owns the ticket; it goes into the
#   HOLD comment and the event row, and status-drift.sh counts the thread as a live owner while it is not settled
#   (a settled thread, one the list lacks or an unreadable list is stuck). Not with --release.
#
# A hold on an In Progress ticket also moves it to To Do (a held ticket is not In Progress); a failed move
# warns and appends an `audit-gap` row (stage transition), and the hold stands.
# Hold = `jira edit --add-labels held`, the label read back, then one HOLD
# comment naming the reason, owner and date. Release = `--remove-labels held`,
# the label read back absent, then a HOLD comment saying so. A label that does
# not read back is exit 1 with a `miss` row (stage edit | readback); a failed
# HOLD comment leaves the label standing, warns, and appends an `audit-gap` row.
# Every outcome appends one row to status-events.jsonl (event hold | hold-release).
# A hold set with --kind or --on, and every release, also appends one row to the
# append-only chain-log.jsonl beside it (change hold | release): chain-state.mjs reads
# it for the Chains tab and the order check (board v4 ruling L4).
#
#
# Platform guard: POSIX bash 3.2+ (shell-only harness).
set -u

usage() {
    echo "usage: ticket-hold.sh <KEY> --reason <text> --owner <who> [--until <YYYY-MM-DD>] [--kind <kind>] [--on <KEY>] [--thread <id>]" >&2
    echo "       kind: chain-order | gate | file-collision | operator | date" >&2
    echo "       ticket-hold.sh <KEY> --release [--owner <who>]" >&2
    echo "       ticket-hold.sh <KEY> --release --cloud-session <session_id> --reason <text> --owner <who>" >&2
    exit 2
}
[ "$#" -ge 2 ] || usage
KEY="$1"
shift
REASON="" OWNER="" UNTIL="" KIND="" ON="" THREAD="" RELEASE=0 CLOUD="" CLOUD_SET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) RELEASE=1; shift ;;
        --reason | --owner | --until | --kind | --on | --thread | --cloud-session)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --cloud-session) CLOUD="$2"; CLOUD_SET=1 ;;
                --reason) REASON="$2" ;;
                --owner) OWNER="$2" ;;
                --until) UNTIL="$2" ;;
                --kind) KIND="$2" ;;
                --on) ON="$2" ;;
                --thread) THREAD="$2" ;;
            esac
            shift 2 ;;
        *) usage ;;
    esac
done
[[ "$KEY" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || usage
if [ "$RELEASE" -eq 0 ]; then
    [ -n "$REASON" ] && [ -n "$OWNER" ] || usage
elif [ "$CLOUD_SET" -eq 1 ]; then
    [ -n "$REASON" ] && [ -n "$OWNER" ] || usage
    [ -z "$UNTIL$KIND$ON$THREAD" ] || usage
    [[ "$CLOUD" =~ ^session_[A-Za-z0-9]+$ ]] || usage
else
    [ -z "$REASON$UNTIL$KIND$ON$THREAD" ] || usage
fi
[ "$CLOUD_SET" -eq 0 ] || [ "$RELEASE" -eq 1 ] || usage
case "$KIND" in "" | chain-order | gate | file-collision | operator | date) ;; *) usage ;; esac
[ "$KIND" != date ] || [ -n "$UNTIL" ] || usage
[ -z "$ON" ] || [[ "$ON" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || usage
[ -z "$THREAD" ] || [[ "$THREAD" =~ ^[A-Za-z0-9][A-Za-z0-9:_.-]{0,95}$ ]] || usage
if [ -n "$OWNER" ]; then
    [[ "$OWNER" =~ ^(chief|operator|[a-z][a-z0-9-]{0,31})$ ]] || usage
fi
if [ -n "$UNTIL" ]; then
    [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    e=$(date -u -d "$UNTIL" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$UNTIL" +%s 2>/dev/null) || usage # swallow-ok: the BSD form follows
    [ "$(date -u -d "@$e" +%Y-%m-%d 2>/dev/null || date -u -r "$e" +%Y-%m-%d 2>/dev/null)" = "$UNTIL" ] || usage # swallow-ok: the BSD form follows
fi
command -v jq >/dev/null 2>&1 || { echo "ticket-hold: jq not found" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/ticket-status.sh"

if [ "$CLOUD_SET" -eq 1 ]; then
    takeover_err=$(status_event event=cloud-takeover key="$KEY" session="$CLOUD" owner="$OWNER" reason="$(printf '%s' "$REASON" | tr -d '|\t\r\n')" result=done 2>&1 >/dev/null)
    case "$takeover_err" in
        *status-log-unwritable*)
            echo "ticket-hold: $KEY: the takeover row was not written" >&2
            exit 1 ;;
    esac
    echo "ticket-hold: $KEY: cloud session $CLOUD taken over"
    exit 0
fi

if [ "$RELEASE" -eq 1 ]; then
    EVENT=hold-release FLAG=--remove-labels
else
    EVENT=hold FLAG=--add-labels
fi

ROWREASON=$(printf '%s' "$REASON" | tr -d '|\t\r\n')
row() { status_event event="$EVENT" key="$KEY" ${OWNER:+owner="$OWNER"} ${REASON:+reason="$ROWREASON"} ${KIND:+kind="$KIND"} ${ON:+on="$ON"} ${THREAD:+thread="$THREAD"} ${UNTIL:+until="$UNTIL"} "$@"; }

# chain_log <k=v>... - one row in chain-log.jsonl, beside status-events.jsonl.
chain_log() {
    # shellcheck disable=SC2016  # $ts and $<k> are jq variables
    local kv k line log obj='{ts:$ts'
    local args=(--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    for kv in "$@"; do
        k=${kv%%=*}
        args+=(--arg "$k" "${kv#*=}")
        obj="$obj,$k:\$$k"
    done
    log="$(ts_state_dir)/chain-log.jsonl"
    if ! line=$(jq -nc "${args[@]}" "$obj}") || ! printf '%s\n' "$line" >> "$log" 2>/dev/null; then
        echo "WARN chain-log-unwritable: $log" >&2
    fi
}

if ! ts_jira edit "$KEY" "$FLAG" held >/dev/null 2>&1; then
    row result=miss stage=edit
    echo "ticket-hold: $KEY: the label edit failed" >&2
    exit 1
fi

# swallow-ok: an unreadable ticket fails the read-back below as result=miss
json=$(ts_jira get "$KEY" --json 2>/dev/null) || json=""
if [ "$RELEASE" -eq 1 ]; then
    jqf='(.fields.labels | type == "array") and (.fields.labels | index("held") == null)'
else
    jqf='(.fields.labels | type == "array") and (.fields.labels | index("held") != null)'
fi
# swallow-ok: anything but a literal true is the miss branch
if [ "$(jq -r "$jqf" <<<"$json" 2>/dev/null)" != true ]; then
    row result=miss stage=readback
    echo "ticket-hold: $KEY: the held label did not read back" >&2
    exit 1
fi

FROMST="" MOVEFAIL=0
if [ "$RELEASE" -eq 0 ]; then
    # swallow-ok: an unreadable status is not In Progress, so the ticket is left as it is
    st=$(jq -r '.fields.status.name // ""' <<<"$json" 2>/dev/null)
    if [ "$st" = "In Progress" ]; then
        # swallow-ok: an unreadable status after the move is no proof it moved
        if ts_jira transition "$KEY" "To Do" >/dev/null 2>&1 && [ "$(ts_jira get "$KEY" --json 2>/dev/null | jq -r '.fields.status.name // ""' 2>/dev/null)" = "To Do" ]; then FROMST=$st; else MOVEFAIL=1; fi
    fi
fi
row result=moved ${FROMST:+from="$FROMST" to="To Do"}
if [ "$MOVEFAIL" -eq 1 ]; then
    status_event event=audit-gap key="$KEY" result=miss stage=transition action="$EVENT"
    echo "ticket-hold: $KEY: the move to To Do failed; the ticket stays In Progress (the label stands)" >&2
fi
if [ "$RELEASE" -eq 1 ]; then
    chain_log change=release key="$KEY" ${OWNER:+who="$OWNER"}
elif [ -n "$KIND$ON" ]; then
    chain_log change=hold key="$KEY" ${KIND:+kind="$KIND"} ${ON:+on="$ON"} who="$OWNER" reason="$REASON" ${UNTIL:+until="$UNTIL"}
fi
if ! body=$(mktemp "${TMPDIR:-/tmp}/ticket-hold.XXXXXX"); then
    status_event event=audit-gap key="$KEY" result=miss stage=comment action="$EVENT"
    echo "ticket-hold: $KEY: audit-gap: no temp file for the HOLD comment (the label stands)" >&2
    exit 0
fi
if [ "$RELEASE" -eq 1 ]; then
    printf 'HOLD released%s\n' "${OWNER:+ by $OWNER}" > "$body"
else
    printf 'HOLD: %s\n\nowner: %s\nuntil: %s (advisory)\n' "$REASON" "$OWNER" "${UNTIL:-none}" > "$body"
    [ -z "$KIND" ] || printf 'kind: %s\n' "$KIND" >> "$body"
    [ -z "$ON" ] || printf 'on: %s\n' "$ON" >> "$body"
    [ -z "$THREAD" ] || printf 'thread: %s\n' "$THREAD" >> "$body"
    [ -z "$FROMST" ] || printf 'status: moved to To Do (a held ticket is not In Progress); release the hold to restart it\n' >> "$body"
fi
if ! ts_jira comment "$KEY" --comment-file "$body" >/dev/null 2>&1; then
    status_event event=audit-gap key="$KEY" result=miss stage=comment action="$EVENT"
    echo "ticket-hold: $KEY: audit-gap: the HOLD comment was not posted (the label stands)" >&2
fi
rm -f "$body"
exit 0
