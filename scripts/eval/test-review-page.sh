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
                              ci=ci, ci_level=0.95, ci_method="wilson", gitsha="0" * 40,
                              meta={"scorer_sha256": "a" * 64})
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
d158 = {"q1.pct": 0.75, "q1.k": 3, "q1.n": 4, "q1.before.pct": 0.5, "q1.before.k": 1, "q1.before.n": 2,
        "q2.pct": 0.3, "q2.k": 30, "q2.n": 100, "q2.before.pct": 0.4, "q2.before.k": 40, "q2.before.n": 100,
        "q3.pct": 0.9, "q3.k": 9, "q3.n": 10}
d158_ci = {"q1.pct": {"lo": 0.3, "hi": 0.95}, "q2.pct": {"lo": 0.22, "hi": 0.4}, "q3.pct": {"lo": 0.6, "hi": 0.98}}
rows.append(eval_runs.make_row("decision-158", "scripts/eval/decision-158-answers.py", {"answers_v": 1}, d158, n=114,
                               run_id="d158-1", ci=d158_ci, ci_level=0.95, ci_method="wilson", gitsha="0" * 40,
                               meta={"notes": {"q3": "verdicts by one judge model"}}))
rows[3]["ts"] = "2026-10-24T12:00:00Z"
pdd = {"pdd.pct": 0.1083, "pdd.k": 13, "pdd.n": 120, "ticket_first.pct": 0.1917, "ticket_first.k": 23,
       "ticket_first.n": 120, "red_green.pct": 0.5917, "red_green.k": 71, "red_green.n": 120}
pdd_ci = {"pdd.pct": {"lo": 0.0644, "hi": 0.1766}, "ticket_first.pct": {"lo": 0.1313, "hi": 0.2712},
          "red_green.pct": {"lo": 0.5022, "hi": 0.6754}}
rows.append(eval_runs.make_row("pdd-share", "scripts/eval/worker-digest/pdd_share.py", {"pdd_v": 1, "prs": 120, "min_n": 50},
                               pdd, n=120, run_id="pdd-1", ci=pdd_ci, ci_level=0.95, ci_method="wilson", gitsha="0" * 40))
rows[4]["ts"] = "2026-10-24T23:52:30Z"
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
has "header: points at the glossary of what each number means" "$out" "What each number means, with its ledger key: scripts/eval/README.md."
has "critic: labelled target defects key-matched, as a count and a percentage" "$out" "The codex critic key-matched 3 of 5 labelled target defects: 60 % (likely between 30 % and 90 %)"
has "critic: trend since the last run" "$out" "up 20 points since the last run (40 %)"
has "proxy_names: findings that key-matched a labelled defect, N in M" "$out" "The codex critic: 7 of 10 findings key-matched a labelled defect"
case "$out" in *"was right"*) fail "proxy_names: a keyword match is never 'was right'";; *) pass "proxy_names: a keyword match is never 'was right'";; esac
has "proxy_names: the page says the numbers are automated key-match proxies" "$out" "automated key-match proxies"
has "CodeRabbit: labelled target defects key-matched" "$out" "CodeRabbit key-matched 4 of 5 labelled target defects: 80 %"
has "critic: weakest kind of bug in plain words" "$out" "fail-open guards (a check that lets an error through), key-matched 1 of 2"
has "proxy_names: labelled-clean blocking" "$out" "labelled-clean blocking on 1 of 4 labelled-clean changes"
has "judges: changed their first answer" "$out" "The judges changed their first answer 12 times in 100: 12 % (likely between 7 % and 20 %)"
has "judges: bugs past a GO" "$out" "A bug got past a GO on 3 of 150 merged PRs: 2 %"
has "judges: wrong NO-GO" "$out" "A NO-GO was wrong 1 time in 40"
has "judges: worse area named only when it is worse" "$out" "guard changes: a bug got past 2 of 10"
case "$out" in *"docs changes"*) fail "judges: an area that is not worse is not named";; *) pass "judges: an area that is not worse is not named";; esac
has "judges: a partial run says the numbers may move" "$out" "2 possible bugs still wait for a ruling"
has "legacy_measurement_unverified: a measured change with no application receipt is a historical delta" "$out" "Historical delta; application unverified: a change to the codex critic's prompt"
has "legacy_measurement_unverified: the delta is shown, not credited" "$out" "from 0 % to 50 %, up 50 points, but no application receipt binds that run to the change"
case "$out" in *": it helped"*|*"Changed the codex"*) fail "legacy_measurement_unverified: no causal claim without a receipt";; *) pass "legacy_measurement_unverified: no causal claim without a receipt";; esac
case "$out" in *friction*) fail "change: a change to an eval that is not a reviewer is left off";; *) pass "change: a change to an eval that is not a reviewer is left off";; esac

has "answers: a question with its percentage, range and sample" "$out" "Do agents write the failing test before the code? 75 % (likely between 30 % and 95 %) of 4 sessions"
has "answers: the earlier figure and the move" "$out" "was 50 % before, up 25 points"
has "answers: a falling figure reads as down" "$out" "was 40 % before, down 10 points"
has "answers: a question with no earlier figure says so" "$out" "no earlier figure yet"
has "answers: a question with no data says not measured" "$out" "Is CodeRabbit right often enough to keep? Not measured yet"
has "answers: the note rides along" "$out" "verdicts by one judge model"
has "answers: the judge question counts merged PRs, not verdicts" "$out" "matter? 90 % (likely between 60 % and 98 %) of 10 merged PRs"

has "proof first: says what counts as proof-first" "$out" "A merged PR counts as proof-first when"
has "proof first: says why the number matters" "$out" "It matters because"
has "proof first: says the RED and GREEN half is self-reported" "$out" "Self-reported: RED and GREEN are words the PR author wrote, not a test run this eval checked."
eq "proof first: the section reads proof-first share (self-reported)" "$(printf '%s\n' "$out" | grep -c '^## Proof-first share (self-reported)$')" "1"
has "proof first: the share as a count, a percentage and a range" "$out" "- Proof-first share (self-reported): 13 of 120 merged PRs: 11 % (likely between 6 % and 18 %)"
case "$out" in *"Proof first"*) fail "proof first: the old display name is gone";; *) pass "proof first: the old display name is gone";; esac
has "proof first: the ticket half on its own" "$out" "The ticket was written first: 23 of 120: 19 % (likely between 13 % and 27 %)"
has "proof first: the RED-then-GREEN half on its own" "$out" "RED then GREEN named in the PR body: 71 of 120: 59 % (likely between 50 % and 68 %)"

# Bottom line: the first section, each eval's headline with its run day.
bottom="$(printf '%s\n' "$out" | awk '/^## /{n++} n==1')"
eq "bottom line: the first section" "$(printf '%s\n' "$out" | grep -m1 '^## ')" "## Bottom line"
has "bottom line: the key-match catch with its run day" "$bottom" "- The codex critic key-matched 3 of 5 labelled target defects: 60 % (likely between 30 % and 90 %), up 20 points since the last run (40 %). Run of 24 Oct 2026."
eq "bottom line: bugs past a GO with its run day" "$(printf '%s\n' "$bottom" | grep -c '^- A bug got past a GO on 3 of 150 merged PRs: 2 % .*\. Run of 24 Oct 2026\.$')" "1"
has "bottom line: proof first with its run day" "$bottom" "- Proof-first share (self-reported): 13 of 120 merged PRs: 11 % (likely between 6 % and 18 %). Run of 24 Oct 2026."
has "proof first: the sample counts PRs whose ticket and commits could be read" "$out" "the last 120 merged PRs whose ticket and commits could be read."
eq "bottom line: one line per eval" "$(printf '%s\n' "$bottom" | grep -c '^- ')" "3"

python3 -I - "$HERE/lib" "$TMP" <<'PY' || { echo "test-review-page: writing the scorer-trend ledgers failed" >&2; exit 1; }
import json, os, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
def row(run_id, ts, recall, scorer):
    meta = {} if scorer is None else {"scorer_sha256": scorer}
    r = eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", {"fixture_set": "f1", "critics": ["codex"]},
                           {"codex.recall": recall, "codex.class.logic.recall": recall, "codex.class.logic.n": 5}, n=5,
                           run_id=run_id, gitsha="0" * 40, meta=meta)
    r["ts"] = ts
    return r
