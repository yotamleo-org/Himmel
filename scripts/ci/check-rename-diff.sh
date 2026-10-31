#!/usr/bin/env bash
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+.
#
# check-rename-diff.sh [--registry FILE] [--warn] [<base>]
# check-rename-diff.sh [--registry FILE] --report <dir>
#
# Refuse a retired name on the lines a pull request ADDS. The
# rename registry (scripts/lib/rename-aliases.tsv) is the source of truth; no
# list lives here. Rows scanned, by their direction column (the mode):
#   prose, path, directory   direction fail          (prose: case-insensitive word)
#   identifier, marker       direction old-to-new    (rows whose new name is still
#                                                     pending-N2892 count too)
#   env, env-prefix          any direction           (a prefix row matches any name
#                                                     that starts with it)
# Not scanned: keep rows (their name, or any name starting with a keep prefix,
# is exempt), warn prose rows, and the registry file itself.
#
# A line carrying `old-term-ok` (the existing inline marker, `# old-term-ok:` or
# `<!-- old-term-ok: ... -->`) is skipped. A prose word followed by `.name` is
# code (`x.word`), not prose, and is skipped; a prose row whose new phrase
# contains the old word ignores the new phrase (old `X`, new `Y X`).
#
# Default mode scans <base>...HEAD (base: origin/main, else main) and exits
# 0 clean, 1 on a hit. --warn prints the hits and exits 0 (report mode: the CI
# step uses it until the v1.1.3 rename batches have merged, then drops it).
# --report <dir> scans every tracked line at the working tree, writes
# <dir>/hits.txt (path:line: old -> new: text) and <dir>/by-file.tsv (count,
# path, most hits first), prints the totals and exits 0. Exit 2: usage or git
# failure.
#
# ponytail: an added line that still carries an old name it already had (an
# edit next to it) is a hit, upgrade path: net the added hits against the
# removed lines of the same file.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
registry="$here/../lib/rename-aliases.tsv"
warn=0
report=""
base=""
while [ $# -gt 0 ]; do
    case "$1" in
        --registry) [ $# -ge 2 ] || { echo "check-rename-diff: --registry needs a file" >&2; exit 2; }; registry="$2"; shift 2 ;;
        --report) [ $# -ge 2 ] || { echo "check-rename-diff: --report needs a directory" >&2; exit 2; }; report="$2"; shift 2 ;;
        --warn) warn=1; shift ;;
        -*) echo "check-rename-diff: unknown option $1" >&2; exit 2 ;;
        *) base="$1"; shift ;;
    esac
done

[ -r "$registry" ] || { echo "check-rename-diff: cannot read registry $registry" >&2; exit 2; }

# The matcher reads "path:line:text" records on stdin and prints one
# "path:line: old -> new: text" per hit and always exits 0, so a finding is non-empty output.
# shellcheck disable=SC2016  # the awk program is single-quoted on purpose
matcher='
function blank(n) { return substr(SP, 1, n) }
function mask(h, ph,   out, i) {
    out = ""
    while ((i = index(h, ph)) > 0) { out = out substr(h, 1, i - 1) blank(length(ph)); h = substr(h, i + length(ph)) }
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
            if (substr(old, length(old)) == "_") keepp[++nkp] = old; else keepx[old] = 1
            continue
        }
        if (old == new) continue
        ty = ""
        if (kind == "prose") { if (dir == "fail") ty = "prose" }
        else if (kind == "path" || kind == "directory") { if (dir == "fail") ty = "path" }
        else if (kind == "identifier" || kind == "marker") { if (dir == "old-to-new") ty = "ident" }
        else if (kind == "env") ty = "ident"
        else if (kind == "env-prefix") ty = "prefix"
        if (ty == "") continue
        r++
        shown[r] = old; N[r] = new; T[r] = ty
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
    if (path ~ /(^|\/)rename-aliases\.tsv$/) next
    if (index(text, "old-term-ok") > 0) next
    lower = tolower(text)
    m = 0
    for (k = 1; k <= r; k++) {
        o = O[k]; ty = T[k]
        if (ty == "prose") { hay = lower; if (index(NL[k], o) > 0) hay = mask(hay, NL[k]) }
        else hay = text
        if (index(hay, o) == 0) continue
        pos = 1
        while ((i = index(substr(hay, pos), o)) > 0) {
            s = pos + i - 1
            pos = s + 1
            e = s + length(o)
            before = (s > 1) ? substr(hay, s - 1, 1) : ""
            after = substr(hay, e, 1)
            ok = 1
            if (ty == "ident") { if (before ~ /[A-Za-z0-9_]/ || after ~ /[A-Za-z0-9_]/) ok = 0 }
            else if (ty == "prefix") { if (before ~ /[A-Za-z0-9_]/) ok = 0 }
            else if (ty == "path") { if (before ~ /[A-Za-z0-9_-]/ || after ~ /[A-Za-z0-9_-]/) ok = 0 }
            else {
                if (before ~ /[A-Za-z0-9_]/) ok = 0
                if (ok && after == "s" && substr(hay, e + 1, 1) !~ /[A-Za-z0-9_]/) { e++; after = substr(hay, e, 1) }
                if (ok && after ~ /[A-Za-z0-9_]/) ok = 0
                if (ok && after == "." && substr(hay, e + 1, 1) ~ /[A-Za-z_]/) ok = 0
            }
            if (ok && (ty == "ident" || ty == "prefix")) {
                a = s; while (a > 1 && substr(text, a - 1, 1) ~ /[A-Za-z0-9_]/) a--
                b = e; while (b <= length(text) && substr(text, b, 1) ~ /[A-Za-z0-9_]/) b++
                tok = substr(text, a, b - a)
                if (tok in keepx) ok = 0
                for (j = 1; ok && j <= nkp; j++) if (index(tok, keepp[j]) == 1) ok = 0
            }
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
        printf "%s:%s: %s -> %s: %s\n", path, ln, shown[mr[a]], N[mr[a]], shown_text
    }
}
'

