#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# check-old-terms.sh [<base> | --staged | --auto | --tree] — refuse NEW old-term
# names in the lines a change adds (slice R3 of the rename plan), or, with
# --tree, every console/leg name left anywhere in the tracked tree.
#
#   <base>     lines added by <base>...<tip> (default origin/main, else main;
#              tip is PRE_COMMIT_TO_REF, else HEAD)
#   --staged   lines added to the index (a commit in progress; skipped while a
#              merge is in progress, the push range check covers it)
#   --auto     the range when pre-commit runs a push (PRE_COMMIT_TO_REF set),
#              else the index: what the pre-commit hook runs
#   --tree     the work tree of the repo the cwd is in, run from CI by
#              scripts/docs/test-check-old-terms-tree.sh. Three kinds of name:
#                path   a git ls-files path matching (^|[/_.-])(console|legs?)([/_.-]|$)
#                token  an upper-case token with LEG, LEGS or CONSOLE as a whole
#                       _-separated part: (^|_)(LEGS?|CONSOLE)(_|$)
#                flag   --leg, --legs or --console, alone or followed by -<word>
#              A name passes when the registry lists it (a path by its full path
#              or its basename) as keep (a keep row ending in _ is a prefix) or
#              as an exact env alias (direction restrict, permit, value or cap).
#              Every other name must be a line of scripts/docs/old-terms-baseline.txt
#              (<kind><TAB><name>). The baseline only shrinks: a line the tree no
#              longer has fails (delete it with the rename), and so does a line
#              the baseline on origin/main (else main) lacks.
#
# Three checks on added lines:
#   (a) PROSE, markdown only. An added line outside code spans, link targets and
#       fences that uses a word the operator renamed: leg(s), console(s), bank,
#       overnight mode, CR marker, judge call, class sweep, sibling sweep, ticket
#       sequence, wave(s), "chain of legs|workers", "batch of workers" and
#       "batch of worker sessions". "parallel wave", "wave it through" and
#       "browser console" are the new or unrelated senses; a bare chain is not
#       linted (CI chain, merge chain, hook chain).
#   (b) IDENTIFIERS, every file. An added upper-case token holding LEG, LEGS or
#       CONSOLE as a whole _-separated part, BANK, OVERNIGHT, a bare WAVE or _WAVE,
#       SEQUENCE_, or HIMMEL_WORKER_ not followed by SESSION_, that is not in
#       the registry scripts/lib/rename-aliases.tsv; and the name chief-judge.
#       The kept HIMMEL_CONSOLE_ prefix is exempt.
#   (c) MOVED PATHS, every file. An added line naming the old spelling of a
#       registry row of kind directory or path (a moved directory) as a whole
#       path run, the way scripts/handover/move-renamed-dirs.sh matches it,
#       unless the line also names that row's new spelling.
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
    --tree) mode=tree ;;
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
elif [ "$mode" = staged ]; then
    # A merge in progress stages lines already reviewed on the other parent; the push range check covers the branch's own lines.
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then exit 0; fi
    diff_args=(--cached)
    src=":"
fi

# The registry of the snapshot being checked, not the working tree's copy.
reg_snap=""
if [ "$mode" != tree ] && [ -z "${OLD_TERMS_REGISTRY:-}" ] && git cat-file -e "${src}scripts/lib/rename-aliases.tsv" 2>/dev/null; then
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
        scripts/eval/lane-quality/tasks/*|scripts/eval/graphify-ab/tasks.json|scripts/eval/graphify-ab/truth.py) return 0 ;;
        scripts/docs/check-old-terms.sh|scripts/docs/test-check-old-terms.sh) return 0 ;;
        scripts/docs/old-terms-baseline.txt|scripts/docs/test-check-old-terms-tree.sh) return 0 ;;
        CHANGELOG.md|*/CHANGELOG.md) return 0 ;;
    esac
    return 1
}

