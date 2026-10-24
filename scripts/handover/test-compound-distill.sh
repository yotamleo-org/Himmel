#!/usr/bin/env bash
# test-compound-distill.sh — hermetic: a stub claude and a stub preflight; no paid or live run.
# A scratch handover bucket, a scratch Jira mirror and scratch output dirs.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/handover/compound-distill.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t compound-distill.XXXXXX)" || exit 1; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }
has() { grep -q -- "$2" "$1" 2>/dev/null && echo yes || echo no; }

R="$W/handovers"; B="$R/u/himmel"; MIR="$W/mirror"
mkdir -p "$B" "$R/.locks/queue" "$MIR" "$W/bin"
SHA="0123456789abcdef0123456789abcdef01234567"
printf '# HIMMEL-1\n\nBODYSECRET\n\n## Results\n\n- 10:00 LIVE — x\n- 10:10 FINDING — the guard over-denies\n- 10:40 WRAPPED — PR #3713 merged, sha %s\n' "$SHA" > "$B/HIMMEL-1-first-2026-10-20.md"
printf '# HIMMEL-2\n\n## Results\n\n- 09:05 BLOCKED — the VM queue is full\n- 09:10 HALTED — console halted\n' > "$B/HIMMEL-2-second-2026-10-21.md"

# the stub claude: records argv and stdin, prints the envelope in $STUB_ENV
cat > "$W/bin/claude-stub" <<EOF
#!/usr/bin/env bash
echo called >> "$W/calls"
printf '%s\n' "\$@" > "$W/args"
cat > "$W/stdin"
cat "\${STUB_ENV:-$W/env.json}"
EOF
chmod +x "$W/bin/claude-stub"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$W/bin/pf-ok"; chmod +x "$W/bin/pf-ok"
printf '#!/usr/bin/env bash\necho SKIPPED-BANK\n' > "$W/bin/pf-skip"; chmod +x "$W/bin/pf-skip"

# envelope <file> <result json text> [is_error]
envelope() { python3 -I -c '
import json, sys
env = {"type": "result", "is_error": sys.argv[3] == "true", "result": sys.argv[2],
       "usage": {"input_tokens": 1200, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 50, "output_tokens": 400}}
open(sys.argv[1], "w").write(json.dumps(env))' "$1" "$2" "${3:-false}"; }

GOOD='{"week":"2026-W43","entries":[
 {"key":"HIMMEL-1","outcome":"merged","decision":"narrow the guard","lesson":"test the read-only path","pr":"999","sha":"deadbee"},
 {"key":"HIMMEL-2","outcome":"halted","decision":"","lesson":""}],
 "themes":[{"slug":"guard-overdeny","title":"Guard over-deny","lessons":[{"text":"read-only greps must pass","keys":["HIMMEL-1"]}]}],
 "proposals":[{"text":"add a lessons note on read-only greps","keys":["HIMMEL-1","HIMMEL-2"]}]}'

OUT="$W/out"; REV="$W/review"
run() { COMPOUND_CLAUDE="$W/bin/claude-stub" COMPOUND_PREFLIGHT_CMD="$W/bin/pf-ok" \
  bash "$SUT" --root "$R" --bucket "$B" --mirror "$MIR" --since-days 0 --week 2026-W43 --out-dir "$OUT" "$@"; }
calls() { [ -f "$W/calls" ] && wc -l < "$W/calls" | tr -d ' ' || echo 0; }

# --- RED: today there is no distill runner ------------------------------------------
[ -f "$SUT" ] || { check "RED: compound-distill.sh exists" yes no; echo "pass=$PASS fail=$FAIL"; exit 1; }
[ -f "$REPO/scripts/handover/compound-schema.json" ] || { check "compound-schema.json exists" yes no; echo "pass=$PASS fail=$FAIL"; exit 1; }

envelope "$W/env.json" "$GOOD"

