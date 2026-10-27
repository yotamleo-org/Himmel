#!/usr/bin/env bash
# scripts/cr/test-evals-page-gen.sh - suite for evals-page-gen.py, the generator behind docs/evals/README.md:
# Wilson 95% precision per critic and pooled from a fixture ledger with known counts, counts pinned to
# cr-scores.sh, the proof-first and test-first shares from a fixture eval-runs ledger, the cache-probe
# refusals, a rendered page whose every percentage carries "as of <date>, n = <n>", and no typed figure.
# Fixture ledgers and fixture cache-probe output only: no model call, no network, never a live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GEN="$HERE/evals-page-gen.py"
PAGE="$ROOT/docs/evals/README.md"
DATA="$ROOT/docs/evals/evals-data.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/evals-page-test.XXXXXX")" || { echo "test-evals-page-gen: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledgers, whatever a case forgets to pass.
export CR_LEDGER="$TMP/never.jsonl"
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/never-eval-runs.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }
lacks() { case "$2" in *"$3"*) fail "$1: '$3' found";; *) pass "$1";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-evals-page-gen: python3 not on PATH"; exit 0; }

# jget <json-file> <a/b/c> - one value from a JSON file.
jget() { python3 -I -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }

# bare_pct <file> - every line that holds a percentage but not "as of <date>, n = <n>".
bare_pct() { grep -E '[0-9]%' "$1" | grep -Ev 'as of [0-9]{4}-[0-9]{2}-[0-9]{2}, n = [0-9,]+' || true; }

# ── Fixture ledger ──────────────────────────────────────────────────────────
# alpha: 12 findings on 2 PRs: 6 agreed + 2 fixed, 2 disproved, 1 deferred, 1 unadjudicated
#        ruled 10, precision 8/10 = 80.0%, Wilson 49.0-94.3
# beta:  50 findings on 5 PRs: 45 agreed, 5 disproved
#        precision 45/50 = 90.0%, Wilson 78.6-95.7
# pooled: 62 findings, ruled 60, precision 53/60 = 88.3%, Wilson 77.8-94.2
L="$TMP/ledger.jsonl"
: > "$L"
finding() { # model branch id
  printf '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"%s","head":"h1","model":"%s","finding_id":"%s","severity":"imp","verdict":"","artifact":"diff","perspective":"off","text":"claim %s"}\n' "$2" "$1" "$3" "$3" >> "$L"
}
amend() { # branch id verdict
  printf '{"kind":"amend","ts":"2026-10-02T10:00:00Z","branch":"%s","target_head":"h1","finding_id":"%s","artifact":"diff","perspective":"off","set":{"verdict":"%s"},"reason":"r"}\n' "$1" "$2" "$3" >> "$L"
}
i=0
while [ "$i" -lt 12 ]; do
  b="a$((i % 2))"; finding alpha "$b" "alpha-$i"
  case "$i" in
    0|1|2|3|4|5) amend "$b" "alpha-$i" agreed;;
    6|7) amend "$b" "alpha-$i" fixed;;
    8|9) amend "$b" "alpha-$i" disproved;;
    10) amend "$b" "alpha-$i" deferred;;
  esac
  i=$((i + 1))
done
i=0
while [ "$i" -lt 50 ]; do
  b="b$((i % 5))"; finding beta "$b" "beta-$i"
  if [ "$i" -lt 45 ]; then amend "$b" "beta-$i" agreed; else amend "$b" "beta-$i" disproved; fi
  i=$((i + 1))
done

C="$TMP/cache-probe.txt"
printf 'cache-probe first-turn\nsession\tstart\tinput\tcache_read\tcache_create\nread-ratio: 97.4%% over 1200000 tokens\nverdict: warm-start warm=9 cold=1\n' > "$C"

