#!/usr/bin/env bash
# test-check-history-comments.sh — tests for scripts/lint/check-history-comments.sh.
#
# Each case feeds the gate a unified diff (--diff <file>) built with printf, so
# this file carries no history-shaped comment of its own, and every key is built
# from $H, $LU and $SA at runtime so the widened gate passes this file. Cases:
#   1-5.  one added comment per history shape (ticket, review-fix note, bot round,
#         round N, judge qid)                                   -> exit 1, path:line named
#   6.    ponytail: line citing a ticket                         -> exit 1
#   7.    old (context) line carrying a ticket                   -> exit 0
#   8.    a ticket in code, data or output is refused in non-test files; test files,
#         fixtures and clean output pass
#   9.    // comment in a .mjs file                              -> exit 1
#   10.   a doc heading with a key is refused; a fixtures path passes
#   11.   clean why-comment                                      -> exit 0
#   12.   --staged and --range read real git state
#   13.   the lint-job step of ci.yml, run against throwaway PR ranges, with the
#         base copies and the bootstrap branch
#   14.   a .gitattributes -diff entry does not hide an added line (--staged, --range)
#   15.   --range ignores unchanged output ids
#   16.   a verbatim move (old path left as a symlink) adds no lines; an edited move is checked
#   17.   a moved file with one edited line: its old comments are not judged, the edit is
#   18.   the ship-gate and CI writers print no ticket id
#   19-20. a key in a doc heading and in a YAML comment
#   21-23. test files: the four citation shapes are refused, data passes
#   24-29. key boundaries, ponytail, history rows, other project keys, K6 rows, a swapped list
#   30.   a missing rule list or classifier -> exit 2
#   31.   --count-comments shapes
#   32.   a binary file is skipped by content
#   33-35. the one-shot tree check on a temp repo, the pre-commit entry, --root on every call
#   36.   non-key refusals stay on code files
#   39.   --range with --tip on a branch HEAD is not on
#   40.   a malformed rule row or a second key row exits 2 (never an exempt-everything row)
#   41.   a symlink replaced by a regular file is judged
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GATE="$SELF_DIR/check-history-comments.sh"
AWKF="$SELF_DIR/ticket-refs.awk"
LIST="$SELF_DIR/ticket-ref-allow.tsv"
ONESHOT="$SELF_DIR/../one-shot/check-ticket-refs.sh"
PRE_S0="$SELF_DIR/fixtures/pre-s0-gate/check-history-comments.sh"

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

H='HIMMEL'; LU='LUNA'; SA='SALUS'; TAB="$(printf '\t')"
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

echo "== 6. ponytail is no exemption =="
expect_block "ponytail line with ticket" scripts/a.sh "+# ponytail: prefix match only, upgrade tracked in ${H}-77"

echo "== 7. unchanged old line =="
expect_allow "context line" scripts/a.sh "=# ${H}-1234 old history" '+echo new'

