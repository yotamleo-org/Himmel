#!/usr/bin/env bash
# succession-tracker.sh — The successor chief's tally of its inherited workers'
# quote-backs, so it reads one table instead of counting ~26 SendMessage replies by hand.
#
#   succession-tracker.sh <chief doc> --successor <session> [--relayed <label>[,<label>...]]
#
# The inherited set is the chief doc's `## Live state` `legs:` entries (the same parse
# relay-batch.sh uses). Each worker's doc comes from the fleet manifest next to the chief doc
# (<chief doc stem>.fleet.json). Per worker it prints one state:
#   quoted-back  the worker's LATEST `SUCCESSION accepted:` Results bullet names --successor as
#                the incoming chief (the worker took this chief over)
#   relayed      no such bullet yet, but the worker is listed in --relayed (the predecessor's
#                relay-batch.sh output, which a script cannot observe being sent)
#   missing      anything else: no bullet, a bullet naming another chief, an ambiguous
#                line, a worker with no manifest row. An ambiguous line is never accepted.
#   own          the worker's brief names --successor as its console: the successor dispatched it,
#                so it is not inherited and is left out of the tally
# The bullet grammar is strict, one whole line:
#   - [HH:MM ][LIVE — ]SUCCESSION accepted: [`]<incoming>[`] replaces [`]<outgoing>[`]
# and it must be a `- ` bullet, so a prose line or a mirrored relay quoting it confirms nothing.
# It is read from `## Results` to the end of the doc: append-results.sh writes at EOF, which on
# a claudex worker is inside the `## Chief Rulings` section inbox-send.sh opened. The latest
# bullet that starts the handshake decides, so a newer ambiguous one outranks an older clean one.
#
# When every worker is quoted-back it prints `COMPLETE n/n` and the exact append-results.sh
# command that writes the LIVE bullet. PRINT ONLY: it never sends a message, never edits a
# doc, never rotates a token; the chief runs the printed line itself. An empty worker set is
# INCOMPLETE, never complete.
#
# Exit: 0 complete; 1 incomplete (or no workers); 2 usage.
# PLATFORM GUARD: the chief kit is Linux-only, as its siblings.
# bash 3.2-safe; needs jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# the manifest worker array is `workers`; a manifest not yet rewritten holds the pre-rename `legs`, read only while legacy names are on
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh"
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi

usage() { echo "usage: succession-tracker.sh <chief doc> --successor <session> [--relayed <label>[,<label>...]]" >&2; exit 2; }
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
# the successor is pasted into a quoted message in the printed command: a session name only
case "$successor" in *[!A-Za-z0-9_.-]*) echo "succession-tracker.sh: --successor must be a session name (letters, digits, . _ -)" >&2; exit 2 ;; esac
manifest="${doc%.md}.fleet.json"

# The worker block of ## Live state (the `workers:` line plus the lines wrapped under it). The
# pre-rename `legs:` line is read only while legacy names are on; `workers:` wins when both exist.
live_key=workers
if ! awk '$0 == "## Live state" { s = 1; next } s && /^## / { exit } s && /^workers:/ { f = 1 } END { exit !f }' "$doc" && legacy_names_on; then live_key=legs; fi
# shellcheck disable=SC2016  # the backticks are literal markers in the Live state / the bullet
block="$(awk -v k="$live_key" '
    $0 == "## Live state" { s = 1; next }
    s && /^## / { exit }
    s && index($0, k ":") == 1 { b = 1; print; next }
    b && (/^[[:space:]]*$/ || /^[0-9]+\. / || /^[A-Za-z][A-Za-z ]*:/ || /^[-*+>#]/) { b = 0 }
    b { print }
' "$doc")"
# Prose may sit on or between the spans (the tick reads it as prose). Malformed is only a
# label-shaped colon span that is not four non-empty fields, a bare (un-backticked) label plus
# three more colon fields, or a stray backtick: each would otherwise vanish as prose.
label_shaped() { [[ $1 =~ ^N[0-9]+[a-z]*$ ]] || [[ $1 =~ -N[0-9]+[a-z]*- ]]; }
entries=""; malformed=""
# shellcheck disable=SC2016
spans="$(printf '%s\n' "$block" | grep -oE '`[^`]*`' | tr -d '`')"
while IFS= read -r span; do
    case "$span" in ''|*[[:space:]]*) continue ;; esac
    f1="${span%%:*}"
    [ "$f1" != "$span" ] || continue
    case "$f1" in *[!A-Za-z0-9_.-]*) continue ;; esac
    colons="${span//[!:]/}"
    case ":$span:" in
        *::*) ok4=0 ;;
        *) if [ "${#colons}" -eq 3 ]; then ok4=1; else ok4=0; fi ;;
    esac
    if [ "$ok4" -eq 1 ]; then
        entries="${entries}${f1}
