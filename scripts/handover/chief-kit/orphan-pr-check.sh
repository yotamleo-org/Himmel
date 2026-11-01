#!/usr/bin/env bash
# orphan-pr-check.sh — every open PR must be owned: its ticket's worker record must not read
# wrapped or none, or the chief doc's `queue:` line must name the PR.
#
#   orphan-pr-check.sh --doc <chief doc> [--repo <path>]
#
# Prints `UNMAPPED <n> <head branch>` per unowned open PR, and exits 1.
# The open PRs come from `gh pr list` (drafts included), never from a record's open flags:
# nothing clears those after a merge. Left out: fork PRs, and Dependabot's (an author
# containing "dependabot", or a dependabot/ branch), which the Dependabot sweep owns.
# The ticket is the first key in the head branch name; a branch that names none is unowned.
# The record is <state dir>/workers/<KEY>.json (the one writer is the worker-jira-status funnel).
# A PR is unowned when its record state is wrapped or none, or the ticket has no record; every
# other state (live, idle, IDLE-HELD, parked, unknown) still owns it. A PR also counts as held
# when the doc's Live state `queue:` line names its number (`#<n>` or `<n>`) or its ticket key.
#
# The PR set is `gh pr list --state open --json number,headRefName,isCrossRepository,author` run in
# <repo> (default: this checkout). Seams (tests): ORPHAN_PR_CHECK_PRS = a file holding that JSON,
# TICKET_STATUS_STATE_DIR = the state dir. An unreadable or malformed PR list is neither an orphan
# nor an all-clear: it prints `orphan-pr-check: unavailable ...` on stderr and exits 3 (chief.sh
# refuses only on 1; the waiter clears its marker only on 0). A record that does not parse
# cannot show its PR unowned, so it owns it.
#
# Exit: 0 every PR owned; 1 at least one orphan; 2 usage; 3 unavailable.
# PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
# ponytail: ownership is the ticket key in the branch name (as tick.sh's unowned-prs= does) and the
# record's derived state; upgrade = a held-label read through ticket-hold.sh once holds are labels.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DEFAULT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/ticket-status.sh
. "$HERE/../../lib/ticket-status.sh"

usage() { echo "usage: orphan-pr-check.sh --doc <chief doc> [--repo <path>]" >&2; exit 2; }
doc=""; repo="$REPO_DEFAULT"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$doc" ] || usage

unavailable() { echo "orphan-pr-check: unavailable ($1)" >&2; exit 3; }
if [ -n "${ORPHAN_PR_CHECK_PRS:-}" ]; then
    prs_json="$(cat "$ORPHAN_PR_CHECK_PRS" 2>/dev/null)" || prs_json=""  # read-sink-ok: a test seam for the gh output, parsed as JSON and never used as a prompt; swallow-ok: an empty read exits as unavailable below, never as an orphan
else
    prs_json="$(cd "$repo" 2>/dev/null && timeout -k 2 30 gh pr list --state open --limit 1000 --json number,headRefName,isCrossRepository,author 2>/dev/null)" || prs_json=""  # gnu-ok: Linux-only kit; swallow-ok: an empty read exits as unavailable below, never as an orphan
fi
[ -n "$prs_json" ] || unavailable "the open-PR list could not be read"
printf '%s\n' "$prs_json" | jq -e 'type == "array" and all(.[]; type == "object" and (.number | type == "number") and (.headRefName | type == "string"))' >/dev/null 2>&1 \
    || unavailable "the open-PR list is not an array of PRs"  # swallow-ok: a malformed list exits as unavailable, never as an orphan
rows="$(printf '%s\n' "$prs_json" | jq -r '.[] | select((.isCrossRepository? // false) == true | not) | select((((.author? | .login?) // "") | tostring | test("dependabot"; "i") | not) and (.headRefName | startswith("dependabot/") | not)) | "\(.number)\t\(.headRefName)"' 2>/dev/null)" || unavailable "the open-PR list could not be filtered"  # swallow-ok: a filter failure exits as unavailable, never as an all-clear
[ -n "$rows" ] || exit 0

ticket_key() { printf '%s\n' "$1" | grep -oiE '[a-z][a-z0-9]*-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]'; }

[ -r "$doc" ] || unavailable "the chief doc could not be read"
queue_line="$(awk '
    $0 == "## Live state" { s = 1; next }
    s && /^## / { exit }
    s && index($0, "queue:") == 1 { print; exit }
' "$doc" 2>/dev/null)" || unavailable "the chief doc's queue: line could not be read"  # swallow-ok: a read failure exits as unavailable, never as an empty queue

owned_by_record() { # <KEY> — rc 0 when its worker record reads a state other than wrapped or none
    local rec_state
    [ -e "$(ts_record_path "$1")" ] || return 1
    ts_record_read "$1" || return 0  # an unparsable record cannot show the PR unowned
    rec_state="$(printf '%s\n' "$TS_REC" | jq -r '.state // "none"' 2>/dev/null)" || return 0  # swallow-ok: an unreadable state cannot show the PR unowned
    case "$rec_state" in wrapped|none) return 1 ;; esac
    return 0
}

orphans=0
while IFS="$(printf '\t')" read -r n branch; do
    [ -n "$n" ] || continue
    key="$(ticket_key "$branch")"
    if [ -n "$key" ] && owned_by_record "$key"; then continue; fi
    if grep -qE "(^|[^0-9A-Za-z-])#?$n([^0-9]|\$)" <<< "$queue_line"; then continue; fi
    if [ -n "$key" ] && grep -qiE "(^|[^A-Za-z0-9])$key([^0-9]|\$)" <<< "$queue_line"; then continue; fi
    printf 'UNMAPPED %s %s\n' "$n" "$branch"
    orphans=$((orphans + 1))
done <<EOF_ROWS
$rows
EOF_ROWS
[ "$orphans" -eq 0 ] || exit 1
exit 0