for name, prev in (("same", "a" * 64), ("other", "b" * 64), ("missing", None)):
    rows = [row("t-1", "2026-10-17T10:00:00Z", 0.4, prev), row("t-2", "2026-10-24T10:00:00Z", 0.6, "a" * 64)]
    open(os.path.join(sys.argv[2], "trend-%s.jsonl" % name), "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
trend() { python3 -I "$PAGE" --ledger "$TMP/trend-$1.jsonl" --changes "$TMP/absent-changes.jsonl" 2>&1 | grep -c 'since the last run'; }
eq "page_trend_requires_same_scorer: one known scorer on both rows shows the trend" "$(trend same)" "2"
eq "page_trend_requires_same_scorer: another scorer on the earlier row shows no trend" "$(trend other)" "0"
eq "page_trend_requires_same_scorer: an earlier row with no scorer identity shows no trend" "$(trend missing)" "0"

python3 -I - "$HERE/lib" "$TMP" <<'PY' || { echo "test-review-page: writing the revision ledgers failed" >&2; exit 1; }
import json, os, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
def row(run_id, ts, recall, ex, sup=None):
    meta = {"scorer_sha256": "a" * 64, "execution_id": ex}
    if sup:
        meta["supersedes_run_id"] = sup
    r = eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", {"fixture_set": "f1", "critics": ["codex"]},
                           {"codex.recall": recall, "codex.class.logic.recall": recall, "codex.class.logic.n": 5}, n=5,
                           run_id=run_id, gitsha="0" * 40, meta=meta)
    r["ts"] = ts
    return r
def put(name, rows):
    open(os.path.join(sys.argv[2], name), "w").write("".join(json.dumps(r) + "\n" for r in rows))
put("rev-head.jsonl", [row("t-1", "2026-10-17T10:00:00Z", 0.4, "x1"), row("t-2", "2026-10-24T10:00:00Z", 0.6, "x2"),
                       row("t-2r", "2026-11-09T10:00:00Z", 0.8, "x2", "t-2")])
put("rev-old.jsonl", [row("t-1", "2026-10-17T10:00:00Z", 0.4, "x1"), row("t-2", "2026-10-24T10:00:00Z", 0.6, "x2"),
                      row("t-1r", "2026-11-09T10:00:00Z", 0.9, "x1", "t-1")])
put("rev-cycle.jsonl", [row("t-1", "2026-10-17T10:00:00Z", 0.4, "x1"), row("t-2", "2026-10-24T10:00:00Z", 0.6, "x2", "t-2b"),
                        row("t-2b", "2026-11-09T10:00:00Z", 0.8, "x2", "t-2")])
PY
revpage() { python3 -I "$PAGE" --ledger "$TMP/$1.jsonl" --changes "$TMP/absent-changes.jsonl" 2>&1; }
has "revision_not_prev_run: the trend is against the previous execution, not the rescored source" "$(revpage rev-head)" "up 40 points since the last run (40 %)"
has "revision_not_prev_run: a rescore of an older execution stays at that execution's place: the newest run is the later one" "$(revpage rev-old)" "down 30 points since the last run (90 %)"
case "$(revpage rev-cycle)" in *"since the last run"*) fail "supersession_cycle: a cycle's rows were read as a series";; *) pass "supersession_cycle: the ambiguous execution is set aside, no trend from it";; esac

# CodeRabbit absent from the critic list: the page says it is not measured, never a silent gap.
python3 -I - "$HERE/lib" "$TMP/codex-only.jsonl" <<'PY' || { echo "test-review-page: writing the codex-only ledger failed" >&2; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
m = {"codex.recall": 0.6, "codex.precision": 0.7, "codex.findings": 10, "codex.class.logic.recall": 0.6, "codex.class.logic.n": 5,
     "panel.recall": 0.8, "panel.class.logic.recall": 0.8, "panel.class.logic.n": 5}
row = eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", {"critics": ["codex"]}, m, n=5,
                         run_id="rp-c", gitsha="0" * 40)
open(sys.argv[2], "w").write(json.dumps(row) + "\n")
PY
out2="$(python3 -I "$PAGE" --ledger "$TMP/codex-only.jsonl" --changes "$TMP/absent-changes.jsonl" 2>&1)"
has "CodeRabbit: history reported separately, controlled recall not measured here" "$out2" "CodeRabbit history is reported separately; controlled recall is not measured here"
has "bottom line: the whole panel's catch when it was scored" "$(printf '%s\n' "$out2" | awk '/^## /{n++} n==1')" "- The whole panel key-matched 4 of 5 labelled target defects"

# A run that scored nothing still shows in the Bottom line, with its run day.
python3 -I - "$HERE/lib" "$TMP/unscored.jsonl" <<'PY' || { echo "test-review-page: writing the unscored ledger failed" >&2; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
rows = [eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", {"critics": ["codex"]}, {"codex.recall": None},
                           n=0,
                           run_id="rp-u", status="partial", gitsha="0" * 40),
        eval_runs.make_row("pdd-share", "scripts/eval/worker-digest/pdd_share.py", {"pdd_v": 1, "prs": 3, "min_n": 50},
                           {"pdd.pct": None},
                           n=0, run_id="pdd-u", status="partial", gitsha="0" * 40)]
