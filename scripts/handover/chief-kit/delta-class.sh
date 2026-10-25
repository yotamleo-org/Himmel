#!/usr/bin/env bash
# scripts/handover/chief-kit/delta-class.sh - classify the delta between the head
# a judge ruled on and a later head of the same PR, so the chief re-judges only
# a push that needs it.
#
# Usage: delta-class.sh [--qid <qid> | --verdict-file <path>]... [--ledger <path>]
#                       [--trust-file <path>] <judged-head> <new-head>
# Run it in the checkout that holds both commits. Prints ONE word and exits 0:
#   trust    a file the delta touches (new name, and old name of a rename) matches a
#            line of the trust list (scripts/ci/ci-trust-paths.txt, read from
#            origin/main unless --trust-file names a copy). Needs a judge.
#   finding  the delta touches the lines of a finding the prior judge named, or
#            of a CR-ledger finding recorded at the judged head. Needs a judge.
#   none     neither. The chief may record a `delta: no-op` verdict
#            (write-verdict.sh --delta-noop) instead of dispatching a judge.
# It FAILS CLOSED: any read error (unreadable trust list, verdict or ledger, an
# unknown sha, a bad regex, no verdict given) prints trust, never none. A trust
# hit wins over a finding hit.
#
# Findings come from two places, both at the judged head's line numbers:
#   - a line `finding: <path>[:<line>[-<line>]]` in each prior verdict file
#     (--verdict-file, or with --qid every non-no-op verdicts/<qid>/*.md that
#     rules on the judged head); no line means the whole file;
#   - every `kind":"finding` row of the CR ledger whose head is the judged head
#     (default <git-common-dir>/cr-critic-scores.jsonl): its file and line.
# A NO-GO verdict that names no `finding:` line classifies finding, never none:
# its findings exist only as prose, so any delta needs a judge.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; needs git, jq (ledger rows only).
set -u

fin() { printf '%s\n' "$1"; exit 0; }
trust() { fin trust; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" 2>/dev/null || trust # swallow-ok: an unloadable scrub lib fails closed to trust on this line
git_env_scrub
QID="" LEDGER="" TRUSTF="" VFILES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --qid) [ "$#" -ge 2 ] || trust; QID=$2; shift 2 ;;
        --verdict-file) [ "$#" -ge 2 ] || trust; VFILES+=("$2"); shift 2 ;;
        --ledger) [ "$#" -ge 2 ] || trust; LEDGER=$2; shift 2 ;;
        --trust-file) [ "$#" -ge 2 ] || trust; TRUSTF=$2; shift 2 ;;
        *) break ;;
    esac
done
[ "$#" -eq 2 ] || trust
J=$1 N=$2
for h in "$J" "$N"; do
    case "$h" in *[!0123456789abcdef]*) trust ;; esac
    [ "${#h}" -eq 40 ] || trust
    git cat-file -e "$h^{commit}" 2>/dev/null || trust
done
command -v jq >/dev/null 2>&1 || trust
[ -n "$QID" ] || [ "${#VFILES[@]}" -gt 0 ] || trust

work=$(mktemp -d "${TMPDIR:-/tmp}/delta-class.XXXXXX") || trust # prim-ok: a read-only classifier's scratch dir, removed by the EXIT trap
trap 'rm -rf "$work"' EXIT

