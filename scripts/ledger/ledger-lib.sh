# shellcheck shell=bash
# shellcheck disable=SC2034  # LEDGER_* are set for the sourcing script
# scripts/ledger/ledger-lib.sh - shared by ceiling-add.sh and ceiling-lookup.sh.
# Sourced; defines functions only. Bash 3.2+.
#
# The ceilings ledger is <bucket>/specs/ledgers/ceilings.tsv, one per bucket,
# where <bucket> is keyed on the repo under review (the cwd's checkout, or
# --repo <owner/name>), never on where this script lives:
#   HIMMEL_CEILINGS_LEDGER  the ledger file itself (tests point it at a fixture)
#   HIMMEL_BUCKET_DIR       <bucket>, so the file is <bucket>/specs/ledgers/ceilings.tsv
#   else                    go_resolve_root <this checkout> + go_verdict_scope <cwd's checkout> [<owner/name>]
#
# Rows: TSV, one header row, append-only, ten fields; a state change appends a
# row with the same id and the newest row per id is that id's state.

LEDGER_HEADER=$'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote'

# ledger_resolve [<owner/name>]: set LEDGER_PATH and LEDGER_REPO (the bucket name
# for messages) and return 0; on failure set LEDGER_WHY and return 1. The file
# itself may not exist.
ledger_resolve() {
    local repo="${1:-}" lib_dir anchor root scope top
    LEDGER_PATH="" LEDGER_REPO="" LEDGER_WHY=""
    if [ -n "${HIMMEL_CEILINGS_LEDGER:-}" ]; then
        LEDGER_PATH=$HIMMEL_CEILINGS_LEDGER LEDGER_REPO=${repo:-HIMMEL_CEILINGS_LEDGER}
        return 0
    fi
    if [ -n "${HIMMEL_BUCKET_DIR:-}" ]; then
        LEDGER_PATH="$HIMMEL_BUCKET_DIR/specs/ledgers/ceilings.tsv" LEDGER_REPO=${repo:-${HIMMEL_BUCKET_DIR##*/}}
        return 0
    fi
    lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || { LEDGER_WHY="cannot find the ledger lib"; return 1; }
    anchor=$(cd "$lib_dir/../.." && pwd) || { LEDGER_WHY="cannot find the harness checkout"; return 1; }
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    if ! { [ -r "$anchor/scripts/lib/handover-path.sh" ] && . "$anchor/scripts/lib/handover-path.sh"; } 2>/dev/null; then
        LEDGER_WHY="cannot load handover-path.sh"; return 1
    fi
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if ! { [ -r "$anchor/scripts/lib/go-gate.sh" ] && . "$anchor/scripts/lib/go-gate.sh"; } 2>/dev/null \
            || ! declare -F go_resolve_root >/dev/null 2>&1 || ! declare -F go_verdict_scope >/dev/null 2>&1; then
        LEDGER_WHY="cannot load go-gate.sh"; return 1
    fi
    if [ -n "$repo" ]; then
        top=$anchor
    else
        top=$(git rev-parse --show-toplevel 2>/dev/null) || { LEDGER_WHY="not a git checkout"; return 1; }
    fi
    root=$(go_resolve_root "$anchor" 2>/dev/null) || root=""
    [ -n "$root" ] || { LEDGER_WHY="no handover root"; return 1; }
    scope=$(go_verdict_scope "$top" ${repo:+"$repo"} 2>/dev/null) || scope=""
    [ -n "$scope" ] || { LEDGER_WHY="no bucket for ${repo:-this checkout}"; return 1; }
    LEDGER_PATH="$root/$scope/specs/ledgers/ceilings.tsv" LEDGER_REPO=${repo:-${scope#*/}}
    return 0
}

# ledger_current <file>: print the newest row per id, in the order each id
# first appeared. A row that is not ten fields, or a header that differs,
# prints only `malformed ...` and returns 1. The file is read once; a last
# line with no newline is an append still in progress and is left out, so a
# reader racing a writer sees whole rows.
ledger_current() {
    local snap
    snap=$(cat -- "$1" && printf x) || { echo "malformed ledger (unreadable)"; return 1; }
    snap=${snap%x}
    case "$snap" in *$'\n') ;; *) snap=${snap%"${snap##*$'\n'}"} ;; esac
    printf '%s' "$snap" | awk -F '\t' -v hdr="$LEDGER_HEADER" '
        NR == 1 { if ($0 != hdr) { print "malformed header"; bad = 1; exit } next }
        $0 == "" { next }
        NF != 10 || $1 !~ /^C-[0-9]+$/ { print "malformed row at line " NR; bad = 1; exit }
        { if (!($1 in row)) order[++n] = $1; row[$1] = $0 }
        END { if (bad) exit 1; for (i = 1; i <= n; i++) print row[order[i]] }
    '
}

# ledger_chars <text>: its length in characters (UTF-8 continuation bytes not counted).
ledger_chars() {
    printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}
