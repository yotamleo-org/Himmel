#!/usr/bin/env bash
# orphan-pr-check.sh — every open PR must be owned: its ticket's worker record must not read
# wrapped or none, or the chief doc's `queue:` line must name the PR.
#
#   orphan-pr-check.sh [--held | --gone-held] --doc <chief doc> [--repo <path>]
#
# Prints `UNMAPPED <n> <head branch>` per unowned open PR, and exits 1.
# --held prints the doc's HELD queue: entries and reads no PR list: one tab-separated line each,
# `<subject> <trigger|-> <resume doc|-> <names> <segment>` (subject `#<n>`, else `<n>`, else the first key,
# else -; names = the numbers and upper-cased keys before the hold word, comma-joined). tick.sh reads this.
# --gone-held prints, verbatim, each HELD segment with a trigger and a resume doc whose subject is a PR
# number and none of whose named numbers is an open PR (merged or closed); chief.sh next drops those.
# A HELD segment without both, or naming any open PR, is kept. Both exit 3 on an unreadable doc, --gone-held on an unreadable list.
# The open PRs come from `gh pr list` (drafts included), never from a record's open flags:
# nothing clears those after a merge. Left out: fork PRs, and Dependabot's (an author
# containing "dependabot", or a dependabot/ branch), which the Dependabot sweep owns.
# The ticket is the first key in the head branch name; a branch that names none is unowned.
# The record is <state dir>/workers/<KEY>.json (the one writer is the worker-jira-status funnel).
# A PR is unowned when its record state is wrapped or none, or the ticket has no record; every
# other state (live, idle, IDLE-HELD, parked, unknown) still owns it. A PR also counts as held
# when a HELD entry of the doc's Live state `queue:` line names its number (`#<n>` or `<n>`) or its
# ticket key before the hold word AND carries a trigger and a resume doc. A HELD entry is a `|`
# segment before any `||` holding the word HELD or HOLD; its trigger is `wake=pr:<n>`,
# `wake=done:<KEY>` or `wake=file:<absolute path>`, its resume doc `resume=<absolute path>`. Only the
# names before the hold word are held: a blocker named after it, or in a wake= or resume= token, stays
# unowned. A HELD entry without both is unowned.
#
# The PR set is `gh pr list --state open --json number,headRefName,isCrossRepository,author` run in
# <repo> (default: this checkout). Seams (tests): ORPHAN_PR_CHECK_PRS = a file holding that JSON,
# TICKET_STATUS_STATE_DIR = the state dir. An unreadable or malformed PR list is neither an orphan
# nor an all-clear: it prints `orphan-pr-check: unavailable ...` on stderr and exits 3 (chief.sh
# refuses only on 1; the waiter clears its marker only on 0). So is a GitHub out: ts_scan_gate
# before the gh read prints its QUOTA-PAUSE or GH-STALL line on stderr. A record that does not parse
# cannot show its PR unowned, so it owns it.
#
# Exit: 0 every PR owned; 1 at least one orphan; 2 usage; 3 unavailable.
# PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DEFAULT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/ticket-status.sh
. "$HERE/../../lib/ticket-status.sh"
GH_READ_BIN="$HERE/../../lib/gh-read.sh"
[ -f "$GH_READ_BIN" ] || GH_READ_BIN=gh
if [ "$GH_READ_BIN" != gh ]; then
    # shellcheck source=../../lib/gh-read.sh
    . "$GH_READ_BIN"
    GH_READ_QUIET=1 gh_read_init
fi

usage() { echo "usage: orphan-pr-check.sh [--held | --gone-held] --doc <chief doc> [--repo <path>]" >&2; exit 2; }
doc=""; repo="$REPO_DEFAULT"; mode=check
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; doc="$2"; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --held) mode=held; shift ;;
        --gone-held) mode=gone; shift ;;
        *) usage ;;
    esac
done
[ -n "$doc" ] || usage

unavailable() { echo "orphan-pr-check: unavailable ($1)" >&2; exit 3; }

