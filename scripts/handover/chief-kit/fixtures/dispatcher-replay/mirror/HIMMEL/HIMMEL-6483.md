---
key: "HIMMEL-6483"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T16:45:05.662+0200"
updated: "2026-10-19T16:55:34.091+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6483: Roadmap tracker parity names the differing tickets and tells mirror lag from drift; console sees a stale published page

## Description

Files: the roadmap tracker renderer (tracker.py, find with grep "DRIFT page"), scripts/handover/console-kit/tick.sh, tests. Single-writer: tick.sh may be held by another leg; check open PRs first.
