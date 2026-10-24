#!/usr/bin/env bash
# scripts/eval/test-review-page.sh - suite for review-page.py, the readable page over the reviewer evals:
# plain sentences and percentages from a fixture eval-runs ledger and eval-changes ledger, with no raw
# field names. Fixture ledgers only: no model, no network, no live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PAGE="$HERE/review-page.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-page-test.XXXXXX")" || { echo "test-review-page: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-runs.jsonl"
export HIMMEL_EVAL_CHANGES_LEDGER="$TMP/never-changes.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-review-page: python3 not on PATH"; exit 0; }

# A review-panel series of two runs (same config), one judge-accuracy run, one measured change.
python3 -I - "$HERE/lib" "$TMP/runs.jsonl" "$TMP/changes.jsonl" <<'PY' || { echo "test-review-page: writing the fixture ledgers failed" >&2; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
cfg = {"fixture_set": "f1", "critics": ["codex", "coderabbit"], "window": 3}
def panel(run_id, codex_recall, codex_fail_open):
    m = {"codex.recall": codex_recall, "codex.precision": 0.7, "codex.fp_rate": 0.25, "codex.findings": 10,
         "codex.clean_scored": 4, "codex.seeded_scored": 5,
         "codex.class.logic.recall": 1.0, "codex.class.logic.n": 3,
         "codex.class.fail-open.recall": codex_fail_open, "codex.class.fail-open.n": 2,
         "coderabbit.recall": 0.8, "coderabbit.precision": 0.5, "coderabbit.fp_rate": 0.0,
         "coderabbit.findings": 8, "coderabbit.clean_scored": 4, "coderabbit.seeded_scored": 5,
         "coderabbit.class.logic.recall": 1.0, "coderabbit.class.logic.n": 3,
         "coderabbit.class.fail-open.recall": 0.5, "coderabbit.class.fail-open.n": 2,
         "defects": 5, "cases": 9, "unscored": 0, "leaked": 0}
    ci = {"codex.recall": {"lo": 0.3, "hi": 0.9}, "coderabbit.recall": {"lo": 0.38, "hi": 0.96}}
    return eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", cfg, m, n=9, run_id=run_id,
                              ci=ci, ci_level=0.95, ci_method="wilson", gitsha="0" * 40)
judge_m = {"flips": 12, "flip_n": 100, "flip_rate": 0.12, "go_merged": 150, "escapes": 3,
           "escapes_plausible": 5, "escape_rate": 0.02, "escape_rate_plausible": 5 / 150,
           "nogo_n": 40, "false_nogo": 1, "false_nogo_plausible": 2, "nogo_candidates": 4,
           "overridden": 2, "procedural": 6, "pending": 2,
           "cause.ci-selection.escapes": 1, "cause.ci-selection.escape_rate": 1 / 150,
           "class.guard.n": 10, "class.guard.escapes": 2, "class.guard.escape_rate": 0.2,
           "class.guard.escape_excess": 0.03, "class.docs.n": 40, "class.docs.escapes": 0,
           "class.docs.escape_rate": 0.0, "class.docs.escape_excess": -0.02,
           "coverage.records": 140, "coverage.no_model": 3}
judge_ci = {"flip_rate": {"lo": 0.07, "hi": 0.2}, "escape_rate": {"lo": 0.007, "hi": 0.057}}
rows = [panel("rp-1", 0.4, 0.0), panel("rp-2", 0.6, 0.5),
        eval_runs.make_row("judge-accuracy", "scripts/eval/judge-accuracy/judge_accuracy.py",
                           {"judge_accuracy_v": 1, "days": 28}, judge_m, n=140, run_id="ja-1", status="partial",
                           ci=judge_ci, ci_level=0.9, ci_method="wilson", gitsha="0" * 40,
                           meta={"since": "2026-09-26T00:00:00Z", "until": "2026-10-24T00:00:00Z"})]
