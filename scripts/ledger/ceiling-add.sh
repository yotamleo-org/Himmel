#!/usr/bin/env bash
# shellcheck disable=SC2329  # the do_* verbs and their helpers run through with_lock
# scripts/ledger/ceiling-add.sh - the only writer of the ceilings ledger.
#
# Usage:
#   ceiling-add.sh add --file <path> --anchor <name> --ceiling <text> --trigger <text> [--ticket <key>] [--pr <n>] [--note <text>]
#   ceiling-add.sh set --id <C-n> --state open|lifted|obsolete|dropped --note <text> [--pr <n>]
#   ceiling-add.sh import --check <draft.tsv>
#   ceiling-add.sh import --pr <n> <draft.tsv>
#
# add appends one open row and prints its id. set appends a copy of the id's
# newest row with the new state, note, date and PR. import --check validates a
# draft (columns file, anchor, ceiling, trigger, ticket, state, note; an
# optional header row) and appends nothing; import --pr validates it, then
# appends every row not already in the ledger in one lock hold, keyed on
# file + anchor + sha256 of ceiling, and prints
#   import: <n> rows (open a, lifted b, dropped c), skipped <k> already in the ledger
#
# Rules (ledger-lib.sh has the ledger path and row format): no tab or newline
# in a field; an open row's file exists at the cwd checkout's HEAD and its
# anchor is found there with grep -F (obsolete and dropped rows are exempt);
# trigger non-empty for open; a closing state needs a note; ticket key-shaped
# when present; pr digits when present. The ceiling is at most 300 characters
# for add and for a draft row, 2000 for a draft row whose note starts
# `migration: `. The ledger is only ever appended to.
#
# Exit: 0 written or checked; 1 a row refused (each reason named); 2 usage, no
# ledger path, or the lock could not be taken.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ledger/ledger-lib.sh
# shellcheck disable=SC1091
. "$HERE/ledger-lib.sh" || { echo "ceiling-add: cannot load ledger-lib.sh" >&2; exit 2; }
# shellcheck source=scripts/lib/prim.sh
# shellcheck disable=SC1091
. "$HERE/../lib/prim.sh" || { echo "ceiling-add: cannot load scripts/lib/prim.sh" >&2; exit 2; }

usage() { echo "ceiling-add: $*" >&2; echo "usage: ceiling-add.sh add|set|import ... (see the header)" >&2; exit 2; }

TODAY=$(date +%Y-%m-%d)
REFUSED=0
refuse() { echo "ceiling-add: refused: $*" >&2; REFUSED=1; }

# split_tab <line>: FIELDS=(its tab-separated fields), empty fields kept
# (read with IFS=tab would merge two tabs, since tab is IFS whitespace).
split_tab() {
    local rest=$1
    FIELDS=()
    while :; do
        case "$rest" in
            *$'\t'*) FIELDS+=("${rest%%$'\t'*}"); rest=${rest#*$'\t'} ;;
            *) FIELDS+=("$rest"); return 0 ;;
        esac
    done
}

sha256() { { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-64; }

# check_row <where> file anchor ceiling trigger ticket state note pr <cap>
check_row() {
    local w=$1 f=$2 a=$3 c=$4 t=$5 k=$6 s=$7 n=$8 p=$9 cap=${10} v
    for v in "$f" "$a" "$c" "$t" "$k" "$s" "$n" "$p"; do
        case "$v" in *$'\t'*|*$'\n'*|*$'\r'*) refuse "$w: a field holds a tab or a newline"; return ;; esac
    done
    case "$s" in open|lifted|obsolete|dropped) ;; *) refuse "$w: state '$s' is not open, lifted, obsolete or dropped" ;; esac
    [ -n "$f" ] || refuse "$w: file is empty"
    [ -n "$a" ] || refuse "$w: anchor is empty"
    [ -n "$c" ] || refuse "$w: ceiling is empty"
    [ "$(ledger_chars "$c")" -le "$cap" ] || refuse "$w: ceiling is over $cap characters"
    if [ "$s" = open ] && [ -z "$t" ]; then refuse "$w: an open row needs a trigger"; fi
    case "$s" in lifted|obsolete|dropped) [ -n "$n" ] || refuse "$w: state $s needs a note" ;; esac
    [ -z "$k" ] || [[ $k =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || refuse "$w: ticket '$k' is not a key like PROJ-123"
    [ -z "$p" ] || [[ $p =~ ^[1-9][0-9]*$ ]] || refuse "$w: pr '$p' is not a PR number"
    case "$s" in obsolete|dropped) return ;; esac
    if [ -n "$f" ] && [ -n "$a" ]; then
        if ! git cat-file -e "HEAD:$f" 2>/dev/null; then
            refuse "$w: file '$f' does not exist at HEAD of $(pwd)"
        elif ! git show "HEAD:$f" 2>/dev/null | grep -qF -- "$a"; then
            refuse "$w: anchor '$a' is not in $f at HEAD"
        fi
    fi
}