echo "== 8. user-facing output =="
expect_block "ticket in data" scripts/a.sh "+ticket=\"${H}-1234\""
expect_block "ticket before clean shell output" scripts/a.sh "+ticket=\"${H}-123\"; echo ready"
expect_block "ticket after clean shell output" scripts/a.sh "+echo ready; ticket=\"${H}-123\""
expect_block "ticket before clean JS output" scripts/a.ts "+const ticket = '${H}-123'; console.log('ready');"
expect_block "ticket after clean JS output" scripts/a.ts "+console.log('ready'); const ticket = '${H}-123';"
expect_block "ticket before clean Python output" scripts/a.py "+ticket = '${H}-123'; print('ready')"
expect_block "ticket after clean Python output" scripts/a.py "+print('ready'); ticket = '${H}-123'"
expect_block "ticket in separate shell and-list" scripts/a.sh "+ticket='${H}-123' && echo ready"
expect_block "ticket in separate shell or-list" scripts/a.sh "+echo ready || ticket='${H}-123'"
expect_block "shell echo output" scripts/a.sh "+echo \"see ${H}-1234 for details\""
expect_block "shell printf output" scripts/a.sh "+printf '%s\\n' '${H}-123'"
expect_block "shell die output" scripts/a.sh "+die '${H}-123 failed'"
expect_block "shell warn output" scripts/a.sh "+warn '${H}-123 failed'"
expect_block "shell say output" scripts/a.sh "+say '${H}-123 ready'"
expect_block "shell stderr echo" scripts/a.sh "+>&2 echo '${H}-123 failed'"
expect_block "shell inline output" scripts/a.sh "+[ -f a ] || echo '${H}-123 missing'"
expect_block "shell then output" scripts/a.sh "+if true; then echo '${H}-123'; fi"
expect_block "shell do output" scripts/a.sh "+for a in b; do echo '${H}-123'; done"
expect_block "shell else output" scripts/a.sh "+if false; then :; else echo '${H}-123'; fi"
expect_block "console error output" scripts/a.ts "+console.error('${H}-123 failed');"
expect_block "console log output" scripts/a.mjs "+console.log('${H}-123 ready');"
expect_block "console warn output" scripts/a.js "+console.warn('${H}-123 warning');"
expect_block "stdout write output" scripts/a.cjs "+process.stdout.write('${H}-123 ready');"
expect_block "stderr write output" scripts/a.tsx "+process.stderr.write('${H}-123 failed');"
expect_block "Python print output" scripts/a.py "+print('${H}-123 ready')"
expect_block "Python stderr output" scripts/a.py "+sys.stderr.write('${H}-123 failed')"
expect_block "output ponytail" scripts/a.sh "+echo '${H}-123 ready' # ponytail: fixed text only, replace when localized"
expect_allow "output fixture" scripts/fixtures/a.sh "+echo '${H}-123 fixture'"
expect_allow "output test file" scripts/test-a.sh "+echo '${H}-123 test'"
expect_allow "output test directory" scripts/tests/a.py "+print('${H}-123 test')"
expect_allow "output JS test file" src/a.test.ts "+console.error('${H}-123 test');"
expect_allow "output spec file" src/a.spec.js "+console.log('${H}-123 test');"
expect_allow "output clean" scripts/a.sh '+echo ready'
expect_block "command mentioned in data" scripts/a.sh "+example=\"echo ${H}-123\""
expect_block "quoted shell delimiter" scripts/a.sh "+example=\"; echo ${H}-123\""
expect_block "quoted JS delimiter" scripts/a.ts "+const example = \"; console.log('${H}-123')\";"
expect_block "quoted Python delimiter" scripts/a.py "+example = \"; print('${H}-123')\""
expect_allow "Python test filename" scripts/test_a.py "+print('${H}-123 fixture')"
expect_block "console mentioned in data" scripts/a.ts "+const example = \"console.error('${H}-123')\";"
expect_block "no invented history-ok exemption" docs/a.md "+echo '${H}-123' # history-ok: example"
expect_block "history-ok is not an exemption" scripts/a.sh "+echo '${H}-123' # history-ok: debug only"
mkdiff scripts/a.sh '+echo clean' "+echo '${H}-123 failed'"
run
if [ "$RC" -eq 1 ] && has "scripts/a.sh:2: ticket id:" && has "echo '${H}-123 failed'"; then pass "output reports path, line and text"; else fail "output diagnostic -> rc=$RC: $OUT"; fi

echo "== 9. // comment =="
expect_block "js comment" scripts/a.mjs "+// ${H}-5 workaround"

echo "== 10. doc heading refused, fixtures path skipped =="
expect_block "markdown" docs/x.md "+# ${H}-1 heading"
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
git -C "$R" rev-parse HEAD > "$R/.git/MERGE_HEAD"
printf '# %s-1 old history\necho a\n# CR fix: added\n# why: clean line from our side\n' "$H" > "$R/scripts/a.sh"
git -C "$R" add -A
OUT="$(cd "$R" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--staged in a merge: a history line already in MERGE_HEAD is not new"; else fail "merge merged-in line -> rc=$RC: $OUT"; fi
printf '# %s-1 old history\necho a\n# CR fix: added\n# round 2 of ours\n' "$H" > "$R/scripts/a.sh"
git -C "$R" add -A
OUT="$(cd "$R" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/a.sh:4"; then pass "--staged in a merge: a history line our side adds is still blocked"; else fail "merge own line -> rc=$RC: $OUT"; fi

echo "== 13. ci.yml lint step (extracted from the real workflow) =="
CI_YML="$SELF_DIR/../../.github/workflows/ci.yml"
STEP="$T/step.sh"
awk '
    /^  [a-z][a-z0-9-]*:/ { injob = ($1 == "lint:") }
    injob && /^      - name: history-comment gate/ { instep = 1; next }
    instep && /^        run: \|/ { inrun = 1; next }
    inrun && /^          / { sub(/^          /, ""); print; next }
    inrun { exit }
