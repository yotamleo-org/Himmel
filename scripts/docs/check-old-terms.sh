#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+ plus git/awk/grep.
#
# check-old-terms.sh — refuse a NEW retired name in tracked text.
# The registry scripts/lib/rename-aliases.tsv is the only list. Rows scanned, by kind and direction:
#   identifier, marker with direction old-to-new   fail tier
#   prose with direction fail                      fail tier
#   prose with direction warn                      warn tier: printed, never fails
# Switching a prose row from warn to fail in the registry is the whole switch.
# Not scanned: keep rows (do-not-rename and other-sense names are masked out of a line
# before it is read, so a retired word inside one is no hit), the registry itself, the
# baseline, binary files, and the env, env-prefix, path and directory rows (those stay
# with scripts/ci/check-rename-diff.sh). A line carrying `old-term-ok` is skipped.
#
# The retired-name hits already in the tree are counted per file in
# scripts/docs/old-terms-baseline.tsv (key<TAB>count, the key being the git blob hash
# of the path, so the baseline carries no file name for a name scan to count). Only the
# files a change touches are judged, so a change that touches no file holding a retired
# name can never fail:
#   a touched file may not hold more fail-tier hits (a line naming two retired names counts two) than the base's version of it
#   (for a renamed file, the version it was renamed from)
#   a baseline row may not rise above the base's row for that path (or for the path it was
#   renamed from), and a new row above zero is refused; a row that only records the
#   count the base's file already had passes (a registry that grew made the row stale)
# A base without a baseline has no rows to compare: the first baseline is taken as it is.
#
# Usage:
#   check-old-terms.sh --staged                       # the index against HEAD (pre-commit)
#   check-old-terms.sh --range <base> [--tip <ref>]   # the fork point of <base> against <tip>, tip defaults to HEAD (CI)
#   check-old-terms.sh --write-baseline               # rewrite the baseline from the working tree
# Exit: 0 clean (warn-tier hits are printed) · 1 findings · 2 cannot evaluate (fail-closed):
# the registry or the tip's baseline is missing or unreadable, or git/awk failed

set -uo pipefail
export LC_ALL=C

usage() { echo "usage: check-old-terms.sh --staged | --range <base> [--tip <ref>] | --write-baseline" >&2; exit 2; }
die() { echo "check-old-terms: $1, cannot evaluate" >&2; exit 2; }
[ $# -ge 1 ] || usage

REG=scripts/lib/rename-aliases.tsv
BL=scripts/docs/old-terms-baseline.tsv

mode="" arg="" tip="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) [ -z "$mode" ] || usage; mode="staged"; shift ;;
        --range)  [ $# -ge 2 ] && [ -z "$mode" ] || usage; mode="range"; arg="$2"; shift 2 ;;
        --write-baseline) [ -z "$mode" ] || usage; mode="write"; shift ;;
        --tip)    [ $# -ge 2 ] || usage; tip="$2"; shift 2 ;;
        *)        usage ;;
    esac
done
[ -n "$mode" ] || usage
if [ "$tip" != "HEAD" ] && [ "$mode" != "range" ]; then usage; fi

top="$(git rev-parse --show-toplevel)" || die "not in a git work tree"
cd "$top" || die "cannot enter $top"
W="$(mktemp -d "${TMPDIR:-/tmp}/check-old-terms.XXXXXX")" || die "mktemp failed"  # prim-ok: CI runs a base copy of this script alone, without scripts/lib
trap 'rm -rf "$W"' EXIT

