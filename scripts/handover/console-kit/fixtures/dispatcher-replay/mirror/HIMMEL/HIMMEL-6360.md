---
key: "HIMMEL-6360"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6205"
created: "2026-10-18T17:08:13.701+0200"
updated: "2026-10-18T18:13:13.260+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6359"]
  blocked_by: ["HIMMEL-6364","HIMMEL-6366","HIMMEL-6386"]
  relates: ["relates to HIMMEL-6284","relates to HIMMEL-5495"]
---

# HIMMEL-6360: [docs-site] UI2: Config becomes Settings with frame-10 groups, Roadmap and Kanban shown per tracker source

## Description

Rename Config to Settings and regroup it as in mockup v4 frame 10. Show Roadmap and Kanban only when a tracker source the UI can read is configured. Correct docs/ui.md.
5. docs/ui.md: replace "never writes your configuration" with what each action writes: .env (HIMMEL_INITIATIVE), lanes.local.json, crontab and plugins.
- Files: scripts/config-ui/public/{index.html,render.js}, read-only feed fields in server.ts if needed, docs/ui.md, and a J3 spec.