rows[0]["ts"], rows[1]["ts"] = "2026-10-23T10:00:00Z", "2026-10-25T01:00:00Z"
open(sys.argv[2], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
bottom3="$(python3 -I "$PAGE" --ledger "$TMP/unscored.jsonl" --changes "$TMP/absent-changes.jsonl" 2>&1 | awk '/^## /{n++} n==1')"
has "bottom line: an unscored key-match run is not dropped" "$bottom3" "- Labelled target defects (key match): no score in this run. Run of 23 Oct 2026."
has "bottom line: an unscored proof-first run is not dropped" "$bottom3" "- Proof-first share (self-reported): no score in this run. Run of 25 Oct 2026."

# The answers script: five questions from fixture ledgers, before and after a cut.
python3 -I - "$HERE/lib" "$TMP/ans-runs.jsonl" "$TMP/cr.jsonl" <<'PY' || { echo "test-review-page: writing the answers fixtures failed" >&2; exit 1; }
import json, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
def row(ev, ts, m, tv=None, **kw):
    cfg = {"k": 1} if tv is None else {"k": 1, "trajectory_v": tv}
    r = eval_runs.make_row(ev, "t", cfg, m, n=kw.pop("n", 1), gitsha="0" * 40, **kw)
    r["ts"] = ts
    return r
rows = [row("leg-trajectory", "2026-10-20T00:00:00Z", {"red_before_green": 1}, tv=2),
        row("leg-trajectory", "2026-10-21T00:00:00Z", {"red_before_green": 0}, tv=2),
        row("leg-trajectory", "2026-10-21T01:00:00Z", {"red_before_green": None}, tv=2),
        row("leg-trajectory", "2026-10-23T00:00:00Z", {"red_before_green": 1}, tv=2),
        row("leg-trajectory", "2026-10-23T01:00:00Z", {"red_before_green": 1}, tv=2),
        row("leg-trajectory", "2026-10-22T00:00:00Z", {"red_before_green": 1}, tv=2),
        row("leg-trajectory", "2026-10-20T12:00:00Z", {"red_before_green": 0}, tv=1),
        row("leg-trajectory", "2026-10-23T12:00:00Z", {"red_before_green": 0}, tv=1),
        row("friction", "2026-10-22T00:00:00Z", {"refusals": 100, "unclear": 40}),
        row("friction", "2026-10-24T12:00:00Z", {"refusals": 100, "unclear": 30}),
        row("judge-accuracy", "2026-10-24T12:00:00Z", {"model.claude-opus-5-5.n": 9, "model.sonnet.n": 1, "model.unknown.n": 4})]
# A refresh re-records a session under its own run_id and original ts; an older restamp re-recorded one with a later
# ts. Neither is a new session: q1 counts each run_id once, at its first ok record time.
refreshed = dict(rows[0], meta=dict(rows[0]["meta"], refreshed_at="2026-10-30T00:00:00Z"))
restamped = dict(rows[1], ts="2026-10-25T00:00:00Z")
rows += [refreshed, restamped]
with open(sys.argv[2], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
def fin(ts, fid, verdict, br):
    return [{"kind": "finding", "ts": ts, "branch": br, "head": "h", "model": "coderabbit", "finding_id": fid, "severity": "imp",
             "file": "a", "line": 1, "verdict": "", "artifact": "diff", "perspective": "off", "text": fid},
            {"kind": "amend", "ts": ts, "branch": br, "target_head": "h", "finding_id": fid, "artifact": "diff",
             "perspective": "off", "set": {"verdict": verdict}, "reason": "r"}]
cr = fin("2026-10-10T00:00:00Z", "c1", "fixed", "b1") + fin("2026-10-11T00:00:00Z", "c2", "fixed", "b2") + \
    fin("2026-10-12T00:00:00Z", "c3", "disproved", "b3") + fin("2026-10-23T00:00:00Z", "c4", "fixed", "b4")
with open(sys.argv[3], "w") as fh:
    for r in cr:
        fh.write(json.dumps(r) + "\n")
PY
ans="$(python3 -I "$HERE/decision-158-answers.py" --ledger "$TMP/ans-runs.jsonl" --cr-ledger "$TMP/cr.jsonl" --cut 2026-10-22T00:00:00Z 2>&1)"; rc=$?
eq "answers: exit 0" "$rc" "0"
pick() { printf '%s' "$ans" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["metrics"].get(sys.argv[1]))' "$1"; }
eq "answers q1: sessions that ran a test, no-test sessions left out" "$(pick q1.n)" "5"
eq "answers q1: test-first count" "$(pick q1.k)" "4"
eq "answers q1: the earlier figure includes a row at the cut, like the others" "$(pick q1.before.n)" "3"
eq "answers q2: unclear share of the newest window" "$(pick q2.pct)" "0.3"
eq "answers q2: the window at the cut" "$(pick q2.before.pct)" "0.4"
eq "answers q3: share of the most used judge model, unknown left out" "$(pick q3.pct)" "0.9"
eq "answers q4: CodeRabbit right 3 of 4 adjudicated" "$(pick q4.pct)" "0.75"
eq "answers q4: the earlier figure stops at the cut" "$(pick q4.before.pct)" "0.6667"
eq "answers q5: no Claude critic findings means no figure" "$(pick q5.pct)" "None"
miss="$(python3 -I "$HERE/decision-158-answers.py" --ledger "$TMP/ans-runs.jsonl" --cr-ledger "$TMP/no-such-cr.jsonl" 2>&1 >/dev/null)"
eq "answers: an unreadable CR ledger is named on stderr, not silently an empty sample" "$(printf '%s' "$miss" | grep -c 'coderabbit measurement unavailable')" "2"
python3 -I "$HERE/decision-158-answers.py" --ledger "$TMP/ans-runs.jsonl" --cr-ledger "$TMP/cr.jsonl" --record >/dev/null 2>&1
eq "answers --record appends one decision-158 row" "$(grep -c decision-158 "$TMP/ans-runs.jsonl")" "1"
eq "answers --record of a complete measurement is an ok row" "$(grep decision-158 "$TMP/ans-runs.jsonl" | grep -c '"status":"ok"')" "1"
cp "$TMP/ans-runs.jsonl" "$TMP/ans-partial.jsonl"
python3 -I "$HERE/decision-158-answers.py" --ledger "$TMP/ans-partial.jsonl" --cr-ledger "$TMP/no-such-cr.jsonl" --record >/dev/null 2>&1; rc=$?
eq "answers --record with an unreadable CR ledger exits 3" "$rc" "3"
eq "answers --record with an unreadable CR ledger writes a partial row that names the gap" "$(grep decision-158 "$TMP/ans-partial.jsonl" | tail -n 1 | grep -c '"status":"partial".*coderabbit')" "1"
# The default CR ledger is found from the script's own checkout, not from the caller's directory (cron runs from $HOME).
dflt="$(cd "$TMP" && env -u CR_LEDGER python3 -I -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("d158", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
p = m.default_cr_ledger()
print("ok" if p and os.path.isabs(p) and os.path.basename(p) == "cr-critic-scores.jsonl" and os.path.isdir(os.path.dirname(p)) else "bad:%s" % p)' "$HERE/decision-158-answers.py" 2>&1)"
eq "answers: with CR_LEDGER unset and the caller outside any repo, the CR ledger path is still found" "$dflt" "ok"

# No raw field name: no metric or interval key from the fixture rows, no dotted or snake_case identifier.
leak="$(printf '%s' "$out" | python3 -I -c 'import json, re, sys
page = sys.stdin.read()
PAGE_WORDS_THAT_ARE_ALSO_KEYS = {"defects"}
keys = set()
for line in open(sys.argv[1]):
    r = json.loads(line)
    keys |= set(r["metrics"]) | set(r["ci"])
for line in open(sys.argv[2]):
    keys.add(json.loads(line)["metric"])
keys -= PAGE_WORDS_THAT_ARE_ALSO_KEYS
hits = sorted(k for k in keys if re.search(r"(?<![\w.-])%s(?![\w-])" % re.escape(k), page))
hits += re.findall(r"\b[a-z]+(?:[._][a-z0-9-]+)+\b", page)
print(" ".join(hits))' "$TMP/runs.jsonl" "$TMP/changes.jsonl")"; rc=$?
eq "the field-name check ran" "$rc" "0"
eq "no raw field names on the page" "$leak" ""
case "$out" in *'`'*) fail "no code spans on the page";; *) pass "no code spans on the page";; esac

out="$(python3 -I "$PAGE" --ledger "$TMP/absent.jsonl" --changes "$TMP/absent-changes.jsonl" 2>&1)"; rc=$?
eq "no ledger: exit 0" "$rc" "0"
for sec in "Bottom line" "The critics on labelled test changes" "The judges" "The five open questions" "Proof-first share (self-reported)"; do
    eq "no ledger: '$sec' says there is no run yet" "$(printf '%s\n' "$out" | awk -v h="## $sec" '/^## /{on=($0==h)} on' | grep -c '^No run yet\.$')" "1"
done

cp "$TMP/changes.jsonl" "$TMP/bad-changes.jsonl"
printf '%s\n' '{"status":"measured"}' '{"status":"open","eval":"review-panel","metric":null}' '7' >> "$TMP/bad-changes.jsonl"
out="$(python3 -I "$PAGE" --ledger "$TMP/runs.jsonl" --changes "$TMP/bad-changes.jsonl" 2>&1)"; rc=$?
eq "malformed change records: exit 0" "$rc" "0"
has "malformed change records: the good change still shows" "$out" "a change to the codex critic's prompt"

python3 -I - "$TMP/m6-changes.jsonl" <<'PY' || { echo "test-review-page: writing the M6 changes ledger failed" >&2; exit 1; }
import json, sys
A, B = "c" * 40, "d" * 40
H0, H1 = "0" * 64, "1" * 64
def rec(cid, **kw):
    return dict({"v": 1, "host": "h", "source": "scripts/eval/lib/eval_feedback.py", "kind": "eval-change", "id": cid,
                 "eval": "review-panel", "metric": "codex.class.%s.recall" % cid}, **kw)
def opened(cid, critic="codex"):
    return rec(cid, ts="2026-11-01T10:00:00Z", status="open", value=0.0, threshold=0.5, better="higher", absent=None,
               change="prompt", target="scripts/cr/critic-first-pass.sh", baseline_run_id="rp", confighash="c",
               critic=critic, per=None, min_gain=0.25)
def applied(cid, commit=A):
    return rec(cid, ts="2026-11-02T10:00:00Z", status="applied", applied_at="2026-11-02T10:00:00Z",
               before_cbs_hash=H0, after_cbs_hash=H1, commit=commit, target_paths=["scripts/cr/critic-first-pass.sh"],
               diff_sha256=H1)
def measured(cid, verdict, commit=A, **kw):
    return rec(cid, ts="2026-11-03T10:00:00Z", status="measured", before=0.0, after=kw.pop("after", 0.5),
               delta=0.5, verdict=verdict, after_run_id="rp2", applied_commit=commit, after_cbs_hash=H1, **kw)
rows = [opened("logic"),
        opened("quoting"), applied("quoting"),
        opened("toctou"), applied("toctou"), measured("toctou", "keep", reason="train and test up"),
        opened("fail-open"), applied("fail-open"), measured("fail-open", "revert", after=0.0, reason="train not up"),
        opened("scope-creep"), applied("scope-creep"), measured("scope-creep", "inconclusive", after=None,
                                                                reason="participation differs"),
        opened("test-cannot-fail"), applied("test-cannot-fail", commit=B), measured("test-cannot-fail", "keep"),
        dict(rec("judge", eval="judge-accuracy", metric="class.guard.escape_excess"), ts="2026-11-01T10:00:00Z",
             status="open", value=0.04, threshold=0, better="lower", absent=None, change="prompt",
             target="docs/handover/judge-brief-template.md", baseline_run_id="ja", confighash="j", critic="judge")]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
