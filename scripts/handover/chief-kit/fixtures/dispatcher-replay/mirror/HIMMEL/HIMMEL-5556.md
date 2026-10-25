---
key: "HIMMEL-5556"
type: "Task"
status: "In Progress"
statusCategory: "In Progress"
priority: "Medium"
labels: ["ci","theme-test-signal"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-13T20:22:50.379+0200"
updated: "2026-10-19T16:56:01.132+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5556: ci: collapse shell-unit shards on PRs now that per-shard required contexts are dropped

## Description

- Start from scripts/ci/pr-plan.sh (shard count output) and the shell-unit-shard matrix in .github/workflows/ci.yml; the aggregator must still verify every shard manifest that ran.
