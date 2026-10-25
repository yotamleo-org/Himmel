---
key: "HIMMEL-6470"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T14:06:04.065+0200"
updated: "2026-10-19T14:06:04.177+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6470: Live-verify the CI_GCP on/off command and add the settings allow rule if it still prompts

## Description

After the HIMMEL-6431 PR merges, run gh variable set CI_GCP --body off -R yotamleo/Himmel from a live leg (or the console), read it back with gh variable list -R yotamleo/Himmel, and restore the prior value. If a denial or prompt appears, add the exact allow pattern to .claude/settings.json (after P
- Files: .claude/settings.json (only if needed).
