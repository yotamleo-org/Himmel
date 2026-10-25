---
key: "HIMMEL-6115"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6173"
created: "2026-10-17T15:25:47.567+0200"
updated: "2026-10-18T12:28:30.503+0200"
resolution: "Done"
resolved: "2026-10-18T12:28:09.218+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6236"]
---

# HIMMEL-6115: residual-depth on judge, CR and panel residuals: depth 1 excluded from dispatch without a residual-must ruling, depth 2 filed to ICE

## Description

Files: scripts/handover/console-kit/write-verdict.sh, next-dispatchable.sh, judge brief template. Sequence after the priority-pool ticket (same next-dispatchable.sh).
PR #3079 (yotamleo/Himmel) merged @ a2bbed50bea9b758414bdcc3717a6a3f59fdde80. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
