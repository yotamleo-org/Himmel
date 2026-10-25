---
key: "HIMMEL-6461"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["residual-depth-1","security","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-19T11:33:57.284+0200"
updated: "2026-10-19T11:34:07.738+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6461: console-wait inbox path and write-verdict byte-guard before their allow rules

## Description

2. scripts/hooks/guard-pr-check-literal.sh HTARGETS (lines 74-75) adds scripts/handover/console-kit/write-verdict.sh, with the same byte-compare against the anchor as go.sh. This is a hook edit, so it needs the hook-integrity bypass.
4. scripts/cr/anchor-handoff.sh:61-62 says no prefix rule reaches scripts/handover/, which is false: fix the comment or make it true.
5. Re-add the console-wait.sh:* and write-verdict.sh:* allow rules in .claude/settings.json.
Files: scripts/handover/console-kit/console-wait.sh, scripts/hooks/guard-pr-check-literal.sh, scripts/cr/anchor-handoff.sh, .claude/settings.json. Related: HIMMEL-3724, HIMMEL-6445.