# --- the billed opt-in -----------------------------------------------------------------
run --review-dir "$REV" >/dev/null 2>&1; check "no --billed and no HIMMEL_BILLED_OK: exit 2" 2 "$?"
check "and claude was never called" 0 "$(calls)"
HIMMEL_BILLED_OK=1 run >/dev/null 2>&1; check "a dry run without --review-dir: exit 2" 2 "$?"
HIMMEL_BILLED_OK=1 run --review-dir "$W/x/specs/lessons" >/dev/null 2>&1; check "a review dir under specs/lessons is refused: exit 2" 2 "$?"
HIMMEL_BILLED_OK=1 bash "$SUT" --root "$R" --bucket "$B" --mirror "$MIR" --out-dir "$W/y/specs/lessons/../lessons" --apply >/dev/null 2>&1
check "an out dir that resolves into specs/lessons is refused: exit 2" 2 "$?"
HIMMEL_BILLED_OK=1 run --review-dir "$REV" --bogus >/dev/null 2>&1; check "an unknown flag: exit 2" 2 "$?"
check "none of the refusals reached claude" 0 "$(calls)"

# --- input size is measured and refused above the limit ---------------------------------
o="$(HIMMEL_BILLED_OK=1 run --review-dir "$REV" --max-tokens 10 2>&1)"; check "input above --max-tokens: exit 3" 3 "$?"
check "and the refusal names the estimate and the limit" yes "$(grep -Eq 'est_input_tokens=[0-9]+ .*max=10' <<< "$o" && echo yes || echo no)"
check "and claude was not called" 0 "$(calls)"

# --- the preflight verdict is respected ---------------------------------------------------
o="$(HIMMEL_BILLED_OK=1 COMPOUND_PREFLIGHT_CMD="$W/bin/pf-skip" bash "$SUT" --root "$R" --bucket "$B" --mirror "$MIR" --since-days 0 --week 2026-W43 --out-dir "$OUT" --review-dir "$REV" 2>&1)"
check "a SKIPPED-BANK preflight is a quiet skip (exit 0)" 0 "$?"
check "and says what the preflight said" yes "$(grep -q 'skipped, preflight said: SKIPPED-BANK' <<< "$o" && echo yes || echo no)"
check "and claude was not called" 0 "$(calls)"
check "and nothing was written" no "$([ -e "$REV" ] && echo yes || echo no)"

# --- a nothing-to-compound week never calls claude -----------------------------------------
mkdir -p "$W/empty/u/himmel"
o="$(HIMMEL_BILLED_OK=1 COMPOUND_CLAUDE="$W/bin/claude-stub" COMPOUND_PREFLIGHT_CMD="$W/bin/pf-ok" bash "$SUT" --root "$W/empty" --bucket "$W/empty/u/himmel" --mirror "$MIR" --week 2026-W43 --out-dir "$OUT" --review-dir "$REV" 2>&1)"
check "an empty extract exits 0" 0 "$?"
check "and claude was not called" 0 "$(calls)"

# --- a valid run ---------------------------------------------------------------------------
o="$(HIMMEL_BILLED_OK=1 run --review-dir "$REV" 2>&1)"; check "valid output: exit 0" 0 "$?"
check "claude was called once" 1 "$(calls)"
check "the call is -p" yes "$(has "$W/args" '^-p$')"
check "the call names the sonnet model" sonnet "$(grep -A1 '^--model$' "$W/args" | tail -n 1)"
check "the call asks for --output-format json" json "$(grep -A1 '^--output-format$' "$W/args" | tail -n 1)"
check "the call sets an explicit permission mode" plan "$(grep -A1 '^--permission-mode$' "$W/args" | tail -n 1)"
check "never bypassPermissions" no "$(has "$W/args" 'bypassPermissions')"
check "stdin carries the extract's marker bullets" yes "$(has "$W/stdin" 'the guard over-denies')"
check "stdin carries no doc body" no "$(has "$W/stdin" 'BODYSECRET')"
check "stdin carries the schema" yes "$(has "$W/stdin" '"additionalProperties"')"
check "the weekly note is in the review dir" yes "$([ -f "$REV/2026-W43.md" ] && echo yes || echo no)"
check "the weekly note has an entry per key" 2 "$(grep -c '^## HIMMEL-' "$REV/2026-W43.md")"
check "the extract's PR overrides the model's" yes "$(has "$REV/2026-W43.md" 'PR: #3713')"
check "the extract's sha overrides the model's" yes "$(has "$REV/2026-W43.md" "$SHA")"
check "a theme note is written with its source key" yes "$(grep -q 'read-only greps must pass.*HIMMEL-1' "$REV/themes/guard-overdeny.md" 2>/dev/null && echo yes || echo no)"
check "proposals are written to a proposals file" yes "$(grep -q 'HIMMEL-1, HIMMEL-2' "$REV/proposals-2026-W43.md" 2>/dev/null && echo yes || echo no)"
check "a dry run leaves the out dir alone" no "$([ -e "$OUT" ] && echo yes || echo no)"
check "the summary line reports the JSON usage input tokens (1200+300+50)" yes "$(grep -q 'usage_input_tokens=1550 ' <<< "$o" && echo yes || echo no)"
check "and the output tokens" yes "$(grep -q 'output_tokens=400' <<< "$o" && echo yes || echo no)"
check "and a dry-run label" yes "$(grep -q 'compound-distill: dry-run ' <<< "$o" && echo yes || echo no)"
check "no CLAUDE.md, MEMORY.md or specs/lessons is ever written" 0 \
  "$(find "$W" \( -name CLAUDE.md -o -name MEMORY.md -o -path '*/specs/lessons*' \) | wc -l | tr -d ' ')"