"
    elif label_shaped "$f1"; then
        malformed="${malformed}${malformed:+ }$f1"
    fi
done <<EOS
$spans
EOS
# shellcheck disable=SC2016
rest="$(printf '%s\n' "$block" | sed -E -e 's/`[^`]*`/ /g' -e "s/^${live_key}://")"
# shellcheck disable=SC2016
case "$rest" in *'`'*) malformed="${malformed}${malformed:+ }unbalanced-backtick" ;; esac
set -f
for word in $rest; do
    word="${word%%[,.;]}"
    colons="${word//[!:]/}"
    [ "${#colons}" -eq 3 ] || continue
    if label_shaped "${word%%:*}"; then malformed="${malformed}${malformed:+ }${word%%:*}"; fi
done
set +f
if [ -n "$malformed" ]; then
    echo "INCOMPLETE 0/0 (malformed workers entry in $doc ## Live state: $malformed)"
    exit 1
fi
entries="$(printf '%s' "$entries" | awk 'NF && !seen[$0]++')"
# A manifest worker the Live state does not list still counts as inherited (relay-batch.sh reports
# the same workers as NOT-IN-LIVE-STATE), so a dropped entry cannot make the set read complete.
if [ -n "$entries" ] && [ -f "$manifest" ]; then
    if ! mlabels="$(jq -r "$JQ_W"'W[] | select(.lockless == true | not) | .label' "$manifest" 2>/dev/null)"; then
        echo "INCOMPLETE 0/0 (fleet manifest $manifest is unreadable: cannot cross-check the workers)"
        exit 1
    fi
    for ml in $mlabels; do
        printf '%s\n' "$entries" | grep -Fxq -- "$ml" || entries="${entries}${entries:+
}$ml"
    done
fi

# state of one worker doc: prints own, quoted-back or missing
worker_state() {
    local ldoc="$1" line inc brief
    [ -f "$ldoc" ] || { echo missing; return; }
    brief="$(awk '/^## Results/ { exit } { print }' "$ldoc")"
    # shellcheck disable=SC2016
    if grep -Fq -- "your chief is **\`$successor\`**" <<< "$brief"; then
        echo own; return
    fi
    # the latest handshake bullet from the Results section on decides; the same text in the
    # brief confirms nothing
    line="$(awk '/^## Results/ { s = 1; next } s && /^- ([0-9][0-9]:[0-9][0-9] )?(LIVE — )?SUCCESSION accepted/ { l = $0 } END { print l }' "$ldoc")"
    [ -n "$line" ] || { echo missing; return; }
    # backticks come as a balanced pair or not at all
    # shellcheck disable=SC2016
    inc="$(printf '%s\n' "$line" | sed -nE \
        -e 's/^- ([0-9]{2}:[0-9]{2} )?(LIVE — )?SUCCESSION accepted: `([A-Za-z0-9_.-]+)` replaces (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+)[[:space:]]*$/\3/p' \
        -e 's/^- ([0-9]{2}:[0-9]{2} )?(LIVE — )?SUCCESSION accepted: ([A-Za-z0-9_.-]+) replaces (`[A-Za-z0-9_.-]+`|[A-Za-z0-9_.-]+)[[:space:]]*$/\3/p' | head -n 1)"
    if [ -n "$inc" ] && [ "$inc" = "$successor" ]; then echo quoted-back; else echo missing; fi
}

total=0; ok=0; pending=""
while IFS= read -r label; do
    [ -n "$label" ] || continue
    ldoc=""
    if [ -f "$manifest" ]; then
        ldoc="$(jq -r --arg l "$label" "$JQ_W"'[W[] | select(.label == $l)][0].doc // empty' "$manifest" 2>/dev/null)"
    fi
    state="$(worker_state "$ldoc")"
    if [ "$state" = own ]; then
        echo "$label own (dispatched by $successor, not inherited)"
        continue
    fi
    total=$((total + 1))
    if [ "$state" = missing ]; then
        case "$relayed" in *",$label,"*) state=relayed ;; esac
    fi
    echo "$label $state"
    if [ "$state" = quoted-back ]; then ok=$((ok + 1)); else pending="${pending}${pending:+,}$label"; fi
done <<EOF
$entries
EOF

if [ "$total" -eq 0 ]; then
    echo "INCOMPLETE 0/0 (no worker entries in $doc ## Live state)"
    exit 1
fi
if [ "$ok" -eq "$total" ]; then
    echo "COMPLETE $ok/$total"
    printf 'bash scripts/handover/chief-kit/append-results.sh %q "LIVE — succession complete: all %s inherited workers quoted back to %s"\n' "$doc" "$total" "$successor"
    exit 0
fi
echo "INCOMPLETE $ok/$total (waiting on: $pending)"
exit 1
