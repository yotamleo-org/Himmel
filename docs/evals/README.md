# Evals: what the review panel catches, how often it is right, and what caching saves

> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by `scripts/cr/evals-page-gen.py`.

## Bottom line

| Question | Answer | Likely range | Sample |
|---|---|---|---|
| Does the review panel catch bugs? | **38.3%**: `claude`, `codex` caught 18 of 47 planted bugs | 25.8 to 52.6 | as of 2026-11-04, n = 47 planted bugs in 94 test changes |
| When the required reviewer flags something, is it right? | **80.1%** of `codex:gpt-6.1-sol` findings ruled right (recorded dispositions) | Wilson 79.2 to 81.1; by PR 78.7 to 81.5 | as of 2026-11-11, n = 6,968 ruled findings over 2,053 PRs |
| Is work proven before it is built? | **10.8%** of merged PRs were proof-first (self-reported) | 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |
| How far can the lane-quality judge be trusted? (arms `claude-haiku-5-5`, `claude-sonnet-5-5`) | **kappa 0.35**: graders agreed on 11 of 17 runs, model-graded (no human label) by OpenAI and Google, tie-breaker DeepSeek sided with grader 1 in 1 and grader 2 in 5 of 6 disagreements; the stored judge flipped its verdict on 2 of 17 runs judged twice | no interval | as of 2026-10-27, n = 17 runs |
| How far can the lane-quality judge be trusted? (arms `gpt-6.1-sol`) | **kappa 0.00**: graders agreed on 5 of 7 runs, model-graded (no human label) by Anthropic and Google, tie-breaker DeepSeek sided with grader 1 in 0 and grader 2 in 2 of 2 disagreements; the stored judge flipped its verdict on 3 of 7 runs judged twice | no interval | as of 2026-10-27, n = 7 runs |
| What does the prompt cache save? | **99.1%** of input tokens were cache reads, not uncached input or cache writes | no interval | as of 2026-11-11, n = 4,950,661,574 tokens over 176 sessions (the sessions of this project modified from 2026-11-08 to 2026-11-10) |

The precision headline is the required reviewer's own, not the all-reviewers pooled figure under History: the pool mixes in models the panel no longer runs. Likely range is the 95 percent interval; every term is defined under How to read these numbers.

Each precision figure counts recorded dispositions only, the PR author's ruling. Left out of every figure: 3,799 ruled findings whose verdict the thread recorder inferred from thread state, and 8 whose verdict source is unknown.

## Current setup