# read-sink-ok: the path is a verdict file the chief names; the classifier only parses it and prints one word
verdict_line() { tr -d '\r' < "$1" | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }'; }
# shellcheck disable=SC2016  # the backticks are literal verdict-line text, not a command substitution
verdict_word() { verdict_line "$1" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `[0-9a-f]{40}`\.?$/\1/p'; }
# shellcheck disable=SC2016  # as above
verdict_head() { verdict_line "$1" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\2/p'; }

# --qid: the prior verdicts are every real (non no-op) record in the qid's dir for the judged head.
if [ -n "$QID" ]; then
    case "$QID" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) trust ;; esac
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/go-gate.sh" 2>/dev/null || trust
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/handover-path.sh" 2>/dev/null || trust
    anchor="$(cd "$HERE/../../.." && pwd)"
    root=$(go_resolve_root "$anchor") || trust
    scope=$(go_verdict_scope "$anchor") || trust
    for f in "$root/$scope/verdicts/$QID"/*.md; do
        [ -f "$f" ] || continue
        [ -r "$f" ] || trust
        grep -qx 'delta: no-op' "$f" && continue
        [ "$(verdict_head "$f")" = "$J" ] || continue
        VFILES+=("$f")
    done
    [ "${#VFILES[@]}" -gt 0 ] || trust
fi

# Trust list: origin/main's copy unless a file is named.
if [ -z "$TRUSTF" ]; then
    TRUSTF="$work/trust.txt"
    git show origin/main:scripts/ci/ci-trust-paths.txt > "$TRUSTF" 2>/dev/null || trust
fi
[ -r "$TRUSTF" ] || trust
grep -vE '^[[:space:]]*(#|$)' "$TRUSTF" > "$work/patterns.txt" 2>/dev/null
[ -s "$work/patterns.txt" ] || trust

# Changed paths (renames as delete + add, so both names are listed), one per line.
git diff --name-only -z --no-renames --no-ext-diff --no-relative "$J" "$N" -- >"$work/names.z" 2>/dev/null || trust
: > "$work/names.txt"
while IFS= read -r -d '' p; do
    case "$p" in *$'\n'*) trust ;; esac
    printf '%s\n' "$p" >> "$work/names.txt"
done < "$work/names.z"

while IFS= read -r pat; do
    grep -Eq -e "$pat" "$work/names.txt" 2>/dev/null
    case $? in 0|2) trust ;; esac
done < "$work/patterns.txt"

# Findings, as <path><TAB><first line><TAB><last line>; the lines are empty for a whole file.
: > "$work/findings.tsv"
nogo_prose=0
re='^finding:[[:space:]]+([^[:space:]:]+)(:([0-9]+)(-([0-9]+))?)?[[:space:]]*$'
for f in "${VFILES[@]}"; do
    [ -r "$f" ] || trust
    [ -n "$(verdict_word "$f")" ] || trust
    [ "$(verdict_head "$f")" = "$J" ] || trust
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ $line =~ $re ]]; then
            lo=${BASH_REMATCH[3]} hi=${BASH_REMATCH[5]:-${BASH_REMATCH[3]}}
            printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "$lo" "$hi" >> "$work/findings.tsv"
            n=$((n + 1))
        else
            case $line in finding:*) trust ;; esac
        fi
    done < "$f"
    [ "$n" -gt 0 ] || [ "$(verdict_word "$f")" != NO-GO ] || nogo_prose=1
done

if [ -z "$LEDGER" ]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || trust # swallow-ok: no git dir fails closed to trust on this line
    LEDGER="$common/cr-critic-scores.jsonl"
fi
[ -r "$LEDGER" ] || trust
grep -F -- "$J" "$LEDGER" > "$work/rows.jsonl" 2>/dev/null
[ $? -le 1 ] || trust
jq -r --arg h "$J" 'select(.kind == "finding" and .head == $h and ((.file // "") != ""))
    | [.file, ((.line // "") | tostring | if test("^[0-9]+$") then . else "" end)] | "\(.[0])\t\(.[1])\t\(.[1])"' \
    "$work/rows.jsonl" >> "$work/findings.tsv" 2>/dev/null || trust

[ "$nogo_prose" -eq 0 ] || fin finding
# a ledger finding that names no file cannot be matched to any hunk, so it needs a judge
[ -z "$(jq -r --arg h "$J" 'select(.kind == "finding" and .head == $h and ((.file // "") == "")) | "x"' "$work/rows.jsonl")" ] || fin finding

# Old-side line ranges the delta rewrites; an insertion counts as touching the line it follows and the next.
git -c core.quotePath=false diff -U0 --no-renames --no-color --no-ext-diff --no-textconv --no-relative --src-prefix=a/ --dst-prefix=b/ "$J" "$N" -- > "$work/patch.txt" 2>/dev/null || trust
awk '
    /^diff --git / { inh = 1; path = ""; next }
    inh && /^--- / { p = substr($0, 5); sub(/\t$/, "", p); if (p ~ /^"/) bad = 1; if (p == "/dev/null") path = ""; else { sub(/^a\//, "", p); path = p }; next }
    inh && /^\+\+\+ / { if (substr($0, 5) ~ /^"/) bad = 1; next }
    /^@@ / {
        inh = 0
        if (path == "") next
        split($2, o, ",")
        a = substr(o[1], 2) + 0
        b = (o[2] == "") ? 1 : o[2] + 0
        if (b == 0) { s = a; e = a + 1 } else { s = a; e = a + b - 1 }
        print path "\t" s "\t" e
    }
    END { exit bad ? 3 : 0 }' "$work/patch.txt" > "$work/hunks.tsv" || trust

# A binary change has no hunks, so a finding on a path git reports as binary counts as touched.
git -c core.quotePath=false diff --numstat -z --no-renames --no-ext-diff --no-textconv --no-relative "$J" "$N" -- > "$work/numstat.z" 2>/dev/null || trust
: > "$work/binary.txt"
while IFS= read -r -d '' rec; do
    case "$rec" in
        -$'\t'-$'\t'*) printf '%s\n' "${rec#-$'\t'-$'\t'}" >> "$work/binary.txt" ;;
    esac
done < "$work/numstat.z"

while IFS=$'\t' read -r fp lo hi; do
    [ -n "$fp" ] || continue
    # a finding must name a repo-root file the judged head holds: any other spelling
    # (absolute, dot segment, directory, absent path) cannot be matched to a hunk
    case "/$fp/" in */./*|*/../*|//*) trust ;; esac
    [ "$(git cat-file -t "$J:$fp" 2>/dev/null)" = blob ] || trust # swallow-ok: an unreadable path fails closed to trust on this line
    if [ -z "$lo" ]; then
        grep -qxF -- "$fp" "$work/names.txt" && fin finding
    fi
    grep -qxF -- "$fp" "$work/binary.txt" && fin finding
done < "$work/findings.tsv"

awk -F'\t' '
    NR == FNR { if ($2 != "") { n++; fp[n] = $1; lo[n] = $2 + 0; hi[n] = $3 + 0 } ; next }
    { for (i = 1; i <= n; i++) if ($1 == fp[i] && $2 + 0 <= hi[i] && $3 + 0 >= lo[i]) { hit = 1; exit } }
    END { exit !hit }' "$work/findings.tsv" "$work/hunks.tsv" && fin finding

fin none