' "$CI_YML" > "$STEP"
if [ -s "$STEP" ]; then pass "lint job has a history-comment gate step"; else fail "no history-comment gate step in the lint job of ci.yml"; fi
S="$T/ci"; mkdir -p "$S/scripts/lint" "$S/tmp"; git -C "$S" init -q
git -C "$S" config user.email t@t; git -C "$S" config user.name t
cp "$GATE" "$AWKF" "$LIST" "$S/scripts/lint/"
printf 'echo a\n' > "$S/scripts/a.sh"
git -C "$S" add -A; git -C "$S" commit -q -m base
pr_base="$(git -C "$S" rev-parse HEAD)"
printf 'echo a\n# %s-1234 added this guard\n' "$H" > "$S/scripts/a.sh"
git -C "$S" add -A; git -C "$S" commit -q -m ticket
step() { OUT="$(cd "$S" && BASE_SHA="$1" RUNNER_TEMP="$S/tmp" bash "$STEP" 2>&1)"; RC=$?; }
step "$pr_base"
if [ "$RC" -eq 1 ] && has "scripts/a.sh:2"; then pass "step: PR range adding a ticket comment fails"; else fail "step ticket -> rc=$RC: $OUT"; fi
step ""
if [ "$RC" -ne 0 ]; then pass "step: missing base sha fails closed"; else fail "step empty base -> rc=$RC: $OUT"; fi
step "0000000000000000000000000000000000000000"
if [ "$RC" -ne 0 ]; then pass "step: unreachable base sha fails closed"; else fail "step bad base -> rc=$RC: $OUT"; fi
printf 'echo a\n# ponytail: prefix only, upgrade tracked in %s-77\n' "$H" > "$S/scripts/a.sh"
git -C "$S" add -A; git -C "$S" commit -q -m ponytail
step "$pr_base"
if [ "$RC" -eq 1 ] && has "scripts/a.sh:2"; then pass "step: ponytail line citing a ticket is refused"; else fail "step ponytail -> rc=$RC: $OUT"; fi
# (a) a base that predates the rule list is judged by its own gate alone
B="$T/boot"; mkdir -p "$B/scripts/lint" "$B/tmp"; git -C "$B" init -q
git -C "$B" config user.email t@t; git -C "$B" config user.name t
cp "$PRE_S0" "$B/scripts/lint/check-history-comments.sh"
printf 'echo a\n' > "$B/scripts/a.sh"
git -C "$B" add -A; git -C "$B" commit -q -m base
boot_base="$(git -C "$B" rev-parse HEAD)"
printf 'echo a\necho b\n' > "$B/scripts/a.sh"
git -C "$B" add -A; git -C "$B" commit -q -m clean
bstep() { OUT="$(cd "$B" && BASE_SHA="$1" RUNNER_TEMP="$B/tmp" bash "$STEP" 2>&1)"; RC=$?; }
bstep "$boot_base"
if [ "$RC" -eq 0 ] && has "bootstrap"; then pass "step: a base without the rule list runs the base gate alone and passes a clean PR"; else fail "step bootstrap clean -> rc=$RC: $OUT"; fi
printf 'echo a\necho b\n# %s-1234 added this guard\n' "$H" > "$B/scripts/a.sh"
git -C "$B" add -A; git -C "$B" commit -q -m ticket
bstep "$boot_base"
if [ "$RC" -eq 1 ] && has "scripts/a.sh:3"; then pass "step: the bootstrap base gate still refuses a code comment"; else fail "step bootstrap ticket -> rc=$RC: $OUT"; fi
# (b) a PR cannot widen the rule list that judges it
P="$T/widen"; mkdir -p "$P/scripts/lint" "$P/docs" "$P/tmp"; git -C "$P" init -q
git -C "$P" config user.email t@t; git -C "$P" config user.name t
cp "$GATE" "$AWKF" "$LIST" "$P/scripts/lint/"
printf 'x\n' > "$P/docs/z.md"
git -C "$P" add -A; git -C "$P" commit -q -m base
widen_base="$(git -C "$P" rev-parse HEAD)"
printf 'K2%s^docs/z\\.md$%s%sthe PR allows itself\n' "$TAB" "$TAB" "$TAB" >> "$P/scripts/lint/ticket-ref-allow.tsv"
printf 'x\nsee %s-5\n' "$H" > "$P/docs/z.md"
git -C "$P" add -A; git -C "$P" commit -q -m widen
OUT="$(cd "$P" && BASE_SHA="$widen_base" RUNNER_TEMP="$P/tmp" bash "$STEP" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "docs/z.md:2"; then pass "step: a PR that adds a rule row and a line it would allow is still refused (base list)"; else fail "step widen -> rc=$RC: $OUT"; fi
printf 'x\n' > "$P/docs/z.md"
git -C "$P" add -A; git -C "$P" commit -q -m clean
OUT="$(cd "$P" && BASE_SHA="$widen_base" RUNNER_TEMP="$P/tmp" bash "$STEP" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "step: the same range without the key line passes"; else fail "step widen clean -> rc=$RC: $OUT"; fi

