---
description: Per-critic CR scorecard.
---

Run `bash scripts/cr/cr-scores.sh`. Optional flags: `--since ISO` / `--until ISO` pick the quality-view window (default: the 14 days ending at `--until`, else now); `--json` prints only the quality view as JSON; `--window N` narrows the history window table to the last N PRs (default 20).

Summarise the output:
1. Present the quality view first: one row per reviewer identity (slug:responding-model), scope and verdict source. Give `author_agreement` (agreed, `fixed` included, over agreed + disproved, recorded dispositions only, with its 95% PR interval), `acceptance_yield` (agreed over all findings, which is not precision), `coverage` (decided over all findings), and the deferred and unresolved counts. Thread-state-inferred rows (CodeRabbit threads the recorder read) carry only resolved-after-change / resolved-without-change / open rates. Unknown-source rows carry no ratio. Report the "Not in author_agreement" exclusions line.
2. Surface the Advice lines verbatim. They read the same window and recorded dispositions only, and each says one of:
   - "ok (author agreement X% over N decided, P PRs)"
   - "insufficient evidence (N decided over P PR(s); needs >= 30 decided over >= 10 PRs)"
   - "low author agreement; investigate" (below `CR_SCORES_DROP_BELOW`, default 40 %)
   - "responding model not recorded; no advice"
   - "not a reviewer (bookkeeping or unmapped slug), no reviewer advice"
   No line says to remove a reviewer.
3. Then the history tables (all-time and the last-N-PRs window): `accept%` is agreed over all findings and `dispr%` disproved over all findings, with every verdict source and model version pooled, so neither is precision or author agreement. Also give the conflict and unaddressed counts and `avail%`.
4. If the ledger is empty, report the friendly "no critic scores recorded yet" message and stop.
