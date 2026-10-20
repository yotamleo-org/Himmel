---
key: "HIMMEL-6119"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6168"
created: "2026-10-17T15:38:05.663+0200"
updated: "2026-10-19T09:20:06.722+0200"
resolution: "Done"
resolved: "2026-10-19T09:20:06.700+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6450"]
---

# HIMMEL-6119: A leg's test run can exhaust station memory and get OOM-killed: cap each leg's memory and bound the qmd fork burst test

## Description

Files: scripts/handover/console-kit/headed-arm-leg.sh and its suite; qmd fork test/mcp-query-burst.test.ts. Detection of the dead window is HIMMEL-6118.
- Step 1 (per-leg MemoryMax scope): on main at 03b5a1399 (PR 3083); suite rows at scripts/handover/console-kit/test-headed-arm-leg.sh:4290.