# ── Fixture eval-runs ledger ────────────────────────────────────────────────
# pdd-share: an older row (2.5 %) and the newest row, 13 of 120 = 10.8 %, Wilson 6.4-17.7.
# leg-trajectory: one version 1 row (never counted), two version 2 rows of which one has no verdict:
#                 test-first n = 1, under the 30-session floor, so "not measured yet".
E="$TMP/eval-runs.jsonl"
mkrow() { # ts eval config-json metrics-json ci-json - one valid eval-runs row, built by the ledger's own writer
  python3 -I -c 'import json,sys
sys.path.insert(0, sys.argv[1])
import eval_runs
r = eval_runs.make_row(sys.argv[3], "fixture", json.loads(sys.argv[4]), json.loads(sys.argv[5]), ci=json.loads(sys.argv[6]), gitsha="0" * 40)
r["ts"] = sys.argv[2]
print(json.dumps(r))' "$ROOT/scripts/eval/lib" "$@"
}
pdd_row() { # ts k pct lo hi
  mkrow "$1" pdd-share '{"pdd_v":1}' \
    "{\"pdd.pct\":$3,\"pdd.k\":$2,\"pdd.n\":120,\"ticket_first.pct\":0.1917,\"ticket_first.k\":23,\"ticket_first.n\":120,\"red_green.pct\":0.575,\"red_green.k\":69,\"red_green.n\":120}" \
    "{\"pdd.pct\":{\"lo\":$4,\"hi\":$5},\"ticket_first.pct\":{\"lo\":0.1313,\"hi\":0.2712},\"red_green.pct\":{\"lo\":0.4856,\"hi\":0.6598}}"
}
traj_row() { # ts trajectory_v red_before_green
  mkrow "$1" leg-trajectory "{\"trajectory_v\":$2}" "{\"red_before_green\":$3}" '{}'
}
# lane-quality-calibration: a row with no second grader (never shown), and per arm set the newest
# model-graded row only: m-a's 2026-10-26 row (kappa 0.50, 14 of 17 agree) replaces its 2026-10-24 one.
cal_row() { # ts config-json verdict_kappa n_verdict verdict_agree
  mkrow "$1" lane-quality-calibration "$2" \
    "{\"verdict_kappa\":$3,\"n_verdict\":$4,\"verdict_agree\":$5,\"n_twice\":$4,\"verdict_flips\":2,\"tiebreak_sent\":3,\"tiebreak_grader1\":2,\"tiebreak_grader2\":1,\"tiebreak_missing\":0}" '{}'
}
grader() { printf '{"role":"%s","model":"%s","effort":"high","lane":"%s","vendor":"%s"}' "$@"; }
CAL_A="[$(grader grader1 gpt-x claudex openai),$(grader grader2 google/gemini-x openrouter google),$(grader tiebreak deepseek/deepseek-x openrouter deepseek)]"
CAL_B="[$(grader grader1 opus native anthropic),$(grader grader2 google/gemini-x openrouter google),$(grader tiebreak deepseek/deepseek-x openrouter deepseek)]"
{
  pdd_row 2026-10-23T10:00:00Z 3 0.025 0.0085 0.0711
  pdd_row 2026-10-24T23:52:30Z 13 0.1083 0.0644 0.1766
  traj_row 2026-10-24T10:00:00Z 1 true
  traj_row 2026-10-25T01:00:00Z 2 0
  traj_row 2026-10-25T02:00:00Z 2 null
  mkrow 2026-10-24T19:25:56Z review-panel '{"critics":["beta"]}' \
    '{"panel.recall":0.75,"defects":12,"cases":24}' '{"panel.recall":{"lo":0.4677,"hi":0.9111}}'
  cal_row 2026-10-23T10:00:00Z '{"judge_models":["opus"],"judge2":null,"model_graded":false}' 0.9 10 9
  cal_row 2026-10-24T10:00:00Z "{\"models\":[\"m-a\"],\"model_graded\":true,\"graders\":$CAL_A}" 0.25 6 4
  cal_row 2026-10-26T10:00:00Z "{\"models\":[\"m-a\"],\"model_graded\":true,\"graders\":$CAL_A}" 0.5 17 14
  cal_row 2026-10-26T11:00:00Z "{\"models\":[\"m-b\"],\"model_graded\":true,\"graders\":$CAL_B}" 0.3333 7 5
} > "$E"