rows[0]["ts"], rows[1]["ts"], rows[2]["ts"] = "2026-10-17T10:00:00Z", "2026-10-24T10:00:00Z", "2026-10-24T11:00:00Z"
with open(sys.argv[2], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
base = {"v": 1, "host": "h", "source": "scripts/eval/lib/eval_feedback.py", "kind": "eval-change",
        "id": "rp-1:codex.class.fail-open.recall", "eval": "review-panel", "metric": "codex.class.fail-open.recall"}
changes = [dict(base, ts="2026-10-17T11:00:00Z", status="open", value=0.0, threshold=0.5, better="higher",
                absent=None, change="prompt", target="scripts/cr/critic-first-pass.sh", baseline_run_id="rp-1",
                confighash=rows[0]["confighash"], critic="codex"),
           dict(base, ts="2026-10-24T10:05:00Z", status="measured", before=0.0, after=0.5, delta=0.5,
                verdict="improved", after_run_id="rp-2"),
           dict(base, id="fr-1:over_deny:x", eval="friction", metric="over_deny:x", ts="2026-10-24T09:00:00Z",
                status="open", value=200, threshold=100, better="lower", absent=0, change="learning",
                target="shell-and-gate-traps.md", baseline_run_id="fr-1", confighash="c", critic=None)]
with open(sys.argv[3], "w") as fh:
    for c in changes:
        fh.write(json.dumps(c) + "\n")
PY

out="$(python3 -I "$PAGE" --ledger "$TMP/runs.jsonl" --changes "$TMP/changes.jsonl" 2>&1)"; rc=$?
eq "page: exit 0" "$rc" "0"
has "critics: the range level comes from the run" "$out" "Ranges are 95 % ranges."
has "judges: the range level comes from the run" "$out" "Ranges are 90 % ranges."
case "$out" in *"is the 95 % range"*) fail "no fixed range level in the header";; *) pass "no fixed range level in the header";; esac
has "header: says a trend compares with the run before" "$out" "a trend compares it with the run before"
has "critic: planted bugs caught, as a count and a percentage" "$out" "The codex critic caught 3 of 5 planted bugs: 60 % (likely between 30 % and 90 %)"
has "critic: trend since the last run" "$out" "up 20 points since the last run (40 %)"
has "critic: right N times in M" "$out" "The codex critic was right 7 times in 10"
has "CodeRabbit: planted bugs caught" "$out" "CodeRabbit caught 4 of 5 planted bugs: 80 %"
has "critic: weakest kind of bug in plain words" "$out" "fail-open guards (a check that lets an error through), caught 1 of 2"
has "critic: false alarms on clean changes" "$out" "raised a blocking finding on 1 of 4 clean changes"
has "judges: changed their first answer" "$out" "The judges changed their first answer 12 times in 100: 12 % (likely between 7 % and 20 %)"
has "judges: bugs past a GO" "$out" "A bug got past a GO on 3 of 150 merged PRs: 2 %"
has "judges: wrong NO-GO" "$out" "A NO-GO was wrong 1 time in 40"
has "judges: worse area named only when it is worse" "$out" "guard changes: a bug got past 2 of 10"
case "$out" in *"docs changes"*) fail "judges: an area that is not worse is not named";; *) pass "judges: an area that is not worse is not named";; esac
has "judges: a partial run says the numbers may move" "$out" "2 possible bugs still wait for a ruling"
has "change: what was changed, and whether it helped" "$out" "Changed the codex critic's prompt"
has "change: re-measured delta" "$out" "from 0 % to 50 %, up 50 points: it helped"
case "$out" in *friction*) fail "change: a change to an eval that is not a reviewer is left off";; *) pass "change: a change to an eval that is not a reviewer is left off";; esac

# No raw field name: no metric or interval key from the fixture rows, no dotted or snake_case identifier.
leak="$(printf '%s' "$out" | python3 -I -c 'import json, re, sys
page = sys.stdin.read()
keys = set()
for line in open(sys.argv[1]):
    r = json.loads(line)
    keys |= set(r["metrics"]) | set(r["ci"])
for line in open(sys.argv[2]):
    keys.add(json.loads(line)["metric"])
hits = sorted(k for k in keys if re.search(r"(?<![\w.-])%s(?![\w-])" % re.escape(k), page))
hits += re.findall(r"\b[a-z]+(?:[._][a-z0-9-]+)+\b", page)
print(" ".join(hits))' "$TMP/runs.jsonl" "$TMP/changes.jsonl")"; rc=$?
eq "the field-name check ran" "$rc" "0"
eq "no raw field names on the page" "$leak" ""
case "$out" in *'`'*) fail "no code spans on the page";; *) pass "no code spans on the page";; esac

out="$(python3 -I "$PAGE" --ledger "$TMP/absent.jsonl" --changes "$TMP/absent-changes.jsonl" 2>&1)"; rc=$?
eq "no ledger: exit 0" "$rc" "0"
eq "no ledger: both sections say there is no run yet" "$(printf '%s\n' "$out" | grep -c 'No run yet')" "2"

cp "$TMP/changes.jsonl" "$TMP/bad-changes.jsonl"
printf '%s\n' '{"status":"measured"}' '{"status":"open","eval":"review-panel","metric":null}' '7' >> "$TMP/bad-changes.jsonl"
out="$(python3 -I "$PAGE" --ledger "$TMP/runs.jsonl" --changes "$TMP/bad-changes.jsonl" 2>&1)"; rc=$?
eq "malformed change records: exit 0" "$rc" "0"
has "malformed change records: the good change still shows" "$out" "Changed the codex critic's prompt"

python3 -I "$PAGE" --ledger "$TMP/runs.jsonl" --changes "$TMP/changes.jsonl" --out "$TMP/page.md" >/dev/null 2>&1
eq "--out writes the page" "$(head -1 "$TMP/page.md" 2>/dev/null)" "# How good are our reviewers?"

echo "test-review-page: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
