---
key: "HIMMEL-6449"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["residual-depth-1","security","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T08:52:13.850+0200"
updated: "2026-10-19T15:06:47.956+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6449: cadence-approve-engines: nav, symlink and model-download containment gaps

## Description

- bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-cadence-approve-engines.sh passes.
Files: scripts/hooks/cadence-approve-engines.sh, scripts/hooks/test-cadence-approve-engines.sh. The hook is a trust path, so the PR needs a trust-reviewed GO.
