#!/usr/bin/env bash
# test-check-history-comments.sh — tests for scripts/lint/check-history-comments.sh.
#
# Each case feeds the gate a unified diff (--diff <file>) built with printf, so
# this file carries no history-shaped comment of its own. Cases:
#   1-5.  one added comment per history shape (ticket, review-fix note, bot round,
#         round N, judge qid)                                   -> exit 1, path:line named
#   6.    ponytail: line citing a ticket                         -> exit 0
#   7.    old (context) line carrying a ticket                   -> exit 0
#   8.    output calls refuse ticket ids; data and exemptions pass
#   9.    // comment in a .mjs file                              -> exit 1
#   10.   non-code path (.md) and fixtures path                  -> exit 0
#   11.   clean why-comment                                      -> exit 0
#   12.   --staged and --range read real git state
#   13.   the lint-job step of ci.yml, run against a throwaway PR range
#   14.   a .gitattributes -diff entry does not hide an added line (--staged, --range)
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

echo "== 8. user-facing output =="
expect_allow "ticket in data" scripts/a.sh "+ticket=\"${H}-1234\""
expect_allow "ticket before clean shell output" scripts/a.sh "+ticket=\"${H}-123\"; echo ready"
expect_allow "ticket after clean shell output" scripts/a.sh "+echo ready; ticket=\"${H}-123\""
expect_allow "ticket before clean JS output" scripts/a.ts "+const ticket = '${H}-123'; console.log('ready');"
expect_allow "ticket after clean JS output" scripts/a.ts "+console.log('ready'); const ticket = '${H}-123';"
expect_allow "ticket before clean Python output" scripts/a.py "+ticket = '${H}-123'; print('ready')"
expect_allow "ticket after clean Python output" scripts/a.py "+print('ready'); ticket = '${H}-123'"
expect_allow "ticket in separate shell and-list" scripts/a.sh "+ticket='${H}-123' && echo ready"
expect_allow "ticket in separate shell or-list" scripts/a.sh "+echo ready || ticket='${H}-123'"
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
expect_allow "output ponytail" scripts/a.sh "+echo '${H}-123 ready' # ponytail: fixed text only, replace when localized"
expect_allow "output fixture" scripts/fixtures/a.sh "+echo '${H}-123 fixture'"
expect_allow "output test file" scripts/test-a.sh "+echo '${H}-123 test'"
expect_allow "output test directory" scripts/tests/a.py "+print('${H}-123 test')"
expect_allow "output JS test file" src/a.test.ts "+console.error('${H}-123 test');"
expect_allow "output spec file" src/a.spec.js "+console.log('${H}-123 test');"
expect_allow "output clean" scripts/a.sh '+echo ready'
expect_allow "command mentioned in data" scripts/a.sh "+example=\"echo ${H}-123\""
expect_allow "quoted shell delimiter" scripts/a.sh "+example=\"; echo ${H}-123\""
expect_allow "quoted JS delimiter" scripts/a.ts "+const example = \"; console.log('${H}-123')\";"
expect_allow "quoted Python delimiter" scripts/a.py "+example = \"; print('${H}-123')\""
expect_allow "Python test filename" scripts/test_a.py "+print('${H}-123 fixture')"
expect_allow "console mentioned in data" scripts/a.ts "+const example = \"console.error('${H}-123')\";"
expect_allow "no invented history-ok exemption" docs/a.md "+echo '${H}-123' # history-ok: example"
expect_block "history-ok is not an exemption" scripts/a.sh "+echo '${H}-123' # history-ok: debug only"
mkdiff scripts/a.sh '+echo clean' "+echo '${H}-123 failed'"
run
if [ "$RC" -eq 1 ] && has "scripts/a.sh:2: ticket id:" && has "echo '${H}-123 failed'"; then pass "output reports path, line and text"; else fail "output diagnostic -> rc=$RC: $OUT"; fi

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
cp "$GATE" "$S/scripts/lint/check-history-comments.sh"
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
if [ "$RC" -eq 0 ]; then pass "step: ponytail line citing a ticket passes"; else fail "step ponytail -> rc=$RC: $OUT"; fi

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

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
