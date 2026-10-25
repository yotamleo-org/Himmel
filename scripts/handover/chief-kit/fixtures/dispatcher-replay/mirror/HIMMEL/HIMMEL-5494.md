---
key: "HIMMEL-5494"
type: "Story"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["config-ui","operator-directed","sector2-visibility","theme-config-ui-himmelctl"]
fixVersions: []
parent: "HIMMEL-4943"
created: "2026-10-13T12:57:31.280+0200"
updated: "2026-10-17T18:14:33.760+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: ["HIMMEL-5495"]
  relates: []
---

# HIMMEL-5494: config-ui Kanban and Roadmap cover all projects by default; a --project flag narrows

## Description

- Today scripts/config-ui/roadmap.ts reads one mirror dir. Enumerate projects from the mirror root (~/.himmel/state/jira-mirror/<KEY>/) and/or the handover registry (~/.claude/handover/registry.json), and name the source in the README.
