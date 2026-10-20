---
key: "HIMMEL-6250"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-17T22:14:55.682+0200"
updated: "2026-10-18T02:42:29.628+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6250: block-destructive-commands still allowlists the deleted cli-proxy-lane.ps1

## Description

Remove the stale exemption for pwsh -file scripts/setup/cli-proxy-lane.ps1 -restart/-stop from the destructive-command guard, its marketplace mirror and its test.
1. Delete the .ps1 exemption rows in scripts/hooks/block-destructive-commands.sh and its marketplace/ mirror.
2. Delete the matching rows in scripts/hooks/test-block-destructive-commands.sh.
Files: scripts/hooks/block-destructive-commands.sh:246-257, its marketplace mirror, scripts/hooks/test-block-destructive-commands.sh:226-266, .gitleaks.toml. Hook edit: launch with the hook-integrity bypass flag. Trust path: yes (judge before GO). Merge after PR 3020.
