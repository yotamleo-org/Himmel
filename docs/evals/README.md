# Evals: what the review panel catches, how often it is right, and what caching saves

> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by `scripts/cr/evals-page-gen.py`.

## Bottom line

| Question | Answer | Likely range | Sample |
|---|---|---|---|
| Does the review panel catch bugs? | **75.0%**: `codex` caught 9 of 12 planted bugs | 46.8 to 91.1 | as of 2026-10-24, n = 12 planted bugs in 24 test changes |
| When the required reviewer flags something, is it right? | **79.5%** of `codex:gpt-6.1-sol` findings ruled right | Wilson 78.4 to 80.5; by PR 77.8 to 81.1 | as of 2026-10-27, n = 5,388 ruled findings over 1,621 PRs |
| Is work proven before it is built? | **10.8%** of merged PRs were proof-first (self-reported) | 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |
| How far can the lane-quality judge be trusted? (arms `claude-haiku-5-5`, `claude-sonnet-5-5`) | **kappa 0.35**: graders agreed on 11 of 17 runs, model-graded (no human label) by OpenAI and Google, tie-breaker DeepSeek sided with grader 1 in 1 and grader 2 in 5 of 6 disagreements; the stored judge flipped its verdict on 2 of 17 runs judged twice | no interval | as of 2026-10-27, n = 17 runs |
| How far can the lane-quality judge be trusted? (arms `gpt-6.1-sol`) | **kappa 0.00**: graders agreed on 5 of 7 runs, model-graded (no human label) by Anthropic and Google, tie-breaker DeepSeek sided with grader 1 in 0 and grader 2 in 2 of 2 disagreements; the stored judge flipped its verdict on 3 of 7 runs judged twice | no interval | as of 2026-10-27, n = 7 runs |
| What does the prompt cache save? | **98.4%** of input tokens were cache reads, not uncached input or cache writes | no interval | as of 2026-10-27, n = 9,267,642,070 tokens over 425 sessions (the sessions of this project modified from 2026-10-25 to 2026-10-27) |

The precision headline is the required reviewer's own, not the all-reviewers pooled figure under History: the pool mixes in models the panel no longer runs. Likely range is the 95 percent interval; every term is defined under How to read these numbers.

## Current setup

