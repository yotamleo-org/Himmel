#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# check-new-comments.sh — refuse a NEW code comment outside the keep list.
# The rule is in docs/internals/code-comments.md. The comments already in the tree are
# counted per file in scripts/lint/comment-baseline.tsv (key<TAB>count, the key being the git blob hash of
# the path, so the baseline carries no file name); a file with no
# row is allowed none. Only the code files a change touches are judged, so a change that
# touches no commented file can never fail:
#   a touched file's count of comment lines outside the keep list may not exceed its row,
#   nor the count of the base's version of the file (the path it was renamed from, for a
#   rename), so a sweep that deletes comments and leaves the baseline alone still lowers
#   the file's limit
#   a row may not rise above the base's row for that path (or for the path it was renamed
#   from in this change), and a new row may not be above zero
#   a count or a row above that limit still passes when it is no higher than the count of
#   the base's version of the file (a change to comment-count.awk recounts the tree, so
#   for a file that change does not touch the changed classifier takes that count)
# A base without a baseline has no rows to compare: the first baseline is taken as it is.
# The classifier is comment-count.awk; the paths left out are the whole-file rows of
# ticket-ref-allow.tsv (fixtures, archives, generated and vendored trees), read through
# ticket-refs.awk.
#
# Usage:
#   check-new-comments.sh --staged                       # the index against HEAD (pre-commit)
#   check-new-comments.sh --range <base> [--tip <ref>]   # <base> against <tip>, tip defaults to HEAD (CI)
#   check-new-comments.sh --write-baseline               # rewrite the baseline from the working tree
# Exit: 0 clean · 1 findings · 2 cannot evaluate (fail-closed): the classifier, the rule
# list or the tip's baseline is missing or unreadable, or git/awk failed

set -uo pipefail
export LC_ALL=C

usage() { echo "usage: check-new-comments.sh --staged | --range <base> [--tip <ref>] | --write-baseline" >&2; exit 2; }
die() { echo "check-new-comments: $1, cannot evaluate" >&2; exit 2; }
[ $# -ge 1 ] || usage
count_ok() { case "$1" in ''|*[!0-9]*|??????????*) return 1 ;; esac; }
gt() {
    if ! count_ok "$1" || ! count_ok "$2"; then die "cannot compare the counts '$1' and '$2'"; fi
    test "$1" -gt "$2"
    case $? in
        0) return 0 ;;
        1) return 1 ;;
        *) die "cannot compare the counts '$1' and '$2'" ;;
    esac
}
has_at() {
    if [ -z "$1" ]; then
        git --literal-pathspecs ls-files --cached -- "$2" > "$W/has" || die "cannot list the index"
    else
        git --literal-pathspecs ls-tree -r --name-only "$1" -- "$2" > "$W/has" || die "cannot list $1"
    fi
    [ -s "$W/has" ]
}
listed() {
    local r=0
    grep -qxF -- "$1" "$2" || r=$?
    [ "$r" -le 1 ] || die "grep failed on $2"
    return "$r"
}
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
unkey() {
    awk -F'\t' 'FILENAME == ARGV[1] { path[$1] = $2; next } ($1 in path) { print path[$1] "\t" $2 }' "$W/map" "$1" > "$2" || die "awk failed"
}

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
classifier="$here/comment-count.awk"
exempt_awk="$here/ticket-refs.awk"
rules="$here/ticket-ref-allow.tsv"
BL=scripts/lint/comment-baseline.tsv
CODE_RE='\.(sh|bash|zsh|ps1|psm1|py|js|mjs|cjs|ts|tsx|mts|cts)$'

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

for f in "$classifier" "$exempt_awk" "$rules"; do
    [ -s "$f" ] || die "cannot read $f"
done

top="$(git rev-parse --show-toplevel)" || die "not in a git work tree"
cd "$top" || die "cannot enter $top"

W="$(mktemp -d "${TMPDIR:-/tmp}/check-new-comments.XXXXXX")" || die "mktemp failed"  # prim-ok: CI runs a base copy of this script alone, without scripts/lib
trap 'rm -rf "$W"' EXIT

judged() {
    grep -E "$CODE_RE" "$1" > "$W/code"
    [ $? -le 1 ] || die "grep failed"
    awk -f "$exempt_awk" -v allow="$rules" -v mode=exempt "$W/code" > "$W/exempt" || die "the rule list did not load"
    awk 'FILENAME == ARGV[1] { x[$0] = 1; next } !($0 in x)' "$W/exempt" "$W/code" > "$2" || die "awk failed"
}

