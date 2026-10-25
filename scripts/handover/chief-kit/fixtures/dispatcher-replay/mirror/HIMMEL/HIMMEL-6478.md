---
key: "HIMMEL-6478"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T16:07:25.879+0200"
updated: "2026-10-19T16:07:26.123+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6478: Dispatcher hides real v1.1.3 work behind false collisions and a priority-only underfill wake

## Description

5. Warn when a ticket names a file path that does not exist (6034 names scripts/handover/tick.sh), since the collision check is then silently off.
Files: scripts/handover/console-kit/next-dispatchable.sh, scripts/handover/console-kit/console-wait.sh, their tests. Single-writer: PR 3199 (HIMMEL-6261) also edits next-dispatchable.sh; start after it merges. Scratch evidence: nddbg.py and ndfix.py in console R's session scratchpad.