held_entries() {
    [ -r "$doc" ] || unavailable "the chief doc could not be read"
    awk '
        $0 == "## Live state" { s = 1; next }
        s && /^## / { exit }
        s && index($0, "queue:") == 1 {
            sub(/^queue:[ \t]*/, "")
            sub(/\|\|.*/, "")
            n = split($0, seg, "|")
            for (i = 1; i <= n; i++) {
                trig = "-"; res = "-"; rest = ""; names = ""; hashed = ""; num = ""; key = ""
                m = split(seg[i], tok, /[ \t]+/)
                for (j = 1; j <= m; j++) {
                    t = tok[j]
                    if (t ~ /^wake=/) {
                        if (trig == "-" && t ~ /^wake=(pr:[0-9]+|done:[A-Za-z][A-Za-z0-9]*-[0-9]+|file:\/[^,|]+)$/) trig = substr(t, 6)
                        if (trig ~ /^done:/) trig = "done:" toupper(substr(trig, 6))
                        continue
                    }
                    if (t ~ /^resume=/) {
                        if (res == "-" && t ~ /^resume=\/[^,|]+$/) res = substr(t, 8)
                        continue
                    }
                    rest = rest " " t
                }
                if (rest !~ /(^|[^A-Za-z0-9_])([Hh][Ee][Ll][Dd]|[Hh][Oo][Ll][Dd])([^A-Za-z0-9_]|$)/) continue
                k = split(rest, w, /[^A-Za-z0-9#-]+/)
                for (j = 1; j <= k; j++) {
                    x = w[j]
                    if (tolower(x) ~ /(^|-)(held|hold)(-|$)/) break
                    if (x ~ /^#?[0-9]+$/) {
                        if (substr(x, 1, 1) == "#") { x = substr(x, 2); if (hashed == "") hashed = x }
                        if (num == "") num = x
                    } else if (x ~ /^[A-Za-z][A-Za-z0-9]*-[0-9]+$/) {
                        x = toupper(x); if (key == "") key = x
                    } else continue
                    names = names (names == "" ? "" : ",") x
                }
                subj = hashed != "" ? "#" hashed : (num != "" ? num : (key != "" ? key : "-"))
                printf "%s\t%s\t%s\t%s\t%s\n", subj, trig, res, (names == "" ? "-" : names), seg[i]
            }
            exit
        }
    ' "$doc" 2>/dev/null || unavailable "the chief doc's queue: line could not be read"  # swallow-ok: a read failure exits as unavailable, never as an empty queue
}

if [ "$mode" = held ]; then
    held_entries
    exit 0
fi

if [ -n "${ORPHAN_PR_CHECK_PRS:-}" ]; then
    prs_json="$(cat "$ORPHAN_PR_CHECK_PRS" 2>/dev/null)" || prs_json=""  # read-sink-ok: a test seam for the gh output, parsed as JSON and never used as a prompt; swallow-ok: an empty read exits as unavailable below, never as an orphan
else
    ts_scan_gate orphan-pr-check graphql || unavailable "the open-PR list could not be read"
    prs_json="$(cd "$repo" 2>/dev/null && GH_READ_NO_MAIN_FALLBACK=1 timeout -k 2 30 "$GH_READ_BIN" pr list --state open --limit 1000 --json number,headRefName,isCrossRepository,author 2>/dev/null)" || prs_json=""  # gnu-ok: Linux-only kit; swallow-ok: an empty read exits as unavailable below, never as an orphan
fi
[ -n "$prs_json" ] || unavailable "the open-PR list could not be read"
printf '%s\n' "$prs_json" | jq -e 'type == "array" and all(.[]; type == "object" and (.number | type == "number") and (.headRefName | type == "string"))' >/dev/null 2>&1 \
    || unavailable "the open-PR list is not an array of PRs"  # swallow-ok: a malformed list exits as unavailable, never as an orphan

if [ "$mode" = gone ]; then
    open_nums="$(printf '%s\n' "$prs_json" | jq -r '[.[].number | tostring] | join(" ")' 2>/dev/null)" || unavailable "the open-PR list could not be filtered"  # swallow-ok: a filter failure exits as unavailable, never as a drop
    held="$(held_entries)" || exit 3
    while IFS="$(printf '\t')" read -r subj trig res names seg; do
        [ "$trig" != - ] && [ "$res" != - ] || continue
        n="${subj#\#}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        still_open=""
        for n in $(printf '%s\n' "$names" | tr ',' ' '); do
            case " $open_nums " in *" $n "*) still_open=1 ;; esac
        done
        [ -z "$still_open" ] || continue
        printf '%s\n' "$seg"
    done <<EOF_HELD
$held
EOF_HELD
    exit 0
fi

rows="$(printf '%s\n' "$prs_json" | jq -r '.[] | select((.isCrossRepository? // false) == true | not) | select((((.author? | .login?) // "") | tostring | test("dependabot"; "i") | not) and (.headRefName | startswith("dependabot/") | not)) | "\(.number)\t\(.headRefName)"' 2>/dev/null)" || unavailable "the open-PR list could not be filtered"  # swallow-ok: a filter failure exits as unavailable, never as an all-clear
[ -n "$rows" ] || exit 0

ticket_key() { printf '%s\n' "$1" | grep -oiE '[a-z][a-z0-9]*-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]'; }

held_names="$(held_entries | awk -F'\t' '$2 != "-" && $3 != "-" && $4 != "-" { n = split($4, a, ","); for (i = 1; i <= n; i++) print a[i] }')" || exit 3

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
    if grep -qxF -- "$n" <<< "$held_names"; then continue; fi
    if [ -n "$key" ] && grep -qxF -- "$key" <<< "$held_names"; then continue; fi
    printf 'UNMAPPED %s %s\n' "$n" "$branch"
    orphans=$((orphans + 1))
done <<EOF_ROWS
$rows
EOF_ROWS
[ "$orphans" -eq 0 ] || exit 1
exit 0
