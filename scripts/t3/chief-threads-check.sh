#!/usr/bin/env bash
# scripts/t3/chief-threads-check.sh - find settled chief-role T3 Code threads, and unsettled
# ones that hold an open linked PR (T3 settles a thread when its linked PR merges).
#
# Usage: chief-threads-check.sh [--wake]
# Chief-role thread: title ends in -chief or -console (case-insensitive, as the T3 title
# guard), or the title is a line of HIMMEL_T3_CHIEF_TITLES (default "Manage T3 Code Sync").
# Skips threadIds starting "import:" and threads settled more than T3_CHIEF_CHECK_WINDOW_HOURS
# (default 24) ago. Prints "SETTLED <id> <title> <settledAt>" per remaining one; a suffix-only
# match is marked "(report only: ...)". With --wake, only threads listed in
# HIMMEL_T3_CHIEF_TITLES are sent a wake message through t3-send.sh (send rc printed).
# Also prints "LINKED-PR <id> <title> open=<n>" for each unsettled chief-role thread with
# openPullRequestCount > 0, whatever the window; report only, never woken.
# rc 0 nothing to report; rc 1 something reported (SETTLED or LINKED-PR); rc 2 usage / list or filter failure.
# Env seams: T3_SEND_BIN, T3_SEND_PROJECT (as t3-send.sh), HIMMEL_T3_CHIEF_TITLES,
# T3_CHIEF_CHECK_WINDOW_HOURS.
# Platform: POSIX bash 3.2+, jq.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="${T3_SEND_BIN:-$HOME/.t3/bin/t3}"
PROJECT="${T3_SEND_PROJECT:-$(cd "$HERE/../.." && pwd -P)}"
TITLES="${HIMMEL_T3_CHIEF_TITLES-Manage T3 Code Sync}"
HOURS="${T3_CHIEF_CHECK_WINDOW_HOURS:-24}"
WAKE=0
die() { echo "chief-threads-check: $2" >&2; exit "$1"; }

[ $# -le 1 ] || die 2 "usage: chief-threads-check.sh [--wake]"
case "${1:-}" in
    "") ;;
    --wake) WAKE=1 ;;
    *) die 2 "usage: chief-threads-check.sh [--wake]" ;;
esac
case "$HOURS" in ""|*[!0-9]*) die 2 "T3_CHIEF_CHECK_WINDOW_HOURS must be a whole number" ;; esac
command -v jq >/dev/null 2>&1 || die 2 "jq is required"

LIST="$("$BIN" thread list --json --project "$PROJECT" 2>&1)" || die 2 "thread list failed: $LIST"
printf '%s' "$LIST" | jq -e 'type == "array"' >/dev/null 2>&1 || die 2 "thread list did not print a JSON array"

ROWS="$(printf '%s' "$LIST" | jq -r --arg extra "$TITLES" --argjson hours "$HOURS" '
    ($extra | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $names
    | (now - ($hours * 3600)) as $since
    | .[] | select(.settled == true)
    | select((.threadId | startswith("import:")) | not)
    | select((.settledAt // "") != "" and ((.settledAt | sub("\\.[0-9]+"; "") | fromdateiso8601) >= $since))
    | (.title // "") as $t | ($t | gsub("^\\s+|\\s+$"; "")) as $tt
    | ($names | index($tt) != null) as $listed
    | select($listed or ($tt | ascii_downcase | test("-(chief|console)$")))
    | [.threadId, $t, .settledAt, (if $listed then "1" else "0" end)] | @tsv')" || die 2 "could not filter the thread list (bad settledAt or thread entry)"

PRROWS="$(printf '%s' "$LIST" | jq -r --arg extra "$TITLES" '
    ($extra | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))) as $names
    | .[] | select(.settled != true)
    | select((.threadId | startswith("import:")) | not)
    | select((.openPullRequestCount // 0) > 0)
    | (.title // "") as $t | ($t | gsub("^\\s+|\\s+$"; "")) as $tt
    | select(($names | index($tt) != null) or ($tt | ascii_downcase | test("-(chief|console)$")))
    | [.threadId, $t, (.openPullRequestCount | tostring)] | @tsv')" || die 2 "could not filter the thread list (bad thread entry)"

[ -n "$ROWS" ] || [ -n "$PRROWS" ] || exit 0
MSG="A chief-role thread was settled (T3 closed its process). You are woken by chief-threads-check; resume your role and tell your chief you are back."
while IFS="$(printf '\t')" read -r id title at listed; do
    [ -n "$id" ] || continue
    if [ "$listed" = 1 ]; then
        echo "SETTLED $id $title $at"
        if [ "$WAKE" = 1 ]; then
            printf '%s\n' "$MSG" | "$HERE/t3-send.sh" "$id" - >/dev/null 2>&1
            echo "  wake-send rc=$?"
        fi
    else
        echo "SETTLED $id $title $at (report only: not in HIMMEL_T3_CHIEF_TITLES)"
    fi
done <<EOF2
$ROWS
EOF2
while IFS="$(printf '\t')" read -r id title n; do
    [ -n "$id" ] && echo "LINKED-PR $id $title open=$n"
done <<EOF3
$PRROWS
EOF3
exit 1
