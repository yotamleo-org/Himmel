#!/usr/bin/env bash
# Platform guard: any POSIX bash 3.2+.
#
# check-operator-voice.sh — no operator-bound template or prompt produces or asks for
# a time estimate (docs/internals/operator-voice.md, rule 8). A time estimate is a
# future duration or arrival: "in about 15 min", "about 2 min", "ETA", "will take",
# "shortly", "in a moment", "in an hour", "done by tonight", "ready by 6 pm". A measured
# past duration ("took 50 min", "took an hour") is a fact and passes, and so does a
# deadline the system enforces ("expires in 6 h", decision 1238). A line naming "time estimate" states the rule and is skipped.
#
# Usage:
#   check-operator-voice.sh [--ticket] [<file>...]
#     --ticket   each file is a ticket draft: only its plain top line (the first line
#                that is not blank and not a heading) is scanned; the agent sections
#                keep their full detail (decision 1235).
#     no files   the operator-bound set: the chief reply style, the voice-line section,
#                the ticket standard and the Telegram reply kinds (whole files), and the
#                Telegram bridge sources (only lines that send: reply(, notifyChat(,
#                replyViaOutbox(, sendMessage(). A doc that tells agents how long a
#                system step takes is not a message and is not scanned.
# Exit: 0 clean · 1 findings (file:line: text) · 2 cannot evaluate (fail-closed)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
FILES=()
TICKET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ticket) TICKET=1; shift ;;
        -*) echo "usage: check-operator-voice.sh [--ticket] [<file>...]" >&2; exit 2 ;;
        *) FILES+=("$1"); shift ;;
    esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
    FILES=("$REPO_ROOT/docs/handover/chief-adhd-brief.md"
        "$REPO_ROOT/docs/handover/chief-sections/voice-lines.md"
        "$REPO_ROOT/marketplace/plugins/himmel-ops/skills/ticket-standard/SKILL.md"
        "$REPO_ROOT/scripts/telegram/message-classes.json")
    for f in "$REPO_ROOT"/scripts/telegram/*.ts; do
        case "$f" in *.test.ts) ;; *) FILES+=("$f") ;; esac
    done
fi
for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "check-operator-voice: no such file: $f" >&2; exit 2; }
done

fail=0
for f in "${FILES[@]}"; do
    sendonly=0
    case "$f" in *.ts) sendonly=1 ;; esac
    out="$(LC_ALL=C awk -v file="$f" -v sendonly="$sendonly" -v ticket="$TICKET" '
        ticket == 1 {
            if (seen || $0 ~ /^[[:space:]]*(#|$)/) next
            seen = 1
        }
        sendonly == 1 {
            if (depth <= 0 && $0 !~ /(reply|notifyChat|replyViaOutbox|sendMessage)\(/) next
            s = $0; gsub(/"([^"\\]|\\.)*"|'\''([^'\''\\]|\\.)*'\''|`[^`]*`/, "", s)
            o = gsub(/\(/, "(", s); c = gsub(/\)/, ")", s)
            depth = (depth > 0 ? depth : 0) + o - c
        }
        tolower($0) ~ /time estimate/ { next }
        {
            raw = $0
            l = tolower($0)
            n = "[0-9]+([.,-][0-9]+)?"
            u = "(s|secs?|seconds?|m|mins?|minutes?|h|hrs?|hours?|days?)([^a-z0-9_]|$)"
            w = "(a|an|half an|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|thirty|forty|fifty|sixty) (sec|second|min|minute|hour|hr|day|week)s?([^a-z]|$)"
            past = "(took|waited|lasted|spent|ran for|ran|after|for the last|been|over|expires?) "
            gsub(past "(in |about |around |roughly |~ ?)?" n " ?" u, " ", l)
            gsub(past "(in )?" w, " ", l)
            gsub("(once|twice|thrice|times) in " w, " ", l)
            gsub("in an? second [a-z]", " ", l)
            clock = "[0-9][0-9]?(:[0-9][0-9] ?(am|pm|h)?| ?(am|pm|h)([^a-z]|$))"
            target = "(tonight|tomorrow|today|noon|midnight|lunch|eod|end of (the )?(day|week)|this (morning|afternoon|evening|week)|(mon|tues|wednes|thurs|fri|satur|sun)day)"
            gsub("(done|ready|back|finished) by (" target "|" clock ") ?(yesterday|last [a-z]+)", " ", l)
            hit = ""
            if (raw ~ /(^|[^A-Za-z])ETAs?([^A-Za-z]|$)/) hit = "ETA"
            else if (l ~ ("(^|[^a-z0-9_])(about|around|roughly|approx\\.?|approximately|~) ?" n " ?" u)) hit = "about N"
            else if (l ~ ("(^|[^a-z0-9_])in " n " ?" u)) hit = "in N"
            else if (l ~ /(^|[^a-z])about (half an|an|a few|a couple of) (hour|minute|second|day)/) hit = "about N"
            else if (l ~ /(^|[^a-z])(will|should|would|might|may|could) take([^a-z]|$)/) hit = "will take"
            else if (l ~ /(^|[^a-z])takes? about([^a-z]|$)/) hit = "takes about"
            else if (l ~ /(^|[^a-z])shortly([^a-z]|$)/) hit = "shortly"
            else if (l ~ /in a (few|couple of) (seconds|minutes|hours|days)/) hit = "in a few"
            else if (l ~ /(^|[^a-z])(in a moment|back in a)([^a-z]|$)/) hit = "in a moment"
            else if (l ~ ("(^|[^a-z])(done|ready|back|finished) by (" target "([^a-z]|$)|" clock ")")) hit = "by <time>"
            else if (l ~ ("(^|[^a-z0-9_])in " w)) hit = "in a <unit>"
            if (hit != "") {
                t = raw; sub(/^[[:space:]]+/, "", t)
                printf "%s:%d: time estimate (%s): %s\n", file, NR, hit, substr(t, 1, 160)
            }
        }' "$f")" || { echo "check-operator-voice: awk failed on $f" >&2; exit 2; }
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        fail=1
    fi
done
exit "$fail"
