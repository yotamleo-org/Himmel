---
key: "HIMMEL-6266"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-17T23:55:03.850+0200"
updated: "2026-10-18T02:42:34.734+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6266: VM guest-exec entry point on vmsdk with one allow rule, so VM-first installs need no operator

## Description

Give legs one sanctioned way to run commands inside a himmel test VM, built on the existing VM controller (scripts/lib/vmsdk.py and the himmel-ops:vm skill), with one permission rule. Installs inside a guest then run unattended, and the same commands on the station stay refused.
1. Add scripts/vm/guest-exec.sh <vm> -- <cmd> on vmsdk.py. It refuses any target that is not a himmel test VM it booted or restored (port and identity checked via vmsdk), and logs every command.
2. Add one allow rule in .claude/settings.json for that entry point only.
Files: scripts/vm/guest-exec.sh plus its test, scripts/lib/vmsdk.py (identity check), scripts/hooks/block-destructive-commands.sh and its test, a new raw-ssh deny hook or a row in an existing one, .claude/settings.json (one allow line), scripts/handover/console-kit/gen-briefs.py. Trust paths: script
