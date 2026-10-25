---
key: "HIMMEL-6122"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["ci","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6196"
created: "2026-10-17T15:45:48.290+0200"
updated: "2026-10-19T12:34:57.074+0200"
resolution: "Done"
resolved: "2026-10-19T12:34:27.277+0200"
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6122: Nightly extended-tier reporter opens a red issue for a cancelled run, even after a newer nightly went green (GH #2999)

## Description

Files: .github/workflows/ci.yml shell-unit aggregator schedule leg and the script it calls (trust path). Unknown: who cancelled run 39029239710 at 13:03Z (no failed job; cancel-in-progress is pull_request-only) — check the audit log if available.
PR #3172 (yotamleo/Himmel) merged @ 8fef22e4e6740f21dd6976df46505526b6cc29ad. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
