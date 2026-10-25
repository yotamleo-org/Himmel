---
key: "HIMMEL-6386"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T18:12:27.527+0200"
updated: "2026-10-18T18:13:13.218+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6385","HIMMEL-6359","HIMMEL-6360"]
  blocked_by: []
  relates: ["relates to HIMMEL-6372","relates to HIMMEL-6284"]
---

# HIMMEL-6386: feat(config-ui): Workflow page showing the development graph

## Description

2. server.ts gets a read-only /dev-graph/<file> route confined by realpath to docs/guide/dev-graph/ (shape of the existing /agui/ handler).
- Operator review locally via node scripts/himmelctl/bin.js ui.
- Files: scripts/config-ui/public/nav.js, scripts/config-ui/server.ts, scripts/config-ui/public/{index.html,app.js}, new scripts/config-ui/tests/e2e/dev-graph-ui.spec.ts.