The reviewers `scripts/cr/critics.json` runs on every PR today. To change the set (a cheaper tier, a required non-Claude reviewer, a reviewer added or dropped on one machine), see [Review by a second model](../configuration.md#review-by-a-second-model).

| Reviewer | What it must do | Precision (recorded dispositions) | Wilson range | Range by PR | Sample |
|---|---|---|---|---|---|
| `codex:gpt-6.1-sol` | required: must pass before every merge | **80.1%** | 79.2 to 81.1 | 78.7 to 81.5 | as of 2026-11-11, n = 6,968 ruled findings over 2,053 PRs |
| `claude:claude-opus-5-5` | must pass where it runs; skipped on a machine without it | **59.9%** | 53.9 to 65.7 | 47.5 to 70.2 | as of 2026-11-11, n = 262 ruled findings over 40 PRs |
| `coderabbit` | best effort: holds a merge only on a posted finding | **87.7%** | 81.8 to 91.9 | 81.0 to 94.4 | as of 2026-11-11, n = 163 ruled findings over 77 PRs |
| `coderabbit-outside` | part of `coderabbit`: findings on lines outside the diff | **63.3%** | 57.2 to 69.1 | 56.8 to 69.8 | as of 2026-11-11, n = 251 ruled findings over 153 PRs |

Precision is the share of a reviewer's ruled findings that were right; when the two ranges disagree, trust the wider one. Method: [review panel](review-panel.md).

## History and what we learned

Every reviewer the ledger holds that the panel no longer runs, oldest first. A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer.

| Reviewer | Ran | Precision (recorded dispositions) | Wilson range | Range by PR | Sample |
|---|---|---|---|---|---|
| `codex:gpt-5.6-sol` | 2026-09-04 to 2026-09-05 | **84.1%** | 76.2 to 89.7 | 74.2 to 91.7 | as of 2026-11-11, n = 113 ruled findings over 23 PRs |
| `codex:gpt-6-astra` | 2026-09-05 to 2026-09-23 | **89.3%** | 87.4 to 90.9 | 86.1 to 92.0 | as of 2026-11-11, n = 1,231 ruled findings over 285 PRs |
| `codex` (model not recorded) | 2026-09-08 to 2026-11-09 | **86.0%** | 82.6 to 88.9 | 79.2 to 90.6 | as of 2026-11-11, n = 458 ruled findings over 23 PRs |
| `claude` (model not recorded) | 2026-09-17 to 2026-11-11 | **68.8%** | 61.1 to 75.6 | 40.6 to 96.2 | as of 2026-11-11, n = 154 ruled findings over 26 PRs |
| `codex:gpt-6-sol` | 2026-09-23 to 2026-09-29 | **70.7%** | 67.0 to 74.1 | 64.8 to 76.2 | as of 2026-11-11, n = 627 ruled findings over 149 PRs |
| All reviewers pooled | 2026-09-04 to 2026-11-11 | **79.9%** | 79.1 to 80.7 | 78.6 to 81.2 | as of 2026-11-11, n = 10,379 ruled findings over 2,658 PRs |

A row marked (model not recorded) holds the findings whose ledger record names no answering model for that review; they are kept apart, never folded into a named model, because which model raised them is unknown. 61 reviewers with fewer than 30 ruled findings are left out: too few to rank. What the history taught, with the analysis behind it: [review panel](review-panel.md).

### Findings in, findings out

| Outcome | Findings | Share | Sample |
|---|---|---|---|
| Raised | 19,982 | | as of 2026-11-11, n = 19,982 findings |
| Agreed | 11,590 of 19,982 | 58.0% `████████████░░░░░░░░` | as of 2026-11-11, n = 19,982 findings |
| Disproved | 2,596 of 19,982 | 13.0% `███░░░░░░░░░░░░░░░░░` | as of 2026-11-11, n = 19,982 findings |
| Deferred | 5,033 of 19,982 | 25.2% `█████░░░░░░░░░░░░░░░` | as of 2026-11-11, n = 19,982 findings |
| No verdict | 763 of 19,982 | 3.8% `█░░░░░░░░░░░░░░░░░░░` | as of 2026-11-11, n = 19,982 findings |

Every reviewer, current and past. Only agreed and disproved count toward precision; deferred and no-verdict findings sit outside it. Method: [review panel](review-panel.md).

## Proof-first share and test-first adherence

| Measure | Share | Likely range | Sample |
|---|---|---|---|
| Proof-first share (self-reported): both halves below | **10.8%** | 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |
| The ticket had a DoD and a Proof and was created before the first commit | **19.2%** | 13.1 to 27.1 | as of 2026-10-24, n = 120 merged PRs |
| RED and then GREEN named in the PR body | **57.5%** | 48.6 to 66.0 | as of 2026-10-24, n = 120 merged PRs |
| Test-first adherence: a test failed before the implementation and passed after | **30.9%** | 29.1 to 32.8 | as of 2026-11-11, n = 2,439 sessions scored under trajectory version 2 |

A merged PR is proof-first only when it has both halves; each half is shown on its own. Method: [proof-first share](../../scripts/eval/README.md) and [test-first record](../../scripts/eval/README.md).

## How to read these numbers

Each number's display name beside its unchanged ledger key: [What each number means](../../scripts/eval/README.md#what-each-number-means).

| Term | Meaning |
|---|---|
| **Precision** | Agreed ÷ (agreed + disproved): of the findings someone ruled true or false, the share ruled true. The PR author rules (in practice the Claude session that wrote the PR), and a finding marked `fixed` counts as agreed. A precision proxy, not precision: the one who rules is also the one who has to fix. Each precision column names the verdict source it counts: recorded dispositions (the author's ruling) only, or all verdict sources pooled, which adds verdicts the thread recorder inferred from thread state and verdicts of unknown source. [review panel](review-panel.md) |
| **Planted-bug catch** | Bugs planted in test changes with a hidden answer key, and the share the reviewer found. It measures what real PRs cannot: the bugs nobody flagged. The set also holds real review escapes, each with a clean twin. [planted-bug eval](../../scripts/eval/review-panel/README.md) |
| **Wilson range** | The 95 percent range the true share most likely sits in, given how many findings were ruled. It treats every finding as independent of the others. |
| **Range by PR** | A bootstrap that resamples whole PRs, not single findings. Findings on one PR share an author, a diff and a review loop, so they are not independent; counting that makes the range wider, most of all for a reviewer whose findings sit on few PRs. |
| **n** | The sample behind a figure: for precision, the ruled findings and the PRs they came from. A small n is noise: one PR more or less can move the figure by many points, which is why a reviewer with fewer than 30 ruled findings is not ranked. |
| **As of** | The day the figures were read off their ledgers; anything recorded later is not in them. |
| **Left out of precision** | Deferred findings (real or plausible, filed as a follow-up instead of fixed in that PR) and findings nobody ruled on. They show only under Findings in, findings out. |
| **Proof-first share (self-reported)** | The share of the last merged PRs whose ticket had a DoD and a Proof and was created before the first commit, and whose PR body names RED and then GREEN. The ticket's created time stands in for when its sections were written, so a section added later still counts. Self-reported: RED and GREEN are words the PR author wrote, not a test run the eval checked. Only the newest measurement counts, because older ones came from an earlier matcher. |
| **Test-first adherence** | The share of agent sessions that wrote code in which a test failed before the first implementation write and passed after it; a session that wrote no code is left out. Only sessions scored under trajectory version 2 count: version 1 scored a session that wrote no code as a miss, so the two are never mixed. It reads not measured yet until 30 such sessions exist. |
| **Model-graded kappa** | Cohen's kappa between two model graders on each run's pass/fail verdict (pass when every correctness claim holds): 1 is full agreement, 0 is what chance alone gives, below 0 is worse than chance. Model-graded, not human-graded: no person labelled these runs. The graders come from different vendors, never a vendor under test, and a third-vendor tie-breaker grades only the runs they disagree on. A flip is the stored judge changing its verdict between two passes on one output. [lane-quality eval](../../scripts/eval/lane-quality/run.sh) |
| **Cache reads** | One probe run's share of input tokens read from the cache. No interval: tokens within one session are not independent. [prompt cache](prompt-cache.md) |

## Regenerate

A new planted-bug row comes from the [planted-bug eval](../../scripts/eval/review-panel/README.md); a new proof-first row from `python3 scripts/eval/worker-digest/pdd_share.py --limit 120 --record`; a new judge-calibration row from `scripts/eval/lane-quality/run.sh calibration` with a second grader; test-first sessions are written as agent sessions end. Then run steps 2 and 3 with --until and --as-of moved past the new row.

1. `bash scripts/eval/cache-probe.sh first-turn $(find ~/.claude/projects/<project-dir> -maxdepth 1 -name '*.jsonl' -newermt <first-day> ! -newermt <day-after-last-day>) > cache-probe.txt` (the transcripts modified from the sample's first day to its last)
2. `python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt --cache-scope 'the sessions of this project modified from 2026-11-08 to 2026-11-10' --until 2026-11-11T05:00:00Z --as-of 2026-11-11`
3. `python3 scripts/cr/evals-page-gen.py render`
