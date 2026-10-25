---
key: "HIMMEL-6442"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["residual-depth-1","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T06:44:15.966+0200"
updated: "2026-10-19T06:44:16.066+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6442: jira CLI: comment --edit <id> so the backend-tier guard can route comment edits

## Description

1. Add an --edit <commentId> option to the comment command in scripts/jira/src, calling the Jira update-comment endpoint.
Files: scripts/jira/src (comment command), scripts/hooks/block-backend-tier.sh and its test. Target version 1.1.3, label residual-depth-1.
