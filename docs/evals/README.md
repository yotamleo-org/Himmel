# Evals: how often a review finding is right, how often work is proof-first, and what caching saves

> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by `scripts/cr/evals-page-gen.py`.

Three questions a user weighs before trusting the harness: how often is a review finding right, how often is work proven before it is built, and what does the prompt cache save. Each figure carries its date and sample size, links the page that explains how it was measured, and names the command that regenerates it.

## How to read these numbers

- **Precision** is agreed ÷ (agreed + disproved): of the findings someone ruled true or false, the share ruled true. The PR author rules (in practice the Claude session that wrote the PR), and a finding marked `fixed` counts as agreed. It is a precision proxy, not precision, because the one who rules is also the one who has to fix. Method: [review panel](review-panel.md).
- **The 95 percent Wilson interval** is the range the true share most likely sits in, given how many findings were ruled. It treats every finding as independent of the others.
- **The bootstrap by PR** is a second range that resamples whole PRs, not single findings. Findings on one PR share an author, a diff and a review loop, so they are not independent; counting that makes the range wider, most of all for a reviewer whose findings sit on few PRs. When the two disagree, trust the wider one.
- **n** is the sample behind a figure: for precision, the ruled findings and the PRs they came from. A small n is noise: one PR more or less can move the figure by many points, which is why a reviewer with fewer than 30 ruled findings is left out of the ranking.
- **As of** is the day the figures were read off their ledgers; anything recorded later is not in them.
- **Left out of precision:** deferred findings (real or plausible, filed as a follow-up instead of fixed in that PR) and findings nobody ruled on. They sit in neither side of the share and show only under Findings in, findings out.
- **Proof-first share** is the share of the last merged PRs whose ticket had its DoD and Proof written before the first commit, and whose PR body names RED and then GREEN. Its range is a Wilson interval over the PRs read; only the newest measurement counts, because older ones came from an earlier matcher. Method: [proof-first share](../../scripts/eval/README.md).
- **Test first** is the share of agent sessions that wrote code in which a test failed before the first implementation write and passed after it; a session that wrote no code is left out. Only sessions scored under trajectory version 2 count: version 1 scored a session that wrote no code as a miss, so the two are never mixed. Version 2 scoring is new, so the figure reads not measured yet until 30 such sessions exist, the same floor as a reviewer's. Method: [test-first record](../../scripts/eval/README.md).
- **The cache figure** is one probe run's share of input tokens read from the cache. It has no interval: tokens within one session are not independent. Method: [prompt cache](prompt-cache.md).

## How often is a review finding right?

### All reviewers pooled

- **79.7%** precision, 95% Wilson interval 78.7 to 80.6; bootstrap by PR 78.2 to 81.1, as of 2026-10-25, n = 7,485 ruled findings over 2,128 PRs. Method: [review panel](review-panel.md).

### Per reviewer

- `codex:gpt-6.1-sol`: **79.5%** precision, 95% Wilson interval 78.3 to 80.6; bootstrap by PR 77.8 to 81.2, as of 2026-10-25, n = 4,968 ruled findings over 1,482 PRs. Method: [review panel](review-panel.md).
- `codex:gpt-6-astra`: **89.3%** precision, 95% Wilson interval 87.4 to 90.9; bootstrap by PR 86.1 to 92.0, as of 2026-10-25, n = 1,231 ruled findings over 362 PRs. Method: [review panel](review-panel.md).
- `codex:gpt-6-sol`: **70.7%** precision, 95% Wilson interval 67.0 to 74.1; bootstrap by PR 64.8 to 76.2, as of 2026-10-25, n = 627 ruled findings over 169 PRs. Method: [review panel](review-panel.md).
- `claude:claude-opus-5-5`: **48.2%** precision, 95% Wilson interval 41.2 to 55.2; bootstrap by PR 36.5 to 59.2, as of 2026-10-25, n = 193 ruled findings over 36 PRs. Method: [review panel](review-panel.md).
- `coderabbit-outside`: **55.0%** precision, 95% Wilson interval 46.1 to 63.6; bootstrap by PR 43.5 to 65.0, as of 2026-10-25, n = 120 ruled findings over 118 PRs. Method: [review panel](review-panel.md).
- `codex:gpt-5.6-sol`: **84.1%** precision, 95% Wilson interval 76.2 to 89.7; bootstrap by PR 74.2 to 91.7, as of 2026-10-25, n = 113 ruled findings over 27 PRs. Method: [review panel](review-panel.md).
- `codex` (model not recorded): **97.1%** precision, 95% Wilson interval 91.7 to 99.0; bootstrap by PR 90.0 to 100.0, as of 2026-10-25, n = 102 ruled findings over 8 PRs. Method: [review panel](review-panel.md).
- `coderabbit`: **91.8%** precision, 95% Wilson interval 82.2 to 96.4; bootstrap by PR 82.6 to 100.0, as of 2026-10-25, n = 61 ruled findings over 51 PRs. Method: [review panel](review-panel.md).

