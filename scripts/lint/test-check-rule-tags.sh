#!/usr/bin/env bash
# test-check-rule-tags.sh — tests for scripts/lint/check-rule-tags.sh.
#
# Cases (each fixture is a file; --enforced-list points at a fixture name list):
#   1. every list item tagged                                   -> exit 0
#   2. an untagged list item                                    -> exit 1, file:line named
#   3. a multi-line item tagged on its LAST line                -> exit 0
#   4. a multi-line item tagged only on its first line          -> exit 1
#   5. list items inside a code fence are ignored               -> exit 0
#   6. the `## graphify` section is ignored                     -> exit 0
#   7. [enforced: x] with x not in the enforced list            -> exit 1
#   8. empty tag name [enforced: ]                              -> exit 1
#   9. missing file                                             -> exit 2
#  10. the real tagged files pass
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

# shellcheck disable=SC2016  # literal backticks are the fixture content
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LINT="$SELF_DIR/check-rule-tags.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if [ ! -f "$LINT" ]; then
    echo "FAIL: $LINT does not exist yet (RED)"
    exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/rule-tags.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

printf 'block-alpha\nblock-beta\n' > "$T/names.txt"

run() { OUT="$(bash "$LINT" --enforced-list "$T/names.txt" "$@" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

put() { printf '%s\n' "$2" > "$T/$1"; }

put ok.md '# t

- Never do the thing. [enforced: block-alpha]
- Prefer the other thing. [prose]
1. Numbered rule. [prose]'
run "$T/ok.md"
if [ "$RC" -eq 0 ]; then pass "all tagged -> 0"; else fail "all tagged exit $RC: $OUT"; fi

put untagged.md '# t

- Tagged. [prose]
- Not tagged at all.'
run "$T/untagged.md"
if [ "$RC" -eq 1 ] && has "untagged.md:4"; then pass "untagged item -> 1 with file:line"; else fail "untagged exit $RC: $OUT"; fi

put steps.md '1. A numbered procedure step, no tag needed.
2. Another one.'
run "$T/steps.md"
if [ "$RC" -eq 0 ]; then pass "numbered steps are not rule lines -> 0"; else fail "steps exit $RC: $OUT"; fi

put multi-ok.md '- First line of a rule
  continues here and ends tagged. [enforced: block-beta]'
run "$T/multi-ok.md"
if [ "$RC" -eq 0 ]; then pass "multi-line tagged on last line -> 0"; else fail "multi-line exit $RC: $OUT"; fi

put multi-bad.md '- First line of a rule [prose]
  continues here with no tag.'
run "$T/multi-bad.md"
if [ "$RC" -eq 1 ]; then pass "tag only on first line -> 1"; else fail "first-line tag exit $RC: $OUT"; fi

put fence.md '# t

```text
- an example bullet in a fence
```'
run "$T/fence.md"
if [ "$RC" -eq 0 ]; then pass "fenced bullets ignored -> 0"; else fail "fence exit $RC: $OUT"; fi

put graphify.md '## rules

- Tagged. [prose]

## graphify

- upstream owned, untagged

## after

- Tagged again. [prose]'
run "$T/graphify.md"
if [ "$RC" -eq 0 ]; then pass "graphify section ignored -> 0"; else fail "graphify exit $RC: $OUT"; fi

put unknown.md '- Rule. [enforced: no-such-hook]'
run "$T/unknown.md"
if [ "$RC" -eq 1 ] && has "no-such-hook"; then pass "unknown hook name -> 1"; else fail "unknown exit $RC: $OUT"; fi

put empty.md '- Rule. [enforced: ]'
run "$T/empty.md"
if [ "$RC" -eq 1 ]; then pass "empty tag name -> 1"; else fail "empty tag exit $RC: $OUT"; fi

run "$T/nope.md"
if [ "$RC" -eq 2 ]; then pass "missing file -> 2"; else fail "missing file exit $RC"; fi

OUT="$(bash "$LINT" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass "real tagged files pass"; else fail "real files exit $RC: $OUT"; fi

echo "check-rule-tags: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
