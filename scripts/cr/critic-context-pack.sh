#!/usr/bin/env bash
# scripts/cr/critic-context-pack.sh - the code and intent the critic gets beyond the diff.
#
# usage (inside the repo under review):
#   critic-context-pack.sh <base> <head> [--intent-file f | --ticket KEY] [--pr-body-file f] [--budget N]
#
# stdout is a critic --context-file (critic-first-pass.sh): one {"range": [path, start, end]} line per
# block, a blank line, then the text, every line numbered. Blocks, in this order:
#   Intent   what the ticket asked for (range path INTENT); the first that answers wins:
#              --intent-file (calls nothing) | Jira `get` What + DoD | the PR body's `## Ticket coverage`
#              | "no ticket intent available".
#   Callers  for each function name git prints in a hunk header, up to 5 `git grep -n -w -F -e <name>`
#            hits with +-5 lines, searched in the BASE tree outside the changed files, so a cited path
#            is always a base-tree path.
#   Changed  each changed file at head: whole up to 16 KB, else its hunks +-60 lines.
# A block that would push the pack past --budget (default 65536 bytes) is left out, never cut.
# The ticket key is --ticket, else the [KEY-n] of the head commit subject. Jira is read only when no
# --intent-file is given; the eval always gives one.
# ponytail: a function name is the token before the first "(" (or after function/def/class) of git's
# hunk-header text, so a language git does not name functions in finds none; upgrade path = per-language
# xfuncname in .gitattributes. A path with a colon, quote, backslash or control character is not cited.
# Exit: 0 pack written; 2 usage error or a bad revision.
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$HERE/../lib/git-clean.sh"
git_env_scrub
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || { echo "critic-context-pack.sh: cannot load scripts/lib/prim.sh" >&2; exit 2; }

die() { echo "critic-context-pack.sh: $*" >&2; exit 2; }
base=""; head=""; intent_file=""; ticket=""; pr_body=""; budget=65536
while [ $# -gt 0 ]; do
    case "$1" in
        --intent-file|--ticket|--pr-body-file|--budget) [ $# -ge 2 ] || die "$1 needs a value" ;;
    esac
    case "$1" in
        --intent-file) intent_file="$2"; shift 2 ;;
        --ticket) ticket="$2"; shift 2 ;;
        --pr-body-file) pr_body="$2"; shift 2 ;;
        --budget) budget="$2"; shift 2 ;;
        -*) die "unknown option: $1" ;;
        *) if [ -z "$base" ]; then base="$1"; elif [ -z "$head" ]; then head="$1"; else die "too many arguments"; fi; shift ;;
    esac
done
[ -n "$base" ] && [ -n "$head" ] || die "usage: critic-context-pack.sh <base> <head> [--intent-file f | --ticket KEY] [--pr-body-file f] [--budget N]"
case "$budget" in ''|*[!0-9]*) die "--budget must be a number" ;; esac
[ "$budget" -ge 256 ] || die "--budget must be at least 256"
[ -z "$intent_file" ] || [ -r "$intent_file" ] || die "--intent-file '$intent_file' is not readable"
[ -z "$pr_body" ] || [ -r "$pr_body" ] || die "--pr-body-file '$pr_body' is not readable"
[ -z "$ticket" ] || [[ "$ticket" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]] || die "--ticket '$ticket' is not a ticket key"
top="$(git rev-parse --show-toplevel)" || die "not inside a git repo"
cd "$top" || die "cannot enter $top"
bsha="$(git rev-parse --verify -q "$base^{commit}")" || die "bad revision: $base"
hsha="$(git rev-parse --verify -q "$head^{commit}")" || die "bad revision: $head"

work="$(tmpdir)" || die "cannot make a temp dir"
trap 'rm -rf "$work"' EXIT
: > "$work/hdr"; : > "$work/body"; used=1   # the blank line between header and text

