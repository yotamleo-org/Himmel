---
key: "HIMMEL-6114"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-3744"
created: "2026-10-17T15:25:45.884+0200"
updated: "2026-10-17T23:16:32.980+0200"
resolution: "Done"
resolved: "2026-10-17T23:15:57.547+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6114: next-dispatchable ranks by operator priority list first and the console fills free slots only from the priority pool

## Description

Files: scripts/handover/console-kit/next-dispatchable.sh, console-wait.sh, gen-briefs.py, docs/handover/console-sections/. Collides with HIMMEL-6111 (PR 2998, same files): cut after 2998 merges.
PR #3032 (yotamleo/Himmel) merged @ 28228f89e0aee53c8bf21bad9338956a719bae76. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