if [ "$mode" = "write" ]; then
    git -c core.quotePath=false ls-files > "$W/all" || die "git ls-files failed"
    judged "$W/all" "$W/paths"
    : > "$W/rows"
    while IFS= read -r p; do
        if [ -f "$p" ] && [ ! -L "$p" ]; then printf '%s\0' "$p"; fi
    done < "$W/paths" > "$W/paths0"
    if [ -s "$W/paths0" ]; then
        xargs -0 awk -f "$classifier" -v mode=tree < "$W/paths0" > "$W/rows" || die "the classifier failed"
    fi
    awk -F'\t' '{ print $1 }' "$W/rows" > "$W/named" || die "awk failed"
    keys "$W/named" "$W/map"
    awk -F'\t' 'FILENAME == ARGV[1] { key[$2] = $1; next } { print key[$1] "\t" $2 }' "$W/map" "$W/rows" > "$W/keyed" || die "awk failed"
    sort "$W/keyed" > "$BL" || die "cannot write $BL"
    echo "check-new-comments: wrote $BL ($(awk -F'\t' '{ n += $2 } END { print NR " files, " n + 0 " comment lines" }' "$BL"))"
    exit 0
fi

case "$mode" in
    staged) base=HEAD
            git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && base=MERGE_HEAD
            tipspec=":" tiprev=""
            set -- --cached "$base" ;;
    range)  base="$arg"
            tipspec="$tip:" tiprev="$tip"
            set -- "$base" "$tip" ;;
esac

git -c core.quotePath=false diff "$@" --name-status --find-renames --diff-filter=ACMRT > "$W/status" || die "git diff failed"
git -c core.quotePath=false diff "$@" -U0 --text --no-color --no-ext-diff --find-renames --diff-filter=ACMRT > "$W/diff" || die "git diff failed"

grep -q "$(printf '\t')\"" "$W/status"
case $? in
    0) die "git quotes a changed path (a double quote, backslash or control character in its name)" ;;
    1) ;;
    *) die "grep failed on the changed paths" ;;
esac
awk -F'\t' '{ print $NF }' "$W/status" > "$W/touched"
cp "$W/touched" "$W/indiff" || die "cp failed"
recount=0
if listed "scripts/lint/comment-count.awk" "$W/indiff"; then
    git show "${tipspec}scripts/lint/comment-count.awk" > "$W/tip.awk" || die "cannot read the classifier at the tip"
    recount=1
fi
awk -F'\t' '$1 ~ /^R/ { print $3 "\t" $2 }' "$W/status" > "$W/renames"

git show "$tipspec$BL" > "$W/tip.tsv" 2>/dev/null || die "$BL is absent at the tip"
git rev-parse -q --verify "$base^{commit}" >/dev/null || die "cannot read the base $base"
has_base=0
: > "$W/base.tsv"
if has_at "$base" "$BL"; then
    git show "$base:$BL" > "$W/base.tsv" || die "cannot read $BL at the base"
    has_base=1
fi
for f in tip base; do
    awk -F'\t' '$2 !~ /^[0-9]+$/ || length($2) > 9 { bad = 1 } END { exit bad }' "$W/$f.tsv" || die "a row of $BL at the $f carries no count of at most 9 digits"
done
awk -F'\t' '{ print $2 }' "$W/renames" > "$W/named" || die "awk failed"
sort -u "$W/named" "$W/touched" > "$W/named.u" || die "sort failed"
keys "$W/named.u" "$W/map"
: > "$W/loose"
if [ "$has_base" -eq 1 ]; then
    raised() {
        awk -F'\t' '
            FILENAME == ARGV[1] { b[$1] = $2; next }
            FILENAME == ARGV[2] { m[$1] = 1; next }
            !($1 in m) && $2 + 0 > b[$1] + 0 { print $1 "\t" $2 "\t" b[$1] + 0 }
        ' "$W/base.tsv" "$W/map" "$W/tip.tsv" > "$W/loose" || die "awk failed"
    }
    raised
    if [ -s "$W/loose" ]; then
        if [ -z "$tiprev" ]; then
            git -c core.quotePath=false ls-files --cached > "$W/tree" || die "cannot list the index"
        else
            git -c core.quotePath=false ls-tree -r --name-only "$tiprev" > "$W/tree" || die "cannot list $tiprev"
        fi
        git -c core.quotePath=false ls-tree -r --name-only "$base" >> "$W/tree" || die "cannot list $base"
        sort -u "$W/tree" > "$W/tree.u" || die "sort failed"
        judged "$W/tree.u" "$W/tree.j"
        keys "$W/tree.j" "$W/map.all"
        cat "$W/map.all" >> "$W/map" || die "cat failed"
        raised
    fi
fi
unkey "$W/tip.tsv" "$W/tip.p"
unkey "$W/base.tsv" "$W/base.p"
if [ "$has_base" -eq 1 ]; then
    awk -F'\t' 'FILENAME == ARGV[1] { b[$1] = $2; next } !($1 in b) || b[$1] != $2 { print $1 }' "$W/base.p" "$W/tip.p" >> "$W/touched" || die "awk failed"
fi
sort -u "$W/touched" > "$W/touched.u" || die "sort failed"
judged "$W/touched.u" "$W/paths"

