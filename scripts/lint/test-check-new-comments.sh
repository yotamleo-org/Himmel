#!/usr/bin/env bash
# test-check-new-comments.sh — tests for scripts/lint/check-new-comments.sh.
#
# Each case builds a throwaway git repo that carries the gate, its classifier and a
# baseline, then stages or commits one change. Cases:
#   1.  an added restating comment is refused, path:line named      (the RED row)
#   2.  keep-list comments pass: license, link, suppression, doc block, file header
#   3.  the baseline: a count above its row fails, equal and lower pass
#   4.  a raised baseline row and a new non-zero row are refused
#   5.  a new file: a body comment is refused, a header alone passes
#   6.  a renamed file keeps its allowance when its row moves with it
#   7.  --range judges a committed range, --tip a branch HEAD is not on
#   8.  a heredoc body and a Python triple-quoted string are not comments
#   9.  a fixtures path and a non-code file are not judged
#   10. a missing classifier or a missing baseline exits 2
#   11. --write-baseline writes the counts the gate then accepts
#   12. a base without a baseline takes the first baseline as it is
#   13. the ci.yml step runs the base copies and passes a base without the gate
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GATE="$SELF_DIR/check-new-comments.sh"
CI_YML="$SELF_DIR/../../.github/workflows/ci.yml"
BL=scripts/lint/comment-baseline.tsv

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/new-comment-gate.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

if [ ! -f "$GATE" ]; then
    echo "FAIL: $GATE does not exist yet (RED)"
    exit 1
fi

