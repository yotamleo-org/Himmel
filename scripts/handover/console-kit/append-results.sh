#!/usr/bin/env bash
# scripts/handover/console-kit/append-results.sh - append a
# leg's marker bullet at a handover doc's true EOF, so it can never land
# mid-doc. Twice in one shift a leg's WRAPPED bullet, written with the Edit
# tool anchored on an earlier bullet, landed ABOVE later bullets instead of
# at the true end of the doc; close-wrapped-leg.sh and tick.sh both read the
# doc's LAST `- ` line (scripts/lib/leg-tail-status.sh) as the leg's current
# status, so the misordered WRAPPED bullet was invisible to them and the
# wrap was refused. This script always appends at the literal end of the
# file, so a leg calling it can never repeat that mistake.
#
# Usage: append-results.sh <doc> <text>
#
# Writes `- HH:MM <text>` as a new final line of <doc> (the timestamp is
# always the current wall-clock HH:MM, never taken from <text>). If the file
# does not already end in a newline, one is added first, so the new bullet
# is never glued onto a prior line. Refuses - doc left byte-for-byte
# unchanged - unless the file exists, is readable and writable, and
# contains a literal `## Results` heading line, matched at a word boundary
# (`## Results` followed by whitespace or end-of-line, so the real
# `## Results (newest at the bottom)` heading still matches but a lookalike
# like `## Results-old` does not), somewhere in it (a doc with no Results
# section has nowhere defined to append a Results bullet).
#
# <text> is read only from argv ($2), never stdin/a file/a
# heredoc, so it can never carry an embedded NUL byte - execve() argv
# strings are NUL-terminated C strings at the kernel level, so no NUL can
# ever cross into $2 in the first place. A NUL-refusal check here would be
# unreachable dead code; if this script ever grows a non-argv text source,
# that path needs its own NUL-refusal with a real test, this guarantee does
# not extend to it.
#
# Exit codes:
#   0  appended
#   2  usage (wrong arg count)
#   3  doc missing / unreadable / unwritable
#   4  doc has no `## Results` heading - nothing written
#   6  <text> leads with an all-caps word that is neither a status
#      marker nor a documented non-status bullet - nothing written
#   5  write failed (e.g. disk full) after the heading/newline checks passed
#   7  bucket-gitleaks.sh finds a secret in the bullet - nothing written
#
# Platform guard: POSIX bash 3.2+, no GNU-only flags.
set -u

if [ "$#" -ne 2 ]; then
    echo "usage: append-results.sh <doc> <text>" >&2
    exit 2
fi
DOC="$1"
TEXT="$2"

if [ ! -f "$DOC" ] || [ ! -r "$DOC" ] || [ ! -w "$DOC" ]; then
    echo "append-results: cannot read/write doc '$DOC'" >&2
    exit 3
fi

if ! grep -Eq '^## Results([[:space:]]|$)' "$DOC"; then
    echo "append-results: '$DOC' has no '## Results' heading - refusing" >&2
    exit 4
fi

# a leading all-caps word that is not in the vocabulary is a coined
# marker (SHIPPED, MERGED): the tick would never read it, so refuse it instead of
# letting it sit invisible. CONSULT / SUCCESSION / MAIN-RED are the preface's
# documented non-status bullets and still append. the floor is 2
# chars (WIP, OK, PR are refused); every real marker is 4+ chars, and a 1-char
# lead is prose.
#
# Leg docs only: a leg doc carries its brief's "RETASK token" line. A console doc
# (name ends -console.md) or a doc with no leg brief takes any bullet, since
# console-template.md has the console log MERGED / VERDICT / OPERATOR / free text
# through this script.
lead="${TEXT%%[!A-Z-]*}"
is_leg=0
case "${DOC##*/}" in
    *-console.md) ;;
    *) grep -q 'RETASK token' "$DOC" && is_leg=1 ;;
esac
case "$is_leg:$lead" in
    1:??*)
        case "$lead" in
            LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED|CONSULT|CONSULT-ANSWER|ANSWER|SUCCESSION|MAIN-RED|PARK-BANK) ;;
            *)
                echo "append-results: '$lead' is not in the marker vocabulary (LIVE FINDING RESOLVED READY BLOCKED HALTED WRAPPED PARKED-USAGE PARKED-BANK RESUMED) - refusing" >&2
                exit 6 ;;
        esac ;;
esac

stamp="$(date +%H:%M)"
bullet="- ${stamp} ${TEXT}"