# shellcheck disable=SC2016  # the awk program is single-quoted on purpose
matcher='
function blank(n) { return substr(SP, 1, n) }
function mask(h, ph,   out, i) {
    out = ""
    while ((i = index(h, ph)) > 0) { out = out substr(h, 1, i - 1) blank(length(ph)); h = substr(h, i + length(ph)) }
    return out h
}
function maskprefix(h, ph,   out, i, j) {
    out = ""
    while ((i = index(h, ph)) > 0) {
        j = i + length(ph)
        while (j <= length(h) && substr(h, j, 1) ~ /[A-Za-z0-9_]/) j++
        out = out substr(h, 1, i - 1) blank(j - i)
        h = substr(h, j)
    }
    return out h
}
BEGIN {
    SP = sprintf("%256s", "")
    r = 0
    while ((getline line < registry) > 0) {
        if (line ~ /^#/ || line == "") continue
        n = split(line, f, "\t")
        if (n < 4 || f[1] == "old") continue
        old = f[1]; new = f[2]; kind = f[3]; dir = f[4]
        if (dir == "keep") {
            if (substr(old, length(old)) == "_") keepp[++nkp] = old; else keepx[++nkx] = old
            continue
        }
        if (old == new) continue
        ty = ""; tier = ""
        if (kind == "prose") { ty = "prose"; if (dir == "fail") tier = "fail"; else if (dir == "warn") tier = "warn" }
        else if ((kind == "identifier" || kind == "marker") && dir == "old-to-new") { ty = "ident"; tier = "fail" }
        if (tier == "") continue
        r++
        shown[r] = old; N[r] = new; T[r] = ty; TIER[r] = tier
        O[r] = (ty == "prose") ? tolower(old) : old
        NL[r] = tolower(new)
    }
    close(registry)
}
{
    if (!match($0, /:[0-9]+:/)) next
    path = substr($0, 1, RSTART - 1)
    ln = substr($0, RSTART + 1, RLENGTH - 2)
    text = substr($0, RSTART + RLENGTH)
    if (path == skipa || path == skipb) next
    if (index(text, "old-term-ok") > 0) next
    ht = text
    for (k = 1; k <= nkx; k++) ht = mask(ht, keepx[k])
    for (k = 1; k <= nkp; k++) ht = maskprefix(ht, keepp[k])
    lower = tolower(ht)
    m = 0
    for (k = 1; k <= r; k++) {
        o = O[k]; ty = T[k]
        if (ty == "prose") { hay = lower; if (index(NL[k], o) > 0) hay = mask(hay, NL[k]) }
        else hay = ht
        if (index(hay, o) == 0) continue
        pos = 1
        while ((i = index(substr(hay, pos), o)) > 0) {
            s = pos + i - 1
            pos = s + 1
            e = s + length(o)
            before = (s > 1) ? substr(hay, s - 1, 1) : ""
            after = substr(hay, e, 1)
            ok = 1
            if (before ~ /[A-Za-z0-9_]/) ok = 0
            if (ok && ty == "prose" && after == "s" && substr(hay, e + 1, 1) !~ /[A-Za-z0-9_]/) { e++; after = substr(hay, e, 1) }
            if (ok && after ~ /[A-Za-z0-9_]/) ok = 0
            if (ok && ty == "prose" && after == "." && substr(hay, e + 1, 1) ~ /[A-Za-z_]/) ok = 0
            if (ok) { m++; ms[m] = s; me[m] = e; mr[m] = k }
        }
    }
    for (a = 1; a <= m; a++) {
        drop = 0
        for (b = 1; b <= m && !drop; b++) {
            if (a == b) continue
            if (ms[b] <= ms[a] && me[b] >= me[a] && (ms[b] < ms[a] || me[b] > me[a] || b < a)) drop = 1
        }
        if (drop) continue
        shown_text = text
        if (length(shown_text) > 160) shown_text = substr(shown_text, 1, 160) "..."
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", TIER[mr[a]], path, ln, shown[mr[a]], N[mr[a]], shown_text
    }
}
'
scan() { awk -v registry="$W/reg" -v skipa="$REG" -v skipb="$BL" "$matcher"; }

keys() {
    local p i=0
    mkdir -p "$W/k" || die "mkdir failed"
    : > "$W/k.list"
    while IFS= read -r p; do
        i=$((i + 1))
        printf '%s' "$p" > "$W/k/$i" || die "cannot write under $W"
        printf '%s\n' "$W/k/$i" >> "$W/k.list"
    done < "$1"  # read-sink-ok: every caller passes a list the gate itself wrote under $W
    git hash-object --no-filters --stdin-paths < "$W/k.list" > "$W/k.out" || die "cannot hash the paths"
    [ "$(awk 'END { print NR }' "$W/k.out")" -eq "$i" ] || die "cannot hash the paths"
    paste "$W/k.out" "$1" > "$2" || die "paste failed"
}

if [ "$mode" = "write" ]; then
    [ -r "$REG" ] || die "cannot read $REG"
    cp "$REG" "$W/reg" || die "cp failed"
    { git -c core.quotePath=false grep -I -n --no-color -e .; g=$?; [ "$g" -le 1 ]; } | scan > "$W/hits" || die "the scan failed"
    awk -F'\t' '$1 == "fail" { c[$2]++ } END { for (p in c) print p "\t" c[p] }' "$W/hits" | sort > "$W/rows" || die "awk failed"
    awk -F'\t' '{ print $1 }' "$W/rows" > "$W/named" || die "awk failed"
    : > "$W/map"
    if [ -s "$W/named" ]; then keys "$W/named" "$W/map"; fi
    awk -F'\t' 'FILENAME == ARGV[1] { key[$2] = $1; next } { print key[$1] "\t" $2 }' "$W/map" "$W/rows" | sort > "$BL" || die "cannot write $BL"
    echo "check-old-terms: wrote $BL ($(awk -F'\t' '{ n += $2 } END { print NR " files, " n + 0 " hits" }' "$BL"))"
    exit 0
fi

case "$mode" in
    staged) base=HEAD
            git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && base=MERGE_HEAD
            fork="$base"
            tipspec=":"
            set -- --cached "$base" ;;
    range)  base="$arg"
            git rev-parse -q --verify "$base^{commit}" >/dev/null || die "no such base: $base"
            git rev-parse -q --verify "$tip^{commit}" >/dev/null || die "no such tip: $tip"
            fork="$(git merge-base "$base" "$tip")" || die "no common history with base: $base"
            tipspec="$tip:"
            set -- "$fork" "$tip" ;;
