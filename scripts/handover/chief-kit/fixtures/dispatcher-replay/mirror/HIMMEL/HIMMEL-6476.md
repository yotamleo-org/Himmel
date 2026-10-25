---
key: "HIMMEL-6476"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T16:01:58.016+0200"
updated: "2026-10-19T16:01:58.125+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6476: Leg launches carry an opt-in API-lane switch so the PR critic runs on API credit

## Description

1. Add an opt-in profile or config key read by scripts/handover/console-kit/headed-arm-leg.sh that puts both variables into the leg environment.
3. Document the switch in docs/internals/enforcement.md (Claude invocation billing).
Files: scripts/handover/console-kit/headed-arm-leg.sh, launch-profile code; scripts/cr/critic-first-pass.sh read only. Follows HIMMEL-6475; re-arm HIMMEL-6419 after about 20 real runs.