# --tree also skips the files that list old names on purpose; the range check still lints their added lines.
is_tree_exempt_path() {
    case "$1" in
        scripts/lib/test-rename-aliases.sh|docs/migration/*) return 0 ;;
    esac
    is_exempt_path "$1"
}

if [ "$mode" = tree ]; then
    top=$(git rev-parse --show-toplevel) || { echo "$me: --tree needs a git work tree" >&2; exit 2; }
    case "$registry" in /*) ;; *) registry="$PWD/$registry" ;; esac
    cd "$top" || { echo "$me: cannot cd to $top" >&2; exit 2; }
    if [ -z "${OLD_TERMS_REGISTRY:-}" ] && [ -f scripts/lib/rename-aliases.tsv ]; then registry="$top/scripts/lib/rename-aliases.tsv"; fi
    baseline_rel=scripts/docs/old-terms-baseline.txt
    [ -f "$baseline_rel" ] || { echo "$me: baseline missing: $top/$baseline_rel" >&2; exit 2; }
    # shellcheck source=../lib/prim.sh
    . "$here/../lib/prim.sh" || { echo "$me: cannot load prim.sh" >&2; exit 2; }
    work=$(tmpdir) || { echo "$me: mktemp failed" >&2; exit 2; }
    trap 'rm -rf "$work"' EXIT
    git ls-files -z > "$work/files.z" || { echo "$me: git ls-files failed" >&2; exit 2; }
    tr '\000' '\n' < "$work/files.z" > "$work/files" || { echo "$me: tr failed" >&2; exit 2; }
    while IFS= read -r f; do
        if is_tree_exempt_path "$f"; then printf '%s\n' "$f"; fi
    done < "$work/files" > "$work/exempt"
    git ls-files -z --deleted > "$work/deleted.z" || { echo "$me: git ls-files --deleted failed" >&2; exit 2; }
    tr '\000' '\n' < "$work/deleted.z" >> "$work/exempt" || { echo "$me: tr failed" >&2; exit 2; }
    git -c core.quotePath=false grep -z -I -n -E -e '(LEGS?|CONSOLE)' -e '--(legs?|console)' > "$work/hits.z"
    [ $? -le 1 ] || { echo "$me: git grep failed" >&2; exit 2; }
    tr '\000' '\001' < "$work/hits.z" > "$work/hits" || { echo "$me: tr failed" >&2; exit 2; }
    have_ref=0
    have_base=0
    for candidate in origin/main main; do
        git rev-parse --verify -q "$candidate^{commit}" >/dev/null || continue
        have_ref=1
        if git cat-file -e "$candidate:$baseline_rel" 2>/dev/null; then
            git show "$candidate:$baseline_rel" > "$work/base" || { echo "$me: cannot read $candidate:$baseline_rel" >&2; exit 2; }
            have_base=1
        fi
        break
    done
    [ "$have_ref" -eq 1 ] || { echo "$me: --tree needs origin/main or main for the shrink-only check" >&2; exit 2; }
    [ "$have_base" -eq 1 ] || echo "$me: no $baseline_rel on origin/main or main, the shrink-only check is skipped" >&2
    LC_ALL=C awk -v registry="$registry" -v exemptf="$work/exempt" -v baselinef="$baseline_rel" -v basef="$work/base" \
        -v have_base="$have_base" -v filesf="$work/files" -v hitsf="$work/hits" '
        function exempt_name(n,    i) {
            if (n in ok) return 1
            for (i = 1; i <= nk; i++) if (index(n, kprefix[i]) == 1) return 1
            return 0
        }
        function add(kind, name, site) { if (!((kind "\t" name) in found)) found[kind "\t" name] = site }
        BEGIN {
            while ((getline l < registry) > 0) {
                if (l ~ /^[[:space:]]*(#|$)/) continue
                split(l, f, "\t")
                if (f[4] == "keep") { if (f[1] ~ /_$/) kprefix[++nk] = f[1]; else ok[f[1]] = 1 }
                else if (f[3] == "env" && f[4] ~ /^(restrict|permit|value|cap)$/) ok[f[1]] = 1
            }
            while ((getline l < exemptf) > 0) skip[l] = 1
            while ((getline l < baselinef) > 0) if (l !~ /^[[:space:]]*(#|$)/) { inbase[l] = 1; border[++nb] = l }
            if (have_base) while ((getline l < basef) > 0) if (l !~ /^[[:space:]]*(#|$)/) onbase[l] = 1
            while ((getline l < filesf) > 0) {
                if ((l in skip) || l !~ /(^|[\/_.-])(console|legs?)([\/_.-]|$)/) continue
                b = l; sub(/.*\//, "", b)
                if (!exempt_name(l) && !exempt_name(b)) add("path", l, "file name")
            }
            sep = sprintf("%c", 1)
            while ((getline l < hitsf) > 0) {
                p = index(l, sep); if (!p) continue
                file = substr(l, 1, p - 1); body = substr(l, p + 1)
                p = index(body, sep); if (!p) continue
                site = file ":" substr(body, 1, p - 1); body = substr(body, p + 1)
                if ((file in skip) || body ~ /old-term-ok:[[:space:]]*[^[:space:]]/) continue
                rest = body
                while (match(rest, /[A-Za-z0-9_]+/)) {
                    tok = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
                    if (tok ~ /^[A-Z][A-Z0-9_]*$/ && tok ~ /(^|_)(LEGS?|CONSOLE)(_|$)/ && !exempt_name(tok)) add("token", tok, site)
                }
                rest = body
                while (match(rest, /--(legs?|console)(-[a-z0-9]+)*/)) {
                    before = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
                    fl = substr(rest, RSTART, RLENGTH); after = substr(rest, RSTART + RLENGTH, 1)
                    rest = substr(rest, RSTART + RLENGTH)
                    if (before ~ /[A-Za-z0-9_-]/ || after ~ /[A-Za-z0-9_]/) continue
                    if (!exempt_name(fl)) add("flag", fl, site)
                }
            }
            for (k in found) if (!(k in inbase)) {
                split(k, kk, "\t")
                printf "new old-term %s `%s` (%s): not in %s\n", kk[1], kk[2], found[k], baselinef
                bad = 1
            }
            for (i = 1; i <= nb; i++) {
                split(border[i], kk, "\t")
                if (!(border[i] in found)) { printf "stale baseline line %s `%s`: the tree no longer has it, delete the line\n", kk[1], kk[2]; bad = 1 }
                else if (have_base && !(border[i] in onbase)) { printf "baseline line %s `%s` is not on the base branch: the baseline only shrinks\n", kk[1], kk[2]; bad = 1 }
            }
            exit bad
        }' > "$work/out"
    rc=$?
    [ "$rc" -le 1 ] || { echo "$me: awk failed (rc=$rc)" >&2; exit 2; }
    LC_ALL=C sort "$work/out"
    if [ "$rc" -eq 1 ]; then
        printf '%s: --tree found old-term names outside the registry and the baseline. Rename the name, list it in scripts/lib/rename-aliases.tsv as keep, or delete its stale baseline line.\n' "$me" >&2
    fi
    exit "$rc"