echo "== 14. .gitattributes -diff cannot hide added lines =="
A="$T/attr"; mkdir -p "$A/scripts"; git -C "$A" init -q
git -C "$A" config user.email t@t; git -C "$A" config user.name t
printf '*.sh -diff\n' > "$A/.gitattributes"
printf 'echo a\n' > "$A/scripts/a.sh"
git -C "$A" add -A; git -C "$A" commit -q -m base
attr_base="$(git -C "$A" rev-parse HEAD)"
printf 'echo a\n# %s-1234 added this guard\n' "$H" > "$A/scripts/a.sh"
git -C "$A" add -A
OUT="$(cd "$A" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/a.sh:2"; then pass "--staged: -diff attribute does not hide the line"; else fail "--staged -diff -> rc=$RC: $OUT"; fi
git -C "$A" commit -q -m ticket
OUT="$(cd "$A" && bash "$GATE" --range "$attr_base" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/a.sh:2"; then pass "--range: -diff attribute does not hide the line"; else fail "--range -diff -> rc=$RC: $OUT"; fi

echo "== 15. --range ignores unchanged output ids =="
O="$T/output"; mkdir -p "$O/scripts"; git -C "$O" init -q
git -C "$O" config user.email t@t; git -C "$O" config user.name t
printf 'echo "%s-123 old output"\n' "$H" > "$O/scripts/a.sh"
git -C "$O" add -A; git -C "$O" commit -q -m base
output_base="$(git -C "$O" rev-parse HEAD)"
printf 'echo ready\n' >> "$O/scripts/a.sh"
git -C "$O" add -A; git -C "$O" commit -q -m clean
OUT="$(cd "$O" && bash "$GATE" --range "$output_base" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--range: unchanged output id is not new"; else fail "unchanged output -> rc=$RC: $OUT"; fi
printf 'echo "%s-456 new output"\n' "$H" >> "$O/scripts/a.sh"
git -C "$O" add -A
OUT="$(cd "$O" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/a.sh:3"; then pass "--staged: new output id refused"; else fail "staged output -> rc=$RC: $OUT"; fi
git -C "$O" commit -q -m output
OUT="$(cd "$O" && bash "$GATE" --range "$output_base" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/a.sh:3"; then pass "--range: new output id refused"; else fail "range output -> rc=$RC: $OUT"; fi

echo "== 16. a verbatim move adds no lines =="
M="$T/move"; mkdir -p "$M/scripts/old"; git -C "$M" init -q
git -C "$M" config user.email t@t; git -C "$M" config user.name t
printf 'echo a\n# %s-9 old history\n' "$H" > "$M/scripts/old/a.sh"
git -C "$M" add -A; git -C "$M" commit -q -m base
move_base="$(git -C "$M" rev-parse HEAD)"
git -C "$M" mv scripts/old scripts/new
ln -s new "$M/scripts/old"
git -C "$M" add -A
OUT="$(cd "$M" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--staged: moved dir with a symlink at the old path -> 0"; else fail "staged move -> rc=$RC: $OUT"; fi
git -C "$M" commit -q -m move
OUT="$(cd "$M" && bash "$GATE" --range "$move_base" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--range: moved dir with a symlink at the old path -> 0"; else fail "range move -> rc=$RC: $OUT"; fi
printf 'echo a\n# %s-9 old history\n# round 2 note\n' "$H" > "$M/scripts/new/a.sh"
git -C "$M" add -A; git -C "$M" commit -q -m edit
OUT="$(cd "$M" && bash "$GATE" --range "$move_base" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/new/a.sh"; then pass "--range: a move that also edits the file is still checked"; else fail "range move+edit -> rc=$RC: $OUT"; fi

