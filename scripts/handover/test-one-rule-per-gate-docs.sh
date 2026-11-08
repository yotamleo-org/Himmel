#!/usr/bin/env bash
# test-one-rule-per-gate-docs.sh — each doc states the one rule its gate enforces.
# PLATFORM GUARD: Bash 3.2, grep/awk/tr only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$HERE/../..}"
PREFACE="$ROOT/docs/handover/worker-preface.md"
CHECK_CI="$ROOT/.claude/commands/check-ci.md"
PLAYBOOK="$ROOT/docs/internals/stuck-playbook.md"
GATES="$ROOT/docs/internals/validation-gates.md"
README="$ROOT/README.md"
CHIEF_RUN="$ROOT/docs/handover/running-a-chief.md"
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
flat() { tr '\n' ' ' | tr -s ' '; }
has() {
    if printf '%s\n' "$2" | flat | grep -iF -- "$3" > /dev/null; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
lacks() {
    if printf '%s\n' "$2" | flat | grep -iF -- "$3" > /dev/null; then fail "$1 (still says '$3')"; else pass "$1"; fi
}
section() {
    awk -v re="$2" '$0 ~ re { f = 1; next } f && /^#+ / { exit } f { print }' "$1"
}

for f in "$PREFACE" "$CHECK_CI" "$PLAYBOOK" "$GATES" "$README" "$CHIEF_RUN"; do
    [ -r "$f" ] || { printf 'FAIL - unreadable %s\n' "$f"; exit 1; }
done

preface="$(cat "$PREFACE")"
lacks 'D1 preface: no foreground blocking wait' "$preface" 'one foreground blocking command'
lacks 'D1 preface: no "never a background job"' "$preface" 'never a background job'
lacks 'D1 preface: check-ci is not run foreground' "$preface" 'one foreground `scripts/check-ci.sh'
lacks 'D1 preface: no "never a background poll"' "$preface" 'never a background poll'
talk="$(section "$PREFACE" '^## Who you are talking to')"
has 'D1 preface: a wait is armed with run_in_background' "$talk" 'run_in_background'
has 'D1 preface: the wait rule names the keepalive section' "$talk" 'worker-sections/cache-keepalive.md'
ship="$(section "$PREFACE" '^## Shipping')"
has 'D1 preface Shipping: check-ci is armed in the background' "$ship" 'run_in_background'
checkci="$(cat "$CHECK_CI")"
lacks 'D1 check-ci: run mode is not foreground-only' "$checkci" 'run **one foreground** Bash command'
# shellcheck disable=SC2016 # the needle is a literal Markdown code span, not an expansion
lacks 'D1 check-ci: run mode does not forbid run_in_background' "$checkci" 'Do not use `run_in_background`'

trailer="$(section "$PLAYBOOK" '^## Symptom: a pre-push gate failed on a missing attestation trailer')"
[ -n "$trailer" ] || fail 'D5 playbook has the attestation-trailer section'
lacks 'D5 playbook: no follow-up-commit recovery' "$trailer" 'recovery is a **follow-up commit**'
malformed="$(printf '%s\n' "$trailer" | awk '/^\*\*What to do if the FIRST commit carries a trailer/ { f = 1 } f { print }')"
[ -n "$malformed" ] || fail 'D5 playbook has the malformed-token paragraph'
has 'D5 playbook: a malformed first-commit token is recut too' "$malformed" 'recut'
has 'D5 playbook: the malformed-token paragraph names check 5' "$malformed" 'check 5'

gates="$(cat "$GATES")"
lacks 'D7 validation-gates: no "operator retains the physical merge"' "$gates" 'retains the physical'
lacks 'D7 validation-gates: no "merge (operator)" checkpoint' "$gates" 'merge (operator)'
lacks 'D7 validation-gates: no "operator merge" chain step' "$gates" '→ operator merge'
claude_row="$(grep -F '| Code diff (Claude lane) |' "$GATES")"
has 'D7 validation-gates: the Claude-lane row merges on the chief GO' "$claude_row" 'chief GO at the reviewed head'
has 'D7 validation-gates: the Claude-lane row merges with merge-on-green.sh' "$claude_row" 'merge-on-green.sh'
owner="$(printf '%s\n' "$gates" | awk '/^\*\*Verdict owner:\*\*/ { f = 1 } f && /^$/ { exit } f { print }')"
has 'D7 validation-gates: the verdict owner paragraph names go.sh' "$owner" 'go.sh'

readme="$(cat "$README")"
lacks 'D8 README: no "no two of them plan to change the same files"' "$readme" 'checks that no two of them plan to change the same files'
lacks 'D8 README: no "can pass if it is small and merges clean"' "$readme" 'can pass if it is small and merges clean'
has 'D8 README: a merge says which conflicts it resolved' "$readme" 'conflicts it resolved'
chiefrun="$(cat "$CHIEF_RUN")"
lacks 'D8 running-a-chief: waves are not "no two of them will change the same files"' "$chiefrun" 'checks that no two of them will change the same files'
lacks 'D8 running-a-chief: no "confirm they are disjoint"' "$chiefrun" 'confirm they are disjoint'

if [ "$fails" -eq 0 ]; then printf 'PASS: one rule per gate docs\n'; exit 0; fi
printf '%d failure(s)\n' "$fails"
exit 1
