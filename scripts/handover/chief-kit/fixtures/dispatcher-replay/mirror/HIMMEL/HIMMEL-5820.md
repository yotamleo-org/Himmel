---
key: "HIMMEL-5820"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-15T22:29:41.402+0200"
updated: "2026-10-18T02:41:24.472+0200"
resolution: "Done"
resolved: "2026-10-17T16:25:14.262+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5820: telegram: stop <KEY> from a group member halts a ticket session with no fromOperator check

## Description

- Route: scripts/telegram/router.ts control route ^stop\s+(\S+)$; handler in scripts/telegram/poller.ts (fromOperator is resolved once in handleInbound).
- Suites: scripts/telegram/poller.test.ts, scripts/telegram/router.test.ts.
PR #3008 (yotamleo/Himmel) merged @ ecd936e0c247cc682732c32ac9ed505dd62c96da. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
