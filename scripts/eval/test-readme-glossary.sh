#!/usr/bin/env bash
# scripts/eval/test-readme-glossary.sh - the "What each number means" table in scripts/eval/README.md
# has a row for every number the evals report, under its display name and its unchanged ledger key.
# No model call, no network, no bank.
#  1. each ledger key is still written by its producer;
#  2. the README table has a row per number: the display name in the first cell, the key in the second;
#  3. the check fails on a README with one row removed, one where a renamed display name is reverted,
#     and one where a key moves behind another key in its cell.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
README="$HERE/README.md"
HEADING="## What each number means"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/readme-glossary-test.XXXXXX")" || { echo "test-readme-glossary: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# display name <TAB> ledger key as the README writes it <TAB> producer <TAB> the code that writes the key
# <TAB> where the key sits in its README cell (first, or any for a row that names it in a sentence)
NUMBERS="$TMP/numbers.tsv"
cat >"$NUMBERS" <<'EOF'
pass@k	pass_at_k	scripts/eval/lib/eval_runs.py	"pass_at_k": _finite_mean(	first
pass^k	pass_pow_k	scripts/eval/lib/eval_runs.py	"pass_pow_k": _finite_mean(	first
cost per accepted run	cost_per_accepted	scripts/eval/lib/eval_runs.py	metrics["cost_per_accepted"] =	first
headroom	_headroom	scripts/eval/eval-compare.json	"_headroom": {	first
test-first adherence	red_before_green_rate	scripts/eval/lib/eval_runs.py	for k in ("red_before_green", "verify_before_claim"):	first
claims-backed rate	verify_before_claim_rate	scripts/eval/lib/eval_runs.py	for k in ("red_before_green", "verify_before_claim"):	first
denial recovery rate	denial_recovery_rate	scripts/eval/lib/eval_runs.py	metrics["denial_recovery_rate"] =	first
identical retries after a denial	identical_denied_retries	scripts/eval/lib/eval_runs.py	metrics["identical_denied_retries"] =	first
false-refusal share	over_deny_share	scripts/eval/friction/friction.py	metrics['over_deny_share'] =	first
detection rate	<critic>.recall	scripts/eval/review-panel/score.py	"recall": (	first
planted-bug precision	<critic>.precision	scripts/eval/review-panel/score.py	"precision": (	first
false-alarm rate	<critic>.fp_rate	scripts/eval/review-panel/score.py	"fp_rate": (	first
detection floor	paired	scripts/eval/eval-compare	detection floor %s	any
escape rate	escape_rate	scripts/eval/escapes.py	m["escape_rate"] =	first
proof-first share (self-reported)	pdd.pct	scripts/eval/worker-digest/pdd_share.py	(("pdd",	first
Wilson interval	ci_method	scripts/eval/worker-digest/pdd_share.py	ci_method="wilson"	any
review precision	precision_pct	scripts/cr/evals-page-gen.py	"precision_pct": pct1(	first
cache read share	read_ratio_pct	scripts/cr/evals-page-gen.py	{"read_ratio_pct": ratio,	first
EOF

# misses <readme>: prints one line per number with no row (display name in cell 1, `key` in cell 2:
# at its start for a "first" row, anywhere in it for an "any" row).
misses() {
    awk -F'\t' -v h="$HEADING" '
        FNR == NR { want[++n] = $1; key[n] = $2; pos[n] = $5; next }
        $0 == h { on = 1; next }
        on && /^## / { on = 0 }
        on && /^\|/ {
            split($0, c, "|"); d = c[2]; k = c[3]; gsub(/^ +| +$/, "", d); gsub(/^ +| +$/, "", k)
            have[d] = have[d] "\n" k
        }
        END {
            for (i = 1; i <= n; i++) {
                k = "`" key[i] "`"
                if (!(want[i] in have) || index(have[want[i]], (pos[i] == "first" ? "\n" : "") k) == 0)
                    print want[i] " (" key[i] ")"
            }
        }' "$NUMBERS" "$1"
}

echo "1. each ledger key is still written by its producer"
while IFS=$'\t' read -r disp _ prod needle _; do
    check "$disp: $prod writes it with $needle" 'grep -qF -- "$needle" "$REPO/$prod"'
done <"$NUMBERS"

echo "2. the README table has a row per number"
check "the README has the heading \"$HEADING\"" 'grep -qxF -- "$HEADING" "$README"'
misses "$README" >"$TMP/miss.txt"
check "every number has a row with its display name and ledger key (missing: $(paste -sd, "$TMP/miss.txt"))" '[ ! -s "$TMP/miss.txt" ]'

echo "3. the check catches a removed row, a reverted rename and a moved key, and only that row"
grep -vF -- '| false-refusal share |' "$README" >"$TMP/no-row.md"
check "a README without the false-refusal share row misses that row alone" '[ -s "$TMP/no-row.md" ] && [ "$(misses "$TMP/no-row.md")" = "false-refusal share (over_deny_share)" ]'
sed 's/^| test-first adherence |/| red before green |/' "$README" >"$TMP/reverted.md"
check "a README whose test-first adherence row is named red before green again misses that row alone" '[ -s "$TMP/reverted.md" ] && [ "$(misses "$TMP/reverted.md")" = "test-first adherence (red_before_green_rate)" ]'
sed 's/^| false-refusal share | `over_deny_share`/| false-refusal share | `wrong_key` (formerly `over_deny_share`)/' "$README" >"$TMP/moved-key.md"
check "a README whose false-refusal share key moves behind another key misses that row alone" '[ -s "$TMP/moved-key.md" ] && [ "$(misses "$TMP/moved-key.md")" = "false-refusal share (over_deny_share)" ]'

echo "test-readme-glossary: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
