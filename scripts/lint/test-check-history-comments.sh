#!/usr/bin/env bash
# test-check-history-comments.sh — tests for scripts/lint/check-history-comments.sh.
#
# Each case feeds the gate a unified diff (--diff <file>) built with printf, so
# this file carries no history-shaped comment of its own. Cases:
#   1-5.  one added comment per history shape (ticket, review-fix note, bot round,
#         round N, judge qid)                                   -> exit 1, path:line named
#   6.    ponytail: line citing a ticket                         -> exit 0
#   7.    old (context) line carrying a ticket                   -> exit 0
#   8.    ticket inside a string, not a comment                  -> exit 0
#   9.    // comment in a .mjs file                              -> exit 1
#   10.   non-code path (.md) and fixtures path                  -> exit 0
#   11.   clean why-comment                                      -> exit 0
#   12.   --staged and --range read real git state
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GATE="$SELF_DIR/check-history-comments.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/hist-comment-gate.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

if [ ! -f "$GATE" ]; then
    echo "FAIL: $GATE does not exist yet (RED)"
    exit 1
fi

# mkdiff <path> <line>...: a one-hunk diff; a line starting with "+" is added,
# "=" is a context (old) line.
mkdiff() {
    local path="$1"; shift
    {
        printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,1 +1,%d @@\n' "$path" "$path" "$path" "$path" "$#"
        local l
        for l in "$@"; do
            case "$l" in
                +*) printf '%s\n' "$l" ;;
                =*) printf ' %s\n' "${l#=}" ;;
            esac
        done
    } > "$T/d.diff"
}
run() { OUT="$(bash "$GATE" --diff "$T/d.diff" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

H='HIMMEL'
expect_block() { # <label> <path> <added line>
    mkdiff "$2" '+echo ok' "$3"
    run
    if [ "$RC" -eq 1 ] && has "$2:" && has "ponytail-convention"; then pass "$1 refused"; else fail "$1 -> rc=$RC: $OUT"; fi
}
expect_allow() { # <label> <path> <diff line>...
    local label="$1" path="$2"; shift 2
    mkdiff "$path" "$@"
    run
    if [ "$RC" -eq 0 ]; then pass "$label allowed"; else fail "$label -> rc=$RC: $OUT"; fi
}

echo "== 1-5. history shapes =="
expect_block "ticket id"          scripts/a.sh "+# ${H}-1234 added this guard"
expect_block "CR fix"             scripts/a.sh "+    # CR fix: quote the path"
expect_block "CodeRabbit round"   scripts/a.sh "+# CodeRabbit round two asked for this"
expect_block "round N"            scripts/a.sh "+# review round 3 moved the check here"
expect_block "judge qid"          scripts/a.sh "+# verdict j0042a said keep"

echo "== 6. ponytail exemption =="
expect_allow "ponytail line with ticket" scripts/a.sh "+# ponytail: prefix match only, upgrade tracked in ${H}-77"

echo "== 7. unchanged old line =="
expect_allow "context line" scripts/a.sh "=# ${H}-1234 old history" '+echo new'

echo "== 8. string, not a comment =="
expect_allow "ticket in a string" scripts/a.sh "+echo \"see ${H}-1234 for details\""

echo "== 9. // comment =="
expect_block "js comment" scripts/a.mjs "+// ${H}-5 workaround"

echo "== 10. out-of-scope paths =="
expect_allow "markdown" docs/x.md "+# ${H}-1 heading"
expect_allow "fixture"  scripts/fixtures/a.sh "+# ${H}-1 fixture comment"

echo "== 11. clean why-comment =="
expect_allow "why comment" scripts/a.sh '+# macOS bash 3.2 has no mapfile, so read the list in a loop'

echo "== 12. real git state =="
R="$T/repo"; mkdir -p "$R/scripts"; git -C "$R" init -q
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '# %s-1 old history\necho a\n' "$H" > "$R/scripts/a.sh"
git -C "$R" add -A; git -C "$R" commit -q -m base
base="$(git -C "$R" rev-parse HEAD)"
printf '# %s-1 old history\necho a\n# why: tool X drops the last newline\n' "$H" > "$R/scripts/a.sh"
git -C "$R" add -A
OUT="$(cd "$R" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--staged: old history line + clean addition -> 0"; else fail "--staged clean -> rc=$RC: $OUT"; fi
printf '# %s-1 old history\necho a\n# CR fix: added\n' "$H" > "$R/scripts/a.sh"
git -C "$R" add -A; git -C "$R" commit -q -m two
OUT="$(cd "$R" && bash "$GATE" --range "$base" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/a.sh:3"; then pass "--range names scripts/a.sh:3"; else fail "--range -> rc=$RC: $OUT"; fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
