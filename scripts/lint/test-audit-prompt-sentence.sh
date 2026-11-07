#!/usr/bin/env bash
# test-audit-prompt-sentence.sh — every audit prompt the repo ships ends with the
# operator's sentence, word for word, as its last non-blank line.
#
# A new audit prompt joins PROMPTS below.
#
# Usage: bash scripts/lint/test-audit-prompt-sentence.sh
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SENTENCE='Be thorough in your analysis and bold in your recommendations'
PROMPTS=(
  .claude/agents/ticket-auditor.md
  .claude/commands/claude-md-audit.md
  .claude/commands/prose-audit.md
  .claude/skills/test-audit/SKILL.md
)

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

ends_with_sentence() { # file
  [ "$(awk 'NF { last = $0 } END { print last }' "$1")" = "$SENTENCE" ]
}

T="$(mktemp -d "${TMPDIR:-/tmp}/audit-prompt-sentence.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

for p in "${PROMPTS[@]}"; do
  if ends_with_sentence "$ROOT/$p"; then
    pass "$p ends with the sentence"
  else
    fail "$p does not end with the sentence"
  fi

  grep -vxF "$SENTENCE" "$ROOT/$p" > "$T/copy.md"
  if ends_with_sentence "$T/copy.md"; then
    fail "$p copy with the sentence removed still passes"
  else
    pass "$p copy with the sentence removed fails"
  fi

  printf '\n%s\n' "$SENTENCE" >> "$T/copy.md"
  if ends_with_sentence "$T/copy.md"; then
    pass "$p copy with the sentence restored passes"
  else
    fail "$p copy with the sentence restored fails"
  fi
done

printf '%s\nsome later line\n' "$SENTENCE" > "$T/not-last.md"
if ends_with_sentence "$T/not-last.md"; then
  fail "the sentence above the last line passes"
else
  pass "the sentence above the last line fails"
fi

printf '%s.\n' "$SENTENCE" > "$T/full-stop.md"
if ends_with_sentence "$T/full-stop.md"; then
  fail "the sentence with an added full stop passes"
else
  pass "the sentence with an added full stop fails"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
