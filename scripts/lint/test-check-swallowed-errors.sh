#!/usr/bin/env bash
# test-check-swallowed-errors.sh — tests for scripts/lint/check-swallowed-errors.sh.
#
# Each case builds a throwaway --root tree. The flagged lines are copied from
# main (arm-resume.sh, cr-scores.sh, notify-console-on-prompt.sh, flush.sh); the
# `|| echo []` line is a variant of the same default-zero shape (main has none).
#   1-4.  one fixture per flagged shape                          -> exit 1, path:line named
#   5.    the same line with a baseline row                      -> exit 0
#   6.    a second line of that shape beyond the baseline count  -> exit 1
#   7.    swallow-ok on the line, and on the line above          -> exit 0
#   8.    comment line, test-*.sh, fixtures/ and a dir outside the scan roots -> exit 0
#   9.    missing baseline / empty scan roots                    -> exit 2 (fail-closed)
#   10.   --write-baseline then a re-run                         -> exit 0
#   11.   the real tree against the committed baseline           -> exit 0
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

# shellcheck disable=SC2016  # fixture lines are literal shell text, never expanded
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LINT="$SELF_DIR/check-swallowed-errors.sh"
REPO="$(cd "$SELF_DIR/../.." && pwd)"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if [ ! -f "$LINT" ]; then
    echo "FAIL: $LINT does not exist yet (RED)"
    exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/swallowed-lint.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2016  # the fixture lines are literal shell, never expanded
L_DEVNULL='ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"'
L_TRUE="_raw=\$(printf '%s' \"\$_fm\" | sed -n 's/^ticket:[[:space:]]*//p' | head -1) || true"
L_ZERO='last="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"'  # gnu-ok: fixture text only, never run
L_EMPTY_LIST='rows=$(cat "$reg" || echo [])'

# newroot <name>: a fresh tree with an empty baseline
newroot() {
    R="$T/$1"; mkdir -p "$R/scripts/hooks" "$R/scripts/cr" "$R/scripts/handover" "$R/scripts/ci"
    : > "$R/base.txt"
}
# put <relpath> <line>...
put() { local p="$1"; shift; mkdir -p "$R/$(dirname "$p")"; printf '%s\n' "$@" > "$R/$p"; }
run() { OUT="$(bash "$LINT" --root "$R" --baseline "$R/base.txt" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

expect_flag() { # <label> <shape> <line>
    newroot "$1"; put scripts/hooks/g.sh '#!/usr/bin/env bash' "$3"
    run
    if [ "$RC" -eq 1 ] && has "scripts/hooks/g.sh:2" && has "$2"; then pass "$1 refused"; else fail "$1 -> rc=$RC: $OUT"; fi
}
expect_flag "devnull-in-cmdsub" cmdsub-devnull "$L_DEVNULL"
expect_flag "true-after-read"   true-after-read "$L_TRUE"
expect_flag "echo-0-default"    default-zero "$L_ZERO"
expect_flag "echo-[]-default"   default-zero "$L_EMPTY_LIST"

# 5. baseline row lets the same shape pass
newroot baseline; put scripts/hooks/g.sh '#!/usr/bin/env bash' "$L_ZERO"
printf 'scripts/hooks/g.sh\tdefault-zero\t1\nscripts/hooks/g.sh\tcmdsub-devnull\t1\n' > "$R/base.txt"
run
if [ "$RC" -eq 0 ]; then pass "baseline row lets the shape pass"; else fail "baseline pass -> rc=$RC: $OUT"; fi

# 6. a new line beyond the baseline count is refused
put scripts/hooks/g.sh '#!/usr/bin/env bash' "$L_ZERO" 'x="$(date +%s 2>/dev/null || echo 0)"'
run
if [ "$RC" -eq 1 ] && has "default-zero"; then pass "line beyond the baseline count refused"; else fail "beyond baseline -> rc=$RC: $OUT"; fi

# 7. per-line allowlist: same line, and the comment line above
newroot allow
put scripts/cr/a.sh '#!/usr/bin/env bash' "$L_ZERO # swallow-ok: stamp may be absent" \
    '# swallow-ok: ledger path is advisory' "$L_DEVNULL"
run
if [ "$RC" -eq 0 ]; then pass "swallow-ok exempts its line and the next"; else fail "allowlist -> rc=$RC: $OUT"; fi

# 8. ignored: comment, test file, fixtures, outside the scan roots
newroot ignored
put scripts/hooks/c.sh '#!/usr/bin/env bash' "# $L_ZERO"
put scripts/hooks/test-x.sh '#!/usr/bin/env bash' "$L_ZERO"
put scripts/ci/fixtures/f.sh '#!/usr/bin/env bash' "$L_ZERO"
put scripts/lib/l.sh '#!/usr/bin/env bash' "$L_ZERO"
run
if [ "$RC" -eq 0 ]; then pass "comments, tests, fixtures and other dirs ignored"; else fail "ignored -> rc=$RC: $OUT"; fi

# 9. fail-closed
newroot nobase; put scripts/hooks/g.sh '#!/usr/bin/env bash' 'echo ok'
rm -f "$R/base.txt"; run
if [ "$RC" -eq 2 ]; then pass "missing baseline -> exit 2"; else fail "missing baseline -> rc=$RC: $OUT"; fi
R="$T/empty"; mkdir -p "$R"; : > "$R/base.txt"; run
if [ "$RC" -eq 2 ]; then pass "no scan roots -> exit 2"; else fail "no scan roots -> rc=$RC: $OUT"; fi

# 10. --write-baseline round trip
newroot wb; put scripts/handover/h.sh '#!/usr/bin/env bash' "$L_ZERO" "$L_DEVNULL"
bash "$LINT" --root "$R" --baseline "$R/base.txt" --write-baseline >/dev/null 2>&1
run
if [ "$RC" -eq 0 ] && [ -s "$R/base.txt" ]; then pass "--write-baseline then re-run is clean"; else fail "write-baseline -> rc=$RC: $OUT"; fi

# 11. the real tree is green against the committed baseline
OUT="$(bash "$LINT" --root "$REPO" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "real tree clean against the committed baseline"; else fail "real tree -> rc=$RC: $(printf '%s' "$OUT" | head -5)"; fi

echo "test-check-swallowed-errors: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
