---
key: "HIMMEL-6131"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6190"
created: "2026-10-17T16:31:57.827+0200"
updated: "2026-10-19T17:33:04.300+0200"
resolution: "Done"
resolved: "2026-10-19T17:33:04.283+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6131: Stability scorecard: daily baseline and metric-per-ticket rule for v1.1.3

## Description

Left open: the operator runs bash scripts/eval/stability-scorecard.sh arm; this ticket closes only after the next-day row exists. The 6034 remainder (audit of other ok:N/M fields, tracker COMPLETE versus the live lock) is not done.
HIMMEL-6131 was already delivered by PR #3021 (merge d74763f26, 2026-10-17): scripts/eval/stability-scorecard.sh plus its test, the ticket-standard Metric rule plus its test, and the docs/cadences.md row. Leg N2798 re-verified it on 2026-10-19 and made no code change.