# ── Fixture panel ───────────────────────────────────────────────────────────
# beta is the required reviewer, delta:m9 runs where present but has no findings yet, coderabbit is best effort;
# alpha is in the ledger but not the panel, so it is history.
K="$TMP/critics.json"
printf '{"panel":[{"slug":"beta","mode":"hard","required":true},{"slug":"delta","model":"m9","mode":"hard","required":false},{"slug":"coderabbit","provider":"github-app","mode":"best-effort"}]}\n' > "$K"

OUT="$TMP/data.json"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --critics "$K" --cache-probe "$C" --as-of 2026-10-25 --out "$OUT" > "$TMP/data.out" 2> "$TMP/data.err"; rc=$?
eq "data: exit 0" "$rc" "0"

# RED row: precision and Wilson interval to one decimal.
eq "pooled: precision to one decimal" "$(jget "$OUT" review/pooled/precision_pct)" "88.3"
eq "pooled: Wilson low" "$(jget "$OUT" review/pooled/wilson/lo)" "77.8"
eq "pooled: Wilson high" "$(jget "$OUT" review/pooled/wilson/hi)" "94.2"
eq "pooled: n is the ruled findings" "$(jget "$OUT" review/pooled/n)" "60"
eq "pooled: findings raised" "$(jget "$OUT" review/pooled/findings)" "62"
eq "pooled: PRs" "$(jget "$OUT" review/pooled/prs)" "7"
eq "alpha: precision" "$(jget "$OUT" review/critics/alpha/precision_pct)" "80.0"
eq "alpha: Wilson low" "$(jget "$OUT" review/critics/alpha/wilson/lo)" "49.0"
eq "alpha: Wilson high" "$(jget "$OUT" review/critics/alpha/wilson/hi)" "94.3"
eq "alpha: fixed counts as agreed" "$(jget "$OUT" review/critics/alpha/agreed)" "8"
eq "alpha: unadjudicated stays out of n" "$(jget "$OUT" review/critics/alpha/n)" "10"
eq "beta: precision" "$(jget "$OUT" review/critics/beta/precision_pct)" "90.0"
eq "beta: Wilson low" "$(jget "$OUT" review/critics/beta/wilson/lo)" "78.6"
eq "beta: Wilson high" "$(jget "$OUT" review/critics/beta/wilson/hi)" "95.7"
eq "pooled: bootstrap interval sits beside Wilson" "$(python3 -I -c 'import json,sys
b=json.load(open(sys.argv[1]))["review"]["pooled"]["bootstrap"]
print(b is not None and 0 <= b["lo"] <= b["hi"] <= 100)' "$OUT")" "True"
eq "meta: as-of date" "$(jget "$OUT" review/as_of)" "2026-10-25"

# The counts are cr-scores.sh's counts: same ledger, same total and agreed share per model.
CS="$(CR_LEDGER="$L" bash "$HERE/cr-scores.sh" 2>/dev/null)"; cs_rc=$?
eq "parity: cr-scores.sh exits 0 on the fixture ledger" "$cs_rc" "0"
a_row="$(printf '%s\n' "$CS" | awk '$1 == "alpha" { print $2, $3; exit }')"
b_row="$(printf '%s\n' "$CS" | awk '$1 == "beta" { print $2, $3; exit }')"
eq "parity: alpha total and agreed% match cr-scores.sh" "$a_row" "12 67%"
eq "parity: beta total and agreed% match cr-scores.sh" "$b_row" "50 90%"
eq "parity: generator alpha findings" "$(jget "$OUT" review/critics/alpha/findings)" "12"
eq "parity: generator alpha agreed share" "$(python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1]))["review"]["critics"]["alpha"]
print(str(round(100*c["agreed"]/c["findings"]))+"%")' "$OUT")" "67%"

# Cache figure from cache-probe output.
eq "cache: read ratio" "$(jget "$OUT" cache/read_ratio_pct)" "97.4"
eq "cache: tokens" "$(jget "$OUT" cache/tokens)" "1200000"
eq "cache: sessions" "$(jget "$OUT" cache/sessions)" "10"