m6="$(python3 -I "$PAGE" --ledger "$TMP/absent.jsonl" --changes "$TMP/m6-changes.jsonl" 2>&1)"
m6line() { printf '%s\n' "$m6" | grep -F "$1"; }
has "open_is_proposed_not_changed: an open change is proposed" "$(m6line 'logic slips')" "- Proposed, not applied: a change to the codex critic's prompt after the run of 1 Nov 2026"
has "open_is_proposed_not_changed: no later run is credited to it" "$(m6line 'logic slips')" "No application receipt yet, so no later run is credited to it."
case "$(m6line 'logic slips')" in *Changed*) fail "open_is_proposed_not_changed: never 'Changed'";; *) pass "open_is_proposed_not_changed: never 'Changed'";; esac
has "keep_revert_render: an applied change awaits a measurement" "$(m6line 'quoting slips')" "- Applied, awaiting measurement: a change to the codex critic's prompt"
has "keep_revert_render: the applied line names its commit and day" "$(m6line 'quoting slips')" "applied in commit cccccccccccc on 2 Nov 2026"
has "keep_revert_render: measured-keep" "$(m6line 'races')" "- Measured, keep: a change to the codex critic's prompt"
has "keep_revert_render: keep shows the measured run's move" "$(m6line 'races')" "The measured run at the applied version: from 0 % to 50 %, up 50 points"
has "keep_revert_render: keep is a recommendation, no action" "$(m6line 'races')" "Keep is a recommendation: nothing was merged, deployed or reverted by it."
has "keep_revert_render: measured-revert" "$(m6line 'fail-open guards')" "- Measured, revert: a change to the codex critic's prompt"
has "keep_revert_render: revert is a recommendation, nothing reverted" "$(m6line 'fail-open guards')" "Revert is a recommendation: nothing was reverted by it."
has "keep_revert_render: inconclusive" "$(m6line 'unannounced changes')" "- Inconclusive: a change to the codex critic's prompt"
has "keep_revert_render: inconclusive shows its reason" "$(m6line 'unannounced changes')" "The measured run at the applied version settles nothing: participation differs."
has "keep_revert_render: revert shows its reason" "$(m6line 'fail-open guards')" "(train not up)"
has "legacy_measurement_unverified: a measurement naming a commit with no matching receipt is unverified" "$(m6line 'tests that cannot fail')" "- Historical delta; application unverified"
has "other_eval_unchanged: a judge change reads as before" "$m6" "- Changed the judges' prompt after the run of 1 Nov 2026"
STUB="$TMP/git-stub"; mkdir -p "$STUB"
printf '#!/bin/sh\necho "$@" >>"%s/calls"\nexit 1\n' "$STUB" >"$STUB/git"; chmod +x "$STUB/git"
stubbed="$(PATH="$STUB:$PATH" python3 -I "$PAGE" --ledger "$TMP/absent.jsonl" --changes "$TMP/m6-changes.jsonl" 2>&1)"; rc=$?
eq "keep_revert_render: the page renders with git stubbed out: exit 0" "$rc" "0"
has "keep_revert_render: the stubbed render shows keep" "$stubbed" "- Measured, keep:"
has "keep_revert_render: the stubbed render shows revert" "$stubbed" "- Measured, revert:"
eq "keep_revert_render: rendering keep and revert runs no git operation" "$(cat "$STUB/calls" 2>/dev/null)" ""
eq "keep_revert_render: the page spawns no process by any path" "$(grep -cE 'subprocess|os\.system|os\.popen|os\.exec' "$PAGE")" "0"

python3 -I "$PAGE" --ledger "$TMP/runs.jsonl" --changes "$TMP/changes.jsonl" --out "$TMP/page.md" >/dev/null 2>&1
eq "--out writes the page" "$(head -1 "$TMP/page.md" 2>/dev/null)" "# How good are our reviewers?"

# --panel: the CR ledger's headline, one count per finding. PR b1 raises one claim three times (codex at
# heads h1 and h2, CodeRabbit at h2) and one other claim; PR b2 has a deferral and two findings with no
# text on one line; PR b3 was reviewed and drew nothing.
python3 -I - "$TMP/cr-panel.jsonl" <<'PY' || { echo "test-review-page: writing the panel CR ledger failed" >&2; exit 1; }
import json, sys
def fin(br, head, model, fid, line, text, ts, sev="imp"):
    r = {"kind": "finding", "ts": ts, "branch": br, "head": head, "model": model, "finding_id": fid, "severity": sev,
         "file": "a.sh", "line": line, "verdict": "", "artifact": "diff", "perspective": "off"}
    if text is not None:
        r["text"] = text
    return r
def amend(br, head, fid, verdict, ts="2026-10-20T00:00:00Z"):
    return {"kind": "amend", "ts": ts, "branch": br, "target_head": head, "finding_id": fid, "artifact": "diff",
            "perspective": "off", "set": {"verdict": verdict}, "reason": "r"}
rows = [
    fin("b1", "h1", "codex", "codex-1", 3, "- [imp]: The guard fails open on an empty file [a.sh:3]", "2026-10-10T00:00:00Z"),
    amend("b1", "h1", "codex-1", "fixed"),
    fin("b1", "h2", "codex", "codex-1", 3, "- [imp]: the guard fails open on an empty file. [a.sh:3]", "2026-10-11T00:00:00Z"),
    amend("b1", "h2", "codex-1", "disproved"),
    fin("b1", "h2", "coderabbit", "coderabbit-7", 3, "The guard fails OPEN on an empty file", "2026-10-11T00:00:01Z"),
    fin("b1", "h1", "codex", "codex-2", 9, "- [sug]: A second claim", "2026-10-10T00:00:00Z", sev="sug"),
    amend("b1", "h1", "codex-2", "disproved"),
    fin("b2", "k1", "codex", "codex-1", 5, "- [imp]: Deferred claim", "2026-10-12T00:00:00Z"),
    amend("b2", "k1", "codex-1", "deferred"),
    fin("b2", "k1", "codex", "codex-2", 7, None, "2026-10-12T00:00:00Z"),
    fin("b2", "k1", "codex", "codex-3", 7, None, "2026-10-12T00:00:00Z"),
    {"kind": "avail", "ts": "2026-10-13T00:00:00Z", "branch": "b3", "head": "m1", "model": "codex", "status": "ok",
     "artifact": "diff", "perspective": "off", "responding_model": "gpt-6.1-sol"},
    fin("b9", "z1", "codex", "codex-1", 1, "- [imp]: After the cut", "2026-10-26T00:00:00Z"),
]
with open(sys.argv[1], "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
panel="$(python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-panel.jsonl" --until 2026-10-25T00:00:00Z --min-findings 1 2>&1)"; rc=$?
eq "panel: exit 0" "$rc" "0"
has "panel: states the as-of date" "$panel" "As of 25 Oct 2026"
has "panel: a claim re-raised across rounds and reviewers counts once" "$panel" "5 distinct findings across 2 PRs"
has "panel: says how many rows were repeats" "$panel" "7 finding rows"
has "panel: per-PR numbers" "$panel" "3 PRs reviewed, 2 with at least one finding"
has "panel: findings per PR" "$panel" "median 2.5 and mean 2.5 distinct findings per PR with findings"
has "panel: a merged finding takes its first raise's verdict" "$panel" "| **All** | **5** | **2** | **1** | **1** | **1** | **2** |"
has "panel: the merged finding counts for each critic that raised it" "$panel" "| \`coderabbit\` | 1 | 1 | 1 | 0 | 0 | 0 |"
has "panel: a re-run command pins the cut" "$panel" "--until 2026-10-25T00:00:00Z"
folded="$(python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-panel.jsonl" --until 2026-10-25T00:00:00Z --min-findings 2 2>&1)"
has "panel: a critic under --min-findings folds into one other row" "$folded" "| other (1 slugs under 2 findings each) | 1 | 1 | 1 | 0 | 0 | 0 |"
has "panel: a critic at --min-findings keeps its row" "$folded" "| \`codex\` | 5 | 2 |"
has "panel: the re-run command keeps a non-default --min-findings" "$folded" "--min-findings 2 --out"
cp "$TMP/page.md" "$TMP/nomark.md"
python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-panel.jsonl" --until 2026-10-25T00:00:00Z --out "$TMP/nomark.md" >/dev/null 2>&1; rc=$?
eq "panel --out: a file with no generated block is refused" "$rc" "2"
eq "panel --out: the refused file is untouched" "$(cmp -s "$TMP/page.md" "$TMP/nomark.md" && echo same)" "same"
printf '%s\n' "# Kept title" "" "<!-- review-page.py --panel: start -->" "stale" "<!-- review-page.py --panel: end -->" "" "Kept tail." > "$TMP/doc.md"
python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-panel.jsonl" --until 2026-10-25T00:00:00Z --out "$TMP/doc.md" >/dev/null 2>&1; rc=$?
eq "panel --out: exit 0" "$rc" "0"
doc="$(cat "$TMP/doc.md")"
has "panel --out: the text before the block is kept" "$doc" "# Kept title"
has "panel --out: the text after the block is kept" "$doc" "Kept tail."
has "panel --out: the block is regenerated" "$doc" "5 distinct findings across 2 PRs"
case "$doc" in *stale*) fail "panel --out: the old block is gone";; *) pass "panel --out: the old block is gone";; esac
printf '%s\n' '{"kind":"finding","ts":"2026-10-10T00:00:00Z","branch":"b1","head":"h1","model":"codex","finding_id":"codex-1","severity":"imp","file":"a.sh","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"- [imp]: a == b [a.sh:1]"}' \
  '{"kind":"finding","ts":"2026-10-10T00:00:00Z","branch":"b1","head":"h1","model":"codex","finding_id":"codex-2","severity":"imp","file":"a.sh","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"- [imp]: a != b [a.sh:1]"}' > "$TMP/cr-ops.jsonl"