echo "== 17. a moved file with one edited line judges only the edit =="
E="$T/moveedit"; mkdir -p "$E/scripts/old"; git -C "$E" init -q
git -C "$E" config user.email t@t; git -C "$E" config user.name t
printf 'echo a\n# %s-9 old history\necho c\necho d\necho e\necho f\n' "$H" > "$E/scripts/old/a.sh"
git -C "$E" add -A; git -C "$E" commit -q -m base || exit 1
edit_base="$(git -C "$E" rev-parse HEAD)"
git -C "$E" mv scripts/old scripts/new || exit 1
printf 'echo b\n# %s-9 old history\necho c\necho d\necho e\necho f\n' "$H" > "$E/scripts/new/a.sh"
git -C "$E" add -A; git -C "$E" commit -q -m move-edit || exit 1
OUT="$(cd "$E" && bash "$GATE" --range "$edit_base" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--range: moved file's old ticket comment is not judged"; else fail "moved+edited old comment -> rc=$RC: $OUT"; fi
printf 'echo b\n# %s-9 old history\necho c\necho d\necho e\n# %s-10 added this guard\n' "$H" "$H" > "$E/scripts/new/a.sh"
git -C "$E" add -A; git -C "$E" commit -q -m add-ticket || exit 1
OUT="$(cd "$E" && bash "$GATE" --range "$edit_base" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "scripts/new/a.sh:6" && ! has "scripts/new/a.sh:2"; then pass "--range: the edited line adding a ticket comment is flagged alone"; else fail "moved+edited new comment -> rc=$RC: $OUT"; fi

echo "== 18. the ship-gate and CI writers print no ticket id =="
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
for f in scripts/check-ci.sh scripts/ci/run-shell-tests.sh scripts/lib/go-gate.sh \
         scripts/handover/merge-on-green.sh scripts/handover/chief-kit/go.sh \
         scripts/handover/chief-kit/write-verdict.sh; do
    RAW="$(grep -n -E "(echo|printf|die|warn).*${H}-[0-9]+" "$REPO_ROOT/$f")"; GRC=$?
    OUT="$(printf '%s\n' "$RAW" | grep -v 'ponytail:' | grep -v '^$')"
    if [ "$GRC" -gt 1 ]; then fail "$f: grep could not read it (rc=$GRC)"
    elif [ -z "$OUT" ]; then pass "$f: no output line carries a ticket id"; else fail "$f: $(printf '%s' "$OUT" | cut -c1-120 | head -3)"; fi
done
HELP="$(bash "$REPO_ROOT/scripts/check-ci.sh" --help 2>&1)"; HRC=$?
OUT="$(printf '%s\n' "$HELP" | grep -n -E "${H}-[0-9]+" | cut -c1-100)"
if [ "$HRC" -ne 0 ] || ! printf '%s' "$HELP" | grep -q 'exit codes'; then fail "check-ci.sh --help: rc=$HRC, usage text not printed"
elif [ -z "$OUT" ]; then pass "check-ci.sh --help prints no ticket id"; else fail "check-ci.sh --help: $(printf '%s' "$OUT" | head -3)"; fi

echo "== 19-20. a key in a doc heading and in a YAML comment =="
expect_block "markdown heading" docs/x.md "+### Foo (${H}-1234)"
expect_block "yaml comment" x.yaml "+# ${H}-1234"

echo "== 21-23. test files: four citation shapes refused, data passes =="
TF=scripts/test-a.sh
expect_block "G1 row name" "$TF" "+check 'x works (${H}-1234)' true"
expect_block "G1 two keys" "$TF" "+check \"x works (${H}-1, ${H}-2)\" true"
expect_block "G2 SKIP" "$TF" "+echo \"  SKIP ${H}-1234\""
expect_block "G2 FAIL" "$TF" "+echo \"FAIL ${H}-1234 x\""
expect_block "G3 message prefix" "$TF" "+fail \"${H}-1234: x\""
expect_block "G4 trailing comment" "$TF" "+run x  # ${H}-1234"
expect_block "G4 trailing slash comment" src/a.test.ts "+run(x); // ${H}-1234"
expect_block "whole-line comment in a test" "$TF" "+# ${H}-1234 why"
expect_allow "quoted # is data" "$TF" "+printf '# ${H}-2 — x\\n'"
expect_allow "data row" "$TF" "+mk ${H}-28 Task \"To Do\""
expect_allow "key built at runtime" "$TF" "+echo \"\$H-5 ok\""
expect_allow "test/ directory data" scripts/himmelctl/test/_hermetic-home.sh "+mk ${H}-1"

