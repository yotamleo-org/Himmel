# scripts/eval

himmel's evals: each one measures one thing and writes its own output.

| Eval | Measures | Own output |
|---|---|---|
| `lane-quality/` | a lane or model on fixed tasks: acceptance, scope, judge scores, cost | `runs.jsonl` per sweep |
| `qmd-quality/` | qmd retrieval: hit@1, hit@5 and MRR per mode, plus latency | `scores.tsv`, `latency.tsv` |
| `docs-review/` | the `docs-reviewer` skill on frozen docs PRs: the operator's points found, the code fix named, BLOCKING true against false | a hand-scored result per case (no ledger row) |
| `guard-corpus/` | a hook change, base vs head, over a command corpus | `diff` stdout plus a `JSON` line |
| `scrape-bench/` | scrape providers on a fixed URL set | one JSONL row per URL |
| `retrieval-eval/` | `retrieval-eval.py`: grep, qmd-lex, qmd-hybrid, graphify and combined (plus opt-in qmd-hybrid-norerank) on transcript-mined questions: recall@k, reason-carried, tokens and ms; `census` counts qmd and graphify use per session role | `results.jsonl`, `scores.tsv` |
| `retrieval-eval/answer-ab.py` | tokens to a correct answer, end to end: a haiku answerer on the questions it fails closed-book, with no retrieval, grep, path + ident-grep, graphify or fused output pasted in; total session tokens per correct answer per arm | `table.tsv`, `results.jsonl` (no ledger row) |
| `handover-cost.py` | the per-handover chief price from session JSONLs: prep, relay+wrap, successor ACTION ZERO and worker-relay turns and cost, gross and net (HIMMEL-6491 method); `--workers-after` counts only newer workers | one `HANDOVER` row per pair plus a `MEAN` row on stdout (no ledger row) |
| `chief-wake-classes.py` | the chief wake mix for one date from session JSONLs: wakes, requests and eq per class (operator, relay-only, escalate) and per wake kind, priced with `handover-cost.py` (HIMMEL-2975 plan method); `--exclude` drops live chiefs | `CLASS` and `KIND` rows on stdout (no ledger row) |
| `compaction-handoff/compaction-defects.py` | the defects in the N turns after each compaction vs a control window, cost-eq per turn on both sides, and a ceiling replay | JSON or a table on stdout (no ledger row) |
| `compaction-handoff/ab.py` + `ab_tasks.py` | a bounded, billed A/B of the 200k compaction loop, a 450k ceiling with compaction and a 450k ceiling with a hand-off on three generated tasks: hidden check, blind judge, defects, cost-eq and wall time per run; `sweep` is resumable under a cost ceiling and a bank preflight before every cell (`HIMMEL_BILLED_OK=1`) | `summary.json` and `judge.json` per run, a table and a recommended arm per profile from `score` (no ledger row) |
| `weekly-rollup.py` | velocity, cost and health per ISO week and per stable version, with the change against the previous row; `review` prints the three version-review lines ([`docs/release/version-review.md`](../../docs/release/version-review.md)) | `~/.himmel/state/rollup/weekly.jsonl` (`WEEKLY_ROLLUP_FILE`; ledger row `weekly-rollup`) |
| `review-page.py` | the reviewers in plain words: how often the critics catch planted bugs and are right, how often a bug gets past a judge's GO, the trend since the last run, and each feedback change with its re-measured result | one Markdown page on stdout or `--out` (no ledger row) |
| `deferred-outcome.py` | what became of each deferred CR-ledger finding: its follow-up ticket in the Jira mirror is done (fixed later), open, or closed Won't Do (disproved), overall and per critic | ledger row `deferred-outcome` |
| `escapes.py` | bugs found after merge (a revert, a caused-by bug, a later fix naming the PR) per merged PR, then per critic that reviewed it and per judge that passed it; reads a `gh pr list` snapshot | ledger row `escapes` |
| `steering-cull/` | each approved cut of the always-on steering text (repo and user `CLAUDE.md`): tokens and cost-eq saved per session, and whether a RED-first probe still passes on the cut text; a SHIP or KEEP verdict per row | `report` table on stdout; ledger row `steering-cull` |
| `worktree-latency-curve.sh` | git list, status, add and remove latency against live worktree count, in a scratch repo | one TSV row per step on stdout (no ledger row) |

## What each number means

The display name is what a page or report prints. The ledger key is the
number's name in an eval-runs row (`metrics`, or `ci` for an interval). A key
does not change with its display name, so its series stays one series.
This table holds no values: read them on the generated evals page,
[`docs/evals/README.md`](../../docs/evals/README.md), or in the output of
`review-page.py`. The sections below give each eval's method. Paths in the last
column are relative to `scripts/eval/` unless they start with `scripts/`.

