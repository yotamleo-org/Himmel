#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-fleet-scorecard.sh - RED/GREEN suite for
# fleet-scorecard.sh over fixtures/fleet-scorecard/ (2 claudex workers, 2 native
# workers). House check style, per test-scorecard.sh.
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ and python3; it
# runs under git bash unchanged.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
FLEET="$HERE/fleet-scorecard.sh"
FX="$HERE/fixtures/fleet-scorecard"
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

# cell <report> <section heading> <first cell> <field>: one trimmed table cell;
# field 2 is the first column (awk -F'|' leaves field 1 empty).
cell() {
    printf '%s\n' "$1" | awk -F'|' -v sec="## $2" -v key="$3" -v f="$4" '
        /^## / { on = ($0 == sec) }
        on && $0 ~ /^\|/ { k = $2; gsub(/^ +| +$/, "", k); if (k == key) { v = $f; gsub(/^ +| +$/, "", v); print v; exit } }'
}

rows() {
    printf '%s\n' "$1" | awk -v sec="## $2" '/^## / { on = ($0 == sec) } on && /^\| N[0-9]/ { n++ } END { print n + 0 }'
}

run() {
    "$FLEET" --manifest "$FX/FT-roadmap-chief.fleet.json" --prs "$FX/prs.json" \
        --cr-ledger "$FX/cr-ledger.jsonl" --verdicts "$FX/verdicts" --denials "$FX/denials.jsonl" \
        --mirror "$FX/mirror" --tz UTC "$@"
}

OUT=$(run --since 2026-10-25T00:00:00Z 2>/dev/null); RC=$?
check "runs over the fixture cohort (exit 0)" "$RC" "0"

# --- (a) the DoD RED control: a planted claudex worker with one judge NO-GO and
# two chief interventions (a FINDING ask and a nudge; the ruling that answers
# the ask is not a third, and the nudge logged both in the doc and in the chief
# doc counts once)
check "(a) planted worker is on the claudex lane" "$(cell "$OUT" "Output quality" N9001 3)" "claudex"
check "(a) planted worker judge cell shows NO-GO=1 with its blocker and major" \
    "$(cell "$OUT" "Output quality" N9001 7)" "GO 1, NO-GO 1 (blocker 1, major 1)"
check "(a) planted worker shows interventions=2" "$(cell "$OUT" "Fleet management" N9001 6)" "2"
check "(a) planted worker breakdown asks/rulings/nudges/expansions" \
    "$(cell "$OUT" "Fleet management" N9001 7)" "1/1/1/0"
check "(a) a nudge only in the worker doc and another only in the chief doc count twice" \
    "$(cell "$OUT" "Fleet management" N9003 7)" "1/1/2/0"
check "(a) a chief GO record is not a judge verdict" "$(cell "$OUT" "Output quality" N9003 7)" "GO 1, NO-GO 0"

# --- (b) both halves print for every worker; a missing source is n/a with its
# reason, never 0
check "(b) every worker has an output-quality row" "$(rows "$OUT" "Output quality")" "4"
check "(b) every worker has a fleet-management row" "$(rows "$OUT" "Fleet management")" "4"
check "(b) CR findings per reviewed head" "$(cell "$OUT" "Output quality" N9001 8)" "crit 0, imp 1, sug 1 over 3 heads"
check "(b) rounds to clean" "$(cell "$OUT" "Output quality" N9001 9)" "2"
check "(b) pushes after the first READY" "$(cell "$OUT" "Output quality" N9001 10)" "1"
check "(b) main reds caused by the PR, from the chief doc" "$(cell "$OUT" "Output quality" N9003 11)" "1"
check "(b) a fix-forward within 7 days is an escape" "$(cell "$OUT" "Output quality" N9001 12)" "fix-forward 1"
check "(b) a caused-by bug within 7 days is an escape, a revert at day 11 is not" \
    "$(cell "$OUT" "Output quality" N9003 12)" "caused-by 1"
check "(b) launch to LIVE" "$(cell "$OUT" "Fleet management" N9001 4)" "5m"
check "(b) launch to READY" "$(cell "$OUT" "Fleet management" N9001 5)" "100m"
check "(b) an earlier ruling after a later bullet is not the next day" "$(cell "$OUT" "Fleet management" N9003 5)" "90m"
check "(b) an unmarked bullet is a protocol miss" "$(cell "$OUT" "Fleet management" N9002 8)" "miss: unmarked 1"
check "(b) a chief entry in the doc is inbox delivery" "$(cell "$OUT" "Fleet management" N9002 9)" "inbox"
check "(b) stalls read the BLOCKED bullets and the chief idle ticks" \
    "$(cell "$OUT" "Fleet management" N9001 10) / $(cell "$OUT" "Fleet management" N9004 10)" "idle 1 / blocked 1"
check "(b) guard denials joined by worktree" "$(cell "$OUT" "Fleet management" N9001 11)" "2"
check "(b) an unreadable denial row is reported, not dropped" \
    "$(printf '%s\n' "$OUT" | grep '^- denials:')" "- denials: $FX/denials.jsonl (1 unreadable row)"
check "(b) cost-eq per merged PR from the worker-burn line" "$(cell "$OUT" "Fleet management" N9001 12)" "1200.0k"
check "(b) an in-flight worker is marked" "$(cell "$OUT" "Output quality" N9004 6)" "in flight"
check "(b) a worker with no PR has n/a judge, not 0" "$(cell "$OUT" "Output quality" N9004 7)" "n/a (no PR)"
check "(b) an unmerged worker has n/a cost, not 0" "$(cell "$OUT" "Fleet management" N9004 12)" "n/a (not merged)"