ledger_resolve || { echo "ceiling-add: no ledger path ($LEDGER_WHY)" >&2; exit 2; }
LEDGER=$LEDGER_PATH

# run_locked <fn> ...: run fn under the ledger lock; fn returns 0 written,
# 11 refused, 12 a write failed. Any other status is with_lock's own.
run_locked() {
    local rc=0
    mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || { echo "ceiling-add: cannot create $(dirname "$LEDGER")" >&2; exit 2; }
    with_lock "$LEDGER.lock" "$@" || rc=$?
    case "$rc" in
        0) return 0 ;;
        11) exit 1 ;;
        12) echo "ceiling-add: writing $LEDGER failed" >&2; exit 2 ;;
        *) echo "ceiling-add: could not take or hold the ledger lock $LEDGER.lock (rc=$rc); nothing written. Once no ceiling-add.sh is running, remove $LEDGER.lock and re-run." >&2
           exit 2 ;;
    esac
}

ensure_header() {
    [ -s "$LEDGER" ] || printf '%s\n' "$LEDGER_HEADER" >> "$LEDGER"
}
next_id() {
    awk -F '\t' 'NR > 1 && $1 ~ /^C-[0-9]+$/ { v = substr($1, 3) + 0; if (v > m) m = v } END { printf "C-%04d\n", m + 1 }' "$LEDGER"
}

VERB=${1:-}
[ "$#" -gt 0 ] && shift
case "$VERB" in
add)
    F="" A="" C="" T="" K="" P="" N=""
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || usage "$1 needs a value"
        case "$1" in
            --file) F=$2 ;; --anchor) A=$2 ;; --ceiling) C=$2 ;; --trigger) T=$2 ;;
            --ticket) K=$2 ;; --pr) P=$2 ;; --note) N=$2 ;;
            *) usage "unknown argument $1" ;;
        esac
        shift 2
    done
    check_row add "$F" "$A" "$C" "$T" "$K" open "$N" "$P" 300
    [ "$REFUSED" -eq 0 ] || exit 1
    do_add() {
        local id
        ensure_header || return 12
        id=$(next_id) || return 12
        printf '%s\t%s\t%s\t%s\t%s\t%s\topen\t%s\t%s\t%s\n' "$id" "$F" "$A" "$C" "$T" "$K" "$TODAY" "$P" "$N" >> "$LEDGER" || return 12
        printf '%s\n' "$id"
    }
    run_locked do_add
    ;;
set)
    I="" S="" N="" P=""
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || usage "$1 needs a value"
        case "$1" in
            --id) I=$2 ;; --state) S=$2 ;; --note) N=$2 ;; --pr) P=$2 ;;
            *) usage "unknown argument $1" ;;
        esac
        shift 2
    done
    [[ $I =~ ^C-[0-9]+$ ]] || usage "--id must be C-<n>"
    [ -n "$N" ] || usage "--note is required"
    do_set() {
        local cur row f a c t k
        [ -s "$LEDGER" ] || { refuse "no ledger at $LEDGER"; return 11; }
        cur=$(ledger_current "$LEDGER") || { refuse "the ledger is $cur"; return 11; }
        row=$(printf '%s\n' "$cur" | awk -F '\t' -v id="$I" '$1 == id')
        [ -n "$row" ] || { refuse "no row $I in $LEDGER"; return 11; }
        split_tab "$row"
        f=${FIELDS[1]} a=${FIELDS[2]} c=${FIELDS[3]} t=${FIELDS[4]} k=${FIELDS[5]}
        check_row "set $I" "$f" "$a" "$c" "$t" "$k" "$S" "$N" "$P" 2000
        [ "$REFUSED" -eq 0 ] || return 11
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$I" "$f" "$a" "$c" "$t" "$k" "$S" "$TODAY" "$P" "$N" >> "$LEDGER" || return 12
    }
    run_locked do_set
    ;;