# add_piece <path> <start> <end>: append $work/piece as one block when it fits the budget.
add_piece() {
    local hl cost
    hl="$(printf '{"range": ["%s", %d, %d]}' "$1" "$2" "$3")"
    cost=$(( ${#hl} + 1 + $(wc -c < "$work/piece") ))
    [ $((used + cost)) -le "$budget" ] || return 1
    printf '%s\n' "$hl" >> "$work/hdr"; cat "$work/piece" >> "$work/body"; used=$((used + cost))
}

# add_file_range <label> <path> <rev> <start> <end>: lines start..end of <rev>:<path>, numbered.
add_file_range() {
    local n
    git show "$3:$2" 2>/dev/null | sed -n "$4,$5p" \
        | awk -v s="$4" -v h="# $1 $2" 'BEGIN { print h } { printf "%d: %s\n", NR + s - 1, $0 }' > "$work/piece"
    n=$(awk 'END { print NR - 1 }' "$work/piece")
    [ "$n" -ge 1 ] || return 0
    add_piece "$2" "$4" "$(( $4 + n - 1 ))"
}

# citable <path>: the header is JSON, so a path with a quote, backslash, control character or a git-quoted
# name is skipped; so is one with a colon (git grep output would not split back).
citable() { case "$1" in ''|\"*|*[\"\\:]*|*[[:cntrl:]]*) return 1 ;; esac; }

# --- Intent -----------------------------------------------------------------------------------------
jira_intent() {
    local key="$ticket" js out sect primary
    [ -n "$key" ] || key="$(git log -1 --format=%s "$hsha" | sed -n 's/.*\[\([A-Z][A-Z0-9]*-[0-9][0-9]*\)\].*/\1/p' | head -n 1)"
    [ -n "$key" ] || return 1
    js="${CRITIC_PACK_JIRA_JS:-}"
    if [ -z "$js" ]; then
        primary="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)" || return 1
        js="${primary%/.git}/scripts/jira/dist/index.js"
    fi
    [ -f "$js" ] && command -v node >/dev/null 2>&1 || return 1
    out="$(JIRA_PROJECT_KEY="${key%%-*}" node "$js" get "$key" 2>/dev/null)" && [ -n "$out" ] || return 1   # swallow-ok: a failed Jira read falls to the next intent tier
    sect="$(printf '%s\n' "$out" | awk '
        { t = $0; gsub(/^[#* ]+|[*: ]+$/, "", t) }
        t ~ /^(Impact|What|Why|Plan|DoD|Proof|Agent detail)$/ { keep = (t == "What" || t == "DoD"); if (keep) print t; next }
        keep { print }')"
    printf '%s\n' "${sect:-$out}"
}
pr_intent() {
    local sect
    [ -n "$pr_body" ] || return 1
    sect="$(awk '/^## Ticket coverage/ { on = 1; print "Ticket coverage:"; next } /^## / { on = 0 } on { print }' "$pr_body")"
    [ -n "${sect//[[:space:]]/}" ] || return 1
    printf '%s\n' "$sect"
}
if [ -n "$intent_file" ]; then intent="$(cat -- "$intent_file")"
else intent="$(jira_intent || pr_intent)"; fi
[ -n "${intent//[[:space:]]/}" ] || intent="no ticket intent available"
cap=$(( budget / 2 )); [ "$cap" -le 4096 ] || cap=4096
printf '%s\n' "$intent" | head -c "$cap" | awk 'BEGIN { print "# intent" } { printf "%d: %s\n", NR, $0 }' > "$work/piece"
add_piece INTENT 1 "$(( $(awk 'END { print NR - 1 }' "$work/piece") ))" || die "the intent does not fit --budget $budget"

# --- Callers ----------------------------------------------------------------------------------------
changed="$work/changed"
git diff --no-renames --no-ext-diff --numstat "$bsha" "$hsha" | awk -F'\t' '$1 != "-" { print $3 }' > "$changed"
excludes=()
while IFS= read -r p; do excludes+=(":(exclude,literal)$p"); done < "$changed"
# Keywords and control words that a hunk header can show but are no function name.
names="$(git diff --no-renames --no-ext-diff -U0 "$bsha" "$hsha" \
    | sed -n -E 's/^@@ -[0-9,]+ \+[0-9,]+ @@ (.+)$/\1/p' | while IFS= read -r t; do
        case "$t" in
            *"("*) t="${t%%(*}" ;;
            function\ *|def\ *|func\ *|fn\ *|sub\ *|class\ *) t="${t%%[{:]*}" ;;
            *) continue ;;
        esac
        t="${t%"${t##*[![:space:]]}"}"; t="${t##*[[:space:]]}"
        case "$t" in ''|if|for|while|switch|case|catch|until|elif|else|return|function|def|func|fn|sub|class) continue ;; esac
        printf '%s\n' "$t"
    done | awk '!seen[$0]++' | head -n 10)"
: > "$work/seen"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    while IFS= read -r line; do
        r="${line#"$bsha":}"; path="${r%%:*}"; r="${r#*:}"; ln="${r%%:*}"
        citable "$path" || continue
        case "$ln" in ''|*[!0-9]*) continue ;; esac
        grep -qFx -e "$path:$ln" "$work/seen" && continue
        printf '%s:%s\n' "$path" "$ln" >> "$work/seen"
        s=$(( ln > 5 ? ln - 5 : 1 ))
        add_file_range "caller of $name:" "$path" "$bsha" "$s" "$(( ln + 5 ))" || break 2
    done < <(git grep -n -w -F -e "$name" "$bsha" -- . ${excludes[@]+"${excludes[@]}"} 2>/dev/null | awk 'NR <= 5')
done <<< "$names"

# --- Changed files at head --------------------------------------------------------------------------
while IFS= read -r path; do
    citable "$path" || continue
    git cat-file -e "$hsha:$path" 2>/dev/null || continue
    size="$(git cat-file -s "$hsha:$path")"
    total="$(git show "$hsha:$path" | awk 'END { print NR }')"
    [ "$total" -ge 1 ] || continue
    if [ "$size" -le 16384 ]; then
        add_file_range "changed file" "$path" "$hsha" 1 "$total" || continue
    else
        while read -r s e; do
            add_file_range "changed file (hunk)" "$path" "$hsha" "$s" "$e" || break
        done < <(git diff --no-renames --no-ext-diff -U0 "$bsha" "$hsha" -- "$path" | awk -v total="$total" -v pad=60 '
            /^@@ / && match($0, /\+[0-9]+(,[0-9]+)?/) {
                split(substr($0, RSTART + 1, RLENGTH - 1), a, ",")
                st = a[1]; cnt = (a[2] == "" ? 1 : a[2])
                s = st - pad; e = (cnt == 0 ? st : st + cnt - 1) + pad
                if (s < 1) s = 1
                if (e > total) e = total
                if (have && s <= pe + 1) { if (e > pe) pe = e } else { if (have) print ps, pe; ps = s; pe = e; have = 1 }
            }
            END { if (have) print ps, pe }')
    fi
done < "$changed"

cat "$work/hdr"; echo; cat "$work/body"
