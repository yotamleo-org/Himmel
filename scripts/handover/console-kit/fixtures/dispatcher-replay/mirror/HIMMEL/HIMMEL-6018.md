---
key: "HIMMEL-6018"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "High"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6174"
created: "2026-10-17T01:03:19.234+0200"
updated: "2026-10-19T07:32:23.958+0200"
resolution: "Done"
resolved: "2026-10-19T07:32:11.424+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6018: feat(cr): knockout gate — revert the non-test half of a diff in a scratch worktree and require ≥1 impacted suite to fail

## Description

PR 3076 (knockout gate, scripts/ci/knockout-gate.sh) residuals from the judge, not fixed in that PR; for the remaining slice of this ticket:
PR 3076 (knockout gate, scripts/ci/knockout-gate.sh), second batch of judge residuals (jC3076), not fixed in that PR; for the remaining slice of this ticket:
PR #3147 (yotamleo/Himmel) merged @ 794aaefc33c903ecaaecf19c8e71b0e29452bcc0. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
