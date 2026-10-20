---
key: "HIMMEL-1179"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Low"
labels: ["needs-standard","phase-0","theme-ship-loop-gates","unscheduled"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-6173"
created: "2026-07-18T08:34:22.733+0200"
updated: "2026-10-17T20:18:58.546+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-1179: Loop-hardening B3: CR convergence ratchet — ledger round counter + round-3 Important ratchet + contingent-findings prompt

## Description

1. Ledger-derived round counter (source-agnostic): scripts/cr/cr-rounds.sh <branch> = count distinct head values for the branch in cr-critic-scores.jsonl. /pr-check step 1 prints "CR round N for this branch".
