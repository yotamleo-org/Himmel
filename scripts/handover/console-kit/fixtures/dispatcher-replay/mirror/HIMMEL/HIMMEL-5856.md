---
key: "HIMMEL-5856"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6175"
created: "2026-10-16T01:26:08.683+0200"
updated: "2026-10-18T08:13:45.339+0200"
resolution: "Done"
resolved: "2026-10-18T08:13:06.810+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5416"]
---

# HIMMEL-5856: clear-cr-marker trivial-descendant path (HIMMEL-5416) writes no status=ok ledger row for the new head, so ready-check item 4 fails at a READY head

## Description

scripts/cr/clear-cr-marker.sh trivial-descendant path (HIMMEL-5416) gates on the reviewed head and writes no status=ok row to .git/cr-critic-scores.jsonl for the new head. scripts/handover/console-kit/ready-check.sh item 4 requires a status=ok row whose head equals the READY head. Found on PR 2773 (
PR #3074 (yotamleo/Himmel) merged @ 6c8588baab8b064c7dfac18d24e44a7660eaf28a. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
