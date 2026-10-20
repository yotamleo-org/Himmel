---
key: "HIMMEL-6303"
type: "Task"
status: "To Do"
statusCategory: "To Do"
priority: "Medium"
labels: ["operator-directed","standalone"]
fixVersions: ["v1.1.3"]
parent: null
created: "2026-10-18T03:17:52.318+0200"
updated: "2026-10-19T10:06:13.225+0200"
resolution: null
resolved: null
links:
  blocks: []
  blocked_by: []
  relates: []
---

# HIMMEL-6303: Review loop runs only for priority findings; everything else defers to a ticket with no new round, and a judge GO at the head counts as review for a post-cap delta

## Description

Files: scripts/cr/review-round.sh, scripts/cr/clear-cr-marker.sh, scripts/handover/console-kit/ready-check.sh, docs for /pr-check, and the leg preface (docs/handover/leg-sections). These are trust paths: opus judge plus trust-reviewed GO. Collision: N2610 (HIMMEL-6279) owns review-round.sh and its t
