---
key: "HIMMEL-5826"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6221"
created: "2026-10-15T23:16:54.606+0200"
updated: "2026-10-18T08:43:59.709+0200"
resolution: "Done"
resolved: "2026-10-18T08:43:38.211+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6132","relates to HIMMEL-6132","relates to HIMMEL-6325","relates to HIMMEL-6339"]
---

# HIMMEL-5826: Version-hygiene residuals from j2753a: merge-on-green fixVersion move and tracker done-in-future

## Description

Files: scripts/handover/console-kit/merge-on-green.sh, scripts/handover/console-kit/tracker.py and their tests.
Linked to HIMMEL-6132 (PR 3031). Done there: item 1 (merge-on-green.sh looks up versions with the ticket's own project), item 4 (done-in-future already covered every unreleased version; a guard row now pins it), item 5 (tracker.py whitespace nit). Re-scoped: this ticket stays open for items 2 and 3
PR #3073 (yotamleo/Himmel) merged @ 93bcc5c0eaf4d975e0e93fc86ddcce3a9f77043a. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
