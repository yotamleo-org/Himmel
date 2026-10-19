---
key: "HIMMEL-6441"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T06:31:26.125+0200"
updated: "2026-10-19T06:31:26.244+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6441: tick ready-mismatch counts normal judge NO-GOs and raises ALERT on already-merged PRs

## Description

scripts/handover/console-kit/tick.sh ready_mismatch_scan (around 330-436). tick.sh is owned by open PR 3143 and is a trust path (HIMMEL-6307); fix after that PR merges. Related: HIMMEL-6074 (bound the scan by wall clock).