# Proof-first share: the newest pdd-share row only, its own date.
eq "pdd: the newest row's share" "$(jget "$OUT" proof_first/pdd/pct)" "10.8"
eq "pdd: Wilson low" "$(jget "$OUT" proof_first/pdd/wilson/lo)" "6.4"
eq "pdd: Wilson high" "$(jget "$OUT" proof_first/pdd/wilson/hi)" "17.7"
eq "pdd: n is the PRs read" "$(jget "$OUT" proof_first/pdd/n)" "120"
eq "pdd: dated by its row" "$(jget "$OUT" proof_first/as_of)" "2026-10-24"
eq "pdd: ticket-first half" "$(jget "$OUT" proof_first/ticket_first/pct)" "19.2"
eq "pdd: red-green half" "$(jget "$OUT" proof_first/red_green/pct)" "57.5"
# Test-first: trajectory version 2 rows with a verdict only, no share under the floor.
eq "test-first: version 1 and verdict-less rows stay out of n" "$(jget "$OUT" test_first/n)" "1"
eq "test-first: no share under the floor" "$(jget "$OUT" test_first/pct)" "null"
# Planted bugs: the newest review-panel row, its own date.
eq "planted: the panel's catch rate" "$(jget "$OUT" planted/pct)" "75.0"
eq "planted: bugs caught" "$(jget "$OUT" planted/k)" "9"
eq "planted: bugs planted" "$(jget "$OUT" planted/n)" "12"
eq "planted: dated by its row" "$(jget "$OUT" planted/as_of)" "2026-10-24"
# Judge calibration: the newest model-graded row per arm set, never a row without a second grader.
eq "calibration: one entry per arm set, newest row each" "$(python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1]))["calibration"]
print(" ".join("%s:%s:%s/%s" % (",".join(e["models"]), e["kappa"], e["agree"], e["n"]) for e in c))' "$OUT")" "m-a:0.5:14/17 m-b:0.3333:5/7"
# The current panel comes from the critics file; a ledger reviewer outside it is history.
eq "panel: a panel reviewer is current" "$(jget "$OUT" review/critics/beta/panel)" "beta"
eq "panel: a ledger reviewer outside the panel is history" "$(jget "$OUT" review/critics/alpha/panel)" "null"

# Render.
R="$TMP/page.md"
python3 -I "$GEN" render --data "$OUT" --out "$R" > "$TMP/render.out" 2> "$TMP/render.err"; rc=$?
eq "render: exit 0" "$rc" "0"
lacks "render: no draft marker" "$(head -5 "$R")" "draft:"
eq "render: bottom line first, then the current setup, then history" \
  "$(grep -E '^## ' "$R" | head -4 | tr '\n' '|')" "## Bottom line|## Current setup|## History and what we learned|## Proof-first share and test-first adherence|"