esac

has_at() { git cat-file -e "$1$2" 2>/dev/null; }
blob_count() {
    git show "$1$2" > "$W/blob" 2>/dev/null || die "cannot read $2 at $1"
    grep -Iq . "$W/blob"
    case $? in
        0) ;;
        1) echo 0; return ;;
        *) die "grep failed on $2" ;;
    esac
    awk -v p="$2" '{ printf "%s:%d:%s\n", p, NR, $0 }' "$W/blob" | scan > "$W/bh" || die "the scan failed on $2"
    awk -F'\t' '$1 == "fail" { n++ } END { print n + 0 }' "$W/bh"
}
count_ok() { case "$1" in ''|*[!0-9]*|??????????*) return 1 ;; esac; }

git show "$tipspec$REG" > "$W/reg" 2>/dev/null || die "$REG is absent at the tip"
git show "$tipspec$BL" > "$W/tip.tsv" 2>/dev/null || die "$BL is absent at the tip"
has_base=0
: > "$W/base.tsv"
if has_at "$fork:" "$BL"; then
    git show "$fork:$BL" > "$W/base.tsv" || die "cannot read $BL at the base"
    has_base=1
fi
for f in tip base; do
    awk -F'\t' 'NF != 2 || $2 !~ /^[0-9]+$/ || length($2) > 9 { bad = 1 } END { exit bad }' "$W/$f.tsv" || die "a row of $BL at the $f carries no key and count of at most 9 digits"
done

git -c core.quotePath=false diff "$@" --name-status --find-renames --diff-filter=ACMRT > "$W/status" || die "git diff failed"
grep -q "$(printf '\t')\"" "$W/status"
case $? in
    0) die "git quotes a changed path (a double quote, backslash or control character in its name)" ;;
    1) ;;
    *) die "grep failed on the changed paths" ;;
