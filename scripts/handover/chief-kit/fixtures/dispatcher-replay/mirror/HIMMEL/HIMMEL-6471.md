---
key: "HIMMEL-6471"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["standalone"]
fixVersions: []
parent: null
created: "2026-10-19T14:08:55.109+0200"
updated: "2026-10-19T16:35:30.701+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6471: gcp-runners up quota preflight: handle extended-memory custom machine types

## Description

1. In scripts/ci/gcp-runners.sh cmd_up, drop a trailing -ext before the custom-type vCPU parse.
2. Add a test row in scripts/ci/test-gcp-runners.sh with GCP_RUNNERS_MACHINE=n2-custom-4-32768-ext that creates the VM.
- bash scripts/ci/test-gcp-runners.sh passes with the new row, RED before the change.
Files: scripts/ci/gcp-runners.sh, scripts/ci/test-gcp-runners.sh. Found in the HIMMEL-6435 review (PR 3190, finding codex-1 at ea57d998). scripts/ci is a trust path.
