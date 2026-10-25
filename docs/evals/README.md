# Evals: what the review panel catches, how often it is right, and what caching saves

> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by `scripts/cr/evals-page-gen.py`.

## Bottom line

| Question | Answer | Likely range | Sample |
|---|---|---|---|
| Does the review panel catch bugs? | **75.0%**: `codex` caught 9 of 12 planted bugs | 46.8 to 91.1 | as of 2026-10-24, n = 12 planted bugs in 24 test changes |
| When the required reviewer flags something, is it right? | **79.5%** of `codex:gpt-6.1-sol` findings ruled right | Wilson 78.3 to 80.6; by PR 77.8 to 81.2 | as of 2026-10-25, n = 4,968 ruled findings over 1,482 PRs |
| Is work proven before it is built? | **10.8%** of merged PRs were proof-first | 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |
| What does the prompt cache save? | **98.4%** of input tokens were cache reads, not uncached input or cache writes | no interval | as of 2026-10-25, n = 11,295,855,068 tokens over 489 sessions (the sessions of this project modified from 2026-10-22 to 2026-10-25) |

The precision headline is the required reviewer's own, not the all-reviewers pooled figure under History: the pool mixes in models the panel no longer runs. Likely range is the 95 percent interval; every term is defined under How to read these numbers.

## Current setup