has "panel: claims that differ only by an operator stay two findings" "$(python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-ops.jsonl" 2>&1)" "2 distinct findings across 1 PRs"
sed -e 's/a == b/a + b/' -e 's/a != b/a - b/' "$TMP/cr-ops.jsonl" > "$TMP/cr-arith.jsonl"
has "panel: claims that differ only by an arithmetic operator stay two findings" "$(python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-arith.jsonl" 2>&1)" "2 distinct findings across 1 PRs"
sed -e 's/a == b/a \&\& b/' -e 's/a != b/a || b/' "$TMP/cr-ops.jsonl" > "$TMP/cr-logic.jsonl"
has "panel: claims that differ only by a logical operator stay two findings" "$(python3 -I "$PAGE" --panel --cr-ledger "$TMP/cr-logic.jsonl" 2>&1)" "2 distinct findings across 1 PRs"
has "--help prints the whole usage text" "$(python3 -I "$PAGE" --help 2>&1)" "--panel [--cr-ledger P] [--until TS]"

M7="$TMP/m7"; mkdir -p "$M7/dir.jsonl"
NOW="2026-11-10T00:00:00Z"
python3 -I - "$HERE/lib" "$M7" <<'PY' || { echo "test-review-page: writing the M7 fixture ledgers failed" >&2; exit 1; }
import json, os, sys
sys.path.insert(0, sys.argv[1])
import eval_runs
D = sys.argv[2]
def put(name, rows):
    open(os.path.join(D, name), "w").write("".join(json.dumps(r) + "\n" for r in rows))
cov = {"scored": 4, "critics": {"codex": {"answered": 4}}}
EVIL = "<img src=x onerror=alert(1)>"
def rp(run_id, ts, critics, recall, status="ok", findings=0, scorer="a" * 64, ex=None, verified=None, sup=None):
    m = {"codex.key_match_recall": recall, "codex.class.logic.recall": recall, "codex.class.logic.n": 5,
         "codex.key_match_precision": None, "codex.findings": findings, "codex.labelled_clean_block_rate": 0.25,
         "codex.clean_scored": 4, "panel.key_match_recall": recall, "panel.class.logic.recall": recall,
         "panel.class.logic.n": 5}
    if EVIL in critics:
        m.update({EVIL + ".findings": 2, EVIL + ".key_match_precision": 0.5})
    meta = {"scorer_sha256": scorer, "execution_id": ex or run_id, "coverage": cov}
    if verified:
        meta["verified"] = verified
    if sup:
        meta["supersedes_run_id"] = sup
    r = eval_runs.make_row("review-panel", "scripts/eval/review-panel/score.py", {"fixture_set": "f1", "critics": critics},
                           m, n=4, run_id=run_id, status=status, gitsha="0" * 40, meta=meta,
                           ci={"codex.key_match_recall": {"lo": 0.3, "hi": 0.9}})
    r["ts"] = ts
    return r
ver = {"metrics": {"codex.adjudicated_precision": 0.75}, "counts": {"codex.adjudicated_precision": {"k": 3, "n": 4},
       "codex.verified_false_block_rate": {"k": 0, "n": 0}}, "coverage": {}, "reasons": ["cohort-pending"], "cohort": {}}
judge = eval_runs.make_row("judge-accuracy", "scripts/eval/judge-accuracy/judge_accuracy.py", {"days": 28},
                           {"escape_rate": 0.02, "flip_rate": 0.1, "go_merged": 50, "escapes": 1}, n=50, run_id="ja-1",
                           gitsha="0" * 40)
judge["ts"] = "2026-11-08T00:00:00Z"
put("runs.jsonl", [rp("rp-a", "2026-10-20T00:00:00Z", ["codex", "claude"], 0.4),
                   rp("rp-b", "2026-11-02T00:00:00Z", ["codex", EVIL], 0.6, verified=ver), judge,
                   rp("rp-c", "2026-11-09T00:00:00Z", ["codex"], None, status="inconclusive")])
put("runs-compat.jsonl", [rp("rp-1", "2026-11-05T00:00:00Z", ["codex"], 0.4), rp("rp-2", "2026-11-08T00:00:00Z", ["codex"], 0.6)])
put("runs-rescore.jsonl", [rp("e1", "2026-10-31T00:00:00Z", ["codex"], 0.4),
                           rp("e1-r", "2026-11-09T00:00:00Z", ["codex"], 0.5, ex="e1", sup="e1")])
put("runs-promoted.jsonl", [rp("e1", "2026-11-05T00:00:00Z", ["codex"], 0.4), rp("e2", "2026-11-07T00:00:00Z", ["codex"], 0.6),
                            rp("e1-r", "2026-11-08T00:00:00Z", ["codex"], 0.5, ex="e1", sup="e1")])
put("runs-orphan.jsonl", [rp("e9-r", "2026-11-09T00:00:00Z", ["codex"], 0.5, ex="e9", sup="e9")])
base = {"v": 1, "host": "h", "source": "scripts/eval/lib/eval_feedback.py", "kind": "eval-change"}
put("changes.jsonl", [dict(base, id="rp-b:codex.key_match_recall", eval="review-panel", metric="codex.key_match_recall",
                           ts="2026-11-02T01:00:00Z", status="open", value=0.6, threshold=0.7, better="higher", absent=None,
                           change="prompt", target="scripts/cr/critic-first-pass.sh", baseline_run_id="rp-b",
                           confighash="c", critic="codex"),
                      dict(base, id="ja-1:escape_rate", eval="judge-accuracy", metric="escape_rate", ts="2026-11-08T01:00:00Z",
                           status="open", value=0.02, threshold=0.01, better="lower", absent=None, change="prompt",
                           target="judge", baseline_run_id="ja-1", confighash="j", critic=None)])
def fin(model, fid, ts, br, source=None, text="SECRET-BODY-TEXT claim"):
    r = {"kind": "finding", "ts": ts, "branch": br, "head": "h1", "model": model, "finding_id": fid, "severity": "imp",
         "file": "a.sh", "line": 1, "verdict": "", "artifact": "diff", "perspective": "off", "text": text}
    if source:
        r["source"], r["verdict"] = source, "fixed"
    return r
def amend(br, fid, verdict, ts="2026-11-06T00:00:00Z"):
    return {"kind": "amend", "ts": ts, "branch": br, "target_head": "h1", "finding_id": fid,
            "artifact": "diff", "perspective": "off", "set": {"verdict": verdict}, "reason": "r"}
put("cr.jsonl", [fin("coderabbit", "cr-1", "2026-11-05T00:00:00Z", "b1"), amend("b1", "cr-1", "agreed"),
                 fin("coderabbit", "cr-2", "2026-11-05T00:00:00Z", "b2"), amend("b2", "cr-2", "disproved"),
                 fin("coderabbit", "cr-3", "2026-11-05T00:00:00Z", "b3", source="cr-thread-recorder"),
                 fin("judge", "j-1", "2026-11-05T00:00:00Z", "b4")])
put("cr-quiet.jsonl", [fin("coderabbit", "cr-1", "2026-09-30T00:00:00Z", "b1"),
                       amend("b1", "cr-1", "agreed", "2026-10-01T00:00:00Z")])