has "render: bottom line gives the planted-bug catch" "$(cat "$R")" "**75.0%**: \`beta\` caught 9 of 12 planted bugs"
has "render: planted-bug sample" "$(cat "$R")" "as of 2026-10-24, n = 12 planted bugs in 24 test changes"
has "render: bottom line gives the required reviewer's precision" "$(cat "$R")" "| **90.0%** of \`beta\` findings ruled right |"
has "render: bottom line says the pooled figure is not the headline" "$(cat "$R")" "not the all-reviewers pooled figure"
has "render: current setup row with its role" "$(cat "$R")" "| \`beta\` | required: must pass before every merge | **90.0%** | 78.6 to 95.7 |"
has "render: a panel reviewer with no findings yet" "$(cat "$R")" "| \`delta:m9\` | must pass where it runs; skipped on a machine without it | no ruled findings yet |"
has "render: current setup links the options" "$(cat "$R")" "(../configuration.md#review-by-a-second-model)"
has "render: pooled figure under history" "$(grep -F '| All reviewers pooled |' "$R")" "**88.3%**"
has "render: a retired reviewer under the floor is counted out" "$(cat "$R")" "One reviewer with fewer than 30 ruled findings is left out"
has "render: findings out as a table row" "$(cat "$R")" "| Agreed | 53 of 62 |"
has "render: a How to read these numbers block" "$(cat "$R")" "## How to read these numbers"
has "render: the block says who rules" "$(cat "$R")" "The PR author rules"
has "render: the block explains the bootstrap by PR" "$(cat "$R")" "resamples whole PRs"
has "render: the block explains as of" "$(cat "$R")" "**As of**"
CAL_LINE="$(grep -F '| How far can the lane-quality judge be trusted?' "$R" | grep -F 'm-a')"
has "render: the judge calibration line says model-graded" "$CAL_LINE" "model-graded"
has "render: the calibration line names the grader vendors" "$CAL_LINE" "OpenAI and Google, tie-breaker DeepSeek"
has "render: the calibration line gives kappa and agreement" "$CAL_LINE" "**kappa 0.50**: graders agreed on 14 of 17 runs"
has "render: the calibration line is dated with its n" "$CAL_LINE" "as of 2026-10-26, n = 17 runs"
has "render: the stored judge as grader 1 is named by vendor" "$(grep -F '| How far can the lane-quality judge be trusted?' "$R" | grep -F 'm-b')" "Anthropic and Google"
lacks "render: a superseded calibration row is not shown" "$(cat "$R")" "kappa 0.25"
has "render: the block defines model-graded kappa" "$(cat "$R")" "| **Model-graded kappa** |"
has "render: pdd figure" "$(cat "$R")" "**10.8%** of merged PRs were proof-first"
has "render: pdd interval and n" "$(cat "$R")" "| 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |"
has "render: test-first not measured yet" "$(grep -F '| Test-first adherence:' "$R")" "| not measured yet; it needs 30 |"
# Display names from the scripts/eval/README.md glossary; the data keys (proof_first, test_first) do not change.
has "render: the proof-first row carries its display name" "$(cat "$R")" "| Proof-first share (self-reported): both halves below | **10.8%** |"
has "render: the bottom line says self-reported" "$(cat "$R")" "of merged PRs were proof-first (self-reported)"
has "render: the block defines proof-first share (self-reported)" "$(cat "$R")" "| **Proof-first share (self-reported)** |"
has "render: the block says what self-reported means" "$(cat "$R")" "RED and GREEN are words the PR author wrote, not a test run the eval checked"
has "render: the block names the ticket created time as the proxy" "$(cat "$R")" "and was created before the first commit, and whose PR body names RED and then GREEN. The ticket's created time stands in"
has "render: the ticket-first row names the created-time proxy" "$(cat "$R")" "| The ticket had a DoD and a Proof and was created before the first commit | **19.2%** |"
lacks "render: no claim that the sections were written before the first commit" "$(cat "$R")" "Proof written before the first commit"
has "render: the block defines test-first adherence" "$(cat "$R")" "| **Test-first adherence** |"
has "render: the page points at the glossary" "$(cat "$R")" "(../../scripts/eval/README.md#what-each-number-means)"
lacks "render: the old proof-first name is gone" "$(cat "$R")" "Proof first"
lacks "render: the old test-first name is gone" "$(cat "$R")" "Test first"
has "render: test-first says how far from the floor" "$(cat "$R")" "n = 1 session scored under trajectory version 2"
has "render: pdd regenerate moves the cut past the new row" "$(cat "$R")" "with --until and --as-of moved past the new row"
has "render: interval printed" "$(cat "$R")" "77.8 to 94.2"
has "render: date and n under a figure" "$(cat "$R")" "as of 2026-10-25, n = 60"
has "render: cache regenerate saves the probe output" "$(cat "$R")" "1. \`bash scripts/eval/cache-probe.sh first-turn"
has "render: cache regenerate bounds the sample on both ends" "$(cat "$R")" "-newermt <first-day> ! -newermt <day-after-last-day>"
has "render: cache regenerate then feeds the data step" "$(cat "$R")" "2. \`python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt"
has "render: cache regenerate ends with the render step" "$(cat "$R")" "3. \`python3 scripts/cr/evals-page-gen.py render\`"
has "render: cache figure says cache reads, not tokens omitted from a request" "$(cat "$R")" "were cache reads"
has "render: links the review panel method page" "$(cat "$R")" "(review-panel.md)"
has "render: links the prompt cache method page" "$(cat "$R")" "(prompt-cache.md)"
eq "render: no bare percentage" "$(bare_pct "$R")" ""

