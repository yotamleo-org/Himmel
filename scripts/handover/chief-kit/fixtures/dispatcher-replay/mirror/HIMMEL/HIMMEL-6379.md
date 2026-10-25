---
key: "HIMMEL-6379"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6173"
created: "2026-10-18T18:11:58.655+0200"
updated: "2026-10-18T18:15:05.717+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6371"]
---

# HIMMEL-6379: CR loop S3: single residual writer with a per-version budget (polish to backlog, overflow to backlog)

## Description

1. Add the residual verb to scripts/jira/src/**. It:
- Trust paths: only the scripts/jira part is outside them. The rest needs an opus judge and a trust-reviewed GO.