PY
rj() { python3 -I "$PAGE" --reviewers-json --ledger "${1:-$M7/runs.jsonl}" --changes "${2:-$M7/changes.jsonl}" --cr-ledger "${3:-$M7/cr.jsonl}" --now "${4:-$NOW}" 2>/dev/null; }
q() { python3 -I -c 'import json, sys
r = json.loads(sys.stdin.read())
print(eval(sys.argv[1], {"r": r, "src": {s["id"]: s for s in r["sources"]}, "met": {m["id"]: m for m in r["metrics"]}}))' "$1"; }
J="$(rj)"; rc=$?
eq "reviewers-json: exit 0" "$rc" "0"
eq "reviewers-json: valid JSON, report v1" "$(printf '%s' "$J" | q 'r["v"]')" "1"
eq "ledger_present_page_missing: no review page file, the ledgers give an ok report" "$(printf '%s' "$J" | q 'r["state"]')" "ok"
eq "ledger_present_page_missing: benchmark and production metrics both present" "$(printf '%s' "$J" | q 'sorted({m["family"] for m in r["metrics"]})')" "['benchmark', 'production']"
eq "reviewers-json: the report is dated by --now" "$(printf '%s' "$J" | q 'r["generated_at"]')" "$NOW"
eq "reviewers-json: each source by basename, with its records and observed-through" "$(printf '%s' "$J" | q '[(s["id"], s["name"], s["state"], s["records"]) for s in r["sources"]]')" "[('eval-runs', 'runs.jsonl', 'ok', 4), ('eval-changes', 'changes.jsonl', 'ok', 2), ('cr-ledger', 'cr.jsonl', 'ok', 6)]"
case "$J" in *"$TMP"*) fail "reviewers-json: no private path reaches the report";; *) pass "reviewers-json: no private path reaches the report";; esac
case "$J" in *SECRET-BODY-TEXT*) fail "reviewers-json: no raw review text reaches the report";; *) pass "reviewers-json: no raw review text reaches the report";; esac
eq "ENOENT_absent: a missing ledger is source absent, ENOENT" "$(rj "$M7/none.jsonl" | q '(src["eval-runs"]["state"], src["eval-runs"]["reason"], r["state"])')" "('absent', 'ENOENT', 'ok')"
eq "ENOENT_absent: every ledger missing is report absent" "$(rj "$M7/none.jsonl" "$M7/none.jsonl" "$M7/none.jsonl" | q '(r["state"], r["metrics"])')" "('absent', [])"
eq "EACCES_or_directory_error: a directory is source error EISDIR, never absent" "$(rj "" "" "$M7/dir.jsonl" | q '(src["cr-ledger"]["state"], src["cr-ledger"]["reason"])')" "('error', 'EISDIR')"
cp "$M7/cr.jsonl" "$M7/locked.jsonl"; chmod 000 "$M7/locked.jsonl"
if [ -r "$M7/locked.jsonl" ]; then pass "EACCES_or_directory_error: (root reads any file; EACCES not testable here)"
else eq "EACCES_or_directory_error: an unreadable ledger is source error EACCES" "$(rj "" "" "$M7/locked.jsonl" | q '(src["cr-ledger"]["state"], src["cr-ledger"]["reason"])')" "('error', 'EACCES')"; fi
chmod 600 "$M7/locked.jsonl"
eq "one_source_error_partial: one unreadable source makes the report partial" "$(rj "" "" "$M7/dir.jsonl" | q 'r["state"]')" "partial"
eq "one_source_error_partial: the readable sources still report" "$(rj "" "" "$M7/dir.jsonl" | q 'sorted({m["family"] for m in r["metrics"]})')" "['benchmark']"
eq "reviewers-json: the newest usable run is the benchmark" "$(printf '%s' "$J" | q 'r["latest_usable"]["run_id"]')" "rp-b"
eq "zero_denominator_dash: no findings means no ratio, never 0" "$(printf '%s' "$J" | q '[(m["k"], m["n"], m["value"]) for m in r["metrics"] if m["id"] == "benchmark.codex.key_match_precision"]')" "[(None, 0, None)]"
eq "reviewers-json: key-match recall as typed k of n with its interval" "$(printf '%s' "$J" | q '[(m["kind"], m["k"], m["n"], m["value"], m["interval"]) for m in r["metrics"] if m["id"] == "benchmark.codex.key_match_recall"]')" "[('proxy', 3, 5, 0.6, {'hi': 0.9, 'lo': 0.3})]"
eq "reviewers-json: adjudicated precision from the verified family, apart from the proxies" "$(printf '%s' "$J" | q '[(m["kind"], m["k"], m["n"], m["value"]) for m in r["metrics"] if m["id"] == "benchmark.codex.adjudicated_precision"]')" "[('adjudicated', 3, 4, 0.75)]"
eq "stale_observation_new_render: a benchmark eight days old is old in a report made now" "$(printf '%s' "$J" | q '(r["benchmark"]["freshness"]["state"], r["benchmark"]["freshness"]["age_days"])')" "('old', 8)"
eq "stale_observation_new_render: the same run read two days after it is current" "$(rj "" "" "" "2026-11-04T00:00:00Z" | q 'r["benchmark"]["freshness"]["state"]')" "current"
eq "stale_observation_new_render: a run observed at --now is 0 days old, not unknown" "$(rj "" "" "" "2026-11-02T00:00:00Z" | q '(r["benchmark"]["freshness"]["age_days"], r["benchmark"]["freshness"]["state"])')" "(0, 'current')"
R="$(rj "$M7/runs-rescore.jsonl")"
eq "rescore_dated_by_execution: an execution 10 days old rescored yesterday is old, 10 days" "$(printf '%s' "$R" | q '(r["latest_usable"]["run_id"], r["benchmark"]["freshness"]["state"], r["benchmark"]["freshness"]["age_days"])')" "('e1-r', 'old', 10)"
eq "rescore_dated_by_execution: observed at the execution's first row, everywhere" "$(printf '%s' "$R" | q '(r["latest_usable"]["at"], r["benchmark"]["freshness"]["observed_at"], {m["window"]["observed_at"] for m in r["metrics"] if m["family"] == "benchmark"})')" "('2026-10-31T00:00:00Z', '2026-10-31T00:00:00Z', {'2026-10-31T00:00:00Z'})"
eq "rescore_dated_by_execution: a rescore whose source row is absent has no known age" "$(rj "$M7/runs-orphan.jsonl" | q '(r["latest_usable"]["at"], r["benchmark"]["freshness"]["age_days"], r["benchmark"]["freshness"]["state"])')" "(None, None, 'unknown')"
eq "promoted_rescore_usable: a rescore of e1 promoted after e2 is no unusable attempt" "$(rj "$M7/runs-promoted.jsonl" | q '(r["latest_usable"]["run_id"], r["latest_attempt"]["run_id"], r["latest_attempt"]["usable"])')" "('e2', 'e1-r', True)"
PP="$(python3 -I "$PAGE" --reviewers-only --ledger "$M7/runs-promoted.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M7/cr.jsonl" --now "$NOW" 2>&1)"; rc=$?
eq "promoted_rescore_usable: the prose renders, exit 0" "$rc" "0"
has "promoted_rescore_usable: the prose names the benchmark run" "$PP" "Run of 7 Nov 2026 (e2, ok)."
case "$PP" in *"not usable"*) fail "promoted_rescore_usable: the prose names no unusable attempt";; *) pass "promoted_rescore_usable: the prose names no unusable attempt";; esac
eq "reviewers-json: a change recorded after --now is not in the report" "$(rj "" "" "" "2026-11-02T00:30:00Z" | q 'r["proposals"]')" "[]"
Q="$(rj "" "" "$M7/cr-quiet.jsonl")"
eq "quiet_history_not_failed_capture: a quiet CR ledger names its last record" "$(printf '%s' "$Q" | q '(r["production"]["last_record_at"], r["production"]["records_in_window"])')" "('2026-10-01T00:00:00Z', 0)"
eq "quiet_history_not_failed_capture: capture coverage stays unknown" "$(printf '%s' "$Q" | q 'r["production"]["capture_coverage"]')" "unknown"
case "$Q" in *stale*|*failed*) fail "quiet_history_not_failed_capture: quiet history is never called stale or failed capture";; *) pass "quiet_history_not_failed_capture: quiet history is never called stale or failed capture";; esac
eq "newer_failed_attempt_visible: the newer inconclusive attempt is the latest attempt" "$(printf '%s' "$J" | q '(r["latest_attempt"]["run_id"], r["latest_attempt"]["status"], r["latest_attempt"]["usable"])')" "('rp-c', 'inconclusive', False)"
eq "incompatible_series_no_trend: another roster is not comparable, with the reason" "$(printf '%s' "$J" | q '(r["comparison_eligibility"]["eligible"], "confighash" in r["comparison_eligibility"]["reasons"][0])')" "(False, True)"
eq "incompatible_series_no_trend: no metric carries a trend" "$(printf '%s' "$J" | q '[m["id"] for m in r["metrics"] if m.get("trend")]')" "[]"
eq "incompatible_series_no_trend: a comparable pair carries its trend (control)" "$(rj "$M7/runs-compat.jsonl" | q '(r["comparison_eligibility"]["eligible"], met["benchmark.codex.key_match_recall"]["trend"])')" "(True, {'previous_run_id': 'rp-1', 'previous_value': 0.4})"
eq "reviewers-json: a recorded disposition is author agreement over decided findings" "$(printf '%s' "$J" | q '[(m["verdict_source"], m["k"], m["n"], m["value"]) for m in r["metrics"] if m["family"] == "production" and m["reviewer"] == "coderabbit" and m["verdict_source"] == "recorded-disposition"]')" "[('recorded-disposition', 1, 2, 0.5)]"
eq "reviewers-json: a thread-recorder verdict is its own thread-state family" "$(printf '%s' "$J" | q '[(m["label"], m["k"], m["n"]) for m in r["metrics"] if m["family"] == "production" and m["verdict_source"] == "thread-state-inferred"]')" "[('resolved after a change (thread state, inferred)', 1, 1)]"
eq "escaped_labels: a reviewer named with markup stays plain data in the JSON" "$(printf '%s' "$J" | q '[x["id"] for x in r["reviewers"] if x["id"].startswith("<")]')" "['<img src=x onerror=alert(1)>']"
eq "reviewers-json: a reviewer change is a typed proposal with its lifecycle" "$(printf '%s' "$J" | q '[(p["id"], p["lifecycle"]) for p in r["proposals"]]')" "[('rp-b:codex.key_match_recall', 'proposed')]"
case "$J" in *judge*|*escape*|*flip*) fail "no_judge_fields_in_new_report: no judge row or change reaches the report";; *) pass "no_judge_fields_in_new_report: no judge row or change reaches the report";; esac
eq "no_judge_fields_in_new_report: a bookkeeping slug in the CR ledger is counted out, never a reviewer row" "$(printf '%s' "$J" | q '(r["production"]["not_reviewers"], sorted({m["reviewer"] for m in r["metrics"] if m["family"] == "production"}))')" "({'findings': 1, 'slugs': 1}, ['coderabbit'])"
P="$(python3 -I "$PAGE" --reviewers-only --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M7/cr-quiet.jsonl" --now "$NOW" 2>&1)"; rc=$?
eq "reviewers-only: exit 0" "$rc" "0"
has "reviewers-only: typed k of n in prose" "$P" "The codex critic key-matched 3 of 5 labelled target defects: 60 %"
has "reviewers-only: a zero denominator reads as a dash" "$P" "0 findings: —"
has "reviewers-only: an old benchmark says so" "$P" "Old: observed 8 days before this report"
has "reviewers-only: the newer failed attempt is named" "$P" "Latest attempt 9 Nov 2026 (rp-c): inconclusive, not usable"
has "reviewers-only: quiet history names the last record" "$P" "No new records since 1 Oct 2026; capture coverage unknown"
case "$P" in *judge*|*"Bugs past a GO"*) fail "reviewers-only: code reviewers only";; *) pass "reviewers-only: code reviewers only";; esac

