#!/usr/bin/env bash
# scripts/handover/console-kit/ticket-hold.sh - put a ticket on hold, or release
# it. A hold is the Jira label `held`, not a status: the derive ignores it, the
# dispatcher (next-dispatchable.sh) excludes it and the FOCUS page shows the
# chain step as `held`.
#
# Usage: ticket-hold.sh <KEY> --reason <text> --owner <who> [--until <YYYY-MM-DD>]
#        ticket-hold.sh <KEY> --release [--owner <who>]
#   --until is advisory: nothing releases a hold on that date.
#
# Hold = `jira edit --add-labels held`, the label read back, then one HOLD
# comment naming the reason, owner and date. Release = `--remove-labels held`,
# the label read back absent, then a HOLD comment saying so. A label that does
# not read back is exit 1 with a `miss` row (stage edit | readback); a failed
# HOLD comment leaves the label standing, warns, and appends an `audit-gap` row.
# Every outcome appends one row to status-events.jsonl (event hold | hold-release).
#
# ponytail: the Jira calls run unbounded, upgrade path = the re-exec under a
# timeout that leg-jira-status.sh uses.
#
# Platform guard: POSIX bash 3.2+, no .ps1 twin by design (shell-only harness).
set -u

usage() {
    echo "usage: ticket-hold.sh <KEY> --reason <text> --owner <who> [--until <YYYY-MM-DD>]" >&2
    echo "       ticket-hold.sh <KEY> --release [--owner <who>]" >&2
    exit 2
}
[ "$#" -ge 2 ] || usage
KEY="$1"
shift
REASON="" OWNER="" UNTIL="" RELEASE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) RELEASE=1; shift ;;
        --reason | --owner | --until)
            [ "$#" -ge 2 ] || usage
            case "$1" in
                --reason) REASON="$2" ;;
                --owner) OWNER="$2" ;;
                --until) UNTIL="$2" ;;
            esac
            shift 2 ;;
        *) usage ;;
    esac
done
[[ "$KEY" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || usage
if [ "$RELEASE" -eq 0 ]; then
    [ -n "$REASON" ] && [ -n "$OWNER" ] || usage
else
    [ -z "$REASON$UNTIL" ] || usage
fi
if [ -n "$UNTIL" ]; then
    [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
fi
command -v jq >/dev/null 2>&1 || { echo "ticket-hold: jq not found" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ticket-status.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/ticket-status.sh"

if [ "$RELEASE" -eq 1 ]; then
    EVENT=hold-release FLAG=--remove-labels
else
    EVENT=hold FLAG=--add-labels
fi

row() { status_event event="$EVENT" key="$KEY" "$@"; }

if ! ts_jira edit "$KEY" "$FLAG" held >/dev/null 2>&1; then
    row result=miss stage=edit
    echo "ticket-hold: $KEY: the label edit failed" >&2
    exit 1
fi

# swallow-ok: an unreadable ticket fails the read-back below as result=miss
json=$(ts_jira get "$KEY" --json 2>/dev/null) || json=""
if [ "$RELEASE" -eq 1 ]; then
    jqf='(.fields.labels // []) | index("held") == null'
else
    jqf='(.fields.labels // []) | index("held") != null'
fi
# swallow-ok: anything but a literal true is the miss branch
if [ "$(jq -r "$jqf" <<<"$json" 2>/dev/null)" != true ]; then
    row result=miss stage=readback
    echo "ticket-hold: $KEY: the held label did not read back" >&2
    exit 1
fi

row result=moved
if ! body=$(mktemp "${TMPDIR:-/tmp}/ticket-hold.XXXXXX"); then
    status_event event=audit-gap key="$KEY" result=miss stage=comment action="$EVENT"
    echo "ticket-hold: $KEY: audit-gap: no temp file for the HOLD comment (the label stands)" >&2
    exit 0
fi
if [ "$RELEASE" -eq 1 ]; then
    printf 'HOLD released%s\n' "${OWNER:+ by $OWNER}" > "$body"
else
    printf 'HOLD: %s\n\nowner: %s\nuntil: %s (advisory)\n' "$REASON" "$OWNER" "${UNTIL:-none}" > "$body"
fi
if ! ts_jira comment "$KEY" --comment-file "$body" >/dev/null 2>&1; then
    status_event event=audit-gap key="$KEY" result=miss stage=comment action="$EVENT"
    echo "ticket-hold: $KEY: audit-gap: the HOLD comment was not posted (the label stands)" >&2
fi
rm -f "$body"
exit 0
