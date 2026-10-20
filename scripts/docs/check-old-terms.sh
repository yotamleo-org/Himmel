#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-old-terms.sh [<base> | --staged | --auto] — refuse NEW old-term names in
# the lines a change adds (slice R3 of the rename plan). Only added lines
# are read, so the terms already in the tree need no baseline file.
#
#   <base>     lines added by <base>...<tip> (default origin/main, else main;
#              tip is PRE_COMMIT_TO_REF, else HEAD)
#   --staged   lines added to the index (a commit in progress; skipped while a
#              merge is in progress, the push range check covers it)
#   --auto     the range when pre-commit runs a push (PRE_COMMIT_TO_REF set),
#              else the index: what the pre-commit hook runs
#
# Two checks:
#   (a) PROSE, markdown only. An added line outside code spans, link targets and
#       fences that uses a word the operator renamed: leg(s), console(s), bank,
#       overnight mode, CR marker, judge call, class sweep, sibling sweep, ticket
#       sequence, wave(s), "chain of legs|workers", "batch of workers" and
#       "batch of worker sessions". "parallel wave", "wave it through" and
#       "browser console" are the new or unrelated senses; a bare chain is not
#       linted (CI chain, merge chain, hook chain).
#   (b) IDENTIFIERS, every file. An added upper-case token holding LEG_ or
#       CONSOLE_ (at a word start), BANK, OVERNIGHT, a bare WAVE or _WAVE,
#       SEQUENCE_, or HIMMEL_WORKER_ not followed by SESSION_, that is not in
#       the registry scripts/lib/rename-aliases.tsv; and the name chief-judge.
#       The kept HIMMEL_CONSOLE_ prefix is exempt.
#
# Skipped: the paths in is_exempt_path below, the CI-matrix sense of "leg" in
# ci-image.md / testing.md, and a line carrying `old-term-ok: <reason>` (a
# marker with no reason does not count).
#
# Exit: 0 clean; 1 at least one new old term; 2 usage / git failure.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
registry="${OLD_TERMS_REGISTRY:-$here/../lib/rename-aliases.tsv}"  # OLD_TERMS_REGISTRY: measurement seam (replay a past tree)
me="check-old-terms"

[ -f "$registry" ] || { echo "$me: registry missing: $registry" >&2; exit 2; }

mode=range
base=""
case "${1:-}" in
    --staged) mode=staged ;;
    --auto) if [ -n "${PRE_COMMIT_TO_REF:-}" ]; then mode=range; else mode=staged; fi ;;
    -*) echo "$me: unknown option '$1'" >&2; exit 2 ;;
    *) base="${1:-}" ;;
esac

tip="${PRE_COMMIT_TO_REF:-HEAD}"
if [ "$mode" = range ]; then
    if [ -z "$base" ]; then
        for candidate in origin/main main; do
            if git rev-parse --verify -q "$candidate^{commit}" >/dev/null; then base="$candidate"; break; fi
        done
    fi
    [ -n "$base" ] || { echo "$me: no usable base ref" >&2; exit 2; }
    git rev-parse --verify -q "$base^{commit}" >/dev/null || { echo "$me: unknown base '$base'" >&2; exit 2; }
    git rev-parse --verify -q "$tip^{commit}" >/dev/null || { echo "$me: unknown tip '$tip'" >&2; exit 2; }
    diff_args=("$base...$tip")
    src="$tip:"
else
    # A merge in progress stages lines already reviewed on the other parent; the push range check covers the branch's own lines.
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then exit 0; fi
    diff_args=(--cached)
    src=":"
fi

# The registry of the snapshot being checked, not the working tree's copy.
reg_snap=""
if [ -z "${OLD_TERMS_REGISTRY:-}" ] && git cat-file -e "${src}scripts/lib/rename-aliases.tsv" 2>/dev/null; then
    reg_snap=$(mktemp "${TMPDIR:-/tmp}/old-terms-reg.XXXXXX") || { echo "$me: mktemp failed" >&2; exit 2; }
    trap 'rm -f "$reg_snap"' EXIT
    git show "${src}scripts/lib/rename-aliases.tsv" > "$reg_snap" || { echo "$me: cannot read the registry from the snapshot" >&2; exit 2; }
    registry="$reg_snap"
fi

is_exempt_path() {
    case "$1" in
        */fixtures/*|fixtures/*|*/fixture/*|fixture/*) return 0 ;;
        scripts/lib/rename-aliases.tsv) return 0 ;;
        docs/glossary.md) return 0 ;;
        scripts/docs/check-old-terms.sh|scripts/docs/test-check-old-terms.sh) return 0 ;;
        CHANGELOG.md|*/CHANGELOG.md) return 0 ;;
    esac
    return 1
}

diff_out=$(git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --diff-filter=AMR "${diff_args[@]}") \
    || { echo "$me: git diff failed" >&2; exit 2; }
[ -n "$diff_out" ] || exit 0

findings=$(mktemp "${TMPDIR:-/tmp}/old-terms.XXXXXX") || { echo "$me: mktemp failed" >&2; exit 2; }
trap 'rm -f "$findings" "$reg_snap"' EXIT