fi

# -C: a doc moved behind a redirect stub reads as a copy, so only its changed lines count.
diff_out=$(git -c core.quotePath=false diff -U0 -C --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --diff-filter=ACMR "${diff_args[@]}") \
    || { echo "$me: git diff failed" >&2; exit 2; }
[ -n "$diff_out" ] || exit 0

findings=$(mktemp "${TMPDIR:-/tmp}/old-terms.XXXXXX") || { echo "$me: mktemp failed" >&2; exit 2; }
trap 'rm -f "$findings" "$reg_snap"' EXIT

# file<TAB>comma-separated added line numbers, one row per changed file. An
# added line that equals the removed line it replaces once every moved-directory
# spelling in that line is rewritten (the move script's own edit) is not added.
added=$(printf '%s\n' "$diff_out" | awk -v registry="$registry" '
    BEGIN {
        while ((getline line < registry) > 0) {
            if (line ~ /^[[:space:]]*(#|$)/) continue
            split(line, f, "\t")
            if (f[3] != "directory" && f[3] != "path") continue
            np++; pold[np] = f[1]; pnew[np] = f[2]
            for (j = np; j > 1 && length(pold[j]) > length(pold[j - 1]); j--) {
                t = pold[j]; pold[j] = pold[j - 1]; pold[j - 1] = t
                t = pnew[j]; pnew[j] = pnew[j - 1]; pnew[j - 1] = t
            }
        }
        close(registry)
    }
    function moved(s,    i, out, k) {
        for (i = 1; i <= np; i++) {
            out = ""
            while ((k = index(s, pold[i])) > 0) { out = out substr(s, 1, k - 1) pnew[i]; s = substr(s, k + length(pold[i])) }
            s = out s
        }
        return s
    }
    function flush() { if (file != "" && nums != "") print file "\t" nums; nums = "" }
    /^diff --git / { flush(); file = ""; inhunk = 0; next }
    /^\+\+\+ / && !inhunk { file = $0; sub(/^\+\+\+ b\//, "", file); if ($0 == "+++ /dev/null") file = ""; next }
    /^@@ / { inhunk = 1; nm = 0; np2 = 0; ln = $0; sub(/^@@ -[0-9,]+ \+/, "", ln); sub(/[, ].*/, "", ln); ln += 0; next }
    /^-/ && inhunk { nm++; minus[nm] = substr($0, 2); next }
    /^\+/ {
        np2++
        if (file != "" && !(np2 <= nm && moved(minus[np2]) == substr($0, 2))) nums = (nums == "" ? ln : nums "," ln)
        ln++
    }
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
                if (f[3] == "directory" || f[3] == "path") { np++; pold[np] = f[1]; pnew[np] = f[2] }
            }
            close(registry)
            single["leg"] = single["legs"] = single["console"] = single["consoles"] = 1
            single["bank"] = single["banks"] = single["wave"] = single["waves"] = 1
            pair["overnight mode"] = pair["cr marker"] = pair["judge call"] = pair["judge calls"] = 1
            pair["class sweep"] = pair["sibling sweep"] = pair["ticket sequence"] = 1
        }
        # names_path(s, p): p occurs in s not preceded by a name character or a
        # dot, and not followed by a name character or a dot and a name character.
        function names_path(s, p,    at, k, b, a, a2) {
            at = 0
            while ((k = index(substr(s, at + 1), p)) > 0) {
                at += k
                b = (at > 1) ? substr(s, at - 1, 1) : ""
                a = substr(s, at + length(p), 1)
                a2 = substr(s, at + length(p) + 1, 1)
                if (b !~ /[A-Za-z0-9_.-]/ && a !~ /[A-Za-z0-9_-]/ && !(a == "." && a2 ~ /[A-Za-z0-9_]/)) return 1
            }
            return 0
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

            # (c) moved paths, every file
            for (i = 1; i <= np; i++) {
                if (index(body, pnew[i]) > 0 || !names_path(body, pold[i])) continue
                report("old-term path", pold[i], body)
                break
            }
            rest = body
            while (match(rest, /[A-Za-z0-9_]+/)) {
                tok = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                if (tok !~ /^[A-Z][A-Z0-9_]*$/) continue
                if (!(tok ~ /(^|_)(LEGS?|CONSOLE)(_|$)/ || tok ~ /BANK/ || tok ~ /OVERNIGHT/ \
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
