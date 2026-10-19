---
key: "HIMMEL-6366"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-4943"
created: "2026-10-18T17:15:33.424+0200"
updated: "2026-10-19T06:53:06.433+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6360"]
  blocked_by: []
  relates: ["relates to HIMMEL-6284","relates to HIMMEL-3999","relates to HIMMEL-5495"]
---

# HIMMEL-6366: [config-ui] Roadmap and Kanban read GitHub issues as a tracker source

## Description

An adopter who tracks work in GitHub issues gets no Roadmap or Kanban in the himmel UI. Both pages read only a Jira mirror (scripts/config-ui/roadmap.ts, /api/roadmap), and the tracker seam has no GitHub backend (scripts/lib/tracker.sh has jira, local and none).
- Files: scripts/config-ui/roadmap.ts (or a sibling reader), server.ts (the predicate), one e2e spec.