HASH='#'
D='$'
SQ="'"
N=0
mkrepo() {
    N=$((N + 1)); R="$T/r$N"
    mkdir -p "$R/scripts/lint" "$R/src"
    cp "$GATE" "$SELF_DIR/comment-count.awk" "$SELF_DIR/ticket-refs.awk" "$SELF_DIR/ticket-ref-allow.tsv" "$R/scripts/lint/"
    git -C "$R" init -q -b main
    git -C "$R" config user.email t@example.invalid
    git -C "$R" config user.name t
    printf '%s!/usr/bin/env bash\n%s a.sh: prints ok\nset -u\n%s first old note\necho ok  %s second old note\n' "$HASH" "$HASH" "$HASH" "$HASH" > "$R/src/a.sh"
    printf 'src/a.sh\t2\n' > "$R/$BL"
    git -C "$R" add -A
    git -C "$R" commit -q -m base
}
gate() { OUT="$(cd "$R" && bash scripts/lint/check-new-comments.sh "$@" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
stage() { git -C "$R" add -A; gate --staged; }
want() {
    if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 -> rc=$RC, wanted $2: $OUT"; fi
}

echo "== 1. an added restating comment is refused =="
mkrepo
printf '%s print it again\necho again\n' "$HASH" >> "$R/src/a.sh"
stage
if [ "$RC" -eq 1 ] && has "src/a.sh:6: $HASH print it again" && has "code-comments.md"; then pass "restating comment refused with path:line"; else fail "restating comment -> rc=$RC: $OUT"; fi

echo "== 2. keep-list comments pass =="
mkrepo
printf '%s Copyright (c) 2026 Example, MIT license\necho l\n' "$HASH" >> "$R/src/a.sh"; stage; want "license line" 0
mkrepo
printf '%s https://example.invalid/issues/7 caps the page at 100\necho u\n' "$HASH" >> "$R/src/a.sh"; stage; want "comment with a link" 0
mkrepo
printf '%s shellcheck disable=SC2086\necho x\n' "$HASH" >> "$R/src/a.sh"; stage; want "suppression directive" 0
mkrepo
printf '/** Returns the sum. */\nexport const f = (a, b) => a + b;\n' > "$R/src/n.mjs"; stage; want "doc block in a new file" 0
mkrepo
printf '%s!/usr/bin/env bash\n%s n.sh: a new tool\n%s Usage: n.sh\n\necho n\n' "$HASH" "$HASH" "$HASH" > "$R/src/n.sh"; stage; want "file header in a new file" 0

echo "== 3. the baseline =="
mkrepo
printf '%s!/usr/bin/env bash\n%s a.sh: prints ok\nset -u\n%s first old note\necho fine  %s second old note\n' "$HASH" "$HASH" "$HASH" "$HASH" > "$R/src/a.sh"
stage; want "count equal to its row (an edited line keeps its comment)" 0
mkrepo
printf '%s!/usr/bin/env bash\n%s a.sh: prints ok\nset -u\necho ok\n' "$HASH" "$HASH" > "$R/src/a.sh"
stage; want "count below its row" 0
mkrepo
printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
stage
if [ "$RC" -eq 1 ] && has "src/a.sh: 3 comment lines outside the keep list, baseline 2"; then pass "count above its row refused"; else fail "count above row -> rc=$RC: $OUT"; fi
mkrepo
printf '%s!/usr/bin/env bash\n%s a.sh: prints ok\nset -u\n%s reworded note\necho ok  %s second old note\n' "$HASH" "$HASH" "$HASH" "$HASH" > "$R/src/a.sh"
stage; want "a reworded comment at the same count" 0

echo "== 4. the baseline only goes down =="
mkrepo
printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
printf 'src/a.sh\t3\n' > "$R/$BL"
stage
if [ "$RC" -eq 1 ] && has "$BL: src/a.sh raised to 3, the base allows 2"; then pass "raised row refused"; else fail "raised row -> rc=$RC: $OUT"; fi
mkrepo
printf 'echo n  %s note\n' "$HASH" > "$R/src/n.sh"
printf 'src/a.sh\t2\nsrc/n.sh\t1\n' > "$R/$BL"
stage
if [ "$RC" -eq 1 ] && has "src/n.sh raised to 1, the base allows 0"; then pass "new non-zero row refused"; else fail "new row -> rc=$RC: $OUT"; fi
mkrepo
printf 'src/a.sh\t1\n' > "$R/$BL"
stage
if [ "$RC" -eq 1 ] && has "src/a.sh: 2 comment lines outside the keep list, baseline 1"; then pass "a row lowered below the count is refused"; else fail "over-lowered row -> rc=$RC: $OUT"; fi

echo "== 5. a new file =="
mkrepo
printf '%s!/usr/bin/env bash\n%s n.sh: a new tool\necho n\n%s say it twice\necho n\n' "$HASH" "$HASH" "$HASH" > "$R/src/n.sh"
stage
if [ "$RC" -eq 1 ] && has "src/n.sh:4: $HASH say it twice" && has "baseline 0"; then pass "body comment in a new file refused"; else fail "new file -> rc=$RC: $OUT"; fi
mkrepo
printf 'const a = 1; // one\n' > "$R/src/n.ts"
stage
if [ "$RC" -eq 1 ] && has "src/n.ts:1: // one"; then pass "trailing // comment in a new file refused"; else fail "new ts -> rc=$RC: $OUT"; fi

echo "== 6. a rename =="
mkrepo
git -C "$R" mv src/a.sh src/b.sh
printf 'src/b.sh\t2\n' > "$R/$BL"
stage; want "renamed file, row moved" 0
mkrepo
git -C "$R" mv src/a.sh src/b.sh
stage
if [ "$RC" -eq 1 ] && has "src/b.sh: 2 comment lines outside the keep list, baseline 0" && has "write-baseline"; then pass "renamed file without its row refused"; else fail "rename, no row -> rc=$RC: $OUT"; fi

echo "== 7. --range and --tip =="
mkrepo
git -C "$R" checkout -q -b topic
printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
git -C "$R" commit -q -am topic
gate --range main; want "--range refuses a committed comment" 1
git -C "$R" checkout -q main
gate --range main; want "--range on an empty range" 0
gate --range main --tip topic; want "--tip judges a branch HEAD is not on" 1

echo "== 8. heredoc bodies and triple-quoted strings =="
mkrepo
printf 'cat <<EOF\n%s Title\n%s not a comment\nEOF\necho after\n' "$HASH" "$HASH" >> "$R/src/a.sh"
stage; want "heredoc body" 0
mkrepo
printf 'DOC = """\n%s Title\n"""\nprint(DOC)\n' "$HASH" > "$R/src/n.py"
stage; want "triple-quoted string" 0
mkrepo
printf 'cat <<EOF\nbody\nEOF\n%s after the heredoc\necho after\n' "$HASH" >> "$R/src/a.sh"
stage; want "a comment after a closed heredoc is still judged" 1

echo "== 9. paths that are not judged =="
mkrepo
mkdir -p "$R/src/fixtures"
printf 'echo f\n%s a fixture comment\n' "$HASH" > "$R/src/fixtures/f.sh"
printf 'key: v\n%s a yaml comment\n' "$HASH" > "$R/src/c.yaml"
stage; want "fixtures path and a non-code file" 0

echo "== 10. cannot evaluate =="
mkrepo
rm "$R/scripts/lint/comment-count.awk"
gate --staged; want "missing classifier" 2
mkrepo
git -C "$R" rm -q "$BL"
gate --staged; want "missing baseline" 2

echo "== 11. --write-baseline =="
mkrepo
printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
printf 'echo n\n%s a note\n' "$HASH" > "$R/src/n.sh"
git -C "$R" add -A
gate --write-baseline
if [ "$RC" -eq 0 ] && [ "$(cat "$R/$BL")" = "$(printf 'src/a.sh\t3\nsrc/n.sh\t1')" ]; then pass "baseline rows are the counts"; else fail "write-baseline -> rc=$RC: $OUT; $(cat "$R/$BL")"; fi
stage; want "the gate still refuses the rows --write-baseline raised" 1

echo "== 12. a base without a baseline =="
mkrepo
git -C "$R" rm -q "$BL"
git -C "$R" commit -q -m "no baseline"
printf 'src/a.sh\t2\n' > "$R/$BL"
stage; want "the first baseline is taken as it is" 0
printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
stage; want "and it already judges the files of that change" 1

echo "== 13. the ci.yml step =="
STEP="$T/step.sh"
awk '
    /^      - name: new-comment gate \(PR range\)$/ { on = 1; next }
    on && /^      - / { exit }
    on && /^        run: \|$/ { run = 1; next }
    on && run { sub(/^          /, ""); print }
' "$CI_YML" > "$STEP"
if [ -s "$STEP" ]; then
    mkrepo
    base="$(git -C "$R" rev-parse HEAD)"
    printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
    git -C "$R" commit -q -am third
    OUT="$(cd "$R" && RUNNER_TEMP="$T/rt1" BASE_SHA="$base" bash "$STEP" 2>&1)"; RC=$?
    want "the step refuses an added comment" 1
    : > "$R/scripts/lint/comment-count.awk"
    git -C "$R" commit -q -am "blank the classifier"
    mkdir -p "$T/rt2"
    OUT="$(cd "$R" && RUNNER_TEMP="$T/rt2" BASE_SHA="$base" bash "$STEP" 2>&1)"; RC=$?
    want "the step judges with the base classifier, not the branch copy" 1
    OUT="$(cd "$R" && RUNNER_TEMP="$T/rt3" BASE_SHA="" bash "$STEP" 2>&1)"; RC=$?
    want "a missing base sha is red" 1
    mkrepo
    git -C "$R" rm -q scripts/lint/check-new-comments.sh
    git -C "$R" commit -q -m "a base before the gate"
    base="$(git -C "$R" rev-parse HEAD)"
    printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
    git -C "$R" commit -q -am third
    OUT="$(cd "$R" && RUNNER_TEMP="$T/rt4" BASE_SHA="$base" bash "$STEP" 2>&1)"; RC=$?
    if [ "$RC" -eq 0 ] && has "absent at base"; then pass "a base without the gate passes with a notice"; else fail "base without gate -> rc=$RC: $OUT"; fi
else
    fail "ci.yml has no 'new-comment gate (PR range)' step"
fi

echo "== 14. shapes that must not hide a comment =="
refused_at() {
    if [ "$RC" -eq 1 ] && has "$2"; then pass "$1"; else fail "$1 -> rc=$RC: $OUT"; fi
}
mkrepo
printf 'f();// note\n' > "$R/src/t.mjs"; stage; refused_at "a trailing // with no space before it" "src/t.mjs:1: // note"
mkrepo
printf 'f()%s note\n' "$HASH" > "$R/src/p.py"; stage; refused_at "a trailing Python comment with no space before it" "src/p.py:1: $HASH note"
mkrepo
printf 'f;%s note\n' "$HASH" > "$R/src/s.sh"; stage; refused_at "a shell comment straight after a semicolon" "src/s.sh:1: $HASH note"
mkrepo
printf 'echo "%s{%sx} %s%s a%sb"\n' "$D" "$HASH" "$D" "$HASH" "$HASH" > "$R/src/s.sh"; printf 'n=%s{%sx}; echo a%sb %s%s\n' "$D" "$HASH" "$HASH" "$D" "$HASH" >> "$R/src/s.sh"; stage; want "a shell hash inside a word is no comment" 0
mkrepo
printf '/* head */ const x = 1;\n// body note\nconst y = 2;\n' > "$R/src/h.mjs"; stage; refused_at "code after a leading block comment ends the header" "src/h.mjs:2: // body note"
mkrepo
printf 'echo "<<EOF"\n%s body note\necho x\n' "$HASH" > "$R/src/q.sh"; stage; refused_at "a quoted << opens no heredoc" "src/q.sh:2: $HASH body note"
mkrepo
printf 'echo x  %s see <<EOF\n%s body note\necho y\n' "$HASH" "$HASH" > "$R/src/q.sh"; stage; refused_at "a << inside a comment opens no heredoc" "src/q.sh:2: $HASH body note"
mkrepo
printf 'r="%s(cat <<EOF\n%s heredoc text\nEOF\n)"\necho r\n' "$D" "$HASH" > "$R/src/q.sh"; stage; want "a heredoc opened inside a quoted command substitution is skipped" 0
mkrepo
printf 'x = 1  %s """\n%s body note\ny = 2\n' "$HASH" "$HASH" > "$R/src/d.py"; stage; refused_at "a triple quote inside a comment opens no string" "src/d.py:2: $HASH body note"

mkrepo
printf 'const re = /[a/*]/;\nconst y = 1;\n' > "$R/src/r.mjs"; stage; want "a /* inside a regex class opens no block" 0
mkrepo
printf 'const u = /[/]/; // note\n' > "$R/src/r.mjs"; stage; refused_at "a comment after a regex literal" "src/r.mjs:1: // note"

mkrepo
printf 'print(%s"""%s)\n%s body note\ny = 2\n' "$SQ" "$SQ" "$HASH" > "$R/src/d.py"; stage; refused_at "a triple quote inside an ordinary string opens no string" "src/d.py:2: $HASH body note"
mkrepo
printf 'x = """one line"""\n%s body note\n' "$HASH" > "$R/src/d.py"; stage; refused_at "a triple-quoted string closed on its line" "src/d.py:2: $HASH body note"
mkrepo
printf '%s!/usr/bin/env node\n// n.mjs: a new tool\n// Usage: n.mjs\n\nconsole.log(1);\n' "$HASH" > "$R/src/n.mjs"; stage; want "a JS file header after a shebang" 0

echo "== 15. a classifier change recounts untouched files only =="
mkrepo
echo >> "$R/scripts/lint/comment-count.awk"
printf 'src/a.sh\t3\n' > "$R/$BL"
stage
if [ "$RC" -eq 1 ] && has "$BL: src/a.sh raised to 3, the changed classifier counts 2"; then pass "a row raised past the changed classifier's count is refused"; else fail "inflated row -> rc=$RC: $OUT"; fi
mkrepo
printf 'echo u\n%s https://example.invalid/x\n' "$HASH" > "$R/src/u.sh"
git -C "$R" add -A; git -C "$R" commit -q -m link
grep -v 'https?:' "$R/scripts/lint/comment-count.awk" > "$R/cc.awk"; mv "$R/cc.awk" "$R/scripts/lint/comment-count.awk"
printf 'src/a.sh\t2\nsrc/u.sh\t1\n' > "$R/$BL"
stage; want "an untouched file's row may rise to the changed classifier's count" 0
mkrepo
echo >> "$R/scripts/lint/comment-count.awk"
printf '%s third\necho t\n' "$HASH" >> "$R/src/a.sh"
printf 'src/a.sh\t3\n' > "$R/$BL"
stage
if [ "$RC" -eq 1 ] && has "$BL: src/a.sh raised to 3, the base allows 2"; then pass "a touched file's row may not rise with the classifier"; else fail "touched file with classifier change -> rc=$RC: $OUT"; fi

echo
echo "test-check-new-comments: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
