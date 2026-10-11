#!/usr/bin/env bash
# test-check-graphify-path-advice.sh — tests for scripts/lint/check-graphify-path-advice.sh (HIMMEL-5303).
#
# Cases (each fixture is a throwaway git repo; the gate reads tracked files):
#   1. ban prose only ("never `graphify path`")                   -> exit 0
#   2-4. installer advice in CLAUDE.md / AGENTS.md / GEMINI.md    -> exit 1, path:line named
#   5. explain-only installer text                                -> exit 0
#   6. no instruction files at all                                -> exit 0
#   7. the real tree passes
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

# shellcheck disable=SC2016  # literal backticks are the fixture content
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LINT="$SELF_DIR/check-graphify-path-advice.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gph-path-gate.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mkrepo() { mkdir -p "$T/$1" && git -C "$T/$1" init -q && printf '%s' "$T/$1"; }
put() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add -- "$2"; }
run() { OUT="$(bash "$LINT" "$1" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

BAN='- **graphify** explains structure — but **never `graphify path`**: node IDs are file-scoped.'
ADV='- For codebase questions, first run `graphify query "<q>"`. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<c>"` for focused concepts.'
OK='- For codebase questions, first run `graphify query "<q>"`. Use `graphify explain "<c>"` for focused concepts.'

if [ ! -f "$LINT" ]; then
    echo "FAIL: $LINT does not exist yet (RED)"
    exit 1
fi

echo "== 1. ban prose only =="
r="$(mkrepo ban)"; put "$r" CLAUDE.md "$BAN"; put "$r" AGENTS.md "$BAN"; put "$r" GEMINI.md "$OK"
run "$r"
if [ "$RC" -eq 0 ]; then pass "ban prose is not advice -> exit 0"; else fail "ban prose -> rc=$RC: $OUT"; fi

for f in CLAUDE.md AGENTS.md GEMINI.md; do
    echo "== advice in $f =="
    r="$(mkrepo "adv-$f")"; put "$r" "$f" "$ADV"
    run "$r"
    if [ "$RC" -eq 1 ] && has "$f:1"; then pass "$f advice refused"; else fail "$f advice -> rc=$RC: $OUT"; fi
done

echo "== 5. explain-only =="
r="$(mkrepo ok)"; put "$r" CLAUDE.md "$OK"
run "$r"
if [ "$RC" -eq 0 ]; then pass "explain-only -> exit 0"; else fail "explain-only -> rc=$RC: $OUT"; fi

echo "== 6. no instruction files =="
r="$(mkrepo empty)"; put "$r" README.md "x"
run "$r"
if [ "$RC" -eq 0 ]; then pass "no instruction files -> exit 0"; else fail "no files -> rc=$RC: $OUT"; fi

echo "== 6b. --strip removes only the banned clause =="
printf '%s\n' "$ADV" > "$T/adv.md"; printf '%s\n' "$OK" > "$T/ok.md"
if [ "$(bash "$LINT" --strip "$T/adv.md")" = "$OK" ] && [ "$(bash "$LINT" --strip "$T/ok.md")" = "$OK" ]; then
    pass "--strip turns advice into the explain-only text and leaves clean text alone"
else
    fail "--strip output wrong: $(bash "$LINT" --strip "$T/adv.md")"
fi

echo "== 7. real tree =="
run "$REPO_ROOT"
if [ "$RC" -eq 0 ]; then pass "real tree clean"; else fail "real tree -> rc=$RC: $OUT"; fi

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
