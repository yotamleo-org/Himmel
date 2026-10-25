---
key: "HIMMEL-6387"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T18:12:30.307+0200"
updated: "2026-10-18T18:13:14.692+0200"
resolution: null
resolved: null
links:
  blocks: ["HIMMEL-6385"]
  blocked_by: []
  relates: ["relates to HIMMEL-6372","relates to HIMMEL-6284"]
---

# HIMMEL-6387: docs: replace the One change and Console tabs of loops-and-graphs with a dev-graph link

## Description

Once the development graph ships, the "One change" and "Console" tabs of docs/guide/loops-and-graphs.html describe the same loop a second time, by hand, with no drift check.
- scripts/docs/test-site-guides.sh passes; no dead tab id remains.
- Files: docs/guide/loops-and-graphs.html only.