M8="$TMP/m8"; mkdir -p "$M8/bin"
PY3="$(command -v python3)"
cp "$M7/cr.jsonl" "$M8/cr.jsonl"
rjp() { env -i PATH="$M8/bin" HOME="$M8" "$PY3" -I "$PAGE" --reviewers-json --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M8/cr.jsonl" --now "$NOW" "$@" 2>/dev/null; }
cr_rd() { q '[(m["model"], m["k"], m["n"]) for m in r["metrics"] if m["family"] == "production" and m["reviewer"] == "coderabbit" and m["verdict_source"] == "recorded-disposition"]'; }
eq "future_PR_appended_updates_report: before the new PR, author agreement is 1 of 2" "$(rjp | cr_rd)" "[('unknown', 1, 2)]"
printf '%s\n' '{"kind":"finding","ts":"2026-11-08T00:00:00Z","branch":"b5","head":"h5","model":"coderabbit","finding_id":"cr-5","severity":"imp","file":"a.sh","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"SECRET-BODY-TEXT new"}' \
  '{"kind":"amend","ts":"2026-11-08T01:00:00Z","branch":"b5","target_head":"h5","finding_id":"cr-5","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"r"}' >> "$M8/cr.jsonl"
A1="$(rjp)"; A2="$(rjp)"
eq "future_PR_appended_updates_report: the next read counts the appended PR, 2 of 3" "$(printf '%s' "$A1" | cr_rd)" "[('unknown', 2, 3)]"
eq "future_PR_appended_updates_report: a second read counts it once, not twice" "$(printf '%s' "$A2" | cr_rd)" "[('unknown', 2, 3)]"
eq "future_PR_appended_updates_report: the CR source shows the new records and date" "$(printf '%s' "$A1" | q '(src["cr-ledger"]["records"], src["cr-ledger"]["observed_through"], r["production"]["last_record_at"])')" "(8, '2026-11-08T01:00:00Z', '2026-11-08T01:00:00Z')"
eq "future_PR_appended_updates_report: read with no command on PATH, so no reviewer, model or network tool ran" "$(printf '%s' "$A1" | q 'r["state"]')" "ok"
printf '%s\n' '{"kind":"attempt","ts":"2026-11-09T00:00:00Z","branch":"b6","head":"h6","model":"coderabbit","artifact":"diff","responding_model":"cr-model-2"}' \
  '{"kind":"finding","ts":"2026-11-09T00:00:00Z","branch":"b6","head":"h6","model":"coderabbit","finding_id":"cr-6","severity":"imp","file":"a.sh","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"SECRET-BODY-TEXT m2"}' \
  '{"kind":"amend","ts":"2026-11-09T01:00:00Z","branch":"b6","target_head":"h6","finding_id":"cr-6","artifact":"diff","perspective":"off","set":{"verdict":"disproved"},"reason":"r"}' >> "$M8/cr.jsonl"
B="$(rjp)"
eq "future_model_change_new_cohort: a new responding model is its own row, never pooled" "$(printf '%s' "$B" | cr_rd)" "[('cr-model-2', 0, 1), ('unknown', 2, 3)]"
eq "future_model_change_new_cohort: the reviewer lists both models" "$(printf '%s' "$B" | q '[x["models"] for x in r["reviewers"] if x["id"] == "coderabbit"]')" "[['cr-model-2', 'unknown']]"
eq "collection_gap_visible: no receipt and no expected-PR snapshot is unknown, never a zero" "$(printf '%s' "$B" | q '(r["production"]["capture_coverage"], "capture" in r["production"])')" "('unknown', False)"
eq "no_receipt_no_snapshot_unchanged: the report keeps the M7 production keys and three sources" "$(printf '%s' "$B" | q '(sorted(r["production"]), [s["id"] for s in r["sources"]])')" "(['capture_coverage', 'capture_reason', 'last_record_at', 'not_reviewers', 'records_in_window', 'roster', 'window'], ['eval-runs', 'eval-changes', 'cr-ledger'])"
has "no_receipt_no_snapshot_unchanged: the prose keeps the M7 capture sentence" "$(env -i PATH="$M8/bin" HOME="$M8" "$PY3" -I "$PAGE" --reviewers-only --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M8/cr.jsonl" --now "$NOW" 2>&1)" "Last record 9 Nov 2026; capture coverage unknown (no per-PR capture receipts and no expected-PR snapshot)."
cap() { printf '{"kind":"capture","ts":"%s","pr":%s,"branch":"%s","head":"%s","thread_count":%s,"outside_count":0,"result":"%s","reason":%s}\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
exp_pr() { printf '{"pr":%s,"branch":"%s","head":"%s","merged_at":"%s"}\n' "$1" "$2" "$3" "$4"; }
{ cap 2026-11-05T02:00:00Z 101 b1 h1 2 ok null; cap 2026-11-05T02:00:00Z 102 b2 h2 1 error '"gh api exit 1"'; } >> "$M8/cr.jsonl"
{ printf '{"taken_at":"2026-11-10T00:00:00Z"}\n'; exp_pr 101 b1 h1 2026-11-05T01:00:00Z; exp_pr 102 b2 h2 2026-11-05T01:00:00Z; exp_pr 103 b3 h3 2026-11-05T01:00:00Z; exp_pr 90 b0 h0 2026-10-01T00:00:00Z; } > "$M8/expected.jsonl"
G="$(rjp --expected-prs "$M8/expected.jsonl")"
eq "collection_gap_visible: with the snapshot, captured k of the expected PRs in the window" "$(printf '%s' "$G" | q '(r["production"]["capture_coverage"], r["production"]["capture"]["k"], r["production"]["capture"]["n"])')" "('measured', 1, 3)"
eq "collection_gap_visible: an error receipt is a failed capture and a missing one is uncaptured, each named" "$(printf '%s' "$G" | q '(r["production"]["capture"]["failed"], r["production"]["capture"]["uncaptured"])')" "([102], [103])"
eq "collection_gap_visible: the snapshot is a named source" "$(printf '%s' "$G" | q '(src["expected-prs"]["name"], src["expected-prs"]["state"], src["expected-prs"]["records"])')" "('expected.jsonl', 'ok', 5)"
eq "collection_gap_visible: a missing snapshot file is absent and coverage stays unknown" "$(rjp --expected-prs "$M8/none.jsonl" | q '(src["expected-prs"]["state"], r["production"]["capture_coverage"])')" "('absent', 'unknown')"
GP="$(env -i PATH="$M8/bin" HOME="$M8" "$PY3" -I "$PAGE" --reviewers-only --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M8/cr.jsonl" --now "$NOW" --expected-prs "$M8/expected.jsonl" 2>&1)"
has "collection_gap_visible: the prose names the gap" "$GP" "Capture: 1 of 3 expected PRs captured (0 with zero threads), snapshot as of 10 Nov 2026; failed: #102; not captured: #103."
{ cap 2026-11-06T02:00:00Z 107 b7 h7 0 ok null; } >> "$M8/cr.jsonl"
{ exp_pr 107 b7 h7 2026-11-06T01:00:00Z; exp_pr 108 b8 h8 2026-11-06T01:00:00Z; } >> "$M8/expected.jsonl"
Z="$(rjp --expected-prs "$M8/expected.jsonl")"
eq "zero_thread_pr_vs_uncaptured: an ok receipt with 0 threads is captured-zero, a PR with no receipt is uncaptured" "$(printf '%s' "$Z" | q '(r["production"]["capture"]["k"], r["production"]["capture"]["n"], r["production"]["capture"]["captured_zero"], r["production"]["capture"]["uncaptured"])')" "(2, 5, [107], [103, 108])"
eq "zero_thread_pr_vs_uncaptured: receipts without a snapshot still name captured-zero, coverage unknown" "$(rjp | q '(r["production"]["capture_coverage"], r["production"]["capture"]["captured_zero"], r["production"]["capture"]["n"])')" "('unknown', [107], None)"
eq "zero_thread_pr_vs_uncaptured: a receipt is no finding, so the counts stay 2 of 3" "$(printf '%s' "$Z" | cr_rd)" "[('cr-model-2', 0, 1), ('unknown', 2, 3)]"
{ cap 2026-10-27T23:00:00Z 109 b9 h9 1 ok null; } >> "$M8/cr.jsonl"
exp_pr 109 b9 h9 2026-10-28T01:00:00Z >> "$M8/expected.jsonl"
eq "collection_gap_visible: a receipt from before the window still captures a PR merged inside it" "$(rjp --expected-prs "$M8/expected.jsonl" | q '(r["production"]["capture"]["k"], r["production"]["capture"]["n"], 109 in r["production"]["capture"]["uncaptured"])')" "(3, 6, False)"
eq "collection_gap_visible: with the CR ledger missing, a snapshot leaves coverage unknown, never all uncaptured" "$(env -i PATH="$M8/bin" HOME="$M8" "$PY3" -I "$PAGE" --reviewers-json --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M8/none.jsonl" --now "$NOW" --expected-prs "$M8/expected.jsonl" 2>/dev/null | q '(r["production"]["capture_coverage"], "capture" in r["production"])')" "('unknown', False)"
{ cap 2026-11-07T00:00:00Z 111 b11 h11 1 ok null; cap 2026-11-07T05:00:00Z 111 b11 h11 1 error '"r"'
  cap 2026-11-07T00:00:00Z 112 b12 h12 1 error '"r"'; cap 2026-11-07T05:00:00Z 112 b12 h12 1 ok null
  printf '{"kind":"capture","ts":"2026-11-07T00:00:00Z","pr":113,"branch":"b13","head":"h13","thread_count":0,"outside_count":2,"result":"ok","reason":null}\n'; } >> "$M8/cr.jsonl"
{ exp_pr 111 b11 h11 2026-11-07T00:00:00Z; exp_pr 112 b12 h12 2026-11-07T00:00:00Z; exp_pr 113 b13 h13 2026-11-07T00:00:00Z
  printf '{"pr":"x","merged_at":"2026-11-07T00:00:00Z"}\n{"pr":114,"merged_at":"not-a-date"}\n'; } >> "$M8/expected.jsonl"
