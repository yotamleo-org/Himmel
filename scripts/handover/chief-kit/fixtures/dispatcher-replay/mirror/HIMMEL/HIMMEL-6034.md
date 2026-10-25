---
key: "HIMMEL-6034"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["audit-6022","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6191"
created: "2026-10-17T02:11:34.973+0200"
updated: "2026-10-19T10:06:27.024+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6034: Cross-check vm-runner and other ok:N/M status fields against ground truth

## Description

- Files: scripts/handover/tick.sh (field vm-runner: gains "(online R)"), the vm-runner status script, himmelctl/doctor probes, plus tests.
