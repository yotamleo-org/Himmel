#!/usr/bin/env bash
# succession-tracker.sh — HIMMEL-3746. The successor console's tally of its inherited legs'
# quote-backs, so it reads one table instead of counting ~26 SendMessage replies by hand.
#
#   succession-tracker.sh <console doc> --successor <session> [--relayed <label>[,<label>...]]
#
# The inherited set is the console doc's `## Live state` `legs:` entries (the same parse
# relay-batch.sh uses). Each leg's doc comes from the fleet manifest next to the console doc
# (<console doc stem>.fleet.json). Per leg it prints one state:
#   quoted-back  the leg's LATEST `SUCCESSION accepted:` Results bullet names --successor as
#                the incoming console (the leg took this console over)
#   relayed      no such bullet yet, but the leg is listed in --relayed (the predecessor's
#                relay-batch.sh output, which a script cannot observe being sent)
#   missing      anything else: no bullet, a bullet naming another console, an ambiguous
#                line, a leg with no manifest row. An ambiguous line is never accepted.
# The bullet grammar is strict, one whole line:
#   - [HH:MM ][LIVE — ]SUCCESSION accepted: [`]<incoming>[`] replaces [`]<outgoing>[`]
# and it must be a `- ` bullet, so a prose line quoting it confirms nothing. The latest line
# that mentions `SUCCESSION accepted` decides, so a newer ambiguous line outranks an older
# clean one.
#
# When every leg is quoted-back it prints `COMPLETE n/n` and the exact append-results.sh
# command that writes the LIVE bullet. PRINT ONLY: it never sends a message, never edits a
# doc, never rotates a token; the console runs the printed line itself. An empty leg set is
# INCOMPLETE, never complete.
#
# Exit: 0 complete; 1 incomplete (or no legs); 2 usage.
# PLATFORM GUARD: no .ps1 twin, by design (the console kit is Linux-only, as its siblings).
# bash 3.2-safe; needs jq.
set -uo pipefail

usage() { echo "usage: succession-tracker.sh <console doc> --successor <session> [--relayed <label>[,<label>...]]" >&2; exit 2; }
[ "$#" -ge 3 ] || usage
doc="$1"; shift
successor=""; relayed=","
while [ "$#" -gt 0 ]; do
    case "$1" in
        --successor) [ "$#" -ge 2 ] || usage; successor="$2"; shift 2 ;;
        --relayed) [ "$#" -ge 2 ] || usage; relayed=",$2,"; shift 2 ;;
        *) usage ;;
    esac
done
{ [ -n "$successor" ] && [ -f "$doc" ]; } || usage
manifest="${doc%.md}.fleet.json"

# The legs: block of ## Live state (the legs: line plus the lines wrapped under it).
# shellcheck disable=SC2016  # the backticks are literal markers in the Live state / the bullet
entries="$(awk '
    $0 == "## Live state" { s = 1; next }
    s && /^## / { exit }
    s && /^legs:/ { b = 1; print; next }
    b && (/^[[:space:]]*$/ || /^[0-9]+\. / || /^[A-Za-z][A-Za-z ]*:/ || /^[-*+>#]/) { b = 0 }
    b { print }
' "$doc" | grep -oE '`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`' | tr -d '`' | cut -d: -f1)"

# state of one leg doc: prints quoted-back or missing
leg_state() {
    local ldoc="$1" line inc
    [ -f "$ldoc" ] || { echo missing; return; }
    # the latest line mentioning the handshake decides
    line="$(grep 'SUCCESSION accepted' "$ldoc" | tail -n 1)"
    [ -n "$line" ] || { echo missing; return; }
    # shellcheck disable=SC2016
    inc="$(printf '%s\n' "$line" | sed -nE 's/^- ([0-9]{2}:[0-9]{2} )?(LIVE — )?SUCCESSION accepted: `?([A-Za-z0-9_.-]+)`? replaces `?[A-Za-z0-9_.-]+`?[[:space:]]*$/\3/p')"
    if [ -n "$inc" ] && [ "$inc" = "$successor" ]; then echo quoted-back; else echo missing; fi
}

total=0; ok=0; pending=""
while IFS= read -r label; do
    [ -n "$label" ] || continue
    total=$((total + 1))
    ldoc=""
    if [ -f "$manifest" ]; then
        ldoc="$(jq -r --arg l "$label" '[.legs[] | select(.label == $l)][0].doc // empty' "$manifest" 2>/dev/null)"
    fi
    state="$(leg_state "$ldoc")"
    if [ "$state" = missing ]; then
        case "$relayed" in *",$label,"*) state=relayed ;; esac
    fi
    echo "$label $state"
    if [ "$state" = quoted-back ]; then ok=$((ok + 1)); else pending="${pending}${pending:+,}$label"; fi
done <<EOF
$entries
EOF

if [ "$total" -eq 0 ]; then
    echo "INCOMPLETE 0/0 (no leg entries in $doc ## Live state)"
    exit 1
fi
if [ "$ok" -eq "$total" ]; then
    echo "COMPLETE $ok/$total"
    echo "bash scripts/handover/console-kit/append-results.sh $doc \"LIVE — succession complete: all $total inherited legs quoted back to $successor\""
    exit 0
fi
echo "INCOMPLETE $ok/$total (waiting on: $pending)"
exit 1
