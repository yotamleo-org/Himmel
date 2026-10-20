---
key: "HIMMEL-6416"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T03:45:52.602+0200"
updated: "2026-10-19T17:16:02.246+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6406"]
---

# HIMMEL-6416: jira transition to Done leaves a versionless ticket versionless; 103 Done tickets have no fixVersion and the tick only counts them

## Description

- scripts/jira/src/commands/transition*.ts plus its test (then bun run build for dist);
- scripts/handover/console-kit/versionless-done.sh;
- scripts/handover/console-kit/tick.sh and its test.
