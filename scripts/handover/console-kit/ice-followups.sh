#!/usr/bin/env bash
# scripts/handover/console-kit/ice-followups.sh - HIMMEL keys cited as follow-ups in
# the last N days of ticket comments that now live in ICE (the icebox project), so a
# parked follow-up is visible instead of silent. Read-only, over the local Jira mirror.
#
#   ice-followups.sh [<mirror dir>] [--days N]
#
# Prints `ice-followups=<n>` then the keys, one per line, numerically sorted; `?` for
# <n> when the mirror is unreadable. Exit 0 always.
#
# A key lives in ICE when its mirror file carries the move comment `Moved to ICE-<n>`
# or `Moved to the ICE project`. A citation is a HIMMEL key on a comment line that
# mentions follow-up / deferred / residual, under a comment header dated within the
# window; a ticket's own comments never count for itself. The mirror dir defaults to
# $BOARD_MIRROR, else ~/.himmel/state/jira-mirror/HIMMEL. ICE_FOLLOWUPS_TODAY
# (YYYY-MM-DD) pins today for tests.
#
# ponytail: a ticket moved to ICE without the move comment reads as not-in-ICE, upgrade path:
# have the mirror writer emit the project move.
#
# Platform guard: POSIX awk, bash 3.2+; GNU or BSD date.

dir=""
days=14
while [ $# -gt 0 ]; do
    case "$1" in
        --days) shift; [ $# -eq 0 ] || { days="$1"; shift; } ;;
        *) dir="$1"; shift ;;
    esac
done
dir="${dir:-${BOARD_MIRROR:-$HOME/.himmel/state/jira-mirror/HIMMEL}}"
case "$days" in '' | *[!0-9]*) days=14 ;; esac

if [ ! -d "$dir" ]; then
    printf 'ice-followups=?\n'
    exit 0
fi

today="${ICE_FOLLOWUPS_TODAY:-$(date +%F)}"
cutoff="$(date -d "$today -$days days" +%F 2>/dev/null || date -j -v-"$days"d -f %F "$today" +%F 2>/dev/null)"  # swallow-ok: GNU date, then BSD date; an empty cutoff prints ? below
if [ -z "$cutoff" ]; then
    printf 'ice-followups=?\n'
    exit 0
fi

set -- "$dir"/HIMMEL-*.md
[ -e "$1" ] || { printf 'ice-followups=0\n'; exit 0; }
raw="$(
    awk -v cutoff="$cutoff" '
    FNR == 1 { self = FILENAME; sub(/^.*\//, "", self); sub(/\.md$/, "", self); incm = 0; inwin = 0 }
    { sub(/\r$/, "") }
    /^## Comments[ \t]*$/ { incm = 1; next }
    !incm { next }
    /^### / {
        inwin = 0
        if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) inwin = (substr($0, RSTART, RLENGTH) >= cutoff)
        next
    }
    /^Moved to (ICE-[0-9]+|the ICE project)/ { ice[self] = 1; next }
    inwin && tolower($0) ~ /follow[- ]?ups?|defer(red|ring)?|residuals?/ {
        s = $0
        while (match(s, /HIMMEL-[0-9]+/)) {
            k = substr(s, RSTART, RLENGTH)
            if (k != self) cited[k] = 1
            s = substr(s, RSTART + RLENGTH)
        }
    }
    END { for (k in cited) if (k in ice) print k }' "$@"
)" || { printf 'ice-followups=?\n'; exit 0; }
keys="$(printf '%s\n' "$raw" | sort -t- -k2,2n | sed '/^$/d')"

n=0
[ -z "$keys" ] || n="$(printf '%s\n' "$keys" | wc -l | tr -d ' ')"
printf 'ice-followups=%s\n' "$n"
[ -z "$keys" ] || printf '%s\n' "$keys"
exit 0