# A leg's exact SUCCESSION acknowledgement also moves its himmel-bus console edge
# (`bus adopt`, which checks the succession itself). The result lands as a
# non-status bullet above it, so the acknowledgement stays the newest line; a
# refusal never blocks the acknowledgement. Only a leg with a bus identity
# (HIMMEL_BUS_NAME) adopts. APPEND_RESULTS_BUS replaces the CLI;
# APPEND_RESULTS_BUS_TIMEOUT bounds the adopt (seconds, default 15).
# Every later marker bullet re-runs the adopt for the doc's newest accepted
# successor, so a leg whose adopt was refused while its old console was still
# live heals once that console is gone. adopt is idempotent: an unchanged
# console never earns a bullet, and a refused re-adopt stays silent.
succ_re='^SUCCESSION accepted: ([A-Za-z0-9][A-Za-z0-9._-]*) replaces [A-Za-z0-9][A-Za-z0-9._-]*$'
adopt_to=""; readopt=0
if [ "$is_leg" -eq 1 ] && [ -n "${HIMMEL_BUS_NAME:-}" ]; then
    if [[ $TEXT =~ $succ_re ]]; then
        adopt_to="${BASH_REMATCH[1]}"
    else
        case "$lead" in
            LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|PARKED-USAGE|RESUMED)
                accepted="$(sed -n 's/^- [0-9][0-9]:[0-9][0-9] //p' "$DOC" | grep -E "$succ_re" | tail -n 1)"
                [[ $accepted =~ $succ_re ]] && { adopt_to="${BASH_REMATCH[1]}"; readopt=1; } ;;
        esac
    fi
fi
if [ -n "$adopt_to" ]; then
    bus="${APPEND_RESULTS_BUS:-$(dirname "${BASH_SOURCE[0]}")/../../../marketplace/plugins/himmel-bus/bin/bus}"
    limit="${APPEND_RESULTS_BUS_TIMEOUT:-15}"
    wait_for=""; command -v timeout >/dev/null 2>&1 && wait_for="timeout $limit"
    if adopted="$($wait_for "$bus" adopt "$adopt_to" 2>&1)"; then
        adopted="${adopted%%$'\n'*}"
        [[ $adopted =~ ^adopted:\ [^\ ]+\ console\ ([^\ ]+)\ -\>\ ([^\ ]+)$ ]] \
            && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && adopted=""
    else
        [ "$?" -eq 124 ] && [ -n "$wait_for" ] && adopted="timed out after ${limit}s"
        adopted="refused (${adopted%%$'\n'*})"
        [ "$readopt" -eq 1 ] && adopted=""
    fi
    [ -z "$adopted" ] || bullet="- ${stamp} bus-adopt: ${adopted//->/→}"$'\n'"$bullet"
fi

# the vault's pre-commit gitleaks would refuse the doc and stall the autosync
# commit, so scan the bullet first (bucket-gitleaks.sh, the vault's config) and
# refuse a FINDING. No gitleaks or an unusable scan (rc 2) appends unscanned.
scan="$(mktemp "${TMPDIR:-/tmp}/append-results.XXXXXX")" || scan=""
if [ -n "$scan" ]; then
    printf '%s\n' "$bullet" > "$scan"
    verdict="$(bash "$(dirname "${BASH_SOURCE[0]}")/bucket-gitleaks.sh" "$scan")"
    vrc=$?
    rm -f "$scan"
    if [ "$vrc" -eq 1 ]; then
        echo "append-results: $verdict - refusing; reword the bullet (break the key=value shape, drop the secret-like value) and re-run" >&2
        exit 7
    fi
fi

# append under the lock every doc writer shares (leg-doc-lock.sh),
# so a rewrite in flight (the launcher's session_ids:, inbox-send.sh,
# live-state.sh) finishes its mv first and this bullet lands on the new doc,
# never on the replaced one. A lock that cannot be taken (rc 1) or no flock
# (rc 3) appends unlocked, as before: the bullet matters more than the race.
# shellcheck source=scripts/handover/console-kit/leg-doc-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/leg-doc-lock.sh"
locked=0
doc_lock "$DOC" append-results && locked=1

# Command substitution strips trailing newlines, so a non-empty result here
# means the file's last byte is NOT a newline.
if [ -s "$DOC" ] && [ -n "$(tail -c 1 "$DOC")" ]; then
    printf '\n' >> "$DOC"
fi

if ! printf '%s\n' "$bullet" >> "$DOC"; then
    echo "append-results: write failed for $DOC" >&2
    exit 5
fi
[ "$locked" -eq 1 ] && doc_unlock
echo "append-results: appended to $DOC"

# a LIVE or WRAPPED bullet records the doc as the ticket's owner (the key in
# the doc name) and re-derives its Jira status. Best-effort - leg-jira-status.sh
# warns and exits 0 on any Jira failure, and LEG_JIRA_STATUS=0 opts out.
event=""
case "$TEXT" in
    LIVE|LIVE[!A-Za-z0-9]*) event=live ;;
    WRAPPED|WRAPPED[!A-Za-z0-9]*) event=wrapped ;;
esac
if [ -n "$event" ] && [ "${LEG_JIRA_STATUS:-1}" != "0" ]; then
    base="${DOC##*/}"
    if [[ $base =~ ^([A-Za-z][A-Za-z0-9]*-[0-9]+)- ]]; then
        bash "$(dirname "${BASH_SOURCE[0]}")/leg-jira-status.sh" "${BASH_REMATCH[1]}" --event "$event" --doc "$DOC" || true
    fi
fi
exit 0