| Number | Ledger key | What it measures | High or low | Unit | Sample and noise | Producer |
|---|---|---|---|---|---|---|
| pass@k | `pass_at_k` (k is `pass_k`, the fewest repeats of any task) | The chance that at least one of k repeats of a task is accepted, averaged over the tasks. | High: the lane solves the task within k tries. Near 1 on every lane means the tasks no longer tell lanes apart. | share, 0 to 1 | Needs `--reps` of at least k; rows are compared only at the same k. A noise band, no interval. | `lane-quality/` via `lib/eval_runs.py` |
| pass^k | `pass_pow_k` | The chance that all k repeats of a task are accepted, averaged over the tasks. | High: the lane solves the task every time. The gap below pass@k shows how inconsistent it is. | share, 0 to 1 | As pass@k; with few repeats it moves a lot. | `lane-quality/` via `lib/eval_runs.py` |
| cost per accepted run | `cost_per_accepted` | The total cost of all the sweep's runs divided by the number that passed the hidden acceptance check. | Low: a correct result costs less. Empty when no run was accepted or any run's cost is missing. | USD, API-equivalent | One sweep; cache state moves it. A relative noise band. | `lane-quality/` via `lib/eval_runs.py` |
| headroom | `_headroom` in `eval-compare.json` (a rule, not a metric) | Whether the baseline's `accept_ok_rate` is at or above the rule's `at` value. | When the `HEADROOM` line prints, quality is near its ceiling and cannot show much gain: read cost and latency instead. | advisory line | Never gates and skips no regression check. | `eval-compare` |
| test-first adherence | `red_before_green_rate` | The share of runs where a test failed before the first implementation write and passed after it. | High: the lane works test-first. | share, 0 to 1 | Only runs with an implementation write count. A quiet-run test is decided by its `OK` or `ERR` line alone; any other test run fails on a non-zero exit, or a `FAIL` line or a non-zero `N failed` count; see [trajectory fields](#lane-quality-trajectory-fields). | `lane-quality/trajectory.py` via `lib/eval_runs.py` |
| claims-backed rate | `verify_before_claim_rate` | The share of runs whose final report claims passing tests only where a passing run after the last write backs the claim. | High: a claim of green can be trusted. Low: the lane reports tests passing without running them. | share, 0 to 1 | Only runs whose report makes such a claim count. Claims are found by a sentence regex. | `lane-quality/trajectory.py` via `lib/eval_runs.py` |
| denial recovery rate | `denial_recovery_rate` | The mean share of hook or permission denials after which the next call changed approach, or no call followed. | High: the lane does not repeat a refused call. | share, 0 to 1 | Only runs with a denial count. A respelled command counts as a change. | `lane-quality/trajectory.py` via `lib/eval_runs.py` |
| identical retries after a denial | `identical_denied_retries` | The number of calls repeated exactly after they were denied, summed over the sweep. | Low: 0 is the goal. | count | Grows with the number of runs. | `lane-quality/trajectory.py` via `lib/eval_runs.py` |
| false-refusal share | `over_deny_share` (per class: `over_deny:<source>/<class>`) | Of the guard refusals with a known verdict, the share that blocked a call which should have run. | Low: the guards rarely block legitimate work. | share, 0 to 1 | Verdicts come from a fixed table of refusal classes; `unclear` refusals are on neither side. Feedback reads the per-class count per `tool_calls`. | `friction/friction.py` |
| detection rate | `<critic>.recall` (`panel.recall` for the panel, `<critic>.class.<class>.recall` per bug class) | The share of planted bugs a critic flagged at the right place with the right class. | High: the critic catches the bugs. | share, 0 to 1, with a Wilson interval (none per bug class) | Planted bugs in a fixed set of test changes, not real bugs. Small n: read the interval. | `review-panel/score.py` |
| planted-bug precision | `<critic>.precision` | The share of a critic's findings on the test changes that match a planted bug. | High: few findings are noise. | share, 0 to 1, with a Wilson interval | A real issue that was not planted counts against it. | `review-panel/score.py` |
| false-alarm rate | `<critic>.fp_rate` | The share of clean test changes (no planted bug) on which the critic raised a critical or important finding. | Low: the critic does not hold clean work. | share, 0 to 1, with a Wilson interval | Few clean changes per run. | `review-panel/score.py` |
| detection floor | none: printed on the `paired` line of `eval-compare` | The estimated smallest mean per-case change the shared cases detect (80 % power, 5 % significance); see [eval-compare](#eval-compare). | Read the paired verdict, not the floor: a sign-test REGRESSION below the floor still gates. More cases lower it. | the metric's own unit | A normal approximation; unestimated for a continuous score with no spread. | `eval-compare` |
| escape rate | `escape_rate` (`escape_rate_plausible` counts the likely ones too) | The share of merged PRs that a revert or a caused-by bug points at. A later fix naming the PR is only a likely escape, so it counts in `escape_rate_plausible` alone. | Low: few bugs get past review and approval (you, or the chief's GO; a judge only on trust paths). | share, 0 to 1, with a Wilson interval | Lags: a recent PR has had less time to show a bug. Reads a `gh pr list` snapshot. | `escapes.py` |
| proof-first share (self-reported) | `pdd.pct` (halves `ticket_first.pct` and `red_green.pct`; `.k` and `.n` beside each) | The share of merged PRs whose ticket has a DoD and a Proof and was created before the first commit, and whose body names RED then GREEN. | High: work is proven before it is built. | share, 0 to 1, with a Wilson interval | The ticket's created time stands in for when the sections were written (the mirror keeps no description history), so a section added later reads as early. Self-reported: RED and GREEN are words the author wrote, not a checked test run. The row is `partial` below `--min-n` readable PRs. | `worker-digest/pdd_share.py` |
| Wilson interval | `ci` with `ci_method` `wilson` (`ci_level` 0.95) | A 95 % range for a share of k in n that stays between 0 and 1 and holds at small n. | Narrow: the share is well measured. Wide: too few cases to rank. | `lo` and `hi`, in the share's unit | Covers sampling noise only, not a biased sample. | `worker-digest/pdd_share.py`, `review-panel/score.py`, `escapes.py`, `judge-accuracy/` |
| review precision | `precision_pct` in `docs/evals/evals-data.json` (no eval-runs row) | Of the real review findings the author ruled true or false, the share ruled true. | High: a finding is usually right. | percent, with a Wilson and a by-PR bootstrap interval | The author who rules is the one who fixes. Deferred and unruled findings are on neither side. | `scripts/cr/evals-page-gen.py` |
| cache read share | `read_ratio_pct` in `docs/evals/evals-data.json` (`hit_pct` in `cache-health.py`, `cache_hit_pct` in `weekly-rollup.py`) | The share of input tokens read from the prompt cache rather than sent uncached or written to the cache. | High: sessions cost less. | percent | No interval. The evals page reads one `cache-probe.sh` run over recent sessions; `cache-health.py` reads a recent window against a baseline window; `weekly-rollup.py` takes the mean of the cache-health history over the week. | `cache-probe.sh` via `scripts/cr/evals-page-gen.py`, `cache-health.py`, `weekly-rollup.py` |

## The eval-runs ledger

Every run of these four evals also appends one row to
`~/.himmel/eval-runs.jsonl` (override: `HIMMEL_EVAL_RUNS_LEDGER`). That gives
one place to see how an eval has done across commits. The ledger is registered
as `eval-runs` in `scripts/observability/ledgers.json`.

- **Writer:** `lib/eval_runs.py`, Python stdlib only. Python evals import it and
  call `make_row` and `append_safe`; the bash evals call its CLI.
- **Schema:** the full v1 schema is in the docstring at the top of that file.
- **No model calls:** the writer never calls a model.
- **Failures:** a failed ledger write prints a warning and never changes the
  eval's own exit code.

What a row holds:

- The envelope: `v`, `ts`, `host`, `source`, `kind`.
- What was run: `run_id`, `eval`, `status`, `gitsha`, `git_dirty`, `model`,
  `lane`, `n` and `reps`.
- `config` with `confighash`. `config` holds the inputs that change what a
  score means. It never holds the git sha, so one config forms one series
  across commits.
- `metrics`: run-level numbers.
- `ci`, `ci_level` and `ci_method`: intervals, when the eval has them.
- `cases`: per-case scores, used for a paired compare.
- `artifact`: the path to the run's own output.
- `meta`: descriptive fields that are not hashed.

`status` is `ok`, `partial` (the run was cut short, for example by a budget
cap or a needs-auth URL) or `inconclusive` (the run measured nothing usable).
Only `ok` rows serve as baselines.

Tests always set `HIMMEL_EVAL_RUNS_LEDGER` to a temp path, so they never write
the live ledger.

Check a ledger: `python3 scripts/eval/lib/eval_runs.py validate <ledger>`.

## Tokens to a correct answer (answer-ab)

The retrieval token goal is the cost of reaching a correct answer, not the size of
one call. `retrieval-eval/answer-ab.py run --questions retrieval-eval/questions.jsonl --out DIR`
screens a sample with a haiku answerer and no retrieval, keeps the questions it fails,
then answers each once per arm with that arm's output pasted in. The answer is a list
of at most three file paths, correct when one is a gold file. `tokens_per_correct` is
an arm's total session tokens (input, cache creation, cache read, output) over its
correct answers.

First run, 2026-10-21, claude-haiku-5-5, 20 sampled, 15 failed closed-book and kept
(`--pool 20 --n 15`), one answer per question and arm, $0.21:

| arm | correct | tokens total | tokens per correct | retrieval tokens (mean) |
|---|---|---|---|---|
| none (no retrieval) | 1/15 | 74879 | 74879 | 0 |
| grep | 6/15 | 110554 | 18426 | 1217 |
| path + ident-grep | 10/15 | 86152 | 8615 | 349 |
| graphify | 11/15 | 286112 | 26010 | 6818 |
| fused (grep + qmd-hybrid + graphify) | 12/15 | 335064 | 27922 | 8535 |

The baseline is below 15/15, so the A/B has no ceiling. Every arm carries a fixed
session overhead of about 4.2k tokens, which the none row shows. Reading the table:
path + ident-grep costs the least per correct answer; graphify and fused answer one to
two more questions but at about three times the tokens per correct answer.

Limits: one sample of 15, one answer per cell (the none arm answered 1 of 15 here
after failing all 15 in the screen, so a cell is noisy by about one question); the
retrieval output is pasted into one turn rather than reached by tool calls, so it
does not price a session that searches in several steps; fused uses qmd-hybrid, which
returns nothing when the qmd server is down.

## eval-compare

```
scripts/eval/eval-compare <eval> [--baseline <run-id> | --best-of N]
                                  [--ledger PATH] [--thresholds PATH]
```

The candidate is the eval's newest row. The baseline depends on the flags:

- **No flag:** the newest earlier `ok` row with the same `confighash`.
- **`--baseline ID`:** that run, whatever its config, if its status is `ok`.
  The candidate's own id is refused (exit 2): a run is not its own baseline.
- **`--best-of N`:** per metric, the best value among the last N earlier `ok`
  rows with the same config.

For each metric it prints the baseline, the candidate and the delta.

A metric regresses when it moves the wrong way past its noise band:

- **Both rows carry a CI:** the two intervals do not overlap.
- **Only one row carries a CI:** the other row's value falls outside it.
- **No CI:** the change is larger than the metric's band in
  `eval-compare.json`. That file has one table per eval, keyed by metric name
  or glob; a band is absolute (`band`) or a fraction of the baseline
  (`band_rel`).

A metric with no direction in that table is printed as `info` and never gated.

Against a single baseline (not `--best-of`), `_cases` in that table names
per-case metrics to compare on the case IDs both rows share. At least two
shared valued cases are needed. The paired line reports the mean
candidate-minus-baseline change, an exact two-sided sign-test verdict (5 %
over the cases that moved), and the **detection floor**: the estimated smallest
mean change this case count can show (2.8 standard errors, a normal
approximation at 80 % power and 5 % significance). With zero spread, binary
scores use a conservative `2.8 / sqrt(n)` floor; a continuous score's floor
is unmeasured. A paired regression gates just like a run-level one. A spec's
`same` names a metric that must match on both rows, so pass@k at different k
is not compared as the same quantity.

`_headroom` holds `{metric, at, target}`. When the baseline metric is at or
above `at`, a `HEADROOM` line points to the target metrics (such as cost and
latency): quality near its ceiling cannot show much gain. The line is
advisory; it does not skip regression checks.

A candidate whose `meta.observational` is true (the `leg-trajectory` rows) is
not compared at all: eval-compare lists the series (the latest `ok` row per
`run_id`, same `confighash`) with runs, mean and latest per metric, prints no
verdict and exits 3. The exporter likewise emits no `baseline_delta` or
`regression` sample for such rows.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | no regression |
| 1 | regression |
| 2 | usage error |
| 3 | nothing to compare (no candidate, no baseline, a candidate whose status is not `ok`, no gated metric with a value on both sides, or a malformed ledger line after the candidate, which may be this eval's newest run); never a pass |

## Eval feedback: a result drives one change, the next run re-measures it

```
python3 scripts/eval/lib/eval_feedback.py run [--eval E]... [--ledger P] [--changes P] [--rules P] [--inbox P]
```

`lib/eval_feedback.py` closes the loop on the eval-runs ledger. For each eval
named in `feedback-rules.json`, over that eval's newest `ok` row:

1. **Measure.** Each open change of that eval whose baseline row is older and
   has the same `confighash` gets one `measured` record: before, after, delta,
   and `improved`, `regressed` or `flat`.
2. **Change.** When that row is not yet the baseline of a change, the first
   rule with a metric worse than its threshold raises one `open` change record
   on the worst such metric. The change is a `learning` (a memory-inbox
   candidate line, written once when `--inbox` is given; a change opened
   without `--inbox`, or whose write failed, is delivered by the next run
   with `--inbox`), a `routing` change or a
   `tool-ruling` (keep, slim or retire), aimed at the rule's `target`.

Records go to the `eval-changes` ledger (`$HIMMEL_EVAL_CHANGES_LEDGER`, else
`~/.himmel/eval-changes.jsonl`). The daily failure review
(`worker-digest/failure_review.py`) runs this step after the friction
subsection and shows what it wrote under `### Eval feedback`. Its friction
run passes `--record`, so `friction.py` appends one `eval: friction` row per
run (`tool_calls`, refusals by verdict, `over_deny_share`,
`over_deny:<source>/<class>`). `tool_calls` counts every `tool_result` in the
same transcript window, including successful, failed and denied calls; it
counts observed results, not outstanding calls with no result.

A rule's optional `per` names a metric of that same row. Feedback judges
`metric / per`, both when opening a change and when re-measuring it; a missing
or zero denominator is unmeasured, not zero. The friction rule uses
`per: tool_calls`, so the same over-denial count can fire with few calls but
not with many. Its provisional threshold is `0.1`, half the fixture class's
rate of 1 over-denial in 5 calls (`0.2`).

**ponytail:** no recorded tool-call history yet; upgrade: re-derive the
threshold once 4 weekly friction rows carry `tool_calls`.

Split rows carry `open.<metric>` (train) and `sealed.<metric>` (test),
beside any whole-set metric. Rules tune on the open half only, never on the
sealed or whole-set values; a sealed-only row opens no change. A missing
metric in either half stays unmeasured, even when the rule has `absent: 0`.

The **train/test keep rule** replaces `improved` / `regressed` / `flat` with
`keep` / `revert` when a change is re-measured on a split row. Keep requires
both train and test to gain strictly more than `min_gain` (optional, default
`0`, the smallest worthwhile gain), with run-to-run noise zero or strictly
below `min_gain`. Noise is the spread (max minus min) of train values in at
least two `ok` runs of the same `confighash` up to the baseline. Otherwise
revert: the record's `reason` names the first failing check (unmeasured test,
insufficient train or test gain, or unmeasured/excessive noise), beside the
test before/after/delta, noise and `min_gain`.

## routing: which skill, command, agent or MCP tool a model picks

```bash
bash scripts/eval/routing/run.sh --model haiku --dry-run                  # list the cases, no call
HIMMEL_BILLED_OK=1 bash scripts/eval/routing/run.sh --model haiku --out D  # billed: one claude -p per case
node scripts/eval/routing/listing.mjs --json >/tmp/listing.json && python3 scripts/eval/routing/score.py lint --listing /tmp/listing.json
```

`routing/cases/open.jsonl` and `sealed.jsonl` hold 47 cases mined from real
misroutes and session picks: request, context, the expected pick (or `none`),
near picks and a source line. `listing.mjs` renders the listing a model sees:
the repo's and the `inventory.json` plugins' skills, commands and agents, the
himmel-bus MCP tools, and the frozen entries of `external.json` that himmel
does not own. `run.sh` gives each case to `claude -p` with that listing as the
system prompt, no tools and an empty cwd, and keeps the JSON envelope.
`score.py` scores the first pick as exact, near, miss or false, and writes
`results.json`, a `table.md` and one `routing` ledger row with
per-case `exact` and `false_pick`. Every metric also comes as `open.*` and
`sealed.*`; tuning reads the open half only. The results files and the run log
carry per-case rows for the open half only and the sealed half as aggregate
numbers, since a sealed pick or outcome hints at what the case expects. Spend is capped at $0.10 a call
(`--max-usd`) and $5 a run (`--ceiling-usd`). `--seed-broken A,B` gives B the
description of A in the rendered listing only, the eval's broken control;
`test-score.sh` proves that control drops sealed accuracy by 25 points on a
fixture with a stub model.

Baseline (2026-10-29, listing of 155 entries, about 4,700 tokens;
`routing/results/`):

| model | accuracy | open | sealed | near | false pick | cost |
|---|---|---|---|---|---|---|
| haiku | 0.81 | 0.87 | 0.75 | 0.15 | 0.04 | $0.01 |
| sonnet | 0.85 | 0.96 | 0.75 | 0.15 | 0.00 | $0.20 |
| opus | 0.91 | 0.96 | 0.88 | 0.09 | 0.00 | $0.39 |

Phase 2 (HIMMEL-8088) hill-climbed the descriptions, then trimmed the listing to
3,257 tokens. Sealed accuracy after the trim is haiku 0.86, sonnet 0.89 and opus
0.93, means over 3 to 5 reps. `routing/results/phase2-summary.md` has every arm.

**ponytail:** the listing renders every description uncapped, as an operator
session sees it; upgrade: a `--profile` flag that applies a launch profile's
name-only overrides and lists MCP tools by name until ToolSearch.

## lane-quality: repeats and judge calibration

`run.sh run --reps N` runs the task set N times into one run dir. `table`
then shows the mean and a bootstrap 95% CI over the repeats for each task and
criterion. It counts the rows with no judge score instead of dropping them.

The ledger row carries:

- `reps`.
- A stratified bootstrap CI for each run-level metric. The repeats are
  resampled within each task.
- From 2 repeats on, per-task metrics: `<task>.judge_<criterion>`,
  `<task>.accept_frac` and `<task>.judge_missing`.

`run.sh calibration <run-dir>...` measures how far the judge can be trusted:

- **Judge vs acceptance:** the AUC and point-biserial r of each criterion
  against the hidden acceptance result (`accept_ok`), each with a bootstrap
  95% CI.
- **Judge vs judge:** with `--judge2-model` (and optionally
  `--judge2-effort`), it re-judges every stored judge packet once and reports
  quadratic weighted kappa per criterion. It reuses stored second-judge
  results, so a rerun makes no call.
- **Runs with no packet:** a run the sweep never judged has no judge packet.
  Without `--sample` the grading pass leaves such runs out, prints how many
  on stderr and still records the row. `--sample` lists the packets to grade;
  if a listed packet is missing and has no stored result, the pass stops
  with exit 75 and records no row.
- **Ledger:** it appends one `lane-quality-calibration` row unless you pass
  `--no-ledger`.

The first real multi-rep sweep is a chief step. Run it on a quiet fleet: 3
repeats of the 4 tasks on one native lane. That is about 12 agent runs plus
their judge calls. For scale, one stored native haiku sweep of the 4 tasks
cost about 0.57 USD API-equivalent. Note the bank reading before and after.

```bash
bash scripts/eval/lane-quality/run.sh run --lane native --model claude-haiku-4-5-20251001 --reps 3 --max-usd 3
bash scripts/eval/lane-quality/run.sh table ~/.himmel/eval/lane-quality/<run-id>
bash scripts/eval/lane-quality/run.sh calibration ~/.himmel/eval/lane-quality/<run-id> --judge2-model sonnet --max-usd 1
```

## lane-quality: trajectory fields

`lane-quality/trajectory.py` reads a run's session transcript and scores four
fields. It makes no model call and draws no bank. `run.sh` writes the fields
into each `runs.jsonl` row. The lane adapter in `lib/eval_runs.py` adds them
to the ledger row:

- `red_before_green_rate`, `denial_recovery_rate` and
  `verify_before_claim_rate`, each over the rows where the field is not null;
- `identical_denied_retries`, a sum.

A run dir written before these fields gets null metrics, and the row schema
does not change.

Terms the definitions use:

- **Test run:** a Bash call whose command runs a test file, directly or
  through an interpreter. A test file's basename is `test-*`, `test_*`,
  `*-test`, `*_test` or `*.test` with a script extension, or any `.bats`.
  A runner (`pytest`, `python3 -m pytest`, `bats`) runs the test files it
  names; one that names none, or `npm test` and the like, matches any test.
  `bash -n` (also inside a flag group such as `-nx`) is a syntax check, not
  a run, and so is a runner given a flag that only lists, counts or
  describes tests (`--collect-only`, `--help`, `--count`, bats `-c` and the
  like). The command is split into commands at `&&`,
  `||`, `;`, `|`, `&` and newlines outside quotes.
- **Outcome:** a test run passed if its tool result is not an error, and
  failed if it is. A run whose exit status is masked has no outcome. It is
  masked when the command holds a pipe, `||` or `&`, or when a command
  follows the test after `;` or a newline. A failure in an `&&` chain counts
  only when every other command in the chain is setup (`cd`, `pushd`,
  `export`, `source`, `.`, `set`, `umask`), since the failure may be the
  other command's; a pass in an `&&` chain always counts. A run wrapped in
  `quiet-run.sh` is decided by its `OK` or `ERR` line whatever surrounds it,
  and has no outcome when that line is missing. A run whose tool result is
  not an error but whose output has a `FAIL` line or a non-zero `N failed`
  count failed.
- **Denial:** a tool result that is an error, does not start with
  `Exit code` (that is a command that ran and failed), and reads as a hook or
  permission refusal. A denied call never ran, so it is never a test run.
- **Implementation write:** a successful Write, Edit, MultiEdit or
  NotebookEdit of a file that is neither a test file nor a doc (`.md`,
  `.markdown`, `.txt`, `.rst`, `.adoc`).
- **Identical:** the same tool name and the same input, compared as
  canonical JSON.

The fields:

- **`red_before_green`:** true when a test run failed before the first
  implementation write and a test run passed after it. False when either run
  is missing. Null when there was no implementation write, whatever test runs
  there were: a session that writes no code has no test-first to score
  (`trajectory_v` 2; v1 scored a test run without a write false).
- **`denial_recovery`:** the fraction of denials recovered from. A denial is
  recovered when the next call issued after its result is not identical to the
  denied call, or when no call follows. Calls sent in parallel with the denied
  one do not count as the next call. Null when there was no denial.
- **`identical_denied_retries`:** the number of calls, issued after a
  denial's result, that are identical to the denied call. They count whether
  or not they come right after it. 0 when there was no denial.
- **`verify_before_claim`:** true when every claim of passing tests in the
  final report is backed by a test run that passed after the last non-doc
  write. A claim that names test files needs a run of one of them; a runner
  run backs any claim. The report is `<stem>.report.md` when it exists, and
  otherwise the assistant text after the last tool call. A claim is a
  sentence that names tests, suites, cases, checks or a test file with a pass
  word
  (`pass`, `green`, `succeed`) and is not negated. Null when the report makes
  no such claim.

Known ceilings:

- A quiet-run test is decided by its `OK` or `ERR` line alone; any other
  test run fails on a non-zero exit, or a `FAIL` line or a non-zero
  `N failed` count. A runner that reports a failure any other way and exits
  0 reads as passing.
- A respelled command (another path to the same file) counts as a changed
  approach.
- Files written through Bash (`cat >`, `sed -i`) are not seen as
  implementation writes.
- A RED caused by a syntax error in the test file still counts as a RED.
- Order is the order calls were issued, except that a test run sent in the
  same assistant message (same `message.id`) as the write it is compared
  with is unordered relative to it and counts as neither a RED before that
  write nor a pass after it. A transcript without `message.id`
  falls back to issue order.
- Claim detection is a sentence-level regex, so an unusual wording can be
  missed or misread.

To re-score stored runs (read only, no model call):

```bash
python3 scripts/eval/lane-quality/trajectory.py rescore ~/.himmel/eval/lane-quality/<run-id> --transcripts ~/.claude/projects
```

`score --denials` adds `denials`, one `{tool_call_id, recovered, identical}`
per denied call, and `trajectory_v`. `identical` counts each later identical
call against the most recent identical denial before it, so the counts sum to
`identical_denied_retries`. Without the flag the output is unchanged.

## worker-digest: one worker's failures as class keys

`worker-digest/worker-digest.ts` (Bun) reads a worker's journal and its subagent
transcripts, merged in the order the AG-UI page uses. It maps them with the
AG-UI mapper and prints one digest JSON. It is read-only, makes no model call
and writes nothing; `worker_ledger.py` (below) turns a digest into ledger rows.

```bash
bun scripts/eval/worker-digest/worker-digest.ts --transcript ~/.claude/projects/<slug>/<session>.jsonl
bun scripts/eval/worker-digest/worker-digest.ts --session <uuid>   # resolved under ~/.claude/projects
```

- **Class key** `<failure>/<sub>`. `<sub>` comes from closed vocabularies,
  never from journal text:
  - `denied/<hook>`: a `scripts/hooks/*.sh` basename.
  - `denied/classifier:<category>`: the category is read from the
    classifier-denials ledger row of the same tool nearest in time, else from the journal's `Reason: [...]`, and is
    kept only if it is on the digest's fixed list.
  - `denied/permission-prompt`.
  - `suite/<tracked test basename>`, with `final_red`.
  - `blocked/-`.
  - `error/<allow-listed tool | mcp>`.
  - `run_error/<listed code>`.
  - `traj/*` rows, taken from the trajectory fields.
  - Anything else is `other`.
- **Recovered / identical retry** on main-agent denied rows come from
  `trajectory.py score --denials`, joined by `tool_call_id`.
- **Status** is `ok`, or `partial` (malformed lines, the subagent cap was
  hit, a file could not be read, `trajectory.py` failed, or the hook or
  tracked-test lookup failed), or
  `inconclusive` (no journal, or over 200 MB).
- **Cross-check:** `stats.denial_divergence` lists the main-agent denials that
  only one detector saw. `test-worker-digest.sh` fails on any divergence not
  enumerated in `worker-digest/denial-exceptions.txt`.
- **Cost:** measured 2026-10-06, 3 runs each:
  - 0.11–0.21 s wall on three recent worker journals of 3.6–6.5 MB;
  - 1.50 s wall on the station's largest journal (58 MB).

  The budget is 5 s per worker.

### Tool health

Digest v2 adds `metrics.tool_calls_by_tool`, `metrics.tool_failures_by_tool`
and per-agent `tool_health` rows (tool, calls, failures, errors, denials,
class counts and lane). Built-in tools and conventional lowercase MCP tool
identifiers stay separate; other MCP identifiers use `mcp`, unlisted tools
use `other`. Arguments and result text never become tool keys. Text-only
blocked reports and trajectory findings are not tool failures; a grep
no-match remains a successful call.

`worker_ledger.py` stores these rows in the existing registered eval-runs
ledger's `meta.tool_health`, with the session's first timestamp in
`meta.started_ts`. No new ledger or writer is introduced. The recorder stamps
the persisted digest and its tool rows with launch provenance: explicit
`--lane`, else the assigned worker's title in the worker doc, else the extractor's
`WORKER_SESSION_LANE`; missing provenance is `unknown`. Canonical environment lanes are
native, claudex, openrouter, cloud and unknown; the recorder normalizes the
historical codex label in explicit recorder input or document titles to claudex.
Backfill never borrows its own launcher's lane or guesses from a model.

`worker-digest/tool-health.mjs` reads eval-runs and worker-failures and computes UTC
calendar-day rollups by model, lane and worker-vs-chief role. Rates use summed
counts, never averages of session percentages. Deny-hook rates divide by
Bash calls across the selected population. Recovery is count-weighted over
known class outcomes (the ledger's boolean describes the entire class row);
unknown outcomes are excluded. Daily rows carry lane; summary rows aggregate
the explicitly selected lanes. Old digests without denominators retain their
failure counts but show no rate, including mixed old/new populations.
Partial/inconclusive digests preserve observations but cannot certify complete
denominators either.
A `since` cutoff uses day cohorts; a partial first UTC day has unknown
call denominators because daily data cannot certify an intraday shift rate.

The config-ui Tool health page and chief board share this reader. The
page shows 7/30-day trends, top classes and session/tool-call-id drill-down,
plus per-lane comparisons and deltas relative to native. All rate math stays
on the server; the page is read-only. Overrides are
`HIMMEL_EVAL_RUNS_LEDGER` and `HIMMEL_WORKER_SESSION_FAILURES_LEDGER`.

Time to result: the digest keeps, per tool row, `timing` = the times (RESULT
time minus START time) of calls issued alone, of calls that shared an API
message, and a count of calls with no time. The page's p50 and p95 come from the
calls issued alone, with n, and it labels the figure "time to result (includes
waiting and hooks)", never a run time. A call without a result shows a dash,
never 0; a digest written before the times were kept leaves its calls unknown.

Why a guard refused: the page joins each counted refusal to its hook-chain row
by call id. The reason rows count only refusals with such a row; the rest are
"recorded before reasons were logged" (the refusal ended before the first
run-log row, `hook-runs.jsonl`) or "no reason row, cause not established", so
the rows and the two residuals add up to Refused.

The daily record: `bun scripts/config-ui/tool-health-record.ts [--day YYYY-MM-DD]
[--dry-run]` writes one finished UTC day of the page's own counts
(`worker-digest/tool-health-record.mjs`) as an eval-runs row with
`eval: tool-health`, through `worker-digest/tool_health_record.py`. Run it by
hand; nothing schedules it. The config names what a count means (count
definition, wiring fingerprint), never the day, so a series has one row per
day, with the day in `meta.day`. `status` is `ok` only with the wiring, the
hook-chain log and every call denominator known and every invariant holding;
`partial` otherwise, `inconclusive` for a complete day with no calls. A day that
has an ok row appends nothing. A late ok row older than the series' newest ok
day is stored `partial` (`meta.revision: backfill`), because
`eval_feedback.py` reads the newest ok row per eval in file order. No rule in
`feedback-rules.json` names `tool-health`, so the record changes nothing by
itself. A rate over several days sums the counts first: 1/10 and 9/30 are
10/40 = 25 %, not the 20 % mean of the two daily rates.

## leg_ledger: digests into the worker ledgers

`worker-digest/worker_ledger.py` writes one digest as:

1. one `worker-failures` row per digest failures row
   (`$HIMMEL_WORKER_SESSION_FAILURES_LEDGER`, else `~/.himmel/leg-failures.jsonl`). The
   row carries closed-list categories only; unknown keys are refused, so no
   journal text can ride in;
2. one eval-runs row, `eval: leg-trajectory`, `run_id` = the session uuid,
   `meta.observational: true`;
3. the digest at `~/.himmel/state/leg-digest/<session>.json`, last, as the
   commit marker.

It is idempotent by session, under a per-session flock: a marker with status
`ok` appends nothing; otherwise only the missing rows are appended (keyed by
agent and class), and a later `ok` digest supersedes a `partial` or
`inconclusive` one with one more eval-runs row.

```bash
python3 scripts/eval/worker-digest/worker_ledger.py record --digest d.json --worker N1 --ticket PROJ-1 [--chief C --pr N --doc D]
python3 scripts/eval/worker-digest/worker_ledger.py backfill --since 2026-10-01 [--projects ~/.claude/projects]
python3 scripts/eval/worker-digest/worker_ledger.py validate ~/.himmel/leg-failures.jsonl
```

`backfill` digests every main journal whose first timestamp is on or after
`--since` and whose `customTitle` names a worker (`<TICKET>-N<n>-...`), reading
the journals only. It refuses a journal whose cwd sits under a salus root (a
`.salus` marker on an ancestor, or a root in `~/.config/claude-glm/phi-roots`
or `egress-denylist`). Every ledger and the state directory take a flag, so a
trial backfill can write to scratch copies.

## pdd_share: the proof-first share of merged PRs

`worker-digest/pdd_share.py` reads the last merged PRs and writes one eval-runs
row, `eval: pdd-share`. It makes no model call. A PR is proof-first when both
hold:

1. its ticket (read from the Jira mirror) has a DoD section and a Proof
   section, and was created before the PR's first commit. The mirror keeps no
   description history, so the created time stands for when the sections
   existed;
2. its body names `RED` and then `GREEN`, the evidence words, in that order,
   on one line or two. The CodeRabbit block is ignored.

The row holds `pdd`, `ticket_first` (half 1 alone) and `red_green` (half 2
alone), each as `.pct`, `.k` and `.n` with a 95 % Wilson range. A PR whose
title names no ticket, whose ticket is not in the mirror, or that lists no
commit is counted in `meta.skipped` and left out of n. A PR whose commit
lookup failed is counted as `commits_unreadable` and makes the row `partial`.
Below `--min-n` (50) readable PRs the row is `partial` and the exit code is 3.

```bash
python3 scripts/eval/worker-digest/pdd_share.py --limit 120            # print the row
python3 scripts/eval/worker-digest/pdd_share.py --limit 120 --record   # append it to the eval-runs ledger
```

`--prs FILE` reads `gh pr list --json number,title,body,commits` output
instead of asking gh; `--mirror DIR` and `--ledger P` point at scratch copies.
