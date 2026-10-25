---
key: "HIMMEL-6475"
type: "Bug"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T15:35:22.111+0200"
updated: "2026-10-19T16:21:41.146+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6475: Skipped Claude critic (rc 5) is recorded as unavailable generic-rc-5 and runs fallbacks

## Description

1. scripts/cr/critic-panel.sh: branch on rc 5 before the failure path; queue the avail row as unavailable with reason critic-skipped and the SKIPPED stderr line as detail; skip the fallback chain and the attempt error row.
2. scripts/cr/failure-classify.sh: add a critic-skipped class for rc 5.
- RED then green row in scripts/cr/test-critic-panel.sh: an rc-5 member records critic-skipped, never generic-rc-5, and runs no fallback.
- A row in scripts/cr/test-failure-classify.sh for rc 5.
- bash scripts/quiet-run.sh suite -- bash scripts/cr/test-critic-panel.sh and the failure-classify and clear-cr-marker suites pass.
Files: scripts/cr/critic-panel.sh, scripts/cr/failure-classify.sh, scripts/cr/clear-cr-marker.sh, their test-*.sh. Impacted suites via scripts/cr/impacted-suites.sh. Related: HIMMEL-1870, HIMMEL-6419.
