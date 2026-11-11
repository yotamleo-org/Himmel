#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-spend-evaluation.sh - RED/GREEN suite for
# fleet-scorecard.sh --exposure-screen (the free B1a context-recovery exposure screen). Fixtures are built at run time by fixtures/spend-evaluation/
# gen-screen-fixture.py over the REAL P1 producer and validator (model-price.mjs),
# so every row reads what P1 writes. No model, Jira or network call runs here.
#
# Platform guard: POSIX bash 3.2+, python3 and node.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FLEET="$HERE/fleet-scorecard.sh"
GEN="$HERE/fixtures/spend-evaluation/gen-screen-fixture.py"
REPO="$(cd "$HERE/../../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spend-eval.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0

check() {
    name="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "ok - $name"
    else
        echo "FAIL - $name: expected [$expected] got [$actual]"
        fails=$((fails + 1))
    fi
}

# jf <file> <key>: one top-level field of a JSON file (python repr for a list).
jf() {
    python3 -I -c 'import json,sys
v = json.load(open(sys.argv[1]))[sys.argv[2]]
print(json.dumps(v) if isinstance(v, (list, dict)) or v is None else v)' "$1" "$2"
}

# fx <scenario>: generate $TMP/<scenario>/ and run the screen on it; RC and $TMP/<scenario>/R.json.
fx() {
    python3 -I "$GEN" "$TMP/$1" "$1" || { echo "FAIL - generator $1"; fails=$((fails + 1)); }
    "$FLEET" --exposure-screen "$TMP/$1/SCREEN.json" --out "$TMP/$1/R.json" >"$TMP/$1/stdout" 2>"$TMP/$1/stderr"
    RC=$?
    R="$TMP/$1/R.json"
}