The reviewers `scripts/cr/critics.json` runs on every PR today. To change the set (a cheaper tier, a required non-Claude reviewer, a reviewer added or dropped on one machine), see [Review by a second model](../configuration.md#review-by-a-second-model).

| Reviewer | What it must do | Precision | Wilson range | Range by PR | Sample |
|---|---|---|---|---|---|
| `codex:gpt-6.1-sol` | required: must pass before every merge | **79.5%** | 78.3 to 80.6 | 77.8 to 81.2 | as of 2026-10-25, n = 4,968 ruled findings over 1,482 PRs |
| `claude:claude-opus-5-5` | must pass where it runs; skipped on a machine without it | **48.2%** | 41.2 to 55.2 | 36.5 to 59.2 | as of 2026-10-25, n = 193 ruled findings over 36 PRs |
| `coderabbit` | best effort: holds a merge only on a posted finding | **91.8%** | 82.2 to 96.4 | 82.6 to 100.0 | as of 2026-10-25, n = 61 ruled findings over 51 PRs |
| `coderabbit-outside` | part of `coderabbit`: findings on lines outside the diff | **55.0%** | 46.1 to 63.6 | 43.5 to 65.0 | as of 2026-10-25, n = 120 ruled findings over 118 PRs |

Precision is the share of a reviewer's ruled findings that were right; when the two ranges disagree, trust the wider one. Method: [review panel](review-panel.md).

## History and what we learned

Every reviewer the ledger holds that the panel no longer runs, oldest first. A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer.

| Reviewer | Ran | Precision | Wilson range | Range by PR | Sample |
|---|---|---|---|---|---|
| `codex:gpt-5.6-sol` | 2026-09-04 to 2026-09-05 | **84.1%** | 76.2 to 89.7 | 74.2 to 91.7 | as of 2026-10-25, n = 113 ruled findings over 27 PRs |
| `codex:gpt-6-astra` | 2026-09-05 to 2026-09-23 | **89.3%** | 87.4 to 90.9 | 86.1 to 92.0 | as of 2026-10-25, n = 1,231 ruled findings over 362 PRs |
| `codex` (model not recorded) | 2026-09-08 to 2026-10-21 | **97.1%** | 91.7 to 99.0 | 90.0 to 100.0 | as of 2026-10-25, n = 102 ruled findings over 8 PRs |
| `codex:gpt-6-sol` | 2026-09-23 to 2026-09-29 | **70.7%** | 67.0 to 74.1 | 64.8 to 76.2 | as of 2026-10-25, n = 627 ruled findings over 169 PRs |
| All reviewers pooled | 2026-09-04 to 2026-10-24 | **79.7%** | 78.7 to 80.6 | 78.2 to 81.1 | as of 2026-10-25, n = 7,485 ruled findings over 2,128 PRs |

A row marked (model not recorded) holds the findings whose ledger record names no answering model for that review; they are kept apart, never folded into a named model, because which model raised them is unknown. 30 reviewers with fewer than 30 ruled findings are left out: too few to rank. What the history taught, with the analysis behind it: [review panel](review-panel.md).

### Findings in, findings out

| Outcome | Findings | Share | Sample |
|---|---|---|---|
| Raised | 11,637 | | as of 2026-10-25, n = 11,637 findings |
| Agreed | 5,963 of 11,637 | 51.2% `██████████░░░░░░░░░░` | as of 2026-10-25, n = 11,637 findings |
| Disproved | 1,522 of 11,637 | 13.1% `███░░░░░░░░░░░░░░░░░` | as of 2026-10-25, n = 11,637 findings |
| Deferred | 3,493 of 11,637 | 30.0% `██████░░░░░░░░░░░░░░` | as of 2026-10-25, n = 11,637 findings |
| No verdict | 659 of 11,637 | 5.7% `█░░░░░░░░░░░░░░░░░░░` | as of 2026-10-25, n = 11,637 findings |

Every reviewer, current and past. Only agreed and disproved count toward precision; deferred and no-verdict findings sit outside it. Method: [review panel](review-panel.md).

## Proof first and test first

| Measure | Share | Likely range | Sample |
|---|---|---|---|
| Proof-first: both halves below | **10.8%** | 6.4 to 17.7 | as of 2026-10-24, n = 120 merged PRs |
| The ticket's DoD and Proof written before the first commit | **19.2%** | 13.1 to 27.1 | as of 2026-10-24, n = 120 merged PRs |
| RED and then GREEN named in the PR body | **57.5%** | 48.6 to 66.0 | as of 2026-10-24, n = 120 merged PRs |
| Test first: a test failed before the implementation and passed after | not measured yet; it needs 30 | | as of 2026-10-25, n = 0 sessions scored under trajectory version 2 |

A merged PR is proof-first only when it has both halves; each half is shown on its own. Method: [proof-first share](../../scripts/eval/README.md) and [test-first record](../../scripts/eval/README.md).

## How to read these numbers

| Term | Meaning |
|---|---|
| **Precision** | Agreed ÷ (agreed + disproved): of the findings someone ruled true or false, the share ruled true. The PR author rules (in practice the Claude session that wrote the PR), and a finding marked `fixed` counts as agreed. A precision proxy, not precision: the one who rules is also the one who has to fix. [review panel](review-panel.md) |
| **Planted-bug catch** | Bugs planted in test changes with a hidden answer key, and the share the reviewer found. It measures what real PRs cannot: the bugs nobody flagged. [planted-bug eval](../../scripts/eval/review-panel/README.md) |
| **Wilson range** | The 95 percent range the true share most likely sits in, given how many findings were ruled. It treats every finding as independent of the others. |
| **Range by PR** | A bootstrap that resamples whole PRs, not single findings. Findings on one PR share an author, a diff and a review loop, so they are not independent; counting that makes the range wider, most of all for a reviewer whose findings sit on few PRs. |
| **n** | The sample behind a figure: for precision, the ruled findings and the PRs they came from. A small n is noise: one PR more or less can move the figure by many points, which is why a reviewer with fewer than 30 ruled findings is not ranked. |
| **As of** | The day the figures were read off their ledgers; anything recorded later is not in them. |
| **Left out of precision** | Deferred findings (real or plausible, filed as a follow-up instead of fixed in that PR) and findings nobody ruled on. They show only under Findings in, findings out. |
| **Proof-first** | The share of the last merged PRs whose ticket had its DoD and Proof written before the first commit, and whose PR body names RED and then GREEN. Only the newest measurement counts, because older ones came from an earlier matcher. |
| **Test first** | The share of agent sessions that wrote code in which a test failed before the first implementation write and passed after it; a session that wrote no code is left out. Only sessions scored under trajectory version 2 count: version 1 scored a session that wrote no code as a miss, so the two are never mixed. It reads not measured yet until 30 such sessions exist. |
| **Cache reads** | One probe run's share of input tokens read from the cache. No interval: tokens within one session are not independent. [prompt cache](prompt-cache.md) |

## Regenerate

A new planted-bug row comes from the [planted-bug eval](../../scripts/eval/review-panel/README.md); a new proof-first row from `python3 scripts/eval/worker-digest/pdd_share.py --limit 120 --record`; test-first sessions are written as agent sessions end. Then run steps 2 and 3 with --until and --as-of moved past the new row.

1. `bash scripts/eval/cache-probe.sh first-turn $(find ~/.claude/projects/<project-dir> -maxdepth 1 -name '*.jsonl' -newermt <first-day> ! -newermt <day-after-last-day>) > cache-probe.txt` (the transcripts modified from the sample's first day to its last)
2. `python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt --cache-scope 'the sessions of this project modified from 2026-10-22 to 2026-10-25' --until 2026-10-25T00:00:00Z --as-of 2026-10-25`
3. `python3 scripts/cr/evals-page-gen.py render`
