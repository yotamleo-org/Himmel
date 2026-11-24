#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# check-new-ticket-ids.sh — refuse a change that ADDS a tracker ticket key to a tracked file.
# A key is a tracker prefix, a hyphen and digits (the pattern is KEY_RE below). Readers of
# the repo see internal tracker numbers that mean nothing to them, and agents copy the lines
# they read, so a key spreads; the operator ruling is that nothing needs one (the commit and
# PR title carry the ticket, handover state keeps it for search).
#
# There is no allow list: a test file, a fixture, a changelog, a data file and a file name
# are judged like any other text. Only ADDED lines (and an added or renamed-to file name
# that carries a key the old name did not) are judged, so the keys already in the tree never
# trip it. A binary file (index blob `-text`) is skipped; the diff keeps --text so a
# .gitattributes `-diff` entry cannot hide an added text line.
#
# Usage:
#   check-new-ticket-ids.sh --staged                       # the index against HEAD (pre-commit)
#   check-new-ticket-ids.sh --range <base> [--tip <ref>]   # <base> against <tip>, tip defaults to HEAD (CI)
# Findings print as `path:line: ticket id: <text>` or `path: ticket id in the file name`.
# Exit: 0 clean · 1 findings · 2 cannot evaluate (fail-closed): git or awk failed, the base
# is unknown, or a changed path is quoted by git

set -uo pipefail
export LC_ALL=C

KEY_RE='(^|[^A-Za-z0-9])(HIMMEL|LUNA|SALUS)-[0-9]+([^0-9]|$)'

usage() { echo "usage: check-new-ticket-ids.sh --staged | --range <base> [--tip <ref>]" >&2; exit 2; }
die() { echo "check-new-ticket-ids: $1, cannot evaluate" >&2; exit 2; }
[ $# -ge 1 ] || usage

mode="" arg="" tip="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) [ -z "$mode" ] || usage; mode="staged"; shift ;;
        --range)  [ $# -ge 2 ] && [ -z "$mode" ] || usage; mode="range"; arg="$2"; shift 2 ;;
        --tip)    [ $# -ge 2 ] || usage; tip="$2"; shift 2 ;;
        *)        usage ;;
    esac
done
[ -n "$mode" ] || usage
if [ "$tip" != "HEAD" ] && [ "$mode" != "range" ]; then usage; fi

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git work tree"
cd "$top" || die "cannot enter $top"

W="$(mktemp -d "${TMPDIR:-/tmp}/check-new-ticket-ids.XXXXXX")" || die "mktemp failed"  # prim-ok: CI runs a base copy of this script alone, without scripts/lib
trap 'rm -rf "$W"' EXIT

case "$mode" in
    staged) base=HEAD
            git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && base=MERGE_HEAD
            set -- --cached "$base" ;;
    range)  base="$arg"
            git rev-parse -q --verify "$tip^{commit}" >/dev/null || die "cannot read the tip $tip"
            set -- "$base" "$tip" ;;
esac
git rev-parse -q --verify "$base^{commit}" >/dev/null || die "cannot read the base $base"

git -c core.quotePath=false diff "$@" --name-status --find-renames --diff-filter=ACMRT > "$W/status" || die "git diff failed"
git -c core.quotePath=false diff "$@" -U0 --text --no-color --no-ext-diff --find-renames --diff-filter=ACMRT > "$W/diff" || die "git diff failed"
grep -q "$(printf '\t')\"" "$W/status"
case $? in
    0) die "git quotes a changed path (a double quote, backslash or control character in its name)" ;;
    1) ;;
    *) die "grep failed on the changed paths" ;;
esac

tipspec=":"
[ "$mode" = "range" ] && tipspec="$tip:"
awk -F'\t' '{ print $NF }' "$W/status" > "$W/touched" || die "awk failed"
: > "$W/bin"
while IFS= read -r p; do
    git show "$tipspec$p" > "$W/blob" 2>/dev/null || die "cannot read $p at the tip"
    all="$(head -c 8000 "$W/blob" | wc -c)"
    txt="$(head -c 8000 "$W/blob" | tr -d '\000' | wc -c)"
    [ "$all" = "$txt" ] || printf '%s\n' "$p" >> "$W/bin"
done < "$W/touched"

awk -F'\t' -v keyre="$KEY_RE" '
    function keys_of(s, set,   r, m) {
        r = s
        while (match(r, keyre)) {
            m = substr(r, RSTART, RLENGTH)
            sub(/^[^A-Za-z0-9]/, "", m); sub(/[^0-9]$/, "", m)
            set[m] = 1
            r = substr(r, RSTART + RLENGTH)
        }
    }
    $1 ~ /^[ACR]/ {
        split("", nk); split("", ok)
        keys_of($NF, nk)
        if ($1 ~ /^[CR]/) keys_of($2, ok)
        for (k in nk) if (!(k in ok)) { printf "%s: ticket id in the file name\n", $NF; break }
    }
' "$W/status" > "$W/names" || die "awk failed"

awk -v keyre="$KEY_RE" -v binlist="$W/bin" '
    BEGIN { while ((getline bp < binlist) > 0) isbin[bp] = 1; close(binlist) }
    function span(s, plus,   r) {
        r = s
        if (plus) { sub(/^[^+]*\+/, "", r); sub(/[ ].*/, "", r) } else { sub(/^[^-]*-/, "", r); sub(/[ ].*/, "", r) }
        return r
    }
    function count(r,   n, a) { n = split(r, a, ","); return n < 2 ? 1 : a[2] + 0 }
    function first(r,   a) { split(r, a, ","); return a[1] + 0 }
    del > 0 || add > 0 {
        c = substr($0, 1, 1)
        if (c == "\\") next
        if (del > 0 && c == "-") { del--; next }
        if (add > 0 && c == "+") {
            add--
            if (path != "" && !(path in isbin)) {
                t = substr($0, 2)
                if (t ~ keyre) { s = t; sub(/^[ \t]+/, "", s); printf "%s:%d: ticket id: %s\n", path, ln, s; bad = 1 }
            }
            ln++
            next
        }
        del = 0; add = 0
    }
    /^@@ / {
        o = $0; sub(/^@@ /, "", o)
        del = count(span(o, 0)); add = count(span(o, 1)); ln = first(span(o, 1))
        next
    }
    /^\+\+\+ / {
        path = substr($0, 7); sub(/\t$/, "", path)
        if ($0 == "+++ /dev/null") path = ""
        next
    }
    END { exit bad ? 1 : 0 }
' "$W/diff" > "$W/lines"
rc=$?
[ "$rc" -le 1 ] || die "awk failed (rc=$rc)"

cat "$W/names" "$W/lines"
[ -s "$W/names" ] || [ "$rc" -eq 1 ] || exit 0

echo "check-new-ticket-ids: a new ticket ID in a tracked file is refused." >&2
echo "  Say what the ID stands for in words; the commit and PR title carry the ticket." >&2
echo "  There is no allow list." >&2
exit 1