# The checker itself must catch one.
printf 'precision is 50%% overall\n' > "$TMP/bad.md"
eq "checker: a bare percentage is reported" "$(bare_pct "$TMP/bad.md")" "precision is 50% overall"

# Determinism: the same inputs give the same bytes.
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --critics "$K" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/data2.json" > /dev/null 2>&1
eq "data: byte-stable across runs" "$(cmp -s "$OUT" "$TMP/data2.json" && echo same || echo differ)" "same"

# --until cuts the eval-runs rows too, and the regenerate command carries the cut and the cache scope.
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$C" --until 2026-10-24T00:00:00Z \
  --cache-scope "three days of sessions" --as-of 2026-10-25 --out "$TMP/cut.json" > /dev/null 2>&1
eq "until: a pdd-share row after the cut is left out" "$(jget "$TMP/cut.json" proof_first/pdd/pct)" "2.5"
has "until: the regenerate command names the cut" "$(jget "$TMP/cut.json" review/command)" "--until 2026-10-24T00:00:00Z"
has "until: the regenerate command names the cache scope" "$(jget "$TMP/cut.json" review/command)" "--cache-scope 'three days of sessions'"

# Test-first over the floor: 30 version 2 sessions, 20 ran a failing test first.
E30="$TMP/eval-runs-30.jsonl"
: > "$E30"
i=0
while [ "$i" -lt 30 ]; do
  if [ "$i" -lt 20 ]; then v=1; else v=0; fi
  traj_row 2026-10-25T03:00:00Z 2 "$v" >> "$E30"
  i=$((i + 1))
done
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E30" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/q1.json" > /dev/null 2>&1
eq "test-first: n over the floor" "$(jget "$TMP/q1.json" test_first/n)" "30"
eq "test-first: share" "$(jget "$TMP/q1.json" test_first/pct)" "66.7"
eq "test-first: Wilson low" "$(jget "$TMP/q1.json" test_first/wilson/lo)" "48.8"
eq "test-first: Wilson high" "$(jget "$TMP/q1.json" test_first/wilson/hi)" "80.8"
python3 -I "$GEN" render --data "$TMP/q1.json" --out "$TMP/q1.md" > /dev/null 2>&1
has "test-first: rendered with its interval" "$(grep -F '| Test-first adherence:' "$TMP/q1.md")" "| **66.7%** | 48.8 to 80.8 |"

# A bare slug beside the same slug with a model is labelled, never merged; a slug that never has a model stays bare.
L2="$TMP/ledger-bare.jsonl"
cp "$L" "$L2"
i=0
while [ "$i" -lt 30 ]; do
  printf '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"g%s","head":"h1","model":"gamma","finding_id":"g-%s","severity":"imp","verdict":"agreed","artifact":"diff","perspective":"off","text":"claim g-%s"}\n' "$((i % 3))" "$i" "$i" >> "$L2"
  i=$((i + 1))
done
printf '{"kind":"avail","ts":"2026-10-01T10:00:00Z","branch":"gm","head":"h1","model":"gamma","artifact":"diff","responding_model":"m1"}\n' >> "$L2"
printf '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"gm","head":"h1","model":"gamma","finding_id":"gm-0","severity":"imp","verdict":"agreed","artifact":"diff","perspective":"off","text":"claim gm-0"}\n' >> "$L2"
# A ledger tag of a panel reviewer that pins no model (CodeRabbit's findings outside the diff) is current, beside it.
i=0
while [ "$i" -lt 30 ]; do
  printf '{"kind":"finding","ts":"2026-10-01T10:00:00Z","branch":"o%s","head":"h1","model":"coderabbit-outside","finding_id":"o-%s","severity":"sug","verdict":"agreed","artifact":"diff","perspective":"off","text":"claim o-%s"}\n' "$((i % 3))" "$i" "$i" >> "$L2"
  i=$((i + 1))
