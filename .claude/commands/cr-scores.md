---
description: Per-critic CR scorecard.
---

Run `bash scripts/cr/cr-scores.sh` (add `--window N` to narrow to the last N PRs; default 20).

Summarise the output:
1. Present the all-time and windowed per-model table (columns: total findings, agreed % — `fixed` verdicts count as agreed, disproved %, conflict count, unaddressed count, availability %).
2. Surface the Advice lines verbatim. They cover the quality view's window (default the trailing 14 days, `--since`/`--until` to choose) and recorded dispositions only: "insufficient evidence" under 30 decided findings or 10 PRs, "low author agreement; investigate" below `CR_SCORES_DROP_BELOW` (default 40) %. No line says to remove a reviewer.
3. If the ledger is empty, report the friendly "no critic scores recorded yet" message and stop.