# --- --apply writes the out dir and feeds the existing themes back ---------------------------
rm -f "$W/calls"
o="$(HIMMEL_BILLED_OK=1 run --apply 2>&1)"; check "--apply exits 0" 0 "$?"
check "--apply writes the weekly note to the out dir" yes "$([ -f "$OUT/2026-W43.md" ] && echo yes || echo no)"
check "--apply writes the theme note to the out dir" yes "$([ -f "$OUT/themes/guard-overdeny.md" ] && echo yes || echo no)"
rm -f "$W/calls"; HIMMEL_BILLED_OK=1 run --apply >/dev/null 2>&1
check "the next run hands the existing theme note to claude" yes "$(has "$W/stdin" 'read-only greps must pass')"

# --- invalid output is refused and writes nothing -----------------------------------------------
bad() {  # bad <label> <result text> [is_error]
  rm -rf "$REV"; envelope "$W/env.json" "$2" "${3:-false}"
  o="$(HIMMEL_BILLED_OK=1 run --review-dir "$REV" 2>&1)"; check "$1: exit 1" 1 "$?"
  check "$1: nothing written" no "$([ -e "$REV" ] && echo yes || echo no)"
}
bad "a result that is not JSON" 'I could not do that'
bad "a missing required field" '{"week":"2026-W43","entries":[],"themes":[]}'
bad "an unknown top-level field" '{"week":"2026-W43","entries":[],"themes":[],"proposals":[],"extra":1}'
bad "a malformed week" '{"week":"43","entries":[],"themes":[],"proposals":[]}'
bad "more than 10 themes" "$(python3 -I -c 'import json; print(json.dumps({"week":"2026-W43","entries":[],"proposals":[],"themes":[{"slug":"t%d"%i,"title":"t","lessons":[]} for i in range(11)]}))')"
bad "a theme slug that could escape the dir" '{"week":"2026-W43","entries":[],"proposals":[],"themes":[{"slug":"../x","title":"t","lessons":[]}]}'
bad "an entry for a key that is not in the extract" '{"week":"2026-W43","entries":[{"key":"HIMMEL-99","outcome":"x","decision":"","lesson":""}],"themes":[],"proposals":[]}'
bad "a proposal citing a key that is not in the extract" '{"week":"2026-W43","entries":[],"themes":[],"proposals":[{"text":"t","keys":["HIMMEL-99"]}]}'
bad "an error envelope" "$GOOD" true
bad "an entry's prose naming a key that is not in the extract" '{"week":"2026-W43","entries":[{"key":"HIMMEL-1","outcome":"see HIMMEL-99","decision":"","lesson":""}],"themes":[],"proposals":[]}'
bad "a lesson's prose naming a key that is not in the extract" '{"week":"2026-W43","entries":[],"proposals":[],"themes":[{"slug":"t","title":"t","lessons":[{"text":"as in HIMMEL-77","keys":["HIMMEL-1"]}]}]}'
bad "a theme title naming a key that is not in the extract" '{"week":"2026-W43","entries":[],"proposals":[],"themes":[{"slug":"t","title":"HIMMEL-77 notes","lessons":[]}]}'
bad "a theme title naming an extracted key that no entry or lesson backs" '{"week":"2026-W43","entries":[],"proposals":[],"themes":[{"slug":"t","title":"HIMMEL-1 notes","lessons":[]}]}'
bad "two themes with one slug" '{"week":"2026-W43","entries":[],"proposals":[],"themes":[{"slug":"t","title":"a","lessons":[{"text":"x","keys":["HIMMEL-1"]}]},{"slug":"t","title":"b","lessons":[{"text":"y","keys":["HIMMEL-2"]}]}]}'
bad "two entries for one key" '{"week":"2026-W43","entries":[{"key":"HIMMEL-1","outcome":"a","decision":"","lesson":""},{"key":"HIMMEL-1","outcome":"b","decision":"","lesson":""}],"themes":[],"proposals":[]}'

