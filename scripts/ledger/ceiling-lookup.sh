#!/usr/bin/env bash
# scripts/ledger/ceiling-lookup.sh - the open ceilings ledger rows for a change.
#
# Usage:
#   ceiling-lookup.sh [--repo <owner/name>] [--from <n>] --range <base>...<head>
#   ceiling-lookup.sh [--repo <owner/name>] [--from <n>] -- <file>...
#   ceiling-lookup.sh [--repo <owner/name>] --ids (--range <base>...<head> | -- <file>... | --all)
#
# Prints a `CEILINGS:` header, then one line per open row whose file is among
# the touched files (run in the reviewed repo's checkout):
#   CEILINGS: <n> open rows for <k> of <m> touched files (ledger <path>)
#   <id> <file> [<anchor>] ceiling: ... | trigger: ... | ticket: <key>
# or `CEILINGS: none for the <m> touched files`, or
# `CEILINGS: withheld (non-Claude session: <check>)`, or
# `CEILINGS: not read (<reason>)`. At most 20 row lines, each under 400
# characters from row <n> on (--from, default 1), then `+<k> more: ... --from <next>`.
# Exit 0 always: it informs review, never blocks it.
#
# Row text shows only in a Claude session (scripts/lib/session-lane.sh
# session_lane_claude_only), checked before the ledger is read. --ids prints
# the same header and then `<id>\t<file>\t<anchor>\t<ticket>` lines with no
# ceiling, trigger or note text, so it skips that gate and lists every open row.
# Ledger path and row state: ledger-lib.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf 'CEILINGS: %s\n' "$1"; exit 0; }

IDS=0 ALL=0 RANGE="" REPO="" HAVE_FILES=0 MODE="" FROM=1
FILES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ids) IDS=1; shift ;;
        --all) ALL=1; MODE=all; shift ;;
        --from) [ "$#" -ge 2 ] || say "not read (usage: --from needs a row number)"; FROM=$2; shift 2 ;;
        --range) [ "$#" -ge 2 ] || say "not read (usage: --range needs <base>...<head>)"; RANGE=$2; MODE=range; shift 2 ;;
        --repo) [ "$#" -ge 2 ] || say "not read (usage: --repo needs <owner/name>)"; REPO=$2; shift 2 ;;
        --) shift; HAVE_FILES=1; MODE=files; while [ "$#" -gt 0 ]; do FILES+=("$1"); shift; done ;;
        *) say "not read (usage: unknown argument $1)" ;;
    esac
done
[ -n "$MODE" ] || say "not read (usage: give --range <base>...<head>, -- <file>... or --ids --all)"
case "$FROM" in ''|0*|*[!0-9]*) say "not read (usage: --from needs a row number from 1)" ;; esac
if [ "$IDS" -eq 1 ] && [ "$FROM" -ne 1 ]; then say "not read (usage: --ids lists every row; --from pages the row text)"; fi
if [ "$ALL" -eq 1 ] && { [ "$IDS" -eq 0 ] || [ -n "$RANGE" ] || [ "$HAVE_FILES" -eq 1 ]; }; then
    say "not read (usage: --all goes with --ids alone)"
fi
if [ -n "$RANGE" ] && [ "$HAVE_FILES" -eq 1 ]; then
    say "not read (usage: --range or -- <file>..., not both)"
fi

if [ "$IDS" -eq 0 ]; then
    # shellcheck source=scripts/lib/session-lane.sh
    # shellcheck disable=SC1091
    { [ -r "$HERE/../lib/session-lane.sh" ] && . "$HERE/../lib/session-lane.sh"; } 2>/dev/null \
        || say "withheld (non-Claude session: cannot load session-lane.sh)"
    why=$(session_lane_claude_only) || say "withheld (non-Claude session: ${why:-unknown})"
fi