# --- screen-low-peak-compaction-counted
python3 -I "$GEN" "$TMP/lowpeak-markers" lowpeak-markers
READER="$REPO/scripts/eval/compaction-trigger-report.py"
SHAPES=$(python3 -I "$READER" --json --min-peak 0 "$TMP/lowpeak-markers/snapshot/proj/wk01.jsonl" \
    "$TMP/lowpeak-markers/snapshot/proj/wk02.jsonl" | python3 -I -c 'import json,sys
s = json.load(sys.stdin)["summary"]["shapes"]
print(s["idle"], s["manual"], s["steady"])')
check "(low-peak) the real reader labels the two fixture markers idle and manual" "$SHAPES" "1 1 0"
DEFAULT=$(python3 -I "$READER" --json "$TMP/lowpeak-markers/snapshot/proj/wk01.jsonl" "$TMP/lowpeak-markers/snapshot/proj/wk02.jsonl" \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["summary"]["workers"])')
check "(low-peak) the reader's default --min-peak would drop both parents" "$DEFAULT" "0"
fx lowpeak-markers
check "(low-peak) idle and manual boundaries both count (exit 0)" "$RC" "0"
check "(low-peak) numerator is the two windows" "$(jf "$R" numerator_nano)" "12000000"
check "(low-peak) denominator is every selected parent and child" "$(jf "$R" denominator_nano)" "2400000000"
check "(low-peak) twelve parents selected, the straddler counted out" "$(jf "$R" selected) $(jf "$R" excluded_straddlers)" "12 1"
check "(low-peak) share under 3 percent is NO-OP" "$(jf "$R" disposition)" "NO-OP"

fx boundary-instant
check "(boundary) exit 0" "$RC" "0"
check "(boundary) the call at the boundary instant is excluded, the strictly later five are in" \
    "$(jf "$R" numerator_nano)" "6000000"
check "(boundary) the excluded call stays in the denominator" "$(jf "$R" denominator_nano)" "2555540000"

fx dup-path
check "(path) a path selected twice is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(path) duplicate reason" "$(jf "$R" reasons)" '["path-duplicate"]'
fx missing-path
check "(path) a selected path no manifest names is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(path) missing reason" "$(jf "$R" reasons)" '["path-missing"]'
fx bad-event-time
check "(time) an invalid compaction event time is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(time) event-time reason" "$(jf "$R" reasons)" '["event-time-invalid"]'

# --- current-recovery-share
fx noop
check "(share) .0299 exits 0" "$RC" "0"
check "(share) .0299 is NO-OP" "$(jf "$R" disposition)" "NO-OP"
check "(share) .0299 numerator and denominator in nano" "$(jf "$R" numerator_nano)/$(jf "$R" denominator_nano)" "71760000/2400000000"
check "(share) .0299 share" "$(jf "$R" share)" "0.0299"
fx qualified
check "(share) exactly .03 exits 0" "$RC" "0"
check "(share) exactly .03 is QUALIFIED" "$(jf "$R" disposition)" "QUALIFIED"
check "(share) exactly .03 numerator and denominator in nano" "$(jf "$R" numerator_nano)/$(jf "$R" denominator_nano)" "72000000/2400000000"
check "(share) result shape" "$(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))))' "$R")" \
    "schema kind lever coverage selected excluded_straddlers numerator_nano denominator_nano share disposition reasons"
check "(share) a complete result is coverage complete with no reasons" "$(jf "$R" coverage) $(jf "$R" reasons)" "complete []"
fx overlap
check "(share) overlapping five-call windows union once" "$(jf "$R" numerator_nano)" "2860000"
check "(share) the union leaves the denominator whole" "$(jf "$R" denominator_nano)" "2400000000"

fx few-parents
check "(coverage) fewer than 12 parents is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(coverage) too-few reason" "$(jf "$R" reasons)" '["too-few-parents"]'
check "(coverage) an incomplete result carries null nano and share" \
    "$(jf "$R" coverage) $(jf "$R" numerator_nano) $(jf "$R" denominator_nano) $(jf "$R" share)" "incomplete null null null"
fx short-window
check "(coverage) a window under seven Berlin days is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(coverage) window reason" "$(jf "$R" reasons)" '["window-too-short"]'
fx early-window
check "(coverage) a window starting before Nov 9 is INCONCLUSIVE (exit 3)" "$RC $(jf "$R" reasons)" '3 ["window-before-nov-9"]'
fx utc-window
check "(coverage) a window that is not Berlin days is INCONCLUSIVE (exit 3)" "$RC $(jf "$R" reasons)" '3 ["window-not-berlin-days"]'
fx role-unknown
check "(coverage) an unknown role in the inventory is INCONCLUSIVE (exit 3)" "$RC $(jf "$R" reasons)" '3 ["role-unknown"]'
python3 -I "$GEN" "$TMP/tamper" qualified
printf 'edited\n' >> "$TMP/tamper/population-review.md"
"$FLEET" --exposure-screen "$TMP/tamper/SCREEN.json" --out "$TMP/tamper/R.json" >/dev/null 2>&1; RC=$?
check "(coverage) a ref whose bytes changed after pinning is INCONCLUSIVE (exit 3)" "$RC $(jf "$TMP/tamper/R.json" reasons)" '3 ["ref-hash-mismatch"]'
python3 -I "$GEN" "$TMP/stale" qualified
python3 -I -c 'import hashlib, json, sys
d = sys.argv[1]
v = json.load(open(d + "/validation.json"))
v["selected_calls"] += 1
raw = (json.dumps(v) + "\n").encode()
open(d + "/validation.json", "wb").write(raw)
s = json.load(open(d + "/SCREEN.json"))
s["validation"]["sha256"] = hashlib.sha256(raw).hexdigest()
json.dump(s, open(d + "/SCREEN.json", "w"))' "$TMP/stale"
"$FLEET" --exposure-screen "$TMP/stale/SCREEN.json" --out "$TMP/stale/R.json" >/dev/null 2>&1; RC=$?
check "(coverage) a validation that differs from the validator's own answer is INCONCLUSIVE (exit 3)" \
    "$RC $(jf "$TMP/stale/R.json" reasons)" '3 ["validation-mismatch"]'
fx population-incomplete
check "(coverage) an incomplete population is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(coverage) population reason" "$(jf "$R" reasons)" '["population-incomplete"]'
fx unpriced
check "(coverage) an unpriced call is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(coverage) price reason carried from the validator" "$(jf "$R" reasons | grep -c unpriced)" "1"
fx source-changed
check "(coverage) a transcript changed after the export is INCONCLUSIVE (exit 3)" "$RC" "3"
check "(coverage) source reason" "$(jf "$R" reasons)" '["source-changed"]'

# --- malformed input and the unsupported lever
fx b2-lever
check "(malformed) a B2 lever is refused (exit 2)" "$RC" "2"
check "(malformed) the B2 refusal names the lever" "$(grep -c 'unsupported lever' "$TMP/b2-lever/stderr")" "1"
check "(malformed) a refused request writes no result" "$([ -e "$R" ] && echo written || echo none)" "none"
fx caller-report
check "(malformed) a caller-supplied compaction report is refused (exit 2)" "$RC" "2"
check "(malformed) the refusal names the field" "$(grep -c 'compaction_report' "$TMP/caller-report/stderr")" "1"
printf 'not json' > "$TMP/junk.json"
ERR=$("$FLEET" --exposure-screen "$TMP/junk.json" --out "$TMP/junk-out.json" 2>&1 >/dev/null); RC=$?
check "(malformed) unreadable SCREEN JSON is refused (exit 2)" "$RC $(printf '%s' "$ERR" | grep -c 'SCREEN is not')" "2 1"
ERR=$("$FLEET" --exposure-screen "$TMP/qualified/SCREEN.json" --out "$TMP/x.json" --tz UTC 2>&1 >/dev/null); RC=$?
check "(malformed) --exposure-screen with a report-mode option is refused (exit 2)" "$RC $(printf '%s' "$ERR" | grep -c 'takes only --out')" "2 1"
ERR=$("$FLEET" --exposure-screen "$TMP/qualified/SCREEN.json" 2>&1 >/dev/null); RC=$?
check "(malformed) --exposure-screen without --out is refused (exit 2)" "$RC $(printf '%s' "$ERR" | grep -c 'needs --out')" "2 1"

# --- no model, Jira or issue-writing command can run
mkdir "$TMP/stubs"
for s in claude codex gh curl wget; do
    { echo '#!/bin/sh'; echo "echo \"\$0\" >> \"$TMP/ran\""; echo 'exit 99'; } > "$TMP/stubs/$s"
    chmod +x "$TMP/stubs/$s"
done
PATH="$TMP/stubs:$PATH" "$FLEET" --exposure-screen "$TMP/qualified/SCREEN.json" --out "$TMP/stub-out.json" >/dev/null 2>&1; RC=$?
check "(no-model) the screen still answers with every model and issue command stubbed" "$RC $(jf "$TMP/stub-out.json" disposition)" "0 QUALIFIED"
check "(no-model) no stub ran" "$([ -e "$TMP/ran" ] && echo ran || echo none)" "none"

echo
if [ "$fails" -eq 0 ]; then echo "PASS test-spend-evaluation.sh"; exit 0; fi
echo "FAIL test-spend-evaluation.sh ($fails)"; exit 1
