---
key: "HIMMEL-6381"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6176"
created: "2026-10-18T18:12:03.469+0200"
updated: "2026-10-18T18:12:16.065+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6371"]
---

# HIMMEL-6381: CR loop S5: restructure trigger files one ticket per recurring finding class and folds its residuals

## Description

- Leaders: scripts/hooks fail-open in 56 PRs, scripts/hooks quoting in 49, and console-kit race in 20.
- Files: either known-findings.sh --recurrence or a new scripts/cr/class-recurrence.sh. Both are trust paths. The slice runs after S1, which shares known-findings.sh.