: > "$W/counts"
while IFS= read -r p; do
    if ! has_at "$tiprev" "$p"; then printf '%s\t0\n' "$p" >> "$W/counts"; continue; fi
    git show "$tipspec$p" > "$W/blob" || die "cannot read $p at the tip"
    n="$(awk -f "$classifier" -v mode=count -v path="$p" "$W/blob")" || die "the classifier failed on $p"
    count_ok "$n" || die "the classifier printed no count for $p"
    printf '%s\t%s\n' "$p" "$n" >> "$W/counts"
done < "$W/paths"

awk -F'\t' -v has_base="$has_base" '
    FILENAME == ARGV[1] { from[$1] = $2; next }
    FILENAME == ARGV[2] { base[$1] = $2 + 0; next }
    FILENAME == ARGV[3] {
        tip[$1] = $2 + 0
        if (!has_base) next
        lim = ($1 in base) ? base[$1] : (($1 in from) && (from[$1] in base)) ? base[from[$1]] : 0
        if ($2 + 0 > lim) printf "B\t%s\t%d\t%d\n", $1, $2, lim
        next
    }
    {
        if ($2 + 0 > tip[$1] + 0) printf "A\t%s\t%d\t%d\n", $1, $2, tip[$1] + 0
        else if (has_base && $2 + 0 > 0) printf "T\t%s\t%d\t%d\n", $1, $2, tip[$1] + 0
    }
' "$W/renames" "$W/base.p" "$W/tip.p" "$W/counts" > "$W/raw" || die "awk failed"
awk -F'\t' '{ printf "B\trow %s, which names no file at the tip or the base,\t%d\t%d\n", $1, $2, $3 }' "$W/loose" >> "$W/raw" || die "awk failed"

: > "$W/findings"
while IFS="$(printf '\t')" read -r kind p n lim; do
    if [ "$kind" != "B" ] && ! listed "$p" "$W/indiff"; then continue; fi
    was="$(awk -F'\t' -v p="$p" '$1 == p { print $2; exit }' "$W/renames")"
    m=0
    if has_at "$base" "${was:-$p}"; then
        git show "$base:${was:-$p}" > "$W/blob" || die "cannot read ${was:-$p} at the base"
        capper="$classifier"
        if [ "$recount" -eq 1 ] && ! listed "$p" "$W/indiff"; then capper="$W/tip.awk"; fi
        m="$(awk -f "$capper" -v mode=count -v path="$p" "$W/blob")" || die "the classifier failed on $p"
        count_ok "$m" || die "the classifier printed no count for $p"
    fi
    gt "$n" "$m" || continue
    if [ "$kind" = "B" ] && gt "$m" "$lim"; then lim="$m"; fi
    if [ "$kind" = "T" ]; then lim="$m"; fi
    printf '%s\t%s\t%s\t%s\n' "$kind" "$p" "$n" "$lim" >> "$W/findings"
done < "$W/raw"

[ -s "$W/findings" ] || exit 0

added_ranges() {
    awk -v want="$1" '
        /^\+\+\+ / { on = (substr($0, 7) == want); next }
        on && /^@@ / {
            r = $0; sub(/^@@ -[0-9,]+ \+/, "", r); sub(/ .*/, "", r)
            n = split(r, ab, ","); if (n < 2) ab[2] = 1
            if (ab[2] > 0) out = out (out == "" ? "" : ",") ab[1] ":" ab[2]
        }
        END { print out }
    ' "$W/diff"
}

moved=0
while IFS="$(printf '\t')" read -r kind p n lim; do
    if [ "$kind" = "B" ]; then
        echo "$BL: $p raised to $n, the base allows $lim"
        continue
    fi
    if [ "$kind" = "T" ]; then
        echo "$p: $n comment lines outside the keep list, the base's version of the file holds $lim"
    else
        echo "$p: $n comment lines outside the keep list, baseline $lim"
    fi
    r="$(added_ranges "$p")"
    git show "$tipspec$p" > "$W/blob" 2>/dev/null || die "cannot read $p at the tip"
    if [ -n "$r" ]; then
        awk -f "$classifier" -v mode=list -v ranges="$r" -v path="$p" "$W/blob" | sed 's/^/  /'
    fi
    if grep -q "^$(printf '%s' "$p" | sed 's/[][\.*^$]/\\&/g')$(printf '\t')" "$W/renames"; then moved=1; fi
done < "$W/findings"

echo "check-new-comments: a new code comment outside the keep list is refused." >&2
echo "  Delete it and let a name, a type or a test say it. A constraint forced by an external" >&2
echo "  dependency, platform or protocol stays when the comment carries its link." >&2
if [ "$moved" -eq 1 ]; then
    echo "  A renamed file's baseline row moves with it: run bash scripts/lint/check-new-comments.sh --write-baseline." >&2
fi
echo "  The baseline only goes down. Policy: docs/internals/code-comments.md." >&2
exit 1
