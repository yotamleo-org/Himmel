---
draft: true
---

# Evals: how often a review finding is right, and what caching saves

> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by `scripts/cr/evals-page-gen.py`. Draft: not on the site. Publishing it is adding it to `site/allowlist.txt` and the Reference nav entry, an operator call.

Two questions a user weighs before trusting the review step: how often is a finding right, and what does the prompt cache save. Each figure carries its date and sample size, links the page that explains how it was measured, and names the command that regenerates it.

## How often is a review finding right?

Precision here is agreed ÷ (agreed + disproved): of the findings the author ruled true or false, the share ruled true. It is a proxy, because the author who rules is also the one who fixes. Deferred and unadjudicated findings are in neither side. The interval is a Wilson interval at the 95 percent level on the ruled findings; the bootstrap interval, resampled by PR, sits beside it.

### All reviewers pooled

- **79.7%** precision, 95% Wilson interval 78.8 to 80.6; bootstrap by PR 78.2 to 81.1, as of 2026-10-25, n = 7,465 ruled findings over 2,121 PRs. Method: [review panel](review-panel.md).

### Per reviewer

- `codex:gpt-6.1-sol`: **79.5%** precision, 95% Wilson interval 78.4 to 80.6; bootstrap by PR 77.8 to 81.2, as of 2026-10-25, n = 4,949 ruled findings over 1,475 PRs. Method: [review panel](review-panel.md).
- `codex:gpt-6-astra`: **89.3%** precision, 95% Wilson interval 87.4 to 90.9; bootstrap by PR 86.1 to 92.0, as of 2026-10-25, n = 1,231 ruled findings over 362 PRs. Method: [review panel](review-panel.md).
- `codex:gpt-6-sol`: **70.7%** precision, 95% Wilson interval 67.0 to 74.1; bootstrap by PR 64.8 to 76.2, as of 2026-10-25, n = 627 ruled findings over 169 PRs. Method: [review panel](review-panel.md).
- `claude:claude-opus-5-5`: **48.2%** precision, 95% Wilson interval 41.2 to 55.2; bootstrap by PR 36.5 to 59.2, as of 2026-10-25, n = 193 ruled findings over 36 PRs. Method: [review panel](review-panel.md).
- `codex:gpt-5.6-sol`: **84.1%** precision, 95% Wilson interval 76.2 to 89.7; bootstrap by PR 74.2 to 91.7, as of 2026-10-25, n = 113 ruled findings over 27 PRs. Method: [review panel](review-panel.md).
- `coderabbit-outside`: **54.6%** precision, 95% Wilson interval 45.7 to 63.3; bootstrap by PR 43.3 to 64.7, as of 2026-10-25, n = 119 ruled findings over 114 PRs. Method: [review panel](review-panel.md).
- `codex`: **97.1%** precision, 95% Wilson interval 91.7 to 99.0; bootstrap by PR 90.0 to 100.0, as of 2026-10-25, n = 102 ruled findings over 8 PRs. Method: [review panel](review-panel.md).
- `coderabbit`: **91.8%** precision, 95% Wilson interval 82.2 to 96.4; bootstrap by PR 82.6 to 100.0, as of 2026-10-25, n = 61 ruled findings over 51 PRs. Method: [review panel](review-panel.md).

A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer. 30 reviewers with fewer than 30 ruled findings are left out: too few to rank.

### Findings in, findings out

- In: 11,602 findings raised, as of 2026-10-25, n = 11,602 findings.
- Out, agreed: 5,948 of 11,602, 51.3% `██████████░░░░░░░░░░`, as of 2026-10-25, n = 11,602 findings. Method: [review panel](review-panel.md).
- Out, disproved: 1,517 of 11,602, 13.1% `███░░░░░░░░░░░░░░░░░`, as of 2026-10-25, n = 11,602 findings. Method: [review panel](review-panel.md).
- Out, deferred: 3,485 of 11,602, 30.0% `██████░░░░░░░░░░░░░░`, as of 2026-10-25, n = 11,602 findings. Method: [review panel](review-panel.md).
- Out, no verdict: 652 of 11,602, 5.6% `█░░░░░░░░░░░░░░░░░░░`, as of 2026-10-25, n = 11,602 findings. Method: [review panel](review-panel.md).

Regenerate: `python3 scripts/cr/evals-page-gen.py data --cache-probe <cache-probe output> --as-of <date>`, then `python3 scripts/cr/evals-page-gen.py render`.

## How much does caching save?

- **98.5%** of prompt tokens were read from the cache instead of re-sent, as of 2026-10-25, n = 10,315,752,980 tokens over 450 sessions (this project's sessions from the three days to 2026-10-25). Method: [prompt cache](prompt-cache.md).

Regenerate: `bash scripts/eval/cache-probe.sh first-turn ~/.claude/projects/<project-dir>/*.jsonl`, then `python3 scripts/cr/evals-page-gen.py render`.
