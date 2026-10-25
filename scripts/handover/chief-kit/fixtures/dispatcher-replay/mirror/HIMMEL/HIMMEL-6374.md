---
key: "HIMMEL-6374"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["ci","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T18:03:48.469+0200"
updated: "2026-10-19T06:53:23.311+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6120"]
---

# HIMMEL-6374: himmel-vm guest cannot reach the Actions artifact blob host: upload-artifact steps likely fail on VM shards

## Description

Files: scripts/vm/ci-runner/egress-refresh.sh, .github/workflows/ci.yml (shell-unit-shard upload steps; a trust path). Relates HIMMEL-6120.
