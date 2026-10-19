---
key: "HIMMEL-6488"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["ci","flaky-test","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T17:15:03.296+0200"
updated: "2026-10-19T17:29:27.076+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6488: Config UI service-mode test reads one stdout chunk, flakes red on unrelated PRs

## Description

1. In scripts/config-ui/tests/service-mode.test.ts launch(), accumulate stdout chunks until the first newline (with a deadline), then match the first line.
Files: scripts/config-ui/tests/service-mode.test.ts (launch(), ~line 26-31: a single p.stdout.getReader().read() then an anchored regex; a partial chunk gives m === null). Passes 4/4 locally on main 96101f2c. Suite: bun test scripts/config-ui/tests/service-mode.test.ts.
