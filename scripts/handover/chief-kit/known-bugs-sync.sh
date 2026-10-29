#!/usr/bin/env bash
# scripts/handover/chief-kit/known-bugs-sync.sh - keep the known-checker-bugs file and the checker
# ticket's Jira links in step (K1). Each side keeps its last edit time and the newer edit wins:
#   - a file row Jira has no link for: if the link was removed in Jira AFTER the row's edit, the
#     row is removed from the file; otherwise the link is created in Jira (`link`)
#   - a Relates link Jira has and the file does not: a row is added with class `unset` (a link
#     cannot name a class) and the link's Jira edit time
#   - a pair on both sides: nothing
# Every change prints one log line (and appends it to --log). Only Relates links count; a Blocks
# link on the checker ticket is not a pairing. Jira writes go through the Jira CLI `link` verb, not
# jira-write.ts (the plan's Q2, the chief's default).
#
# Usage: known-bugs-sync.sh --checker <KEY> [--tsv <file>] [--log <file>]
#   --tsv defaults to known-checker-bugs.tsv beside this script (rows: checker, class, key, edited-at)
# Env: KBS_JIRA (an executable standing in for the Jira CLI, tests), JIRA_PROJECT_KEY (default HIMMEL).
# Exit: 0 synced, 1 a Jira read or write failed (the file is then left as it was), 2 usage.
#
# ponytail: a row deleted from the file by hand comes back as class `unset` on the next sync,
# upgrade path = a tombstone row with an edit time.
# Platform guard: bash 3.2+ with GNU date and jq; the chief kit is Linux-only, no .ps1 twin by design.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh"
git_env_scrub
# shellcheck source=../../lib/prim.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/prim.sh"
export LC_ALL=C

usage() { echo "usage: known-bugs-sync.sh --checker <KEY> [--tsv <file>] [--log <file>]" >&2; exit 2; }
CHECKER="" TSV="$HERE/known-checker-bugs.tsv" LOG=""
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --checker) CHECKER="$2" ;;
        --tsv) TSV="$2" ;;
        --log) LOG="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[[ "$CHECKER" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || usage
command -v jq >/dev/null 2>&1 || { echo "known-bugs-sync: jq not found" >&2; exit 1; }

if [ -n "${KBS_JIRA:-}" ]; then
    JIRA=("$KBS_JIRA")
else
    PRIMARY=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && PRIMARY="${PRIMARY%/.git}" || PRIMARY="" # swallow-ok: no checkout leaves the CLI path empty and the first read fails by name
    JIRA=(node "$PRIMARY/scripts/jira/dist/index.js")
fi
export JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}"

log() { # <message>
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) known-bugs-sync $CHECKER: $1" # gnu-ok: chief kit is Linux-only
    printf '%s\n' "$line"
    [ -z "$LOG" ] || printf '%s\n' "$line" >> "$LOG"
}
epoch() { [ -n "$1" ] && date -d "$1" +%s 2>/dev/null; } # gnu-ok: chief kit is Linux-only; an empty time is no time
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; } # gnu-ok: chief kit is Linux-only

links=$("${JIRA[@]}" links "$CHECKER" 2>/dev/null) || { echo "known-bugs-sync: jira links $CHECKER failed" >&2; exit 1; } # swallow-ok: a failed read exits 1 by name, nothing is written
hist=$("${JIRA[@]}" history "$CHECKER" --json 2>/dev/null) || { echo "known-bugs-sync: jira history $CHECKER failed" >&2; exit 1; } # swallow-ok: a failed read exits 1 by name, nothing is written

# the other end of every Relates link
jira_keys=$(printf '%s\n' "$links" | awk -F'\t' -v c="$CHECKER" '
    $2 == "Relates" { for (i = 3; i <= 4; i++) { sub(/^(inward|outward)=/, "", $i); if ($i != c) print $i } }')
# the last Link event per key: key<TAB>added|removed<TAB>created
events=$(printf '%s' "$hist" | jq -r '
    [.[] | .created as $c | .items[]? | select((.field | ascii_downcase) == "link")
     | (.toString // .fromString // "") as $t | select($t | test("relates to"))
     | {key: ($t | capture("(?<k>[A-Z][A-Z0-9]*-[0-9]+)").k), kind: (if .toString then "added" else "removed" end), created: $c}]
    | group_by(.key)[] | .[-1] | [.key, .kind, .created] | @tsv') || { echo "known-bugs-sync: unreadable history for $CHECKER" >&2; exit 1; }

in_jira() { printf '%s\n' "$jira_keys" | grep -Fxq "$1"; }
event_of() { printf '%s\n' "$events" | awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3 }'; }

tmp="$TSV.sync.$$"
trap 'rm -f "$tmp"' EXIT
: > "$tmp"
file_keys=""
if [ -f "$TSV" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        IFS=$'\t' read -r checker _ key edited <<< "$line"
        if [ "$checker" != "$CHECKER" ] || [ -z "$key" ]; then printf '%s\n' "$line" >> "$tmp"; continue; fi
        file_keys="$file_keys$key"$'\n'
        if in_jira "$key"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
        ev=$(event_of "$key")
        kind="${ev%%$'\t'*}" jat="${ev#*$'\t'}"
        fe=$(epoch "$edited") || fe=0
        je=0
        [ -z "$ev" ] || je=$(epoch "$jat") || je=0
        if [ "$kind" = removed ] && [ "$je" -gt "$fe" ]; then
            log "$key removed from the file: Jira's link was removed at $jat, after the file row's edit at $edited"
            continue
        fi
        "${JIRA[@]}" link "$CHECKER" "$key" --type Relates >/dev/null 2>&1 || { echo "known-bugs-sync: jira link $CHECKER $key failed" >&2; exit 1; }
        log "$key linked in Jira: the file row's edit at $edited is newer than the Jira side"
        printf '%s\n' "$line" >> "$tmp"
    done < "$TSV"
fi
while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s' "$file_keys" | grep -Fxq "$key" && continue
    ev=$(event_of "$key")
    jat="${ev#*$'\t'}"
    je=$(epoch "$jat") || je=$(date +%s)
    printf '%s\tunset\t%s\t%s\n' "$CHECKER" "$key" "$(iso "$je")" >> "$tmp"
    log "$key added to the file from Jira as class unset (Jira edit at $jat)"
done <<EOF_KEYS
$jira_keys
EOF_KEYS
if ! cmp -s "$tmp" "$TSV"; then atomic_write "$TSV" < "$tmp" || { echo "known-bugs-sync: could not write $TSV" >&2; exit 1; }; fi
exit 0