# file<TAB>comma-separated added line numbers, one row per changed file.
added=$(printf '%s\n' "$diff_out" | awk '
    function flush() { if (file != "" && nums != "") print file "\t" nums; nums = "" }
    /^diff --git / { flush(); file = ""; inhunk = 0; next }
    /^\+\+\+ / && !inhunk { file = $0; sub(/^\+\+\+ b\//, "", file); if ($0 == "+++ /dev/null") file = ""; next }
    /^@@ / { inhunk = 1; ln = $0; sub(/^@@ -[0-9,]+ \+/, "", ln); sub(/[, ].*/, "", ln); ln += 0; next }
    /^\+/ { if (file != "") nums = (nums == "" ? ln : nums "," ln); ln++ }
    END { flush() }')

while IFS="$(printf '\t')" read -r file nums; do
    [ -n "$file" ] || continue
    is_exempt_path "$file" && continue
    case "$file" in
        *.md) md=1 ;;
        *) md=0 ;;
    esac
    ci_leg=0
    case "$file" in
        */ci-image.md|ci-image.md|*/testing.md|testing.md) ci_leg=1 ;;
    esac
    git show "$src$file" 2>/dev/null | awk -v file="$file" -v nums="$nums" -v md="$md" -v ci_leg="$ci_leg" -v registry="$registry" '
        BEGIN {
            n = split(nums, a, ",")
            for (i = 1; i <= n; i++) want[a[i]] = 1
            while ((getline line < registry) > 0) {
                if (line ~ /^[[:space:]]*(#|$)/) continue
                split(line, f, "\t")
                known[f[1]] = 1
            }
            close(registry)
            single["leg"] = single["legs"] = single["console"] = single["consoles"] = 1
            single["bank"] = single["banks"] = single["wave"] = single["waves"] = 1
            pair["overnight mode"] = pair["cr marker"] = pair["judge call"] = pair["judge calls"] = 1
            pair["class sweep"] = pair["sibling sweep"] = pair["ticket sequence"] = 1
        }
        function fenceline(s) { return s ~ /^[[:space:]]*(```|~~~)/ }
        function report(kind, what, body) {
            printf "%s:%d: %s `%s`: %s\n", file, NR, kind, what, body
        }
        {
            if (md && fenceline($0)) { fence = !fence; next }
            if (!(NR in want)) next
            body = $0
            if (body ~ /old-term-ok:[[:space:]]*[^[:space:]]/) next

            # (b) identifiers, every file
            if (body ~ /chief-judge/) report("old-term name", "chief-judge", body)
            rest = body
            while (match(rest, /[A-Za-z0-9_]+/)) {
                tok = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                if (tok !~ /^[A-Z][A-Z0-9_]*$/) continue
                if (!(tok ~ /(^|_)(LEG|CONSOLE)_[A-Z0-9]/ || tok ~ /BANK/ || tok ~ /OVERNIGHT/ \
                      || tok ~ /^WAVE$/ || tok ~ /_WAVE/ || tok ~ /SEQUENCE_/ \
                      || (tok ~ /^HIMMEL_WORKER_/ && tok !~ /^HIMMEL_WORKER_SESSION_/))) continue
                if (tok ~ /^HIMMEL_CONSOLE_/ || (tok in known)) continue
                report("old-term identifier", tok, body)
                break
            }

            # (a) prose, markdown outside fences
            if (!md || fence) next
            s = body
            gsub(/`[^`]*`/, " ", s)
            gsub(/\]\([^)]*\)/, "]", s)
            gsub(/https?:\/\/[^ )>]*/, " ", s)
            nw = split(s, w, /[ \t]+/)
            for (i = 1; i <= nw; i++) {
                t = tolower(w[i])
                sub(/\047s$/, "", t)
                gsub(/^[^a-z0-9]+|[^a-z0-9]+$/, "", t)
                w[i] = t
            }
            for (i = 1; i <= nw; i++) {
                t = w[i]
                if (t == "") continue
                hit = ""
                if (t in single) {
                    hit = t
                    if (ci_leg && (t == "leg" || t == "legs")) hit = ""
                    if ((t == "wave" || t == "waves") && ((i > 1 && w[i - 1] == "parallel") || w[i + 1] == "through" || w[i + 2] == "through" || w[i + 3] == "through")) hit = ""
                    if (t == "console" && i > 1 && w[i - 1] == "browser") hit = ""
                } else if (i < nw && ((t " " w[i + 1]) in pair)) {
                    hit = t " " w[i + 1]
                } else if (i + 2 <= nw && t == "chain" && w[i + 1] == "of" && w[i + 2] ~ /^(legs?|workers?)$/) {
                    hit = "chain of " w[i + 2]
                } else if (i + 2 <= nw && t == "batch" && w[i + 1] == "of" && w[i + 2] == "workers") {
                    hit = "batch of workers"
                } else if (i + 3 <= nw && t == "batch" && w[i + 1] == "of" && w[i + 2] == "worker" && w[i + 3] == "sessions") {
                    hit = "batch of worker sessions"
                }
                if (hit != "") { report("old-term prose", hit, body); break }
            }
        }' >> "$findings"
    # a file the diff names but git cannot read, or an awk failure, must not pass as clean
    pipe_rc=("${PIPESTATUS[@]}")
    if [ "${pipe_rc[0]}" -ne 0 ] || [ "${pipe_rc[1]}" -ne 0 ]; then
        echo "$me: cannot read $src$file (git show rc=${pipe_rc[0]}, awk rc=${pipe_rc[1]})" >&2
        exit 2
    fi
done <<EOF
$added
EOF

if [ -s "$findings" ]; then
    cat "$findings"
    count=$(wc -l < "$findings" | tr -d ' ')
    # shellcheck disable=SC2016  # the backticks are literal text in the message
    printf '%s: %s old-term finding(s) in added lines. Use the plain name (chief, worker, parallel wave), register a new identifier in scripts/lib/rename-aliases.tsv, or add `old-term-ok: <reason>` on the line.\n' "$me" "$count" >&2
    exit 1
fi
exit 0