NOLEDGER=$(run --since 2026-10-25T00:00:00Z --cr-ledger "$FX/absent.jsonl" 2>/dev/null)
check "(b) a missing CR ledger is n/a with its reason" \
    "$(cell "$NOLEDGER" "Output quality" N9001 8)" "n/a (no CR ledger: $FX/absent.jsonl)"
check "(b) a missing CR ledger leaves rounds n/a" "$(cell "$NOLEDGER" "Output quality" N9001 9)" "n/a (no CR ledger: $FX/absent.jsonl)"
NOPRS=$("$FLEET" --manifest "$FX/FT-roadmap-chief.fleet.json" --cr-ledger "$FX/cr-ledger.jsonl" \
    --verdicts "$FX/verdicts" --denials "$FX/absent-denials.jsonl" --mirror "$FX/mirror" --tz UTC 2>/dev/null)
check "(b) without --prs the PR column is n/a with its reason" "$(cell "$NOPRS" "Output quality" N9001 5)" "n/a (no --prs)"
check "(b) without --prs the state is n/a, not unmerged" "$(cell "$NOPRS" "Output quality" N9001 6)" "n/a (no --prs)"
check "(b) without --prs the lane merged and in-flight totals are n/a" \
    "$(cell "$NOPRS" "Per lane" claudex 4) / $(cell "$NOPRS" "Per lane" claudex 5)" "n/a / n/a"
check "(b) a missing denial log is n/a with its reason" \
    "$(cell "$NOPRS" "Fleet management" N9001 11)" "n/a (no denial log: $FX/absent-denials.jsonl)"
GONE=$(run --doc "$FX/HIMMEL-9099-N9099-gone-2026-10-25.md" \
    --chief-doc "$FX/FT-roadmap-chief.md" --chief-doc "$FX/absent-chief.md" 2>/dev/null)
check "(b) a missing worker doc leaves its lane merged and in-flight n/a" \
    "$(cell "$GONE" "Per lane" unknown 4) / $(cell "$GONE" "Per lane" unknown 5)" "n/a / n/a"
check "(b) a missing chief doc is named on the Sources line" \
    "$(printf '%s\n' "$GONE" | grep '^- chief docs:')" "- chief docs: $FX/FT-roadmap-chief.md (missing: $FX/absent-chief.md)"

# --- (c) per-lane totals and medians; a total that skips an n/a worker says so,
# and the cost median runs over merged PRs (N9002 merged two), not workers
check "(c) claudex lane row" "$(printf '%s\n' "$OUT" | grep '^| claudex |')" \
    "| claudex | 2 | 2 | 0 | 2 | 1 | 1 | 1 | 2 | 1.5 | 7.5m | 80m | 2 | 1 | 2 | 800.0k |"
check "(c) native lane row" "$(printf '%s\n' "$OUT" | grep '^| native |')" \
    "| native | 2 | 1 | 1 | 1 (n/a 1) | 0 (n/a 1) | 0 (n/a 1) | 0 (n/a 1) | 2 (n/a 1) | 2 | 3.5m | 90m | 3 | 1.5 | 1 | 1600.0k |"
SINCE=$(run --since 2026-10-25T16:05:00Z 2>/dev/null)
check "(c) --since keeps only workers launched at or after it" "$(rows "$SINCE" "Fleet management")" "1"

# --- (d) the report goes to stdout or --out <local path>, nothing else
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-scorecard.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
TOFILE=$(run --out "$TMP/report.md" 2>/dev/null); RC=$?
check "(d) --out exits 0" "$RC" "0"
check "(d) --out prints nothing to stdout" "$TOFILE" ""
check "(d) --out writes the report" "$(grep -c '^| N9001 |' "$TMP/report.md" 2>/dev/null)" "2"
check "(d) --out writes nothing else" "$(ls -A "$TMP")" "report.md"
ERR=$(cd "$TMP" && run --out "https://example.invalid/report.md" 2>&1 >/dev/null); RC=$?
check "(d) an --out URL is refused (exit 2)" "$RC" "2"
check "(d) an --out URL is refused by the scheme guard" \
    "$ERR" "fleet-scorecard: --out is a local path, never a URL: https://example.invalid/report.md"
ERR=$(cd "$TMP" && run --out "gs://bucket/report.md" 2>&1 >/dev/null); RC=$?
check "(d) an --out bucket URI is refused (exit 2)" "$RC" "2"
check "(d) an --out bucket URI is refused by the scheme guard" \
    "$ERR" "fleet-scorecard: --out is a local path, never a URL: gs://bucket/report.md"
check "(d) a refused --out writes nothing in the working dir" "$(ls -A "$TMP")" "report.md"

# --- (b) continued: a source that cannot be read is n/a, never read as another
mkdir -p "$TMP/m" "$TMP/mirror/HIMMEL-1.md"
cp "$FX/FT-roadmap-chief.fleet.json" "$TMP/m/legs.json"
OTHER=$(run --manifest "$TMP/m/legs.json" 2>/dev/null)
check "(b) a manifest not named *.fleet.json is not read as its own chief doc" \
    "$(printf '%s\n' "$OTHER" | grep '^- chief docs:')" "- chief docs: $FX/FT-roadmap-chief.md (missing: $TMP/m/legs.md)"
BADMIRROR=$(run --mirror "$TMP/mirror" 2>/dev/null); RC=$?
check "(b) an unreadable Jira mirror still exits 0" "$RC" "0"
check "(b) an unreadable Jira mirror is n/a with its reason" \
    "$(printf '%s\n' "$BADMIRROR" | grep '^- Jira mirror:')" "- Jira mirror: n/a (unreadable: $TMP/mirror)"

echo
if [ "$fails" -eq 0 ]; then echo "PASS test-fleet-scorecard.sh"; exit 0; fi
echo "FAIL test-fleet-scorecard.sh ($fails)"; exit 1
