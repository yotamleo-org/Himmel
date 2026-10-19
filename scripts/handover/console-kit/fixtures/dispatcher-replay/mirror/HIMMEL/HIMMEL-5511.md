---
key: "HIMMEL-5511"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["cost-reduction","operator-directed","sector2-visibility","theme-bank-ci-cost","unscheduled"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-2763"
created: "2026-10-13T14:39:22.239+0200"
updated: "2026-10-18T08:09:03.886+0200"
resolution: "Done"
resolved: "2026-10-18T08:08:29.406+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5511: tick.sh compact line: drop empty/default fields, inbox= only for unread inboxes

## Description

- Files: scripts/handover/console-kit/tick.sh, test-tick.sh, console-wait.sh (if it parses fields), and board.mjs (if it parses the tick).
PR #3049 (yotamleo/Himmel) merged @ e7c72fcf96d71b4e76bc0cdc87cd4b078f32a500. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