W="$(rjp --expected-prs "$M8/expected.jsonl")"
eq "two_receipts_one_pr: the newest receipt wins, ok then error is failed and error then ok is captured" "$(printf '%s' "$W" | q '(r["production"]["capture"]["k"], r["production"]["capture"]["n"], r["production"]["capture"]["failed"])')" "(5, 9, [102, 111])"
eq "zero_thread_pr_vs_uncaptured: no threads but an outside-diff finding is captured, not captured-zero" "$(printf '%s' "$W" | q '(r["production"]["capture"]["captured_zero"], 113 in r["production"]["capture"]["uncaptured"])')" "([107], False)"
eq "collection_gap_visible: snapshot rows with no PR number or merge time are counted as dropped" "$(printf '%s' "$W" | q 'r["production"]["capture"]["snapshot_dropped"]')" "2"
eq "collection_gap_visible: without a snapshot, a receipt from before the window is not counted" "$(rjp | q '(r["production"]["capture"]["receipts"], 109 in r["production"]["capture"]["captured_zero"] + r["production"]["capture"]["failed"])')" "(6, False)"
eq "collection_gap_visible: the snapshot's as-of time is in the report" "$(printf '%s' "$W" | q '(r["production"]["capture_coverage"], r["production"]["capture"]["snapshot_as_of"])')" "('measured', '2026-11-10T00:00:00Z')"
sed -e 's/"taken_at":"2026-11-10T00:00:00Z"/"taken_at":"2026-11-06T12:00:00Z"/' "$M8/expected.jsonl" > "$M8/stale.jsonl"
cap 2026-11-08T02:00:00Z 115 b15 h15 1 ok null >> "$M8/cr.jsonl"
S="$(rjp --expected-prs "$M8/stale.jsonl")"
eq "stale_snapshot_not_full_coverage: a snapshot older than the report day, with a later merge, is partial with its date" "$(printf '%s' "$S" | q '(r["production"]["capture_coverage"], r["production"]["capture"]["snapshot_as_of"])')" "('partial', '2026-11-06T12:00:00Z')"
has "stale_snapshot_not_full_coverage: the prose dates the snapshot and says it is partial" "$(env -i PATH="$M8/bin" HOME="$M8" "$PY3" -I "$PAGE" --reviewers-only --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M8/cr.jsonl" --now "$NOW" --expected-prs "$M8/stale.jsonl" 2>&1)" "snapshot as of 6 Nov 2026, partial: PRs merged after it are not in it"
grep -v taken_at "$M8/expected.jsonl" > "$M8/undated.jsonl"
eq "stale_snapshot_not_full_coverage: a snapshot with no as-of time leaves coverage unknown, with no ratio" "$(rjp --expected-prs "$M8/undated.jsonl" | q '(r["production"]["capture_coverage"], r["production"]["capture"]["k"], r["production"]["capture"]["n"], r["production"]["capture"]["snapshot_as_of"])')" "('unknown', None, None, None)"
printf '{"taken_at":"2026-11-10T00:00:00Z"}\n' > "$M8/empty-snap.jsonl"
has "collection_gap_visible: a snapshot with no PR merged in the window says so, never 0 of 0" "$(env -i PATH="$M8/bin" HOME="$M8" "$PY3" -I "$PAGE" --reviewers-only --ledger "$M7/runs.jsonl" --changes "$M7/changes.jsonl" --cr-ledger "$M8/cr.jsonl" --now "$NOW" --expected-prs "$M8/empty-snap.jsonl" 2>&1)" "Capture: no expected PR merged in the window, snapshot as of 10 Nov 2026"
case "$Z$G" in *SECRET-BODY-TEXT*|*"gh api"*) fail "zero_thread_pr_vs_uncaptured: no review text or receipt reason text reaches the report";; *) pass "zero_thread_pr_vs_uncaptured: no review text or receipt reason text reaches the report";; esac

# The evals page must not tell a reader to run a script that is not in the tree.
ROOT="$(cd "$HERE/../.." && pwd)"
python3 -I "$ROOT/scripts/cr/evals-page-gen.py" render --out "$TMP/evals-page.md" >/dev/null 2>&1
missing=""
while IFS= read -r p; do
  [ -e "$ROOT/$p" ] || missing="$missing $p"
done < <(grep -Eo 'scripts/[A-Za-z0-9_./-]+\.(py|sh)' "$TMP/evals-page.md" | sort -u)
eq "evals page: every script path it names exists in the tree" "$missing" ""
if [ -s "$TMP/evals-page.md" ]; then pass "evals page: rendered"; else fail "evals page: rendered nothing"; fi

echo "test-review-page: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
