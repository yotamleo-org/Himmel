#!/usr/bin/env bash
# Report memory notes that tell a session something no longer true on main.
#
# For every top-level *.md of the auto-memory store it reads the body lines
# (front matter skipped) and reports:
#   dead-path   <note>:<line> <path>   a repo path missing on main
#   closed-wait <note>:<line> <KEY>    a ticket named after "wait on|for" or
#                                      "sync with" that the Jira mirror shows Done
# then one summary line. It only reports: no note is written, moved or deleted.
#
# A body line starting "Incident YYYY-MM-DD:" (optionally after "- " or "**")
# records what once went wrong, not what to do, so it is not judged.
# A note whose file name marks it sensitive (secret, token, credential,
# password, keyring, private, keys, env) is never opened, only counted.
#
# A repo path is a slash-joined token whose first part is a top-level
# directory of the repo tree. Not one: a token after "/", "~", "$" or ":"
# (absolute, home, variable, URL), one running into a placeholder or glob
# ("<", "*", "{", "$", "["), a fragment ending in "-", a path .gitignore
# covers (a local file that is never on main), and a two-part token with no
# file extension, trailing "/" or opening backtick ("docs/audit work" is
# prose). A ticket counts as waited on only inside the phrase's own clause:
# up to the next ";", "(", ")", "!", "?", " — " or sentence-ending ".".
#
# Env: MEMDIR (store; default derived by scripts/lib/memory-slug.sh),
#      MEMORY_TRUTH_REPO (default this checkout), MEMORY_TRUTH_REF (default
#      origin/main, else main), MEMORY_TRUTH_MIRROR (default
#      ~/.himmel/state/jira-mirror, read as <mirror>/<PROJECT>/<KEY>.md),
#      JIRA_PROJECT_KEY (the project of a bare ticket number; default HIMMEL).
# Exit: 0 nothing found, 1 findings, 2 setup error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 2
# shellcheck source=../lib/memory-slug.sh
. "$HERE/../lib/memory-slug.sh"

if [ -z "${MEMDIR:-}" ]; then
    MEMDIR="$(memory_resolve_memdir)" || exit 2
fi
[ -d "$MEMDIR" ] || { printf 'memory-truth: memory dir not found: %s\n' "$MEMDIR" >&2; exit 2; }
REPO="${MEMORY_TRUTH_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$REPO" ] || { echo 'memory-truth: cannot find the repo; set MEMORY_TRUTH_REPO' >&2; exit 2; }
REF="${MEMORY_TRUTH_REF:-}"
if [ -z "$REF" ]; then
    for r in origin/main main; do
        git -C "$REPO" rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1 && { REF="$r"; break; }
    done
fi
[ -n "$REF" ] || { printf 'memory-truth: no origin/main or main in %s; set MEMORY_TRUTH_REF\n' "$REPO" >&2; exit 2; }
MIRROR="${MEMORY_TRUTH_MIRROR:-${HOME:-}/.himmel/state/jira-mirror}"
PROJ="${JIRA_PROJECT_KEY:-HIMMEL}"

TMP="$(tmpdir)" && [ -d "$TMP" ] || exit 2
trap 'rm -rf "$TMP"' EXIT
git -C "$REPO" ls-tree -r --name-only "$REF" > "$TMP/tree" 2>/dev/null && [ -s "$TMP/tree" ] \
    || { printf 'memory-truth: cannot list %s in %s\n' "$REF" "$REPO" >&2; exit 2; }

notes=(); skipped=0
for f in "$MEMDIR"/*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    if printf '%s\n' "$b" | grep -Eq 'secret|token|credential|password|passwd|keyring|private|(^|[-_.])(keys?|env)([-_.]|$)'; then
        skipped=$((skipped + 1)); continue
    fi
    notes+=("$f")
done

: > "$TMP/raw"
if [ "${#notes[@]}" -gt 0 ]; then
    awk -v proj="$PROJ" '
    FNR == 1 { fileno++ }
    fileno == 1 {
        have[$0] = 1; n = split($0, part, "/"); if (n < 2) next
        top[part[1]] = 1; have[part[1]] = 1; d = part[1]
        for (i = 2; i < n; i++) { d = d "/" part[i]; have[d] = 1 }
        next
    }
    FNR == 1 { fm = ($0 == "---"); name = FILENAME; sub(/.*\//, "", name); if (fm) next }
    fm { if ($0 == "---") fm = 0; next }
    $0 ~ /^[[:space:]]*([-*][[:space:]]+)?(\*\*|_)?Incident [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { next }
    {
        line = $0; off = 0
        while (match(line, /[A-Za-z0-9._@+-]+(\/[A-Za-z0-9._@+-]+)+\/?/)) {
            p = substr(line, RSTART, RLENGTH)
            before = (off + RSTART > 1) ? substr($0, off + RSTART - 1, 1) : ""
            after = substr(line, RSTART + RLENGTH, 1)
            off += RSTART + RLENGTH - 1; line = substr(line, RSTART + RLENGTH)
            if (before ~ /[\/~$:]/ || after ~ /[<*{$[]/) continue
            sub(/\.+$/, "", p); slash = (p ~ /\/$/); sub(/\/$/, "", p)
            if (p ~ /-$/) continue
            n = split(p, comp, "/")
            if (!(comp[1] in top)) continue
            if (n < 3 && comp[n] !~ /\./ && !slash && before != "`") continue
            if (!(p in have)) printf "P\t%s\t%d\t%s\n", name, FNR, p
        }
        low = tolower($0)
        if (match(low, /(wait(s|ed|ing)?[[:space:]]+(on|for)|sync(s|ed|ing)?[[:space:]]+with)[[:space:]]+/)) {
            rest = substr($0, RSTART + RLENGTH)
            if (match(rest, /[;!?()]|\."?[[:space:]]|\."?$| — /)) rest = substr(rest, 1, RSTART - 1)
            if (match(rest, /^[0-9][0-9][0-9]+/)) printf "W\t%s\t%d\t%s-%s\n", name, FNR, proj, substr(rest, 1, RLENGTH)
            while (match(rest, /[A-Z][A-Z0-9]+-[0-9]+/)) {
                printf "W\t%s\t%d\t%s\n", name, FNR, substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    }' "$TMP/tree" "${notes[@]}" > "$TMP/raw"
fi
awk -F '\t' '$1 == "P" { print $4 }' "$TMP/raw" | git -C "$REPO" check-ignore --no-index --stdin > "$TMP/ignored" 2>/dev/null
awk -F '\t' 'FILENAME == ARGV[1] { ign[$0] = 1; next } !($1 == "P" && ($4 in ign))' "$TMP/ignored" "$TMP/raw" > "$TMP/kept"

found=0
while IFS=$'\t' read -r kind name lno what; do
    case "$kind" in
        P) printf 'dead-path %s:%s %s\n' "$name" "$lno" "$what"; found=$((found + 1)) ;;
        W)
            mf="$MIRROR/${what%%-*}/$what.md"
            if [ -f "$mf" ] && grep -q '^statusCategory: "Done"$' "$mf"; then
                printf 'closed-wait %s:%s %s (Done in the Jira mirror)\n' "$name" "$lno" "$what"; found=$((found + 1))
            fi ;;
    esac
done < <(sort -u "$TMP/kept" | sort -t "$(printf '\t')" -k2,2 -k3,3n)

printf 'memory-truth: %d finding(s) in %d note(s) checked against %s; %d skipped as sensitive\n' \
    "$found" "${#notes[@]}" "$REF" "$skipped"
[ "$found" -eq 0 ]
