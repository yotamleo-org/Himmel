---
key: "HIMMEL-5843"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "High"
labels: ["operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6173"
created: "2026-10-16T00:30:46.238+0200"
updated: "2026-10-19T04:06:27.595+0200"
resolution: "Done"
resolved: "2026-10-19T04:06:16.148+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6133"]
---

# HIMMEL-5843: Close the remaining dropped-work gaps: brief completes-ticket binds the merge, residuals must be ticketed at verdict/wrap, ICE-cited follow-ups surfaced

## Description

PR #3128 (yotamleo/Himmel) merged @ 463d1f279bbbe15f5b61d8fe196ace667d7d10ad. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
Part 3 merged: PR 3128, merge sha f68ac65e0702415fb75c772a63fd751b0d94b47d. Adds scripts/handover/console-kit/ice-followups.sh and an ice-followups=<n> field plus key list on the fleet board. Detection is read-only from the Jira mirror, so no per-key network call. A ticket moved to ICE without a mov
