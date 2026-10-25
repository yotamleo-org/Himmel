---
key: "HIMMEL-6487"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T17:12:27.698+0200"
updated: "2026-10-19T17:12:27.825+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6487: Turning GCP CI off cancels and reruns every job still queued on the GCP runner label

## Description

1. A drain step (scripts/ci/gcp-runners.sh drain, or in the off path of watch and of the autoscaler) that lists queued and orphaned in_progress jobs with the gcp label on same-repo runs, cancels those runs and reruns them (gh run cancel + gh run rerun --failed or a fresh rerun).
Files: scripts/ci/gcp-runners.sh (owned by HIMMEL-6471 until it merges), scripts/ci/gcp-runner-autoscale.sh, scripts/handover/console-kit/tick.sh, tests. Related: HIMMEL-6482, HIMMEL-6431.