echo "== 24-26. key boundaries, ponytail, history rows =="
expect_allow "key glued to a word" docs/x.md "+foo${H}-1"
expect_block "key in parentheses" docs/x.md "+see (${H}-1)"
expect_block "key at line end" docs/x.md "+ends with ${H}-1"
expect_block "ponytail line carries a key" scripts/a.sh "+# ponytail: x, upgrade when ${H}-1234 lands"
expect_allow "release history" docs/release/v1.md "+- shipped ${H}-1"
expect_allow "fixture markdown" fixtures/x.md "+${H}-1 input"

echo "== 27-28. a row's file and shape; other project keys =="
KB=scripts/handover/chief-kit/known-checker-bugs.tsv
expect_allow "data row a program reads" "$KB" "+${H}-7980${TAB}UNOWNED${TAB}${H}-7848${TAB}2026-10-28T22:31:00Z"
expect_block "same file, another line" "$KB" "+# note about ${H}-7980"
expect_block "LUNA key in a doc" docs/x.md "+see ${LU}-12"
expect_block "SALUS key in a doc" docs/x.md "+see ${SA}-3"

echo "== 29. the key pattern comes from the rule list =="
W="$T/swap"; mkdir -p "$W/scripts/lint"
cp "$GATE" "$AWKF" "$W/scripts/lint/"
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "key" { $3 = "ZZZ-[0-9]+" } { print }' "$LIST" > "$W/scripts/lint/ticket-ref-allow.tsv"
SWAPGATE="$W/scripts/lint/check-history-comments.sh"
swap() { # <label> <expected rc> <path> <line>
    mkdiff "$3" "$4"
    OUT="$(bash "$SWAPGATE" --diff "$T/d.diff" 2>&1)"; RC=$?
    if [ "$RC" -eq "$2" ]; then pass "swapped list: $1"; else fail "swapped list $1 -> rc=$RC: $OUT"; fi
}
swap "ZZZ in a code comment is refused" 1 scripts/a.sh "+# ZZZ-1 x"
swap "ZZZ in an output call is refused" 1 scripts/a.sh "+echo 'ZZZ-1 x'"
swap "ZZZ in a doc line is refused" 1 docs/x.md "+see ZZZ-1"
swap "ZZZ in a G1 test row is refused" 1 "$TF" "+check 'x (ZZZ-1)' true"
swap "HIMMEL in a code comment passes" 0 scripts/a.sh "+# ${H}-1 x"
swap "HIMMEL in an output call passes" 0 scripts/a.sh "+echo '${H}-1 x'"
swap "HIMMEL in a doc line passes" 0 docs/x.md "+see ${H}-1"
swap "HIMMEL in a G1 test row passes" 0 "$TF" "+check 'x (${H}-1)' true"

echo "== 30. a missing rule list or classifier cannot evaluate =="
M2="$T/miss"; mkdir -p "$M2/scripts/lint"; git -C "$M2" init -q
git -C "$M2" config user.email t@t; git -C "$M2" config user.name t
printf 'echo a\n' > "$M2/scripts/a.sh"
git -C "$M2" add -A; git -C "$M2" commit -q -m base
miss_base="$(git -C "$M2" rev-parse HEAD)"
printf 'echo a\necho b\n' > "$M2/scripts/a.sh"
git -C "$M2" add -A
cp "$GATE" "$AWKF" "$M2/scripts/lint/"
MG="$M2/scripts/lint/check-history-comments.sh"
OUT="$(cd "$M2" && bash "$MG" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "no rule list: --staged exits 2"; else fail "no rule list --staged -> rc=$RC: $OUT"; fi
OUT="$(cd "$M2" && bash "$MG" --range "$miss_base" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "no rule list: --range exits 2"; else fail "no rule list --range -> rc=$RC: $OUT"; fi
rm -f "$M2/scripts/lint/ticket-refs.awk"; cp "$LIST" "$M2/scripts/lint/"
OUT="$(cd "$M2" && bash "$MG" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "no classifier: --staged exits 2"; else fail "no classifier --staged -> rc=$RC: $OUT"; fi
OUT="$(cd "$M2" && bash "$MG" --range "$miss_base" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "no classifier: --range exits 2"; else fail "no classifier --range -> rc=$RC: $OUT"; fi

