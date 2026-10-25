#!/usr/bin/env bash
# scripts/eval/friction/test-friction.sh - suite for friction.py.
# Fixture clock: --now 2026-10-08T00:00:00Z, 7-day window. The 2026-01-01 row is outside it.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
FRICTION="${FRICTION_PY:-$HERE/friction.py}"
FIX="$HERE/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/friction-test.XXXXXX")" || { echo "test-friction: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_USER_REPORTS="$TMP/no-user-reports.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }

OUT="$TMP/out.json"
python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 \
  --projects "$FIX/proj" --docs "$FIX/docs" --json "$OUT" --md "$TMP/out.md" >/dev/null 2>"$TMP/err"
eq "runs clean" "$?" "0"

# field <python expr over the loaded json d>
field() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$OUT" "$1"; }

eq "window: tx rows (old row excluded)" "$(field 'd["meta"]["tx_rows"]')" "3"
eq "chain-prefixed hook name extracted + text-mention class" \
  "$(field '[c["class"] for c in d["by_class"] if c["source"]=="hook:guard-pr-check-literal"]')" "['text-mentions-gate-path']"
eq "text-mention class is an over-deny" \
  "$(field '[c["verdicts"] for c in d["by_class"] if c["class"]=="text-mentions-gate-path"]')" "[{'over-deny': 1}]"
eq "classifier tag becomes the class" \
  "$(field '[c["class"] for c in d["by_class"] if c["source"]=="classifier"]')" "['classifier-instruction-poisoning']"
eq "suite-slot wait is a lane rule" \
  "$(field '[c["count"] for c in d["by_class"] if c["class"]=="suite-slot-busy"]')" "[1]"
eq "plain test failure is not a refusal" \
  "$(field 'len([c for c in d["by_class"] if "quiet" in c["class"]])')" "0"
eq "recovery minutes measured to the next good call" \
  "$(field '[c["median_recovery_min"] for c in d["by_class"] if c["class"]=="text-mentions-gate-path"]')" "[2.0]"
eq "doc: continuation bullet is not a second block" \
  "$(field 'sum(r["doc_blocks"] for r in d["doc_classes"])')" "2"
eq "doc: classifier hold = BLOCKED to next RESOLVED (15 min)" \
  "$(field '[r["median_hold_min"] for r in d["doc_classes"] if r["class"]=="classifier-instruction-poisoning"]')" "[15]"
eq "doc: operator mention counted" \
  "$(field '[r["operator_interrupts"] for r in d["doc_classes"] if r["source"]=="hook:guard-pr-check-literal"]')" "[1]"
case "$(cat "$TMP/out.md")" in
  *"| hook:guard-pr-check-literal | text-mentions-gate-path |"*) pass "markdown carries the ranked class row";;
  *) fail "markdown carries the ranked class row";;
esac

python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 --section \
  --projects "$FIX/proj" --docs "$FIX/docs" >"$TMP/section.md" 2>"$TMP/err2"
case "$(cat "$TMP/section.md")" in
  *"- hook:guard-pr-check-literal / text-mentions-gate-path: 1 refusals (over-deny, prior 0, new)"*"- classifier / classifier-instruction-poisoning: 1 blocks, 15 hold min"*) pass "section: refusal line with trend and escalation line";;
  *) fail "section: refusal line with trend and escalation line: $(cat "$TMP/section.md")";;
esac

OUT2="$TMP/out2.json"
python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 \
  --projects "$FIX/proj2" --docs "$FIX/docs" --json "$OUT2" --md "$TMP/out2.md" >/dev/null 2>&1
field2() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$OUT2" "$1"; }
eq "rows after --now are excluded" "$(field2 '[c["count"] for c in d["by_class"] if c["class"]=="suite-slot-busy"]')" "[3]"
eq "a recovery after --now does not resolve an in-window refusal" \
  "$(field2 '[c["median_recovery_min"] for c in d["by_class"] if c["class"]=="suite-slot-busy"]')" "[4.5]"
eq "every refusal in a retry chain gets a recovery time" \
  "$(field2 '[c["median_recovery_min"] for c in d["by_class"] if c["class"]=="suite-slot-busy"]')" "[4.5]"
python3 -I "$FRICTION" --repo "$REPO" --now notatime --projects "$FIX/proj2" --docs "$FIX/docs" >/dev/null 2>&1
eq "an invalid --now is rejected" "$?" "2"

# One fixture refusal per sampled sub-class lands in its named class and verdict.
OUT3="$TMP/out3.json"
python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 \
  --projects "$FIX/proj3" --docs "$FIX/docs" --json "$OUT3" --md "$TMP/out3.md" >/dev/null 2>&1
eq "the classes run exits 0" "$?" "0"
eq "ci-wait stays out of the per-class table" "$(python3 -I -c 'import json,sys; print(sum(1 for c in json.load(open(sys.argv[1]))["by_class"] if c["source"]=="ci-wait"))' "$OUT3")" "0"
field3() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$OUT3" "$1"; }
sort "$FIX/classes.tsv" | uniq -c | sed 's/^ *\([0-9][0-9]*\) /\1	/' >"$TMP/classes.counts"
while IFS="$(printf '\t')" read -r n src cls verdict; do
  eq "named class $src / $cls x$n" \
    "$(field3 '[[c["count"], c["verdicts"]] for c in d["by_class"] if c["source"]=="'"$src"'" and c["class"]=="'"$cls"'"]')" "[[$n, {'$verdict': $n}]]"
done <"$TMP/classes.counts"
NROWS="$(wc -l <"$FIX/classes.tsv" | tr -d ' ')"
NUNC="$(grep -c "$(printf '\t')unclear\$" "$FIX/classes.tsv")"
eq "no other-* catch-all class from the fixtures" \
  "$(field3 'len([c for c in d["by_class"] if c["class"].startswith("other-")])')" "0"
eq "ci-wait is reported apart, not in the refusal total" \
  "$(field3 '[d["meta"]["refusals"], d["meta"]["ci_wait"]]')" "[$NROWS, 1]"
eq "hook refusal and unclear counts" \
  "$(field3 '[d["meta"]["hook_refusals"], d["meta"]["hook_unclear"]]')" "[$NROWS, $NUNC]"
eq "hook unclear share" \
  "$(field3 'd["meta"]["hook_unclear_share"]')" "$(python3 -I -c "print(round($NUNC / $NROWS, 4))")"
case "$(cat "$TMP/out3.md")" in
  *"ci-wait: 1 CI re-polls"*) pass "markdown reports ci-wait on its own line";;
  *) fail "markdown reports ci-wait on its own line";;
esac
OUT4="$TMP/out4.json"; L4="$TMP/runs4.jsonl"
python3 -I "$FRICTION" --repo "$REPO" --now 2026-10-08T00:00:00Z --days 7 --projects "$FIX/proj3" --docs "$FIX/docs" \
  --record --eval-ledger "$L4" --json "$OUT4" --md "$TMP/out4.md" >/dev/null 2>&1
eq "the record run exits 0" "$?" "0"
eq "ledger row: refusals exclude ci-wait" \
  "$(python3 -I -c 'import json,sys; m=json.loads(open(sys.argv[1]).readline())["metrics"]; print([m["refusals"], m["ci_wait"], m["hook_unclear"], m["hook_refusals"]])' "$L4")" \
  "[$NROWS, 1, $NUNC, $NROWS]"

echo "friction: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