import)
    CHECK=0 P="" DRAFT=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check) CHECK=1; shift ;;
            --pr) [ "$#" -ge 2 ] || usage "--pr needs a value"; P=$2; shift 2 ;;
            -*) usage "unknown argument $1" ;;
            *) [ -z "$DRAFT" ] || usage "one draft file"; DRAFT=$1; shift ;;
        esac
    done
    [ -n "$DRAFT" ] || usage "import needs a draft file"
    [ -f "$DRAFT" ] && [ -r "$DRAFT" ] || usage "cannot read draft $DRAFT"
    # validate and append the same bytes: both passes read one private copy
    SNAP=$(mktemp "${TMPDIR:-/tmp}/ceiling-draft.XXXXXX") || usage "cannot create a temp file"
    trap 'rm -f "$SNAP"' EXIT
    cp -- "$DRAFT" "$SNAP" || usage "cannot read draft $DRAFT"
    if [ "$CHECK" -eq 0 ]; then
        [ -n "$P" ] || usage "import needs --check or --pr <n>"
        [[ $P =~ ^[1-9][0-9]*$ ]] || usage "--pr must be a PR number"
    fi
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
        ln=$((ln + 1))
        [ -n "$line" ] || continue
        [ "$ln" -eq 1 ] && [ "${line%%$'\t'*}" = file ] && continue
        split_tab "$line"
        if [ "${#FIELDS[@]}" -ne 7 ]; then refuse "draft line $ln: ${#FIELDS[@]} fields, want 7"; continue; fi
        f=${FIELDS[0]} a=${FIELDS[1]} c=${FIELDS[2]} t=${FIELDS[3]} k=${FIELDS[4]} s=${FIELDS[5]} n=${FIELDS[6]}
        cap=300
        case "$n" in "migration: "*) cap=2000 ;; esac
        check_row "draft line $ln" "$f" "$a" "$c" "$t" "$k" "$s" "$n" "$P" "$cap"
    done < "$SNAP"
    [ "$REFUSED" -eq 0 ] || exit 1
    if [ "$CHECK" -eq 1 ]; then echo "import --check: $DRAFT passes"; exit 0; fi
    do_import() {
        local keys tmp id num line f a c t k s n key n_open=0 n_lifted=0 n_dropped=0 n_obsolete=0 added=0 skipped=0 ln=0
        ensure_header || return 12
        keys=$(awk -F '\t' 'NR > 1 { print $2 "\t" $3 "\t" $4 }' "$LEDGER" | while IFS= read -r l; do
            printf '%s\t%s\n' "${l%$'\t'*}" "$(printf '%s' "${l##*$'\t'}" | sha256)"; done) || return 12
        id=$(next_id) || return 12
        num=$((10#${id#C-}))
        tmp=$(mktemp "$(dirname "$LEDGER")/.ceiling-import.XXXXXX") || return 12
        while IFS= read -r line || [ -n "$line" ]; do
            ln=$((ln + 1))
            [ -n "$line" ] || continue
            [ "$ln" -eq 1 ] && [ "${line%%$'\t'*}" = file ] && continue
            split_tab "$line"
            f=${FIELDS[0]} a=${FIELDS[1]} c=${FIELDS[2]} t=${FIELDS[3]} k=${FIELDS[4]} s=${FIELDS[5]} n=${FIELDS[6]}
            key="$f"$'\t'"$a"$'\t'"$(printf '%s' "$c" | sha256)"
            if printf '%s\n' "$keys" | grep -qxF -- "$key"; then skipped=$((skipped + 1)); continue; fi
            keys="$keys"$'\n'"$key"
            printf 'C-%04d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$f" "$a" "$c" "$t" "$k" "$s" "$TODAY" "$P" "$n" >> "$tmp" || { rm -f "$tmp"; return 12; }
            num=$((num + 1)) added=$((added + 1))
            case "$s" in open) n_open=$((n_open + 1)) ;; lifted) n_lifted=$((n_lifted + 1)) ;;
                dropped) n_dropped=$((n_dropped + 1)) ;; obsolete) n_obsolete=$((n_obsolete + 1)) ;; esac
        done < "$SNAP"
        # one append of every new row under the lock; a reader racing it sees
        # whole rows only (ledger_current leaves out a torn last line)
        cat "$tmp" >> "$LEDGER" || { rm -f "$tmp"; return 12; }
        rm -f "$tmp"
        printf 'import: %s rows (open %s, lifted %s, dropped %s%s), skipped %s already in the ledger\n' \
            "$added" "$n_open" "$n_lifted" "$n_dropped" "$([ "$n_obsolete" -eq 0 ] || printf ', obsolete %s' "$n_obsolete")" "$skipped"
    }
    run_locked do_import
    ;;
*) usage "unknown verb '${VERB}'" ;;
esac
exit 0