# --- provenance comes from the extract only, never from the model -----------------------------------
rm -rf "$REV"
envelope "$W/env.json" '{"week":"2026-W43","entries":[{"key":"HIMMEL-1","outcome":"m","decision":"","lesson":""},{"key":"HIMMEL-2","outcome":"h","decision":"","lesson":"","pr":"555","sha":"cafef00d"}],"themes":[],"proposals":[]}'
HIMMEL_BILLED_OK=1 run --review-dir "$REV" >/dev/null 2>&1
check "a model-supplied PR for a key the extract has no PR for is dropped" no "$(has "$REV/2026-W43.md" '555')"
check "and so is a model-supplied sha" no "$(has "$REV/2026-W43.md" 'cafef00d')"

# --- a rerun with no proposals removes the previous proposals file ----------------------------------
rm -rf "$REV"; envelope "$W/env.json" "$GOOD"
HIMMEL_BILLED_OK=1 run --review-dir "$REV" >/dev/null 2>&1
check "the first run wrote a proposals file" yes "$([ -f "$REV/proposals-2026-W43.md" ] && echo yes || echo no)"
envelope "$W/env.json" '{"week":"2026-W43","entries":[],"themes":[],"proposals":[]}'
HIMMEL_BILLED_OK=1 run --review-dir "$REV" >/dev/null 2>&1
check "a rerun with zero proposals removes the stale file" no "$([ -f "$REV/proposals-2026-W43.md" ] && echo yes || echo no)"

# --- a symlinked destination into specs/lessons is refused -----------------------------------------
mkdir -p "$W/x/specs/lessons"; ln -s "$W/x/specs/lessons" "$W/lnk"
HIMMEL_BILLED_OK=1 run --review-dir "$W/lnk" >/dev/null 2>&1
check "a review dir that is a symlink into specs/lessons: exit 2" 2 "$?"
mkdir -p "$W/out2"; ln -s "$W/x/specs/lessons" "$W/out2/themes"; envelope "$W/env.json" "$GOOD"
HIMMEL_BILLED_OK=1 COMPOUND_CLAUDE="$W/bin/claude-stub" COMPOUND_PREFLIGHT_CMD="$W/bin/pf-ok" bash "$SUT" --root "$R" --bucket "$B" --mirror "$MIR" --since-days 0 --week 2026-W43 --out-dir "$W/out2" --apply >/dev/null 2>&1
check "a themes dir that is a symlink into specs/lessons: exit 1" 1 "$?"
check "and nothing was written through it" 0 "$(find "$W/x/specs/lessons" -type f | wc -l | tr -d ' ')"
check "and nothing else was written either" no "$([ -e "$W/out2/2026-W43.md" ] && echo yes || echo no)"

# --- a fenced JSON result is accepted ---------------------------------------------------------------
rm -rf "$REV"
# shellcheck disable=SC2016  # the backticks are the literal fence
envelope "$W/env.json" "$(printf '```json\n%s\n```' "$GOOD")"
HIMMEL_BILLED_OK=1 run --review-dir "$REV" >/dev/null 2>&1; check 'a fenced json result: exit 0' 0 "$?"

# --- a claude that exits non-zero ----------------------------------------------------------------------
printf '#!/usr/bin/env bash\ncat >/dev/null; echo boom >&2; exit 7\n' > "$W/bin/claude-fail"; chmod +x "$W/bin/claude-fail"
rm -rf "$REV"
HIMMEL_BILLED_OK=1 COMPOUND_CLAUDE="$W/bin/claude-fail" COMPOUND_PREFLIGHT_CMD="$W/bin/pf-ok" bash "$SUT" --root "$R" --bucket "$B" --mirror "$MIR" --since-days 0 --week 2026-W43 --out-dir "$OUT" --review-dir "$REV" >/dev/null 2>&1
check "a claude exit 7: exit 1" 1 "$?"
check "and nothing written" no "$([ -e "$REV" ] && echo yes || echo no)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
