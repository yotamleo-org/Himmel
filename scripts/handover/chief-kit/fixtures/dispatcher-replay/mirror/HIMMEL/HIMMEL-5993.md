---
key: "HIMMEL-5993"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6229"
created: "2026-10-16T22:47:36.769+0200"
updated: "2026-10-19T09:49:32.852+0200"
resolution: "Done"
resolved: "2026-10-19T09:49:18.975+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5908","relates to HIMMEL-6068"]
---

# HIMMEL-5993: Fork merge gate hardening: four Low findings from the 5899 judge

## Description

Files: scripts/lib/go-gate.sh, scripts/handover/console-kit/go.sh, scripts/handover/merge-fork-pr.sh.
Done when: each has a RED row in scripts/handover/test-merge-fork-pr.sh, then green.
Findings 2-4 merged in PR 2923. Finding 1 (add go_fork_ready to the function-clear list and the load-check list in scripts/handover/console-kit/go.sh) is open: the unset -f line (185) and the declare -F checks (188-192) do not name it, while it is called at line 246. It waited on PR 2910, which is m
PR #3137 (yotamleo/Himmel) merged @ 5f4fb6a77e1f10a1e0b51609eaee9d87060d83b3. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
