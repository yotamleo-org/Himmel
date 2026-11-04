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
    local doc="$1" dir stem label base named path next_label next_stem expected own_set suc_set own_n
    [ -r "$doc" ] || return 0
    dir="$(dirname "$doc")"; stem="$(basename "$doc" .md)"
    label="$(worker_label "$doc")"
    [[ $label =~ ^(N[0-9]+)[a-z]*$ ]] || return 0
    base="${BASH_REMATCH[1]}"
    # shellcheck disable=SC2016  # literal delimiters around Markdown paths
    # Only the first Results heading opens the worker's own record: a second one is quoted text.
    # A negated hand-off ("not a hand-off", "no hand-off to ...") names no successor.
    named="$(awk '
        /^## Results([ \t]|$)/ { keep = !seen; seen = 1; next }
        /^## / { keep = seen && ($0 ~ /^## (Chief|Console) Rulings([ \t]|$)/); next }
        !keep || !/^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|BLOCKED)([^A-Za-z0-9_]|$)/ { next }
        !/([Hh]and-?off|RESUME written:)/ { next }
        /(^|[^A-Za-z0-9_])([Nn]o|[Nn]ot|[Nn]ever|[Ww]ithout|[Cc]annot)[^A-Za-z0-9_][^;.]{0,30}[Hh]and-?off/ { next }
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
    # A successor that never launched proves nothing: its own Results must hold a marker bullet.
    awk '
        /^## Results([ \t]|$)/ { r = !seen; seen = 1; next }
        /^## / { r = seen && ($0 ~ /^## (Chief|Console) Rulings([ \t]|$)/); next }
        r && /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/ { f = 1; exit }
        END { exit !f }' "$path" || return 0
    # A successor running under any of this worker's own session names is no distinct worker.
    own_set=",$(worker_identity "$doc" | cut -f2),$stem,"
    suc_set=",$(worker_identity "$path" | cut -f2),$next_stem,"
    for own_n in ${own_set//,/ }; do
        case "$suc_set" in *",$own_n,"*) return 0 ;; esac
    done
    printf '%s\n' "$path"
}

# worker_handoff_tail <worker doc>: success when the worker's newest own marker bullet is itself a
# WRAPPED or BLOCKED hand-off (not negated) and that hand-off names a successor. A later ordinary
# BLOCKED (waiting on CI) is a working worker and fails.
worker_handoff_tail() {
    local last
    [ -r "$1" ] || return 1
    last="$(awk '
        /^## Results([ \t]|$)/ { r = !seen; seen = 1; next }
        /^## / { r = seen && ($0 ~ /^## (Chief|Console) Rulings([ \t]|$)/); next }
        r && /^- ([0-9]?[0-9]:[0-9][0-9][ \t]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_]|$)/ { l = $0 }
        END { print l }' "$1")" || return 1
    printf '%s\n' "$last" | grep -Eq '^- ([0-9]?[0-9]:[0-9][0-9][[:space:]]+)?(\*\*)?(WRAPPED|BLOCKED)([^A-Za-z0-9_]|$)' || return 1
    printf '%s\n' "$last" | grep -Eq '([Hh]and-?off|RESUME written:)' || return 1
    ! printf '%s\n' "$last" | grep -Eq '(^|[^A-Za-z0-9_])([Nn]o|[Nn]ot|[Nn]ever|[Ww]ithout|[Cc]annot)[^A-Za-z0-9_][^;.]{0,30}[Hh]and-?off' || return 1
    [ -n "$(worker_named_successor "$1")" ]
}
