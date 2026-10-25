---
key: "HIMMEL-6140"
type: "Task"
status: "Done"
statusCategory: "Done"
priority: "Highest"
labels: ["knowledge-critical","must-v1.1.3","operator-directed"]
fixVersions: ["v1.1.3"]
parent: "HIMMEL-6212"
created: "2026-10-17T16:37:29.796+0200"
updated: "2026-10-18T08:34:34.941+0200"
resolution: "Done"
resolved: "2026-10-18T08:34:15.128+0200"
links:
  blocks: []
  blocked_by: []
  relates: ["relates to HIMMEL-6137","relates to HIMMEL-6123"]
---

# HIMMEL-6140: K4: semantic re-extraction on claude-api across API accounts A and B

## Description

Q3: bash scripts/graphify/leg-graph.sh query "relationship between console sessions and implementation legs"
Metric mismatch noted by leg N2578: the ticket quotes 38 percent rationale coverage and about 350 cross-file semantic edges. Measured on the live himmel graph with the committed scripts/graphify/semantic-metrics.py before the re-extraction: all semantic nodes 10.7 percent (754 of 7026), model-made n
PR #3060 (yotamleo/Himmel) merged @ 52d02b21d9a3452c91c47da0a33901026254f083. scripts/handover/merge-on-green.sh is attempting to auto-transition this ticket to 'Done'.