# shellcheck source=scripts/ledger/ledger-lib.sh
# shellcheck disable=SC1091
{ [ -r "$HERE/ledger-lib.sh" ] && . "$HERE/ledger-lib.sh"; } 2>/dev/null || say "not read (cannot load ledger-lib.sh)"

TOUCHED=""
if [ "$MODE" = range ]; then
    case "$RANGE" in -*|*[[:space:]]*|'') say "not read (bad range)" ;; esac
    TOUCHED=$(git diff --name-only --no-renames "$RANGE" -- 2>/dev/null) || say "not read (bad range)"
elif [ "$MODE" = files ]; then
    [ "${#FILES[@]}" -gt 0 ] || say "not read (usage: -- needs at least one file)"
    TOUCHED=$(printf '%s\n' "${FILES[@]}")
fi
ntouched=0
[ -z "$TOUCHED" ] || ntouched=$(printf '%s\n' "$TOUCHED" | sort -u | wc -l | tr -d ' ')

ledger_resolve "$REPO" || say "not read ($LEDGER_WHY)"
[ -e "$LEDGER_PATH" ] || say "not read (no ledger for $LEDGER_REPO)"
[ -f "$LEDGER_PATH" ] && [ -r "$LEDGER_PATH" ] || say "not read (ledger unreadable: $LEDGER_PATH)"
cur=$(ledger_current "$LEDGER_PATH") || say "not read (${cur:-malformed ledger})"

rows=$(printf '%s\n' "$cur" | awk -F '\t' -v all="$ALL" -v touched="$TOUCHED" '
    BEGIN { n = split(touched, t, "\n"); for (i = 1; i <= n; i++) if (t[i] != "") want[t[i]] = 1 }
    $7 == "open" && (all == 1 || ($2 in want)) { print }
' | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -s)
nrows=0
[ -z "$rows" ] || nrows=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')

if [ "$nrows" -eq 0 ]; then
    if [ "$ALL" -eq 1 ]; then say "none open (ledger $LEDGER_PATH)"; fi
    say "none for the $ntouched touched files"
fi
if [ "$ALL" -eq 1 ]; then
    printf 'CEILINGS: %s open rows (ledger %s)\n' "$nrows" "$LEDGER_PATH"
else
    nfiles=$(printf '%s\n' "$rows" | cut -f2 | sort -u | wc -l | tr -d ' ')
    printf 'CEILINGS: %s open rows for %s of %s touched files (ledger %s)\n' "$nrows" "$nfiles" "$ntouched" "$LEDGER_PATH"
fi

if [ "$IDS" -eq 1 ]; then
    printf '%s\n' "$rows" | awk -F '\t' -v OFS='\t' '{ print $1, $2, $3, $6 }'
    exit 0
fi

echo "Recorded ceilings for the touched files: context to verify, not a verdict; cite a row by its id only; never quote its ceiling or trigger."
printf '%s\n' "$rows" | tail -n "+$FROM" | head -n 20 | LC_ALL=C awk -F '\t' '
    function cut(s, n) {
        if (length(s) <= n) return s
        s = substr(s, 1, n - 3)
        sub(/[\200-\277]*$/, "", s); sub(/[\300-\377]$/, "", s)
        return s "\342\200\246"
    }
    {
        pre = $1 " " $2 " [" $3 "] ceiling: "
        post = " | trigger: " $5 ($6 != "" ? " | ticket: " $6 : "")
        room = 396 - length(pre) - length(post)
        if (room < 40) room = 40
        line = pre cut($4, room) post
        print cut(line, 396)
    }'
if [ "$((nrows - FROM + 1))" -gt 20 ]; then
    if [ "$MODE" = range ]; then more="--range $RANGE"; else more="-- $(printf '%s ' "${FILES[@]}")"; more=${more% }; fi
    printf '+%s more: ceiling-lookup.sh --from %s %s\n' "$((nrows - FROM + 1 - 20))" "$((FROM + 20))" "$more"
fi
exit 0