A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer. A row marked (model not recorded) holds the findings whose ledger record names no answering model for that review; they are kept apart, never folded into a named model, because which model raised them is unknown. 30 reviewers with fewer than 30 ruled findings are left out: too few to rank.

### Findings in, findings out

- In: 11,637 findings raised, as of 2026-10-25, n = 11,637 findings. Method: [review panel](review-panel.md).
- Out, agreed: 5,963 of 11,637, 51.2% `██████████░░░░░░░░░░`, as of 2026-10-25, n = 11,637 findings. Method: [review panel](review-panel.md).
- Out, disproved: 1,522 of 11,637, 13.1% `███░░░░░░░░░░░░░░░░░`, as of 2026-10-25, n = 11,637 findings. Method: [review panel](review-panel.md).
- Out, deferred: 3,493 of 11,637, 30.0% `██████░░░░░░░░░░░░░░`, as of 2026-10-25, n = 11,637 findings. Method: [review panel](review-panel.md).
- Out, no verdict: 659 of 11,637, 5.7% `█░░░░░░░░░░░░░░░░░░░`, as of 2026-10-25, n = 11,637 findings. Method: [review panel](review-panel.md).

Regenerate: `python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt --cache-scope 'the sessions of this project modified from 2026-10-22 to 2026-10-25' --until 2026-10-25T00:00:00Z --as-of 2026-10-25`, then `python3 scripts/cr/evals-page-gen.py render`.

## How often is work proof-first?

- **10.8%** of merged PRs were proof-first, 95% Wilson interval 6.4 to 17.7, as of 2026-10-24, n = 120 merged PRs. Method: [proof-first share](../../scripts/eval/README.md).
- Ticket first alone: **19.2%** had the ticket's DoD and Proof before the first commit, 95% Wilson interval 13.1 to 27.1, as of 2026-10-24, n = 120 merged PRs. Method: [proof-first share](../../scripts/eval/README.md).
- RED then GREEN alone: **57.5%** named RED and then GREEN in the PR body, 95% Wilson interval 48.6 to 66.0, as of 2026-10-24, n = 120 merged PRs. Method: [proof-first share](../../scripts/eval/README.md).
- Test first: not measured yet, as of 2026-10-25, n = 0 sessions scored under trajectory version 2; it needs 30. Method: [test-first record](../../scripts/eval/README.md).

Regenerate: `python3 scripts/eval/leg-digest/pdd_share.py --limit 120 --record` writes a new proof-first row; the test-first sessions are written as agent sessions end. Then run the review regenerate above.

## How much does caching save?

- **98.4%** of input tokens were cache reads (served from the prompt cache) rather than uncached input or cache writes, as of 2026-10-25, n = 11,295,855,068 tokens over 489 sessions (the sessions of this project modified from 2026-10-22 to 2026-10-25). Method: [prompt cache](prompt-cache.md).

Regenerate, in order:

1. `bash scripts/eval/cache-probe.sh first-turn $(find ~/.claude/projects/<project-dir> -maxdepth 1 -name '*.jsonl' -newermt <first-day>) > cache-probe.txt` (the transcripts modified since the sample's first day)
2. `python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt --cache-scope 'the sessions of this project modified from 2026-10-22 to 2026-10-25' --until 2026-10-25T00:00:00Z --as-of 2026-10-25`
3. `python3 scripts/cr/evals-page-gen.py render`
