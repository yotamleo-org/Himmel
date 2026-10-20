---
key: "HIMMEL-5973"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: []
fixVersions: ["v1.1.3"]
parent: "HIMMEL-2763"
created: "2026-10-16T21:39:50.630+0200"
updated: "2026-10-18T01:21:20.671+0200"
resolution: "Done"
resolved: "2026-10-18T00:46:48.633+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-5970"]
---

# HIMMEL-5973: Console may run bounded scripts in the foreground (kill the background round trip)

## Description

Files: scripts/hooks/guard-console-foreground.sh, scripts/handover/console-kit/long-running.txt, console template. Keep the guard for unbounded commands. Relates to HIMMEL-5821, HIMMEL-5914, HIMMEL-5827. Source: HIMMEL-5970.
Design: docs/internals/console-ops-lane.md (PR in flight, branch feat/himmel-5973-console-ops-offload). The ops lane is the existing relay role (HIMMEL-2975 pieces already merged), plus console-kit/ops-run.sh: an allowlisted runner that prints one OPS ... PASS|FAIL|ESCALATE|TIMEOUT line and refuses
Slice merged: PR #2866, merge sha 642a0b7c554491fa3666e39f85e6967e3d3e2880 (design note docs/internals/console-ops-lane.md, ops-run.sh allowlisted runner + suite, relay brief ops duty). Remaining on this ticket: VM POC (1 console turn per event instead of 3) and the live-flow wiring PR.
PR #3009 (yotamleo/Himmel) merged @ 112fabc951f521cba604bc7a69fb5054a0bb6d5d. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Finding [Important]: the foreground exception in scripts/hooks/guard-console-foreground.sh:93 is not fully bounded. GNU timeout sends SIGTERM with no -k kill-after deadline, so a script that ignores or traps SIGTERM can still block the console. Proposed fix: require a bounded SIGKILL escalation (tim