done
python3 -I "$GEN" data --ledger "$L2" --eval-runs "$E" --critics "$K" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/bare.json" > /dev/null 2>&1
python3 -I "$GEN" render --data "$TMP/bare.json" --out "$TMP/bare.md" > /dev/null 2>&1
eq "label: the bare slug is kept apart from its named model" "$(jget "$TMP/bare.json" review/critics/gamma/n)" "30"
has "label: a bare slug with a named sibling reads model not recorded" "$(grep -F "| \`gamma\` (model not recorded) |" "$TMP/bare.md")" "**100.0%**"
has "label: one sentence says why those rows exist" "$(cat "$TMP/bare.md")" "names no answering model"
has "label: a slug that never names a model stays bare" "$(cat "$TMP/bare.md")" "| \`beta\` | required"
has "panel: a tag of a reviewer that pins no model sits beside it" "$(cat "$TMP/bare.md")" "| \`coderabbit-outside\` | part of \`coderabbit\`: findings on lines outside the diff | **100.0%** |"
has "panel: two retired reviewers under the floor are counted out" "$(cat "$TMP/bare.md")" "2 reviewers with fewer than 30 ruled findings are left out"

# One finding counts once, the way review-page.py --panel counts it: the same claim on the same file and
# line of the same PR, raised again in a later round or by another critic. dup raises claim A in two rounds (the later
# round unruled) and claim B once; echo raises claim A again; claim A on another PR is a second finding.
L3="$TMP/ledger-dup.jsonl"
: > "$L3"
dupf() { # ts model branch head id line text verdict
  printf '{"kind":"finding","ts":"%s","branch":"%s","head":"%s","model":"%s","finding_id":"%s","severity":"imp","verdict":"%s","artifact":"diff","perspective":"off","file":"a.py","line":"%s","text":"%s"}\n' "$1" "$3" "$4" "$2" "$5" "$8" "$6" "$7" >> "$L3"
}
dupf 2026-10-01T10:00:00Z dup d0 h1 dup-1 10 "- [important]: Off by one in the loop [a.py:10]" agreed
dupf 2026-10-01T11:00:00Z dup d0 h2 dup-2 10 "- [important]: Off by one in the loop [a.py:10]" ""
dupf 2026-10-01T11:00:00Z echo d0 h2 echo-1 10 "- [important]: Off by one in the loop [a.py:10]" disproved
dupf 2026-10-01T10:00:00Z dup d0 h1 dup-3 20 "- [important]: Unquoted path [a.py:20]" disproved
dupf 2026-10-01T10:00:00Z dup d1 h1 dup-4 10 "- [important]: Off by one in the loop [a.py:10]" agreed
python3 -I "$GEN" data --ledger "$L3" --eval-runs "$E" --critics "$K" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/dup.json" > /dev/null 2>&1; rc=$?
eq "dedup: data exits 0" "$rc" "0"
eq "dedup: a finding raised in two rounds and by two critics counts once in the pool" "$(jget "$TMP/dup.json" review/pooled/findings)" "3"
eq "dedup: the pool's ruled n is the distinct findings" "$(jget "$TMP/dup.json" review/pooled/n)" "3"
eq "dedup: a critic's repeat raise counts once in its row" "$(jget "$TMP/dup.json" review/critics/dup/findings)" "3"
eq "dedup: the later critic's row holds the finding too" "$(jget "$TMP/dup.json" review/critics/echo/findings)" "1"
eq "dedup: the merged finding takes the earliest ruled verdict" "$(jget "$TMP/dup.json" review/pooled/agreed)" "2"
eq "dedup: the same claim on another PR stays a separate finding" "$(jget "$TMP/dup.json" review/pooled/prs)" "2"

# write() replaces the output path, never writes through a symlink.
printf 'keep\n' > "$TMP/target.md"
ln -s "$TMP/target.md" "$TMP/link.md"
python3 -I "$GEN" render --data "$OUT" --out "$TMP/link.md" > /dev/null 2>&1; rc=$?
eq "write: rendering over a symlinked output succeeds" "$rc" "0"
eq "write: a symlinked output leaves the link target untouched" "$(cat "$TMP/target.md")" "keep"
if [ -L "$TMP/link.md" ]; then kind="symlink"; else kind="file"; fi
eq "write: the symlink is replaced by a regular file" "$kind" "file"
has "write: the replacement holds the page" "$(cat "$TMP/link.md")" "## How to read these numbers"

# Refusals.
python3 -I "$GEN" data --ledger "$TMP/missing.jsonl" --eval-runs "$E" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: a missing ledger is refused" "$rc" "2"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$TMP/missing-runs.jsonl" --cache-probe "$C" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: a missing eval-runs ledger is refused" "$rc" "2"
printf 'nothing here\n' > "$TMP/junk.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/junk.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: cache-probe output without a read-ratio is refused" "$rc" "2"
printf 'cache-probe first-turn\nread-ratio: 0.0%% over 0 tokens\nverdict: inconclusive warm=0 cold=0\n' > "$TMP/zero.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/zero.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: a zero-token cache probe is refused" "$rc" "2"
printf 'cache-probe idle-gap (cold expected at gap >= session TTL, warm expected at 60s <= gap < TTL)\nread-ratio: 97.4%% over 1200000 tokens\nverdict: ttl-consistent cold-expected=1 cold-rewrote=1 warm-expected=2 warm-rewrote=0\n' > "$TMP/idle.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/idle.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: an idle-gap probe is refused, first-turn only" "$rc" "2"
printf 'cache-probe idle-gap\nread-ratio: 97.4%% over 1200000 tokens\nverdict: warm-start warm=9 cold=1\n' > "$TMP/idle-warm.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/idle-warm.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: an idle-gap header is refused even with a warm=/cold= verdict line" "$rc" "2"
printf 'cache-probe first-turn\nread-ratio: 1..2%% over 1200000 tokens\nverdict: warm-start warm=9 cold=1\n' > "$TMP/dots.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/dots.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: an unparsable read ratio is refused, not a traceback" "$rc" "2"
printf 'cache-probe first-turn\nread-ratio: 120.0%% over 1200000 tokens\nverdict: warm-start warm=9 cold=1\n' > "$TMP/over.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/over.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: a read ratio above 100 is refused" "$rc" "2"
printf 'cache-probe first-turn\nread-ratio: 97.4%% over 1200000 tokens\n' > "$TMP/noverdict.txt"
python3 -I "$GEN" data --ledger "$L" --eval-runs "$E" --cache-probe "$TMP/noverdict.txt" --as-of 2026-10-25 --out "$TMP/x.json" > /dev/null 2>&1; rc=$?
eq "data: a probe without its verdict line is refused" "$rc" "2"

# ── The committed page ───────────────────────────────────────────────────────
eq "page: committed README is the render of the committed data file" \
  "$(python3 -I "$GEN" render --data "$DATA" --out "$TMP/committed.md" > /dev/null 2>&1; cmp -s "$TMP/committed.md" "$PAGE" && echo same || echo differ)" "same"
eq "page: no bare percentage" "$(bare_pct "$PAGE")" ""
eq "page: this suite runs in PR CI, so a hand edit of the page fails the PR" \
  "$(awk -F'\t' '$1 == "scripts/cr/test-evals-page-gen.sh" { print $2 " " $3 }' "$ROOT/scripts/ci/suite-tiers.tsv")" "pr static-gate"
lacks "page: no draft marker" "$(head -5 "$PAGE")" "draft:"
eq "page: on the site allowlist" "$(grep -cx 'evals/README.md' "$ROOT/site/allowlist.txt")" "1"
eq "page: in the site nav" "$(grep -cF "slug: 'evals' }" "$ROOT/site/astro.config.mjs")" "1"
# The page's headline figures live in the data file only, never in the generator.
figs="$(grep -oE '\*\*[0-9][0-9.]*%\*\*' "$PAGE" | tr -d '*%' | sort -u)"
has "no typed figure: the page has headline figures to check" "$figs" "."
for lit in $figs; do
  eq "no typed figure: '$lit' absent from the generator" "$(grep -cF -- "$lit" "$GEN")" "0"
done

echo "evals-page-gen: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