echo "== 31. --count-comments =="
count() { # <label> <expected> <path> <line>...
    local label="$1" want="$2" path="$3"; shift 3
    mkdiff "$path" "$@"
    OUT="$(bash "$GATE" --diff "$T/d.diff" --count-comments 2>&1)"; RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "$want" ]; then pass "count: $label -> $want"; else fail "count $label -> rc=$RC out=$OUT (want $want)"; fi
}
count "two # lines and one code line" 2 scripts/a.sh '+# a' '+x=1' '+# b'
count "three-line JSDoc" 3 src/a.ts '+/**' '+ * doc' '+ */'
count "block without leading stars" 3 src/a.ts '+/* start' '+inner' '+end */'
count "docstring opener alone" 1 src/a.py '+"""doc text'
count "docstring with inner and closing lines" 3 src/a.py '+    """Doc.' '+    inner' '+    """'
count "quote-aware trailing comment" 1 scripts/a.sh '+x=1  # why'
count "# inside a quote" 0 scripts/a.sh "+printf '# x'"
count "markdown heading" 0 docs/x.md '+## heading'

echo "== 32. a binary file is skipped by content =="
BN="$T/bin"; mkdir -p "$BN/assets" "$BN/docs"; git -C "$BN" init -q
git -C "$BN" config user.email t@t; git -C "$BN" config user.name t
printf 'x\n' > "$BN/docs/t.md"; git -C "$BN" add -A; git -C "$BN" commit -q -m base
printf '\211PNG\r\n\032\n\000\000 %s-1234 \000' "$H" > "$BN/assets/a.png"
git -C "$BN" add -A
OUT="$(cd "$BN" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "--staged: a PNG whose bytes carry a key is skipped"; else fail "staged binary -> rc=$RC: $OUT"; fi
printf 'x\nsee %s-1234\n' "$H" > "$BN/docs/t.md"; git -C "$BN" add -A
OUT="$(cd "$BN" && bash "$GATE" --staged 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "docs/t.md:2" && ! has "assets/a.png"; then pass "--staged: the text file beside the PNG is still refused"; else fail "staged text beside binary -> rc=$RC: $OUT"; fi

echo "== 33. the one-shot on a temp repo =="
OS="$T/oneshot"; mkdir -p "$OS/docs/release"; git -C "$OS" init -q
git -C "$OS" config user.email t@t; git -C "$OS" config user.name t
printf 'see %s-5\n' "$H" > "$OS/docs/a.md"; printf 'clean\n' > "$OS/docs/clean.md"
printf 'shipped %s-6\n' "$H" > "$OS/docs/release/v1.md"
git -C "$OS" add -A; git -C "$OS" commit -q -m base
OUT="$(bash "$ONESHOT" --root "$OS" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && has "HIT docs/a.md:1" && ! has "docs/release"; then pass "one-shot: a tracked key is a HIT, a history row is not"; else fail "one-shot -> rc=$RC: $OUT"; fi
printf 'docs/clean.md\n' > "$T/paths.txt"
OUT="$(bash "$ONESHOT" --root "$OS" --paths "$T/paths.txt" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "one-shot: --paths excluding the file exits 0"; else fail "one-shot --paths -> rc=$RC: $OUT"; fi
OUT="$(bash "$ONESHOT" --root "$OS" --bogus 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "one-shot: a bad flag exits 2"; else fail "one-shot bad flag -> rc=$RC: $OUT"; fi

echo "== 34. pre-commit entry sees every file =="
PC="$SELF_DIR/../../.pre-commit-config.yaml"
ENTRY="$(awk '/^      - id: /{ inb = ($3 == "no-history-comments") } inb' "$PC")"
if [ -n "$ENTRY" ] \
   && ! printf '%s\n' "$ENTRY" | grep -q '^ *files:' \
   && ! printf '%s\n' "$ENTRY" | grep -q '^ *types:' \
   && printf '%s\n' "$ENTRY" | grep -q '^ *pass_filenames: false'; then
    pass "no-history-comments has no files: or types: filter and pass_filenames: false"
else
    fail "no-history-comments entry: $ENTRY"
fi

