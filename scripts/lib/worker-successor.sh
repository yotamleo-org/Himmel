#!/usr/bin/env bash
# One read-only derivation of a worker's explicitly named hand-off successor.
# Only the worker's leading Results markers count, including its own EOF appends
# below ruling headings. A quoted/mirrored ruling or a filename in Notes proves nothing.
# bash 3.2-safe. Source this library; it performs no close or message action.
_WS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worker-identity.sh
. "$_WS_HERE/worker-identity.sh"

# worker_named_successor <worker doc>: print the newest explicitly named existing
# successor in the same family and directory, or nothing. Never use file mtimes.
worker_named_successor() {
    local doc="$1" dir stem label base named path next_label next_stem expected
    [ -r "$doc" ] || return 0
    dir="$(dirname "$doc")"; stem="$(basename "$doc" .md)"
    label="$(worker_label "$doc")"
    [[ $label =~ ^(N[0-9]+)[a-z]*$ ]] || return 0
    base="${BASH_REMATCH[1]}"
    # shellcheck disable=SC2016  # literal delimiters around Markdown paths
    named="$(awk '
        /^## Results( |$)/ { seen = 1; keep = 1; next }
        /^## / { keep = seen && ($0 ~ /^## (Chief|Console) Rulings( |$)/); next }
        !keep || !/^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|BLOCKED)([^A-Za-z0-9_]|$)/ { next }
        !/([Hh]and-?off|RESUME written:)/ { next }
        {
            found = ""; text = $0
            while (match(text, /[^ \t`"<>():,;]+-RESUME\.md/)) {
                found = substr(text, RSTART, RLENGTH)
                text = substr(text, RSTART + RLENGTH)
            }
        }
        END { print found }
    ' "$doc")" || return 1
    [ -n "$named" ] || return 0
    case "$named" in
        */*) [ "$(dirname "$named")" = "$dir" ] || return 0; path="$named" ;;
        *) path="$dir/$named" ;;
    esac
    [ "$path" != "$doc" ] && [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 0
    next_label="$(worker_label "$path")"
    [[ $next_label =~ ^${base}[a-z]*$ ]] || return 0
    # Equal labels are the legacy <stem>-RESUME hand-off; letters only move forward.
    if [ "$next_label" != "$label" ] && [[ ! $next_label > $label ]]; then return 0; fi
    expected="$(printf '%s' "${stem%-RESUME}" | sed -E "s/-(leg)?${label}(-|\$)/-\\1${next_label}\\2/")-RESUME"
    next_stem="$(basename "$path" .md)"
    [ "$next_stem" = "$expected" ] || return 0
    printf '%s\n' "$path"
}
