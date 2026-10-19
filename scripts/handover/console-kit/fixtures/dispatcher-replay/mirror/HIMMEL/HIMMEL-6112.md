---
key: "HIMMEL-6112"
type: "Story"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["agui","operator-directed"]
fixVersions: ["v1.1.4"]
parent: "HIMMEL-6192"
created: "2026-10-17T15:17:10.563+0200"
updated: "2026-10-17T18:44:41.640+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6112: AG-UI service: username/password login with a session cookie instead of the full token URL

## Description

1. scripts/config-ui/server.ts: a /login form that checks a hashed credential stored mode 600 under ~/.himmel/state, sets an HttpOnly SameSite=Strict session cookie bound to loopback; the token URL keeps working.
Files: scripts/config-ui/server.ts, scripts/himmelctl/lib/ui-service.js, their tests. Loopback only; no remote exposure in scope.
