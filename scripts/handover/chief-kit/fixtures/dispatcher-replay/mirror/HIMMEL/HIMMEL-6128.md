---
key: "HIMMEL-6128"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed","security"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-513"
created: "2026-10-17T16:22:37.703+0200"
updated: "2026-10-18T09:27:14.767+0200"
resolution: "Done"
resolved: "2026-10-18T09:27:05.326+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6342"]
---

# HIMMEL-6128: telegram: stop <KEY> halts nothing (no reader of the stop marker), and a non-operator can spawn or un-park ticket sessions

## Description

Judge j3008a on PR 3008 (HIMMEL-5820), 10-17: (1) nothing in the tree reads the session stop marker (git grep finds only the writer, scripts/telegram/poller.ts:559), so stop was nominal even before 5820; (2) a non-operator can create or spawn ticket-session runs and un-park a failed one (poller.ts:6
Files: scripts/telegram/poller.ts, scripts/telegram/run.ts (or the runner that owns ticket sessions), their tests. Judge before GO (security).
PR #3080 (yotamleo/Himmel) merged @ 12b93ad1a8379b0d091c4cbb89c2eb0ad0d5ea99. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
