---
key: "HIMMEL-6005"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6194"
created: "2026-10-16T23:39:47.561+0200"
updated: "2026-10-18T01:42:17.952+0200"
resolution: "Done"
resolved: "2026-10-18T01:42:17.921+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6005: Run the added-but-unwired check at /pr-check round 1, not only at ready-check

## Description

Run the added-but-unwired check (scripts/ci/check-added-unwired.sh, the same logic as ready-check item 11) inside /pr-check round 1 and in the pre-push gate. Any new script then gets its wiring before the first review round instead of after the last.
Files: scripts/cr/ (the /pr-check round-1 path) or the pre-push gate config, plus scripts/ci/check-added-unwired.sh as the shared check.
PR #3039 (yotamleo/Himmel) merged @ 9db294e855784eae11a42c38acb20b681d82164e. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