if [ -n "$report" ]; then
    mkdir -p "$report" || { echo "check-rename-diff: cannot create $report" >&2; exit 2; }
    # git grep exits 1 when nothing matches (fine); the matcher exits 0 even with hits,
    # so any non-zero status of the pipeline is a broken scan.
    rc=0
    { git -c core.quotePath=false grep -I -n --no-color -e .; g=$?; [ "$g" -le 1 ]; } \
        | awk -v registry="$registry" "$matcher" > "$report/hits.txt" || rc=$?
    [ "$rc" -eq 0 ] || { echo "check-rename-diff: scan failed (rc=$rc)" >&2; exit 2; }
    awk '{ p = $0; sub(/:[0-9]+: .*/, "", p); c[p]++ } END { for (p in c) printf "%d\t%s\n", c[p], p }' "$report/hits.txt" \
        | sort -t "$(printf '\t')" -k1,1nr -k2,2 > "$report/by-file.tsv"
    hits=$(wc -l < "$report/hits.txt" | tr -d ' ')
    files=$(wc -l < "$report/by-file.tsv" | tr -d ' ')
    echo "check-rename-diff: $hits hit(s) in $files file(s); see $report/by-file.tsv and $report/hits.txt"
    exit 0
fi

tip="${PRE_COMMIT_TO_REF:-HEAD}"
if [ -z "$base" ]; then
    for candidate in origin/main main; do
        if git rev-parse --verify -q "$candidate^{commit}" >/dev/null; then base="$candidate"; break; fi
    done
fi
[ -n "$base" ] || { echo "check-rename-diff: no usable base ref" >&2; exit 2; }
git rev-parse --verify -q "$base^{commit}" >/dev/null || { echo "check-rename-diff: unknown base '$base'" >&2; exit 2; }

# Added lines as "path:line:text". A file header sits between its `diff --git`
# line and its first hunk, so an added source line reading `++ b/x` is content.
out=$(git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --diff-filter=AMR "$base...$tip" \
    | awk '
        /^diff --git / { inhdr = 1; next }
        inhdr && /^\+\+\+ / { file = $0; sub(/^\+\+\+ b\//, "", file); next }
        /^@@ / { inhdr = 0; lineno = $0; sub(/^@@ -[0-9,]+ \+/, "", lineno); sub(/[, ].*/, "", lineno); lineno += 0; next }
        /^\+/ && !inhdr { printf "%s:%d:%s\n", file, lineno++, substr($0, 2) }' \
    | awk -v registry="$registry" "$matcher")
rc=$?
[ "$rc" -eq 0 ] || { echo "check-rename-diff: scan failed (rc=$rc)" >&2; exit 2; }
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
if [ "$warn" -eq 1 ]; then
    echo "check-rename-diff: retired name(s) on added lines (report mode, not failing). Use the new name, or add 'old-term-ok: <reason>' on the line; see docs/internals/rename-procedure.md." >&2
    exit 0
fi
echo "check-rename-diff: retired name(s) on added lines. Use the new name, or add 'old-term-ok: <reason>' on the line; see docs/internals/rename-procedure.md." >&2
exit 1