esac
awk -F'\t' -v a="$REG" -v b="$BL" '$NF != a && $NF != b { print $NF }' "$W/status" > "$W/touched"
awk -F'\t' '$1 ~ /^R/ { print $2 "\t" $3 }' "$W/status" > "$W/renames"
git -c core.quotePath=false diff "$@" -U0 --text --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --find-renames --diff-filter=ACMRT \
    | awk '
        /^diff --git / { inhdr = 1; next }
        inhdr && /^\+\+\+ / { file = $0; sub(/^\+\+\+ b\//, "", file); next }
        /^@@ / { inhdr = 0; n = $0; sub(/^@@ -[0-9,]+ \+/, "", n); sub(/[, ].*/, "", n); n += 0; next }
        /^\+/ && !inhdr { printf "%s:%d:%s\n", file, n++, substr($0, 2) }' \
    | scan > "$W/added" || die "the scan failed"

: > "$W/findings"
while IFS= read -r p; do
    has_at "$tipspec" "$p" || continue
    n="$(blob_count "$tipspec" "$p")" || die "cannot count $p at the tip"
    was="$(awk -F'\t' -v p="$p" '$2 == p { print $1; exit }' "$W/renames")"
    m=0
    if has_at "$fork:" "${was:-$p}"; then m="$(blob_count "$fork:" "${was:-$p}")" || die "cannot count ${was:-$p} at the base"; fi
    if ! count_ok "$n" || ! count_ok "$m"; then die "no count for $p"; fi
    if [ "$n" -gt "$m" ]; then
        printf 'A\t%s\t%s\t%s\n' "$p" "$n" "$m" >> "$W/findings"
    fi
done < "$W/touched"

if [ "$has_base" -eq 1 ]; then
    awk -F'\t' '{ print $1; print $2 }' "$W/renames" > "$W/named"
    cat "$W/touched" >> "$W/named"
    sort -u "$W/named" > "$W/named.u" || die "sort failed"
    : > "$W/map"
    if [ -s "$W/named.u" ]; then keys "$W/named.u" "$W/map"; fi
    awk -F'\t' '{ print $1 "\t" $2 }' "$W/renames" > "$W/pairs"
    : > "$W/pairs.k"
    while IFS="$(printf '\t')" read -r from to; do
        fk="$(awk -F'\t' -v p="$from" '$2 == p { print $1; exit }' "$W/map")"
        tk="$(awk -F'\t' -v p="$to" '$2 == p { print $1; exit }' "$W/map")"
        printf '%s\t%s\n' "$fk" "$tk" >> "$W/pairs.k"
    done < "$W/pairs"
    raised() {
        awk -F'\t' '
            FILENAME == ARGV[1] { b[$1] = $2 + 0; next }
            FILENAME == ARGV[2] { from[$2] = $1; next }
            {
                lim = ($1 in b) ? b[$1] : (($1 in from) && (from[$1] in b)) ? b[from[$1]] : 0
                if ($2 + 0 > lim) print $1 "\t" $2 "\t" lim
            }
        ' "$W/base.tsv" "$W/pairs.k" "$W/tip.tsv" > "$W/rose" || die "awk failed"
    }
    raised
    if [ -s "$W/rose" ]; then
        git -c core.quotePath=false ls-tree -r --name-only "${tipspec%:}" > "$W/tree" 2>/dev/null || git -c core.quotePath=false ls-files --cached > "$W/tree" || die "cannot list the tip"
        git -c core.quotePath=false ls-tree -r --name-only "$fork" >> "$W/tree" || die "cannot list the base"
        sort -u "$W/tree" > "$W/tree.u" || die "sort failed"
        keys "$W/tree.u" "$W/map.all"
        cat "$W/map.all" >> "$W/map" || die "cat failed"
        while IFS="$(printf '\t')" read -r key n lim; do
            p="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$W/map")"
            if [ -z "$p" ]; then
                printf 'B\t%s\t%s\t%s\n' "a row that names no file at the tip or the base" "$n" "$lim" >> "$W/findings"
                continue
            fi
            was="$(awk -F'\t' -v p="$p" '$2 == p { print $1; exit }' "$W/renames")"
            m=0
            if has_at "$fork:" "${was:-$p}"; then m="$(blob_count "$fork:" "${was:-$p}")" || die "cannot count ${was:-$p} at the base"; fi
            count_ok "$m" || die "no count for ${was:-$p}"
            if [ "$n" -le "$m" ]; then continue; fi
            printf 'B\t%s\t%s\t%s\n' "row for $p" "$n" "$lim" >> "$W/findings"
        done < "$W/rose"
    fi
fi

if [ -s "$W/added" ]; then
    awk -F'\t' '$1 == "warn" { printf "WARN %s:%s: %s -> %s: %s\n", $2, $3, $4, $5, $6 }' "$W/added" >&2
fi

if [ -s "$W/findings" ]; then
    while IFS="$(printf '\t')" read -r kind p n lim; do
        if [ "$kind" = "B" ]; then
            echo "$BL: $p raised to $n, the base allows $lim"
            continue
        fi
        echo "$p: $n retired-name hits, the base's version has $lim"
        awk -F'\t' -v p="$p" '$1 == "fail" && $2 == p { printf "  %s:%s: %s -> %s: %s\n", $2, $3, $4, $5, $6 }' "$W/added"
    done < "$W/findings"
    echo "check-old-terms: a new retired name is refused. Use the new name from scripts/lib/rename-aliases.tsv," >&2
    echo "  or add 'old-term-ok: <reason>' on the line. The baseline only goes down; see docs/internals/rename-procedure.md." >&2
    exit 1
fi
echo "check-old-terms: OK — no retired name added"
