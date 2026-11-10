---
name: cr-scores
description: Print the per-critic scorecard - quality view, advice and pooled history. Use for CR critic scores or /cr-scores.
---

# cr-scores

When the user asks for the critic scorecard, run:

    bash scripts/cr/cr-scores.sh [--since ISO] [--until ISO] [--json] [--window N]

Summarise the quality view first. It has one row per slug:responding-model, scope and verdict source, over `--since`..`--until` (default: the 14 days ending at `--until`, else now). Give:

- `author_agreement`: agreed (`fixed` included) over agreed + disproved, recorded dispositions only;
- `acceptance_yield`: agreed over all findings, which is not precision;
- `coverage`: decided over all findings;
- the deferred and unresolved counts.

Thread-state-inferred and unknown-source rows never enter `author_agreement`.

Surface the Advice lines verbatim. Each is "ok", "insufficient evidence" (under 30 decided over 10 PRs), "low author agreement; investigate", "responding model not recorded" or "not a reviewer"; none says to remove a reviewer.

Then the history tables: all-time, plus the last `--window N` PRs (default 20). Their `accept%` and `dispr%` divide by all findings, with every verdict source and model pooled, so neither is precision. Give the conflict and unaddressed counts and `avail%`.

If the ledger is empty, report "no critic scores recorded yet" and stop.
See `.claude/commands/cr-scores.md`.
