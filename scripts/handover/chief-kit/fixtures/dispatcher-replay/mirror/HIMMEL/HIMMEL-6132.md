---
key: "HIMMEL-6132"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6221"
created: "2026-10-17T16:32:00.189+0200"
updated: "2026-10-18T01:21:22.462+0200"
resolution: "Done"
resolved: "2026-10-18T00:43:33.183+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5217","relates to HIMMEL-5826","relates to HIMMEL-5217","relates to HIMMEL-5826","relates to HIMMEL-6246"]
---

# HIMMEL-6132: Remaining-only v1.1.3 roadmap board (tracker open-tickets render mode)

## Description

PR #3031 (yotamleo/Himmel) merged @ 93c213d1f3439c128e0fdfe79f70a5e94357e83a. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Finding [Important]: --remaining in scripts/handover/console-kit/tracker.py:1011 does not check that the mirror directory exists before read_mirror() globs it. A missing or mistyped mirror therefore yields a successful "0 open" board, which can overwrite a valid board with an empty state.
