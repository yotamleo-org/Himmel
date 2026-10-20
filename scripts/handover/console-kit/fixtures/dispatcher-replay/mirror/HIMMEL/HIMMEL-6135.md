---
key: "HIMMEL-6135"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6158"
created: "2026-10-17T16:32:04.180+0200"
updated: "2026-10-18T04:11:30.329+0200"
resolution: "Done"
resolved: "2026-10-18T04:11:12.163+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-4580","relates to HIMMEL-4581","relates to HIMMEL-4277","relates to HIMMEL-4745","relates to HIMMEL-6247"]
---

# HIMMEL-6135: Cloud-lane capability map and cloud VM environment as code

## Description

PR #3037 (yotamleo/Himmel) merged @ 39e7705df60dcad54094a9720239cac65d8cf661. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
- Capability matrix: scripts/lanes/cloud-capabilities.json, 28 rows; cloud-route reads it.
- Environment change made from code: scripts/cloud/setup-env.sh installs gitleaks 8.30.1.
