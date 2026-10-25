---
key: "HIMMEL-6078"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6176"
created: "2026-10-17T09:07:34.045+0200"
updated: "2026-10-17T18:51:22.486+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6078: known-findings --refresh --learnings: a stop-word-only high-usage row yields an empty PROPOSE-CLASS match

## Description

1. In the cluster step of scripts/cr/known-findings.sh, drop a cluster whose phrase is empty.
2. Add a test row in scripts/cr/test-known-findings.sh: one row with 25 or more uses and only stop words.
- bash scripts/cr/test-known-findings.sh passes, including the new row, which fails before the fix.
Files: scripts/cr/known-findings.sh (cluster loop for single high-usage rows), scripts/cr/test-known-findings.sh. Suite: test-known-findings.sh.
