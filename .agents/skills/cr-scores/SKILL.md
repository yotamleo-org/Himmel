---
name: cr-scores
description: Print the per-critic agreed/availability scorecard and drop advice. Use for CR critic scores or /cr-scores.
---

# cr-scores

When the user asks for the critic scorecard, run:

    bash scripts/cr/cr-scores.sh [--window N]

`--window N` narrows to the last N PRs (default 20). Summarise the all-time +
windowed per-model table (total findings, agreed % — `fixed` verdicts count as
agreed, disproved %, conflict count, unaddressed count, availability %) and
surface the Advice lines verbatim ("insufficient evidence" or "low author
agreement; investigate", over the quality view's window). If the ledger is empty, report
"no critic scores recorded yet" and stop.
See `.claude/commands/cr-scores.md`.
