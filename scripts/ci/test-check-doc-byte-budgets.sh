#!/usr/bin/env bash
# Usage: bash scripts/ci/test-check-doc-byte-budgets.sh
# Exit: 0 all passed, 1 at least one case failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SRC="$HERE/check-doc-byte-budgets.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h11292.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

PREFACE=docs/handover/worker-preface.md
TEMPLATE=docs/handover/chief-template.md
PRCHECK=.claude/commands/pr-check.md

mkroot() {
    local r="$1"
    mkdir -p "$r/scripts/ci" "$r/docs/handover" "$r/.claude/commands"
    cp "$SCRIPT_SRC" "$r/scripts/ci/check-doc-byte-budgets.sh" 2>/dev/null || true
    printf 'x' > "$r/$PREFACE"
    printf 'x' > "$r/$TEMPLATE"
    printf 'x' > "$r/$PRCHECK"
}
run() {
    local r="$1"; shift
    out=$(cd "$r" && bash scripts/ci/check-doc-byte-budgets.sh "$@" 2>&1); rc=$?
}
pad() { awk -v n="$2" 'BEGIN { for (i = 0; i < n; i++) printf "x" }' > "$1"; }

base="$tmp/base"; mkroot "$base"
run "$base"
max_of() { sed -n "s|^doc-byte-budgets: ok $1 [0-9]* <= \([0-9]*\)\$|\1|p" <<< "$out"; }
MAX_PREFACE=$(max_of "$PREFACE")
MAX_TEMPLATE=$(max_of "$TEMPLATE")
MAX_PRCHECK=$(max_of "$PRCHECK")
if [ -z "$MAX_PREFACE" ] || [ -z "$MAX_TEMPLATE" ] || [ -z "$MAX_PRCHECK" ]; then
    fail "setup: could not read the three maxes from the script's ok lines: $out"
    printf '%s case(s) failed\n' "$failures"
    exit 1
fi

echo "== T1: every row within =="
run "$base"
n_ok=$(grep -c '^doc-byte-budgets: ok ' <<< "$out")
if [ "$rc" -eq 0 ] && [ "$n_ok" -eq 3 ]; then pass "exit 0, three ok lines"; else fail "T1 rc=$rc ok=$n_ok out=$out"; fi

echo "== T2: a file at exactly its max =="
r="$tmp/t2"; mkroot "$r"; pad "$r/$PREFACE" "$MAX_PREFACE"
run "$r"
if [ "$rc" -eq 0 ]; then pass "exit 0 at max"; else fail "T2 rc=$rc out=$out"; fi

echo "== T3: one at max+1 =="
r="$tmp/t3"; mkroot "$r"; pad "$r/$PREFACE" $((MAX_PREFACE + 1))
run "$r"
want="doc-byte-budgets: $PREFACE is $((MAX_PREFACE + 1)) bytes, over its ${MAX_PREFACE}-byte budget (+1)"
if [ "$rc" -eq 1 ] && grep -qxF "$want" <<< "$out"; then pass "exit 1, line names path size max (+1)"; else fail "T3 rc=$rc out=$out"; fi

echo "== T4: two over =="
r="$tmp/t4"; mkroot "$r"; pad "$r/$PREFACE" $((MAX_PREFACE + 5)); pad "$r/$TEMPLATE" $((MAX_TEMPLATE + 7))
run "$r"
if [ "$rc" -eq 1 ] && grep -qF "$PREFACE is $((MAX_PREFACE + 5)) bytes" <<< "$out" && grep -qF "$TEMPLATE is $((MAX_TEMPLATE + 7)) bytes" <<< "$out"; then
    pass "both named, exit 1"
else
    fail "T4 rc=$rc out=$out"
fi

echo "== T5: a missing file =="
r="$tmp/t5"; mkroot "$r"; rm -f "$r/$TEMPLATE"
run "$r"
if [ "$rc" -eq 2 ] && grep -qF "$TEMPLATE" <<< "$out"; then pass "exit 2 naming the row"; else fail "T5 rc=$rc out=$out"; fi

echo "== T6: the file a symlink =="
r="$tmp/t6"; mkroot "$r"; printf 'x' > "$tmp/t6-target.md"; rm -f "$r/$PREFACE"; ln -s "$tmp/t6-target.md" "$r/$PREFACE"
run "$r"
if [ "$rc" -eq 2 ] && grep -qF "$PREFACE" <<< "$out"; then pass "exit 2 for a symlinked file"; else fail "T6 rc=$rc out=$out"; fi

echo "== T6b: a symlinked directory =="
r="$tmp/t6b"; mkroot "$r"; mkdir -p "$tmp/t6b-dir"; printf 'x' > "$tmp/t6b-dir/worker-preface.md"; printf 'x' > "$tmp/t6b-dir/chief-template.md"
rm -rf "$r/docs/handover"; ln -s "$tmp/t6b-dir" "$r/docs/handover"
run "$r"
if [ "$rc" -eq 2 ] && grep -qF "$PREFACE" <<< "$out"; then pass "exit 2 for a symlinked directory"; else fail "T6b rc=$rc out=$out"; fi

echo "== T7: an argument with no row =="
run "$base" docs/nothing.md
if [ "$rc" -eq 2 ]; then pass "exit 2 for an unknown row"; else fail "T7 rc=$rc out=$out"; fi

echo "== T8: a path argument reads only that row =="
r="$tmp/t8"; mkroot "$r"; pad "$r/$TEMPLATE" $((MAX_TEMPLATE + 1))
run "$r" "$PREFACE"
if [ "$rc" -eq 0 ] && ! grep -qF "$TEMPLATE" <<< "$out"; then pass "other row over, exit 0"; else fail "T8 rc=$rc out=$out"; fi

echo "== T9: one row over, another missing =="
r="$tmp/t9"; mkroot "$r"; pad "$r/$PREFACE" $((MAX_PREFACE + 1)); rm -f "$r/$TEMPLATE"
run "$r"
missing_line=$(grep -F "$TEMPLATE" <<< "$out")
if [ "$rc" -eq 2 ] \
    && grep -qF "$PREFACE is $((MAX_PREFACE + 1)) bytes" <<< "$out" \
    && [ -n "$missing_line" ] && ! grep -q ' is [0-9]* bytes' <<< "$missing_line"; then
    pass "exit 2, both named, the missing one with no size"
else
    fail "T9 rc=$rc out=$out"
fi

echo "== T10: CDPATH does not redirect the root (relative \$0) =="
r="$tmp/t10"; mkroot "$r"; pad "$r/$PREFACE" $((MAX_PREFACE + 1))
decoy="$tmp/t10-decoy"; mkroot "$decoy"
out=$(cd "$r" && CDPATH="$decoy" bash scripts/ci/check-doc-byte-budgets.sh 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -qF "$PREFACE is $((MAX_PREFACE + 1)) bytes" <<< "$out"; then
    pass "decoy CDPATH ignored, fixture preface measured"
else
    fail "T10 rc=$rc out=$out"
fi

echo
if [ "$failures" -eq 0 ]; then echo "all cases passed"; exit 0; fi
printf '%s case(s) failed\n' "$failures"
exit 1
