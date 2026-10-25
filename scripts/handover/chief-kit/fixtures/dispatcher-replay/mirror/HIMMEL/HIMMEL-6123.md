---
key: "HIMMEL-6123"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6212"
created: "2026-10-17T15:55:04.298+0200"
updated: "2026-10-17T19:52:49.716+0200"
resolution: "Done"
resolved: "2026-10-17T19:52:20.376+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6140"]
---

# HIMMEL-6123: qmd embed and graphify semantic + AST on a 2-hour cadence for himmel and luna (claude-api semantic, OpenRouter embed and rerank)

## Description

Files: scripts/luna/qmd-cadence.sh, scripts/graphify/graph-cadence.sh (+ their arm/runner generators and suites). One-off operator refresh run 10-17 16:55 (konsole refresh-qmd-graphify-now) gives the first cost and runtime numbers: log in the console scratchpad refresh-now.log.
PR #3016 (yotamleo/Himmel) merged @ 9c9d56c599065f8863b48be9e777722c9e64d0ea. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
