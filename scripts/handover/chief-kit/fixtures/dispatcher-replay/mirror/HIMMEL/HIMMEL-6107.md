---
key: "HIMMEL-6107"
type: "Bug"
status: "Done"
statusCategory: "Done"
priority: "Medium"
labels: ["handover","merge"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6177"
created: "2026-10-17T14:20:36.701+0200"
updated: "2026-10-17T23:44:56.118+0200"
resolution: "Done"
resolved: "2026-10-17T23:44:33.827+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6133"]
---

# HIMMEL-6107: pr-merge.sh bare merge still prints would auto-transition to Done; report status unchanged like merge-on-green

## Description

1. scripts/handover/pr-merge.sh ~328: replace the "would auto-transition … to 'Done'" line with a status-unchanged line.
2. scripts/handover/test-pr-merge.sh ~524: update the assertion; add a lacks-row for "would auto-transition".
Mirror merge-on-green's bare result shape: skip=partial key=<key> status-unchanged. Trust path check: run scripts/ci/ci-trust-paths.txt match on the diff before READY.
Judge LOW residual from PR #2994 (j2994b): the usage header of scripts/handover/merge-on-green.sh, lines 60-61, still says a PARTIAL (bare) merge returns the ticket to To Do. Since #2994 a bare merge leaves the status unchanged and only posts the Remaining comment. Reword the header alongside the pr
PR #3042 (yotamleo/Himmel) merged @ e32605677ac1a1b34675cce23658aa7f6df526ff. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
