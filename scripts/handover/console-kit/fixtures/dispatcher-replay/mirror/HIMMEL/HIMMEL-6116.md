---
key: "HIMMEL-6116"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-17T15:25:49.438+0200"
updated: "2026-10-18T02:42:25.504+0200"
resolution: "Done"
resolved: "2026-10-17T17:00:59.037+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6116: console.sh next refuses a HANDOFF whose decisions line is shorter than the predecessor's without a DECISIONS-DROP ruling

## Description

Files: scripts/handover/console/console.sh and its suite.
PR #3010 (yotamleo/Himmel) merged @ 8a1c832d0ebde270b01a67946ea401c8122d1e60. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
