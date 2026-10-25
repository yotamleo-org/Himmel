---
key: "HIMMEL-6465"
type: "Task"
status: "IN CI"
statusCategory: "In Progress"
priority: "Medium"
labels: ["lanes","plugins","sector2-cost","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T13:19:43.219+0200"
updated: "2026-10-19T16:36:05.379+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-4018"]
---

# HIMMEL-6465: graphify skill refresh writes a profile-controlled plugin, not ~/.claude/skills

## Description

1. In scripts/lib/graphify-bin.sh, change _graphify_skill_refresh (called from sync_graphify in scripts/himmel-update.sh) to write the skill into a plugin directory that the himmel marketplace serves, not ~/.claude/skills/graphify.
2. Add graphify@himmel to the catalog in scripts/lanes/plugin-profiles.json and enable it in the profiles that use the graph.
3. Update the graphify tests and scripts/lanes/tests/fixtures.
- bash scripts/lib/test-graphify-bin.sh and the lane node tests pass.
Writer: _graphify_skill_refresh in scripts/lib/graphify-bin.sh. Skill source: the installed graphifyy package. Link: HIMMEL-4018. Out of scope for that ticket on purpose.