echo "== 35. every one-shot call in this file carries --root =="
SELF_FILE="${BASH_SOURCE[0]:-$0}"
# the single quotes are deliberate: the pattern is the literal text of a call
# shellcheck disable=SC2016
CALLS="$(grep -c 'bash "\$ONESHOT"' "$SELF_FILE")"
# shellcheck disable=SC2016
BADCALL="$(grep -n 'bash "\$ONESHOT"' "$SELF_FILE" | grep -v -e '--root')"
if [ "$CALLS" -ge 1 ] && [ -z "$BADCALL" ]; then pass "$CALLS one-shot calls, all with --root"; else fail "one-shot calls without --root: $BADCALL"; fi

echo "== 36. non-key refusals stay on code files =="
expect_allow "round word in a doc" docs/x.md "+## Review round 2"
expect_allow "CR fix note in YAML" x.yaml "+# CR fix: y"
expect_block "round note in code" scripts/a.sh "+# round 2"

echo "== 39. --range --tip with HEAD on another branch =="
TP="$T/tip"; mkdir -p "$TP/scripts"; git -C "$TP" init -q
git -C "$TP" config user.email t@t; git -C "$TP" config user.name t
printf 'echo a\n' > "$TP/scripts/a.sh"
git -C "$TP" add -A; git -C "$TP" commit -q -m base
tip_base="$(git -C "$TP" rev-parse HEAD)"
git -C "$TP" checkout -q -b b
printf 'echo a\n# why: tool X drops the last newline\n' > "$TP/scripts/a.sh"
git -C "$TP" add -A; git -C "$TP" commit -q -m comment
git -C "$TP" checkout -q -
OUT="$(cd "$TP" && bash "$GATE" --range "$tip_base" --tip b --count-comments 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "1" ]; then pass "--tip b counts the comment added on b"; else fail "--tip count -> rc=$RC out=$OUT"; fi
OUT="$(cd "$TP" && bash "$GATE" --range "$tip_base" --count-comments 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "0" ]; then pass "default tip is HEAD, which has no new comment"; else fail "default tip count -> rc=$RC out=$OUT"; fi

echo "== 40. a malformed rule row cannot turn the gate off =="
MR="$T/malformed"; mkdir -p "$MR/scripts/lint"
cp "$GATE" "$AWKF" "$MR/scripts/lint/"
mkdiff docs/x.md "+see ${H}-1"
MRG="$MR/scripts/lint/check-history-comments.sh"
cp "$LIST" "$MR/scripts/lint/ticket-ref-allow.tsv"
OUT="$(bash "$MRG" --diff "$T/d.diff" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "control: the real list refuses a doc key"; else fail "control -> rc=$RC: $OUT"; fi
{ cat "$LIST"; printf 'K7 docs/ whole file by spaces\n'; } > "$MR/scripts/lint/ticket-ref-allow.tsv"
OUT="$(bash "$MRG" --diff "$T/d.diff" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "a space-separated row exits 2"; else fail "space-separated row -> rc=$RC: $OUT"; fi
{ cat "$LIST"; printf 'K9\tdocs/\t\tunknown kind\n'; } > "$MR/scripts/lint/ticket-ref-allow.tsv"
OUT="$(bash "$MRG" --diff "$T/d.diff" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "an unknown kind exits 2"; else fail "unknown kind -> rc=$RC: $OUT"; fi
{ cat "$LIST"; printf 'key\t\tZZZ-[0-9]+\tsecond key row\n'; } > "$MR/scripts/lint/ticket-ref-allow.tsv"
OUT="$(bash "$MRG" --diff "$T/d.diff" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ]; then pass "a second key row exits 2"; else fail "second key row -> rc=$RC: $OUT"; fi

echo "== 41. a symlink replaced by a regular file is judged =="
SL="$T/symlink"; mkdir -p "$SL/scripts"; git -C "$SL" init -q
git -C "$SL" config user.email t@t; git -C "$SL" config user.name t
printf 'echo a\n' > "$SL/scripts/real.sh"
ln -s real.sh "$SL/scripts/a.sh"
git -C "$SL" add -A; git -C "$SL" commit -q -m base
sl_base="$(git -C "$SL" rev-parse HEAD)"
rm "$SL/scripts/a.sh"
printf 'echo a\n# why: %s-1 x\n' "$H" > "$SL/scripts/a.sh"
git -C "$SL" add -A; git -C "$SL" commit -q -m typechange
OUT="$(cd "$SL" && bash "$GATE" --range "$sl_base" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ]; then pass "a key in a file that replaced a symlink is refused"; else fail "symlink replaced -> rc=$RC: $OUT"; fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
