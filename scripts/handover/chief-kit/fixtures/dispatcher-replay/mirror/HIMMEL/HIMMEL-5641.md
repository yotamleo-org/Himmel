---
key: "HIMMEL-5641"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["sector2-cost"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-5654"
created: "2026-10-14T14:20:38.325+0200"
updated: "2026-10-19T10:06:01.960+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-5641: VM runner phase 2b follow-up: R4 live proof from main, ci.yml routing, j2574f review notes

## Description

Files: scripts/handover/console-kit/vm-runner.sh, scripts/himmel-doctor.sh, scripts/chokepoints.json, .github/workflows/ci.yml. Suites: test-vm-runner.sh, test-tick.sh, test-himmel-doctor.sh.
- (a) Register HIMMEL_VMRUN_PROBE and the vm-runner seams in scripts/chokepoints.json, especially HIMMEL_VM_RUNNER_VM_LIB, which sources a file.
PR #2867 (yotamleo/Himmel) merged @ e2148be2f04ed905563c4b2bf6cd74eaa7b50e05. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
- L6: scripts/vm/ is not in scripts/ci/ci-trust-paths.txt, so changes there get no trust-path review.
