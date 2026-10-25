---
key: "HIMMEL-6431"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T05:26:29.458+0200"
updated: "2026-10-19T14:28:35.928+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6431: Allow agents to flip the CI_GCP kill switch: narrow block-destructive-commands carve-out for gh variable set CI_GCP on/off

## Description

3. If the permission allowlist in .claude/settings.json must also list it, add that exact pattern.
- Files: scripts/hooks/block-destructive-commands.sh, scripts/hooks/test-block-destructive-commands.sh, maybe .claude/settings.json allow list.