The reviewers `scripts/cr/critics.json` runs on every PR today. To change the set (a cheaper tier, a required non-Claude reviewer, a reviewer added or dropped on one machine), see [Review by a second model](../configuration.md#review-by-a-second-model).

| Reviewer | What it must do | Precision | Wilson range | Range by PR | Sample |
|---|---|---|---|---|---|
| `codex:gpt-6.1-sol` | required: must pass before every merge | **79.5%** | 78.4 to 80.5 | 77.8 to 81.1 | as of 2026-10-27, n = 5,388 ruled findings over 1,621 PRs |
| `claude:claude-opus-5-5` | must pass where it runs; skipped on a machine without it | **48.2%** | 41.2 to 55.2 | 36.5 to 59.2 | as of 2026-10-27, n = 193 ruled findings over 36 PRs |
| `coderabbit` | best effort: holds a merge only on a posted finding | **84.8%** | 76.5 to 90.6 | 76.4 to 94.5 | as of 2026-10-27, n = 99 ruled findings over 71 PRs |
| `coderabbit-outside` | part of `coderabbit`: findings on lines outside the diff | **62.5%** | 55.2 to 69.3 | 54.0 to 69.7 | as of 2026-10-27, n = 176 ruled findings over 168 PRs |

Precision is the share of a reviewer's ruled findings that were right; when the two ranges disagree, trust the wider one. Method: [review panel](review-panel.md).

## History and what we learned

Every reviewer the ledger holds that the panel no longer runs, oldest first. A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer.

| Reviewer | Ran | Precision | Wilson range | Range by PR | Sample |
|---|---|---|---|---|---|
| `codex:gpt-5.6-sol` | 2026-09-04 to 2026-09-05 | **84.1%** | 76.2 to 89.7 | 74.2 to 91.7 | as of 2026-10-27, n = 113 ruled findings over 27 PRs |
| `codex:gpt-6-astra` | 2026-09-05 to 2026-09-23 | **89.3%** | 87.4 to 90.9 | 86.1 to 92.0 | as of 2026-10-27, n = 1,231 ruled findings over 362 PRs |
| `codex` (model not recorded) | 2026-09-08 to 2026-10-26 | **98.0%** | 93.1 to 99.5 | 95.8 to 100.0 | as of 2026-10-27, n = 102 ruled findings over 10 PRs |
| `codex:gpt-6-sol` | 2026-09-23 to 2026-09-29 | **70.7%** | 67.0 to 74.1 | 64.8 to 76.2 | as of 2026-10-27, n = 627 ruled findings over 169 PRs |
| All reviewers pooled | 2026-09-04 to 2026-10-27 | **79.6%** | 78.7 to 80.5 | 78.2 to 81.0 | as of 2026-10-27, n = 8,003 ruled findings over 2,287 PRs |

A row marked (model not recorded) holds the findings whose ledger record names no answering model for that review; they are kept apart, never folded into a named model, because which model raised them is unknown. 38 reviewers with fewer than 30 ruled findings are left out: too few to rank. What the history taught, with the analysis behind it: [review panel](review-panel.md).

### Findings in, findings out

| Outcome | Findings | Share | Sample |
|---|---|---|---|
| Raised | 12,338 | | as of 2026-10-27, n = 12,338 findings |
| Agreed | 6,371 of 12,338 | 51.6% `██████████░░░░░░░░░░` | as of 2026-10-27, n = 12,338 findings |
| Disproved | 1,632 of 12,338 | 13.2% `███░░░░░░░░░░░░░░░░░` | as of 2026-10-27, n = 12,338 findings |
| Deferred | 3,683 of 12,338 | 29.9% `██████░░░░░░░░░░░░░░` | as of 2026-10-27, n = 12,338 findings |
| No verdict | 652 of 12,338 | 5.3% `█░░░░░░░░░░░░░░░░░░░` | as of 2026-10-27, n = 12,338 findings |

Every reviewer, current and past. Only agreed and disproved count toward precision; deferred and no-verdict findings sit outside it. Method: [review panel](review-panel.md).

## Proof-first share and test-first adherence

| Measure | Share | Likely range | Sample |
|---|---|---|---|
| Proof-first share (self-reported): both halves below | **10.8%** | 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |
| The ticket had a DoD and a Proof and was created before the first commit | **19.2%** | 13.1 to 27.1 | as of 2026-10-24, n = 120 merged PRs |
| RED and then GREEN named in the PR body | **57.5%** | 48.6 to 66.0 | as of 2026-10-24, n = 120 merged PRs |
| Test-first adherence: a test failed before the implementation and passed after | **39.1%** | 33.1 to 45.5 | as of 2026-10-27, n = 235 sessions scored under trajectory version 2 |

A merged PR is proof-first only when it has both halves; each half is shown on its own. Method: [proof-first share](../../scripts/eval/README.md) and [test-first record](../../scripts/eval/README.md).

## How to read these numbers

Each number's display name beside its unchanged ledger key: [What each number means](../../scripts/eval/README.md#what-each-number-means).

| Term | Meaning |
|---|---|
| **Precision** | Agreed ÷ (agreed + disproved): of the findings someone ruled true or false, the share ruled true. The PR author rules (in practice the Claude session that wrote the PR), and a finding marked `fixed` counts as agreed. A precision proxy, not precision: the one who rules is also the one who has to fix. [review panel](review-panel.md) |
| **Planted-bug catch** | Bugs planted in test changes with a hidden answer key, and the share the reviewer found. It measures what real PRs cannot: the bugs nobody flagged. The set also holds real review escapes (bugs the review let through, frozen from merged PRs), each with a clean twin of the same change; the next sweep scores them with the planted bugs, so it starts a new series and n grows. [planted-bug eval](../../scripts/eval/review-panel/README.md) |
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
2. `python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt --cache-scope 'the sessions of this project modified from 2026-10-25 to 2026-10-27' --until 2026-10-27T09:30:00Z --as-of 2026-10-27`
3. `python3 scripts/cr/evals-page-gen.py render`
