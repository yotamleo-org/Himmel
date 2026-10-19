---
key: "HIMMEL-6120"
type: "Bug"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["ci","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-17T15:38:07.551+0200"
updated: "2026-10-19T10:05:42.263+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6374"]
---

# HIMMEL-6120: himmel-vm CI runners fail setup-bun (bun missing after cache restore) and checkout (github.com refused): random shard reds on every PR

## Description

Files: scripts/handover/console-kit/vm-runner.sh, the ci-runner VM provisioning, .github/workflows/ci.yml setup-bun step. Related: HIMMEL-6034 (vm-runner status).
